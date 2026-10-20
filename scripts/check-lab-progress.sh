#!/usr/bin/env bash

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
work_dir="$repo_root/work"
vm_name="lab-k8s-01"
vm_user="labadmin"
managed_title="microsegmentation-iac-lab-k8s-01"
namespace="netpol-test"
namespace_owner="microsegmentation-iac"
minimum_guest_free_kib=$((84 * 1024 * 1024))
recommendation=""
unhealthy_pods="unknown"
started_vm=false

recommend() {
  if [[ -z "$recommendation" ]]; then
    recommendation="$1"
  fi
}

for command_name in virsh ssh jq awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required on the physical QEMU/KVM host.\n' "$command_name" >&2
    exit 1
  fi
done

printf 'Lab progress snapshot: %s\n\n' "$(date --iso-8601=seconds)"

printf '%s\n' '--- Host readiness ---'
if bash "$script_dir/00-host-preflight/check-host.sh"; then
  printf 'PASS host preflight\n'
else
  printf 'FAIL host preflight\n'
  recommend "Resolve host preflight failures: bash scripts/00-host-preflight/check-host.sh"
fi

printf '\n%s\n' '--- Outer lab VM ---'
if ! virsh -c qemu:///system dominfo "$vm_name" >/dev/null 2>&1; then
  printf 'FAIL %s does not exist\n' "$vm_name"
  recommend "Create the outer VM: bash scripts/10-create-lab-vm/provision-lab-vm.sh"
  printf '\nNEXT: %s\n' "$recommendation"
  exit 1
fi

vm_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
vm_state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
if [[ "$vm_title" != "$managed_title" ]]; then
  printf 'FAIL managed ownership marker mismatch: %s\n' "${vm_title:-none}"
  recommend "Verify the VM manually; the status script will not proceed on an unowned VM."
  printf '\nNEXT: %s\n' "$recommendation"
  exit 1
elif [[ "$vm_state" != running ]]; then
  printf 'WARN %s state: %s\n' "$vm_name" "$vm_state"
  if [[ "$vm_state" != "shut off" ]]; then
    printf 'Verification incomplete: resolve VM state manually before retrying.\n'
    exit 1
  fi
  if [[ ! -t 0 ]]; then
    printf 'Verification incomplete: no interactive terminal available to approve powering on the VM.\n'
    printf '\nNEXT: Run bash scripts/check-lab-progress.sh interactively to approve starting the VM.\n'
    exit 1
  fi
  while true; do
    if ! read -r -p "Power on $vm_name and continue verification? [y/N] " answer; then
      printf '\nVerification incomplete: no power-on approval received.\n'
      exit 1
    fi
    case "${answer,,}" in
      y|yes) break ;;
      ""|n|no)
        printf 'Leaving VM powered off; verification incomplete.\n'
        exit 1
        ;;
      *) printf 'Answer yes or no.\n' ;;
    esac
  done
  if ! virsh -c qemu:///system start "$vm_name"; then
    printf 'FAIL could not power on %s; verification incomplete.\n' "$vm_name"
    exit 1
  fi
  started_vm=true
  vm_state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
  printf 'Waiting up to 5 minutes for the guest network and SSH.\n'
else
  printf 'PASS %s is running and project-managed\n' "$vm_name"
fi

disk_info=$(virsh -c qemu:///system domblkinfo "$vm_name" vda 2>/dev/null || true)
disk_capacity_bytes=$(awk '$1 == "Capacity:" { print $2; exit }' <<< "$disk_info")
if [[ "$disk_capacity_bytes" =~ ^[0-9]+$ ]]; then
  printf 'Outer disk capacity: %s GiB\n' "$(((disk_capacity_bytes + 1073741823) / 1073741824))"
fi

ssh_key="$work_dir/${vm_name}_ed25519"
known_hosts="$work_dir/${vm_name}_known_hosts"
if [[ ! -r "$ssh_key" ]]; then
  printf 'FAIL SSH key missing: %s\n' "$ssh_key"
  recommend "Restore the project SSH key or use the VM console; do not regenerate it without checking guest authorized_keys."
  printf '\nNEXT: %s\n' "$recommendation"
  exit 1
fi
ssh_options=(
  -i "$ssh_key"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$known_hosts"
)
boot_deadline=$((SECONDS + 300))
while true; do
  guest_ip=$(virsh -c qemu:///system domifaddr "$vm_name" --source lease 2>/dev/null |
    awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }')
  if [[ -z "$guest_ip" && "$vm_state" == running && "$vm_title" == "$managed_title" ]]; then
    guest_mac=$(virsh -c qemu:///system domiflist "$vm_name" |
      awk '$3 == "default" { print tolower($5); exit }')
    interface_json=$(virsh -c qemu:///system qemu-agent-command "$vm_name" \
      '{"execute":"guest-network-get-interfaces"}' 2>/dev/null || true)
    if [[ -n "$interface_json" ]]; then
      guest_ip=$(jq -r --arg mac "$guest_mac" \
        '.return[] | select((."hardware-address" // "" | ascii_downcase) == $mac) | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("169.254.") | not)) | .["ip-address"]' \
        <<< "$interface_json" | awk 'NR == 1 { print; exit }')
      if [[ -n "$guest_ip" ]]; then
        printf 'Guest IP: %s (QEMU guest agent; DHCP lease unavailable)\n' "$guest_ip"
      fi
    fi
  fi

  if [[ -n "$guest_ip" ]]; then
    destination="$vm_user@$guest_ip"
    if ssh "${ssh_options[@]}" "$destination" true >/dev/null 2>&1; then
      break
    fi
  fi
  if [[ "$started_vm" != true ]] || (( SECONDS >= boot_deadline )); then
    break
  fi
  sleep 5
done

if [[ -z "$guest_ip" ]]; then
  printf 'FAIL no DHCP lease or guest-agent IPv4 available\n'
  recommend "Diagnose guest networking: bash scripts/20-install-k3s-kubevirt/repair-guest-network.sh --diagnose"
  printf '\nNEXT: %s\n' "$recommendation"
  exit 1
fi

destination="$vm_user@$guest_ip"
if ! ssh "${ssh_options[@]}" "$destination" true >/dev/null 2>&1; then
  printf 'FAIL SSH unavailable at %s\n' "$guest_ip"
  recommend "Diagnose/recover the managed guest network: bash scripts/20-install-k3s-kubevirt/repair-guest-network.sh --diagnose"
  printf '\nNEXT: %s\n' "$recommendation"
  exit 1
fi
printf 'PASS SSH reachable at %s\n' "$guest_ip"

guest_disk=$(ssh "${ssh_options[@]}" "$destination" 'df -Pk /')
guest_free_kib=$(awk 'NR == 2 { print $4 }' <<< "$guest_disk")
if [[ "$guest_free_kib" =~ ^[0-9]+$ ]]; then
  printf 'Guest root free space: %s GiB\n' "$((guest_free_kib / 1024 / 1024))"
  if (( guest_free_kib < minimum_guest_free_kib )); then
    recommend "Expand the outer VM disk: bash scripts/10-create-lab-vm/resize-lab-vm-disk.sh 130"
  fi
else
  printf 'WARN could not parse guest root free space\n'
fi

node_json=$(ssh "${ssh_options[@]}" "$destination" 'sudo -n k3s kubectl get nodes -o json' 2>/dev/null || true)
pods_json=$(ssh "${ssh_options[@]}" "$destination" 'sudo -n k3s kubectl get pods -A -o json' 2>/dev/null || true)
if [[ -z "$node_json" || -z "$pods_json" ]]; then
  printf 'FAIL could not query Kubernetes resources\n'
  recommend "Inspect the cluster: bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh"
else
  node_ready=$(jq -r '(.items | length) > 0 and all(.items[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))' <<< "$node_json")
  # Task 30 launcher pods are reported in their own section.
  unhealthy_pods=$(jq -r --arg ns "$namespace" '[.items[] | select(.metadata.namespace != $ns) | select(.status.phase != "Succeeded") | select(.status.phase != "Running" or any((.status.containerStatuses // [])[]; .ready != true))] | length' <<< "$pods_json")
  if [[ "$node_ready" == true && "$unhealthy_pods" == 0 ]]; then
    printf 'PASS Kubernetes node Ready; all pods Running/ready\n'
  else
    printf 'WARN Kubernetes nodeReady=%s; unhealthyPods=%s\n' "$node_ready" "$unhealthy_pods"
    recommend "Inspect the cluster: bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh"
  fi
fi

printf '\n%s\n' '--- Local inputs (tasks 20/25) ---'
for file_path in "$work_dir/kubeconfig-${vm_name}.yaml" \
  "$work_dir/Rocky-10-latest-x86_64-minimal.iso" \
  "$work_dir/ubuntu-24.04.5-live-server-amd64.iso" \
  "$work_dir/windows-server-2025-evaluation.iso"; do
  if [[ -s "$file_path" ]]; then
    printf 'PASS %s\n' "${file_path#"$repo_root/"}"
  else
    printf 'FAIL missing %s\n' "${file_path#"$repo_root/"}"
    case "$file_path" in
      *kubeconfig*) recommend "Re-export kubeconfig by rerunning: bash scripts/20-install-k3s-kubevirt/setup-k3s-kubevirt.sh" ;;
      *) recommend "Stage guest media per scripts/25-prepare-guest-images/README.md" ;;
    esac
  fi
done

# Events expire after ~1h, so also check the template for the known schema-1 image.
virtio_image_ref=$(awk -F'"' '/^virtio_disk_image=/ { print $2; exit }' "$script_dir/30-create-kubevirt-vms/create-test-vms.sh")
virtio_image_known_bad=false
if [[ "$virtio_image_ref" == "quay.io/kubevirt/virtio-container-disk" || "$virtio_image_ref" == "quay.io/kubevirt/virtio-container-disk:latest" ]]; then
  virtio_image_known_bad=true
  printf 'BLOCKED task 30 Windows VirtIO image is the known schema-1 image: %s\n' "$virtio_image_ref"
else
  printf 'INFO task 30 Windows VirtIO image: %s\n' "$virtio_image_ref"
fi
fix_virtio_recommendation="Fix the Windows VirtIO container-disk reference (virtio_disk_image) to an OCI/schema-2-compatible image in scripts/30-create-kubevirt-vms/create-test-vms.sh, then rerun this status check before resuming task 30."

namespace_json=$(ssh "${ssh_options[@]}" "$destination" \
  "sudo -n k3s kubectl get namespace '$namespace' --ignore-not-found -o json" 2>/dev/null || true)
if [[ -z "$namespace_json" ]]; then
  printf '\nTask 30 namespace: not created\n'
  if [[ "$virtio_image_known_bad" == true ]]; then
    recommend "$fix_virtio_recommendation"
  fi
  recommend "Create and boot-check the guest VM resources: bash scripts/30-create-kubevirt-vms/create-test-vms.sh"
  printf '\nNEXT: %s\n' "$recommendation"
  exit 0
fi

namespace_manager=$(jq -r '.metadata.labels["microsegmentation-lab/managed-by"] // ""' <<< "$namespace_json")
if [[ "$namespace_manager" != "$namespace_owner" ]]; then
  printf '\nTask 30 namespace exists but is not project-managed; refusing to recommend writes.\n'
  recommend "Inspect namespace $namespace manually; do not let the creator reuse it."
  printf '\nNEXT: %s\n' "$recommendation"
  exit 1
fi

resources_json=$(ssh "${ssh_options[@]}" "$destination" \
  "sudo -n k3s kubectl get pvc,dv,vm,vmi,pods -n '$namespace' -o json" 2>/dev/null || true)
events_json=$(ssh "${ssh_options[@]}" "$destination" \
  "sudo -n k3s kubectl get events -n '$namespace' -o json" 2>/dev/null || true)
if [[ -z "$resources_json" ]]; then
  printf '\nTask 30 namespace is project-managed; resource query failed.\n'
  recommend "Inspect task 30 resources before retrying."
  printf '\nNEXT: %s\n' "$recommendation"
  exit 1
fi

printf '\n%s\n' '--- Task 30 resources ---'
jq -r '.items[] | select(.kind == "PersistentVolumeClaim") | "PVC \(.metadata.name): \(.status.phase // "Pending") (\(.status.capacity.storage // .spec.resources.requests.storage // "size unknown"))"' <<< "$resources_json"
jq -r '.items[] | select(.kind == "DataVolume") | "DataVolume \(.metadata.name): \(.status.phase // "Pending")"' <<< "$resources_json"
jq -r '.items[] | select(.kind == "VirtualMachine") | "VM \(.metadata.name): \(.status.printableStatus // (if .status.ready then "Ready" else "not ready" end))"' <<< "$resources_json"
jq -r '.items[] | select(.kind == "VirtualMachineInstance") | "VMI \(.metadata.name): \(.status.phase // "unknown")"' <<< "$resources_json"

schema1_error=$(jq -r '[.items[]? | .message // "" | select(test("manifest\\.v1|schema.?1|no longer supported"; "i"))] | first // empty' <<< "${events_json:-"{}"}")
image_pull_error=$(jq -r '[.items[] | select(.kind == "Pod") | ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]? | select(.state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull") | "\(.image): \(.state.waiting.message // .state.waiting.reason)"] | first // empty' <<< "$resources_json")
vm_count=$(jq '[.items[] | select(.kind == "VirtualMachine")] | length' <<< "$resources_json")
stopped_vm_count=$(jq '[.items[] | select(.kind == "VirtualMachine") | select(.status.printableStatus == "Stopped")] | length' <<< "$resources_json")
failed_vmi_count=$(jq '[.items[] | select(.kind == "VirtualMachineInstance") | select(.status.phase == "Failed")] | length' <<< "$resources_json")
task30_complete=false
ubuntu_cloud_init=$(jq -r 'any(.items[]; .kind == "VirtualMachine" and .metadata.name == "netpol-client" and .metadata.annotations["microsegmentation-lab/provisioning"] == "ubuntu-cloud-init")' <<< "$resources_json")
if (( vm_count == 3 && stopped_vm_count == 3 && failed_vmi_count == 0 )); then
  task30_complete=true
fi

if [[ -n "$schema1_error" || -n "$image_pull_error" ]]; then
  printf 'BLOCKED launcher image pull: %s\n' "${schema1_error:-$image_pull_error}"
  recommend "$fix_virtio_recommendation"
elif [[ "$virtio_image_known_bad" == true ]]; then
  recommend "$fix_virtio_recommendation"
elif jq -e '[.items[] | select(.kind == "DataVolume") | select(.status.phase == "PVCBound" or .status.phase == "WaitForFirstConsumer")] | length > 0' <<< "$resources_json" >/dev/null; then
  printf 'BLOCKED a CDI DataVolume is waiting for its first consumer.\n'
  recommend "Use and validate the direct-PVC guest-disk path in scripts/30-create-kubevirt-vms/create-test-vms.sh before resuming."
elif (( failed_vmi_count > 0 )); then
  printf 'BLOCKED task 30 has a failed VMI; stopped VM resources do not prove a successful boot check.\n'
  recommend "Inspect the failed task 30 VMI and launcher events before resuming: bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh"
elif [[ "$unhealthy_pods" != 0 ]]; then
  recommend "Resolve cluster or launcher pod warnings before resuming task 30."
elif [[ "$ubuntu_cloud_init" == true ]]; then
  printf 'Ubuntu client uses the configured unattended cloud-init disk; do not reapply manual installer templates.\n'
  recommend "If Ubuntu is running, verify it: bash scripts/30-create-kubevirt-vms/setup-ubuntu-client.sh --verify. Review doco/IMPLEMENTATION-STATUS.md for the remaining Windows setup; stop Ubuntu before starting another guest."
else
  if [[ "$task30_complete" == true ]]; then
    printf 'All three task 30 VMs exist and are stopped; Kubernetes state does not prove OS installation.\n'
    recommend "Install guest operating systems one at a time using the start/VNC instructions in scripts/30-create-kubevirt-vms/README.md, then continue to task 35."
  else
    recommend "Resume recognized task 30 resources: bash scripts/30-create-kubevirt-vms/create-test-vms.sh"
  fi
fi

printf '\nNEXT: %s\n' "$recommendation"