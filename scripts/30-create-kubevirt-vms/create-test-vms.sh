#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
vm_name="lab-k8s-01"
vm_user="labadmin"
managed_title="microsegmentation-iac-lab-k8s-01"
namespace="netpol-test"
namespace_owner="microsegmentation-iac"
remote_upload_port=18443
virtctl_sha256="c289393c8186a258653594605f5199b4c171a3131e6e409ed204a96b491b782a"
virtio_disk_image="quay.io/kubevirt/virtio-container-disk@sha256:06a32bc8a4d84d2d8d86ef06ba92dad00d78d1b34cec2ee48e17a2fbe438a094"
dry_run=false

usage() {
  printf 'Usage: %s [--dry-run]\n' "${0##*/}"
  printf 'Create and boot-check the Rocky, Ubuntu, and Windows KubeVirt installer VMs in order.\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command_name in virsh ssh scp sha256sum stat awk jq python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required on the physical QEMU/KVM host.\n' "$command_name" >&2
    exit 1
  fi
done

host_kubeconfig="$work_dir/kubeconfig-${vm_name}.yaml"
ssh_key="$work_dir/${vm_name}_ed25519"
known_hosts="$work_dir/${vm_name}_known_hosts"
virtctl_path="$work_dir/virtctl-v1.9.1"
rocky_iso="$work_dir/Rocky-10-latest-x86_64-minimal.iso"
ubuntu_iso="$work_dir/ubuntu-24.04.5-live-server-amd64.iso"
windows_iso="$work_dir/windows-server-2025-evaluation.iso"

for file_path in "$host_kubeconfig" "$ssh_key" "$rocky_iso" "$ubuntu_iso" "$windows_iso"; do
  if [[ ! -s "$file_path" ]]; then
    printf 'Error: required file is missing or empty: %s\n' "$file_path" >&2
    exit 1
  fi
done

vm_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
if [[ "$vm_title" != "$managed_title" ]]; then
  printf 'Error: VM %s is not marked as managed by this project.\n' "$vm_name" >&2
  exit 1
fi
vm_state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
if [[ "$vm_state" != "running" ]]; then
  printf 'Error: VM %s must be running; current state: %s.\n' "$vm_name" "$vm_state" >&2
  exit 1
fi

guest_ip=$(virsh -c qemu:///system domifaddr "$vm_name" --source lease | awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }')
if [[ -z "$guest_ip" ]]; then
  guest_mac=$(virsh -c qemu:///system domiflist "$vm_name" | awk '$3 == "default" { print tolower($5); exit }')
  interface_json=$(virsh -c qemu:///system qemu-agent-command "$vm_name" \
    '{"execute":"guest-network-get-interfaces"}') || {
    printf 'Error: no DHCP lease and QEMU guest agent is unavailable for %s.\n' "$vm_name" >&2
    exit 1
  }
  guest_ip=$(jq -r --arg mac "$guest_mac" \
    '.return[] | select((."hardware-address" // "" | ascii_downcase) == $mac) | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("169.254.") | not)) | .["ip-address"]' \
    <<< "$interface_json" | awk 'NR == 1 { print; exit }')
  if [[ -z "$guest_ip" ]]; then
    printf 'Error: no DHCP lease or host-reachable guest-agent IPv4 found for %s.\n' "$vm_name" >&2
    exit 1
  fi
fi

ssh_options=(
  -i "$ssh_key"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$known_hosts"
)
destination="$vm_user@$guest_ip"

media_files=("$rocky_iso" "$ubuntu_iso" "$windows_iso")
media_names=("Rocky Linux 10" "Ubuntu Server 24.04.5" "Windows Server 2025 Evaluation")
vm_names=(netpol-server-rocky netpol-client netpol-server-windows)
vm_roles=(server client server)
vm_memory=(2Gi 2Gi 4Gi)
vm_cores=(2 2 2)
vm_disk_sizes=(10Gi 10Gi 40Gi)
iso_pvcs=(rocky-installer-iso ubuntu-installer-iso windows-installer-iso)

media_capacity_gib=0
for index in "${!media_files[@]}"; do
  media_bytes=$(stat -c %s "${media_files[$index]}")
  media_capacity_gib=$((media_capacity_gib + (media_bytes + 1073741823) / 1073741824))
done
disk_capacity_gib=0
for disk_size in "${vm_disk_sizes[@]}"; do
  disk_capacity_gib=$((disk_capacity_gib + ${disk_size%Gi}))
done
minimum_free_gib=$((media_capacity_gib + disk_capacity_gib + 10))
minimum_free_kib=$((minimum_free_gib * 1024 * 1024))

if [[ "$dry_run" == true ]]; then
  printf 'Dry run: no cluster resources or files will be changed.\n'
  printf 'Namespace: %s (new or recognized project-owned resources only)\n' "$namespace"
  printf 'VM order: Rocky Linux, Ubuntu Server, Windows Server 2025 Evaluation\n'
  for index in "${!vm_names[@]}"; do
    printf '  %s: %s disk, %s memory, installer %s (%s bytes)\n' \
      "${vm_names[$index]}" "${vm_disk_sizes[$index]}" "${vm_memory[$index]}" \
      "${media_names[$index]}" "$(stat -c %s "${media_files[$index]}")"
  done
  printf 'Required free space in the K3s guest: at least %s GiB (installer media, requested disk capacities, and 10 GiB reserve).\n' "$minimum_free_gib"
  printf 'Each VM will be started until its VMI phase is Running, then stopped before the next VM starts.\n'
  printf 'OS installation and guest configuration are not performed by this script.\n'
  exit 0
fi

bash "$repo_root/scripts/20-install-k3s-kubevirt/check-cluster-status.sh" --infrastructure-only

namespace_exists=$(ssh "${ssh_options[@]}" "$destination" \
  "sudo -n k3s kubectl get namespace '$namespace' -o name 2>/dev/null || true")
if [[ -n "$namespace_exists" ]]; then
  existing_owner=$(ssh "${ssh_options[@]}" "$destination" \
    "sudo -n k3s kubectl get namespace '$namespace' -o 'jsonpath={.metadata.labels.microsegmentation-lab/managed-by}'")
  if [[ "$existing_owner" != "$namespace_owner" ]]; then
    printf 'Error: namespace %s exists but is not marked as managed by this project; refusing to use it.\n' "$namespace" >&2
    exit 1
  fi
  existing_resources=$(ssh "${ssh_options[@]}" "$destination" \
    "sudo -n k3s kubectl get pvc,dv,vm,vmi,networkpolicy -n '$namespace' -o json" |
    jq -r '.items[] | "\(.kind)/\(.metadata.name)"')
  while IFS= read -r resource_id; do
    [[ -n "$resource_id" ]] || continue
    case "$resource_id" in
      PersistentVolumeClaim/rocky-installer-iso|PersistentVolumeClaim/ubuntu-installer-iso|PersistentVolumeClaim/windows-installer-iso|\
      PersistentVolumeClaim/netpol-server-rocky-disk|PersistentVolumeClaim/netpol-client-disk|PersistentVolumeClaim/netpol-server-windows-disk|\
      DataVolume/netpol-server-rocky-disk|DataVolume/netpol-client-disk|DataVolume/netpol-server-windows-disk|\
      VirtualMachine/netpol-server-rocky|VirtualMachine/netpol-client|VirtualMachine/netpol-server-windows|\
      VirtualMachineInstance/netpol-server-rocky|VirtualMachineInstance/netpol-client|VirtualMachineInstance/netpol-server-windows)
        ;;
      *)
        printf 'Error: namespace %s contains an unrecognized resource; refusing to resume: %s\n' \
          "$namespace" "$resource_id" >&2
        exit 1
        ;;
    esac
  done <<< "$existing_resources"
  printf 'Resuming in the project-owned namespace %s. Existing task resources will be reused only by their expected names.\n' "$namespace"
fi

guest_disk_report=$(ssh "${ssh_options[@]}" "$destination" 'df -Pk /')
guest_free_kib=$(awk 'NR == 2 { print $4 }' <<< "$guest_disk_report")
if [[ ! "$guest_free_kib" =~ ^[0-9]+$ ]] || (( guest_free_kib < minimum_free_kib )); then
  printf 'Error: the K3s guest needs at least %s GiB free for installer media, requested VM disks, and reserve; current free space is %s GiB.\n' \
    "$minimum_free_gib" \
    "$(( ${guest_free_kib:-0} / 1024 / 1024 ))" >&2
  exit 1
fi

existing_virtctl=false
if [[ -e "$virtctl_path" ]]; then
  actual_virtctl_sha256=$(sha256sum "$virtctl_path" | awk '{print $1}')
  if [[ "$actual_virtctl_sha256" != "$virtctl_sha256" ]]; then
    printf 'Error: existing virtctl checksum mismatch at %s. Move it aside before retrying.\n' "$virtctl_path" >&2
    exit 1
  fi
  existing_virtctl=true
else
  scp -i "$ssh_key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$known_hosts" \
    "$destination:/usr/local/bin/virtctl" "$virtctl_path"
  chmod 0700 "$virtctl_path"
  actual_virtctl_sha256=$(sha256sum "$virtctl_path" | awk '{print $1}')
  if [[ "$actual_virtctl_sha256" != "$virtctl_sha256" ]]; then
    printf 'Error: copied virtctl checksum mismatch; expected %s, found %s.\n' \
      "$virtctl_sha256" "$actual_virtctl_sha256" >&2
    exit 1
  fi
fi

local_upload_port=""
for candidate in $(seq 18443 18453); do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then
    local_upload_port="$candidate"
    break
  fi
done
if [[ -z "$local_upload_port" ]]; then
  printf 'Error: no free local port is available for the CDI upload tunnel.\n' >&2
  exit 1
fi

remote_pf_pid=""
tunnel_pid=""
cleanup_tunnel() {
  if [[ -n "$tunnel_pid" ]]; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
  fi
  if [[ -n "$remote_pf_pid" ]]; then
    ssh "${ssh_options[@]}" "$destination" \
      "sudo -n kill '$remote_pf_pid'" >/dev/null 2>&1 || true
  fi
}
trap cleanup_tunnel EXIT
trap 'exit 130' INT TERM

remote_pf_command="nohup k3s kubectl port-forward --address 127.0.0.1 -n cdi svc/cdi-uploadproxy $remote_upload_port:443 >/tmp/netpol-cdi-uploadproxy.log 2>&1 </dev/null & echo \$!"
printf -v quoted_remote_pf_command '%q' "$remote_pf_command"
remote_pf_pid=$(ssh "${ssh_options[@]}" "$destination" \
  "sudo -n bash -c $quoted_remote_pf_command" | tr -d '\r')
if [[ ! "$remote_pf_pid" =~ ^[0-9]+$ ]]; then
  printf 'Error: could not start the CDI upload-proxy port-forward in the K3s guest.\n' >&2
  exit 1
fi

ssh "${ssh_options[@]}" -N \
  -L "127.0.0.1:${local_upload_port}:127.0.0.1:${remote_upload_port}" \
  "$destination" >"$work_dir/.netpol-upload-tunnel.log" 2>&1 &
tunnel_pid=$!
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$local_upload_port") 2>/dev/null; then
    break
  fi
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    printf 'Error: SSH tunnel did not start. See %s/.netpol-upload-tunnel.log.\n' "$work_dir" >&2
    exit 1
  fi
  sleep 1
done
if ! (exec 3<>"/dev/tcp/127.0.0.1/$local_upload_port") 2>/dev/null; then
  printf 'Error: CDI upload-proxy is not reachable through the SSH tunnel.\n' >&2
  exit 1
fi

remote_kubectl() {
  local remote_command='sudo -n k3s kubectl'
  local argument quoted
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    remote_command+=" $quoted"
  done
  ssh "${ssh_options[@]}" "$destination" "$remote_command"
}

apply_remote_manifest() {
  ssh "${ssh_options[@]}" "$destination" 'sudo -n k3s kubectl apply -f -' < "$1"
}

ssh "${ssh_options[@]}" "$destination" 'sudo -n k3s kubectl apply -f -' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
  labels:
    microsegmentation-lab/managed-by: ${namespace_owner}
EOF

upload_iso() {
  local label="$1"
  local pvc_name="$2"
  local image_path="$3"
  local bytes size_gib existing_pvc existing_size existing_class existing_mode existing_rwo upload_complete
  bytes=$(stat -c %s "$image_path")
  size_gib=$(( (bytes + 1073741823) / 1073741824 ))
  existing_pvc=$(remote_kubectl get pvc "$pvc_name" -n "$namespace" --ignore-not-found -o json)
  if [[ -n "$existing_pvc" ]]; then
    existing_size=$(jq -r '.spec.resources.requests.storage // ""' <<< "$existing_pvc")
    existing_class=$(jq -r '.spec.storageClassName // ""' <<< "$existing_pvc")
    existing_mode=$(jq -r '.spec.volumeMode // "Filesystem"' <<< "$existing_pvc")
    existing_rwo=$(jq -r 'any(.spec.accessModes[]?; . == "ReadWriteOnce")' <<< "$existing_pvc")
    existing_size_bytes=$(python3 -c '
from decimal import Decimal
import re
import sys

match = re.fullmatch(r"([0-9]+(?:\\.[0-9]+)?)([A-Za-z]*)", sys.argv[1])
if not match:
    raise SystemExit(1)
number = Decimal(match.group(1))
suffix = match.group(2)
binary = {unit + "i": 1024 ** power for power, unit in enumerate(("", "K", "M", "G", "T", "P", "E")) if unit}
decimal = {unit: 1000 ** power for power, unit in enumerate(("", "k", "M", "G", "T", "P", "E"))}
if suffix in binary:
    number *= binary[suffix]
elif suffix in decimal:
    number *= decimal[suffix]
elif suffix == "m":
    number /= 1000
else:
    raise SystemExit(1)
print(int(number))
' "$existing_size") || {
      printf 'Error: cannot parse storage request %s on existing installer PVC %s.\n' "$existing_size" "$pvc_name" >&2
      return 1
    }
    if [[ "$existing_class" != local-path || "$existing_mode" != Filesystem || "$existing_rwo" != true ]] ||
      (( existing_size_bytes < bytes )); then
      printf 'Error: existing installer PVC %s is incompatible (class=%s mode=%s RWO=%s size=%s); expected local-path, Filesystem, RWO, and at least %s bytes.\n' \
        "$pvc_name" "$existing_class" "$existing_mode" "$existing_rwo" "$existing_size" "$bytes" >&2
      return 1
    fi
    upload_complete=$(jq -r \
      '(.metadata.annotations["cdi.kubevirt.io/storage.condition.running.reason"] == "Completed") and (.status.phase == "Bound")' \
      <<< "$existing_pvc")
    if [[ "$upload_complete" == true ]]; then
      printf '%s installer PVC %s is already bound and upload-complete; skipping upload.\n' "$label" "$pvc_name"
      return 0
    fi
  fi
  printf 'Uploading %s to PVC %s...\n' "$label" "$pvc_name"
  local upload_args=(image-upload pvc "$pvc_name"
    --namespace="$namespace"
    --uploadproxy-url="https://127.0.0.1:${local_upload_port}"
    --insecure
    --image-path="$image_path")
  if [[ -n "$existing_pvc" ]]; then
    upload_args+=(--no-create)
  else
    upload_args+=(
      --size="${size_gib}Gi"
      --storage-class=local-path
      --access-mode=ReadWriteOnce
      --volume-mode=filesystem
      --force-bind)
  fi
  KUBECONFIG="$host_kubeconfig" "$virtctl_path" "${upload_args[@]}"
}

create_disk() {
  local disk_name="$1"
  local disk_size="$2"
  local existing_pvc existing_class existing_mode existing_rwo existing_request
  existing_pvc=$(remote_kubectl get pvc "$disk_name" -n "$namespace" --ignore-not-found -o json)
  if [[ -n "$existing_pvc" ]]; then
    existing_class=$(jq -r '.spec.storageClassName // ""' <<< "$existing_pvc")
    existing_mode=$(jq -r '.spec.volumeMode // "Filesystem"' <<< "$existing_pvc")
    existing_rwo=$(jq -r 'any(.spec.accessModes[]?; . == "ReadWriteOnce")' <<< "$existing_pvc")
    existing_request=$(jq -r '.spec.resources.requests.storage // ""' <<< "$existing_pvc")
    if [[ "$existing_class" != local-path || "$existing_mode" != Filesystem || "$existing_rwo" != true || -z "$existing_request" ]]; then
      printf 'Error: existing guest disk PVC %s is incompatible (class=%s mode=%s RWO=%s request=%s).\n' \
        "$disk_name" "$existing_class" "$existing_mode" "$existing_rwo" "$existing_request" >&2
      return 1
    fi
    return 0
  fi
  local manifest
  manifest=$(mktemp "$work_dir/.${disk_name}.XXXXXX.yaml")
  cat > "$manifest" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${disk_name}
  namespace: ${namespace}
spec:
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: ${disk_size}
EOF
  apply_remote_manifest "$manifest"
  rm -f -- "$manifest"
}

wait_disk_bound() {
  local disk_name="$1"
  local phase
  for _ in $(seq 1 120); do
    phase=$(remote_kubectl get pvc "$disk_name" -n "$namespace" -o 'jsonpath={.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == Bound ]]; then
      return 0
    fi
    sleep 3
  done
  printf 'Error: guest disk PVC %s did not reach Bound.\n' "$disk_name" >&2
  remote_kubectl get pvc "$disk_name" -n "$namespace" -o wide || true
  return 1
}

stop_pending_vmi_for_update() {
  local name="$1"
  local phase
  phase=$(remote_kubectl get vmi "$name" -n "$namespace" -o 'jsonpath={.status.phase}' 2>/dev/null || true)
  case "$phase" in
    "")
      return 0
      ;;
    Failed)
      local failed_vmi vm_uid
      failed_vmi=$(remote_kubectl get vmi "$name" -n "$namespace" -o json)
      vm_uid=$(remote_kubectl get vm "$name" -n "$namespace" -o 'jsonpath={.metadata.uid}')
      if [[ -z "$vm_uid" ]] || ! jq -e --arg name "$name" --arg uid "$vm_uid" \
        '.status.phase == "Failed" and any(.metadata.ownerReferences[]?; .kind == "VirtualMachine" and .name == $name and .uid == $uid and .controller == true)' \
        <<< "$failed_vmi" >/dev/null; then
        printf 'Error: failed VMI %s ownership or phase changed; refusing recovery.\n' "$name" >&2
        return 1
      fi
      printf 'Removing terminal failed VMI %s; its VM definition and persistent volumes are preserved.\n' "$name"
      remote_kubectl delete vmi "$name" -n "$namespace" --wait=true --timeout=180s
      return
      ;;
    Pending|Scheduling)
      printf 'Stopping unfinished %s VMI (phase %s) before updating its disk template.\n' "$name" "$phase"
      KUBECONFIG="$host_kubeconfig" "$virtctl_path" stop "$name" --namespace="$namespace" || true
      for _ in $(seq 1 60); do
        phase=$(remote_kubectl get vmi "$name" -n "$namespace" -o 'jsonpath={.status.phase}' 2>/dev/null || true)
        if [[ -z "$phase" ]]; then
          return 0
        fi
        sleep 3
      done
      printf 'Error: unfinished VMI %s did not stop.\n' "$name" >&2
      return 1
      ;;
    *)
      printf 'Error: VMI %s is %s. Refusing to interrupt a guest that may be in use; stop it explicitly before retrying.\n' "$name" "$phase" >&2
      return 1
      ;;
  esac
}

make_vm_manifest() {
  local name="$1"
  local role="$2"
  local memory="$3"
  local cores="$4"
  local iso_pvc="$5"
  local windows="$6"
  local manifest
  manifest=$(mktemp "$work_dir/.${name}.XXXXXX.yaml")
  cat > "$manifest" <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ${name}
    microsegmentation-lab/managed-by: ${namespace_owner}
    microsegmentation-lab/role: ${role}
spec:
  runStrategy: Manual
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${name}
        microsegmentation-lab/managed-by: ${namespace_owner}
        microsegmentation-lab/role: ${role}
        microsegmentation-lab/os: ${name#netpol-}
    spec:
      domain:
        cpu:
          cores: ${cores}
        resources:
          requests:
            memory: ${memory}
        devices:
          disks:
            - name: installer
              cdrom:
                bus: sata
                readonly: true
              bootOrder: 1
            - name: osdisk
              disk:
                bus: virtio
              bootOrder: 2
EOF
  if [[ "$windows" == true ]]; then
    cat >> "$manifest" <<EOF
            - name: virtio-drivers
              cdrom:
                bus: sata
                readonly: true
EOF
  fi
  cat >> "$manifest" <<EOF
          interfaces:
            - name: default
              masquerade: {}
EOF
  if [[ "$role" == server && "$windows" == true ]]; then
    cat >> "$manifest" <<EOF
              ports:
                - name: allowed-http
                  port: 80
                  protocol: TCP
                - name: denied-http
                  port: 8081
                  protocol: TCP
EOF
  elif [[ "$role" == server ]]; then
    cat >> "$manifest" <<EOF
              ports:
                - name: ssh
                  port: 22
                  protocol: TCP
                - name: allowed-http
                  port: 8080
                  protocol: TCP
                - name: denied-http
                  port: 8081
                  protocol: TCP
EOF
  fi
  cat >> "$manifest" <<EOF
      networks:
        - name: default
          pod: {}
      volumes:
        - name: installer
          persistentVolumeClaim:
            claimName: ${iso_pvc}
        - name: osdisk
          persistentVolumeClaim:
            claimName: ${name}-disk
EOF
  if [[ "$windows" == true ]]; then
    cat >> "$manifest" <<EOF
        - name: virtio-drivers
          containerDisk:
            image: ${virtio_disk_image}
EOF
  fi
  printf '%s\n' "$manifest"
}

wait_vmi_running() {
  local name="$1"
  local phase
  for _ in $(seq 1 200); do
    phase=$(remote_kubectl get vmi "$name" -n "$namespace" -o 'jsonpath={.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == Running ]]; then
      printf 'PASS %s VMI reached Running.\n' "$name"
      return 0
    fi
    sleep 3
  done
  printf 'Error: VMI %s did not reach Running within 10 minutes.\n' "$name" >&2
  remote_kubectl get vmi "$name" -n "$namespace" -o wide || true
  remote_kubectl get pods -n "$namespace" -o wide || true
  return 1
}

stop_vmi() {
  local name="$1"
  KUBECONFIG="$host_kubeconfig" "$virtctl_path" stop "$name" --namespace="$namespace"
  local phase
  for _ in $(seq 1 60); do
    phase=$(remote_kubectl get vmi "$name" -n "$namespace" -o 'jsonpath={.status.phase}' 2>/dev/null || true)
    if [[ -z "$phase" ]]; then
      printf 'PASS %s VMI stopped.\n' "$name"
      return 0
    fi
    sleep 3
  done
  printf 'Error: VMI %s did not stop within 3 minutes.\n' "$name" >&2
  return 1
}

for index in "${!vm_names[@]}"; do
  vm_name_current="${vm_names[$index]}"
  disk_name="${vm_name_current}-disk"
  windows=false
  [[ "$vm_name_current" == netpol-server-windows ]] && windows=true

  upload_iso "${media_names[$index]}" "${iso_pvcs[$index]}" "${media_files[$index]}"
  create_disk "$disk_name" "${vm_disk_sizes[$index]}"
  stop_pending_vmi_for_update "$vm_name_current"
  vm_manifest=$(make_vm_manifest "$vm_name_current" "${vm_roles[$index]}" \
    "${vm_memory[$index]}" "${vm_cores[$index]}" "${iso_pvcs[$index]}" "$windows")
  apply_remote_manifest "$vm_manifest"
  rm -f -- "$vm_manifest"

  printf 'Starting %s to bind its local-path disk and validate boot...\n' "$vm_name_current"
  existing_vmi=$(remote_kubectl get vmi "$vm_name_current" -n "$namespace" -o name 2>/dev/null || true)
  if [[ -z "$existing_vmi" ]]; then
    KUBECONFIG="$host_kubeconfig" "$virtctl_path" start "$vm_name_current" --namespace="$namespace"
  fi
  wait_vmi_running "$vm_name_current"
  wait_disk_bound "$disk_name"
  stop_vmi "$vm_name_current"
done

printf '\nAll three KubeVirt installer VM resources were created and reached Running in the requested order.\n'
printf 'The VMs are stopped with installer media attached. OS installation and guest readiness are not verified.\n'
printf 'Run one guest at a time. For each VM, start it and open its installer console with these commands:\n'
for name in "${vm_names[@]}"; do
  printf '  KUBECONFIG=%q %q start %q --namespace=%q\n' \
    "$host_kubeconfig" "$virtctl_path" "$name" "$namespace"
  printf '  KUBECONFIG=%q %q vnc %q --namespace=%q\n' \
    "$host_kubeconfig" "$virtctl_path" "$name" "$namespace"
done