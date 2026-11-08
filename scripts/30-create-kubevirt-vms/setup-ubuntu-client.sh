#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
config_path="$script_dir/ubuntu-client.json"
mode=--plan
while (( $# > 0 )); do
  case "$1" in
    --config)
      if (( $# < 2 )); then printf 'Error: --config requires a JSON file.\n' >&2; exit 2; fi
      config_path="$2"; shift 2 ;;
    --plan|--apply|--verify|--ssh) mode="$1"; shift ;;
    *) printf 'Usage: %s [--config <file.json>] [--plan|--apply|--verify|--ssh]\n' "${0##*/}" >&2; exit 2 ;;
  esac
done

for command_name in jq virsh ssh ssh-keygen curl sha256sum timeout git; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Error: %s is required on the physical host.\n' "$command_name" >&2; exit 1;
  }
done
source "$repo_root/scripts/lib/common.sh"
msl_init "$repo_root"
jq -e '
  .namespace == "netpol-test" and .vmName == "netpol-client" and
  (.hostname | type == "string" and test("^[a-z][a-z0-9-]{0,62}$")) and
  (.adminUser | type == "string" and test("^[a-z_][a-z0-9_-]{0,30}$")) and .adminUser != "root" and
  (.timezone | type == "string" and test("^[A-Za-z_]+(/[A-Za-z_+-]+)*$")) and
  (.memory | type == "string" and test("^[1-9][0-9]*Gi$")) and
  (.cores | type == "number" and floor == . and . >= 1 and . <= 8) and
  .disk.pvcName == "netpol-client-cloud-disk" and .disk.storageClass == "local-path" and
  (.disk.size | type == "string" and test("^[1-9][0-9]*Gi$")) and
  (.image.url | type == "string" and startswith("https://cloud-images.ubuntu.com/")) and
  (.image.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
  (.ssh.privateKey | type == "string" and test("^work/[a-zA-Z0-9_-]+$")) and
  (.ssh.knownHosts | type == "string" and test("^work/[a-zA-Z0-9_-]+$")) and
  .ssh.privateKey != .ssh.knownHosts and
  (.waitSeconds | type == "number" and floor == . and . >= 60 and . <= 7200)
' "$config_path" >/dev/null || { printf 'Error: invalid Ubuntu configuration.\n' >&2; exit 2; }
namespace=$(jq -r .namespace "$config_path")
vm_name=$(jq -r .vmName "$config_path")
admin_user=$(jq -r .adminUser "$config_path")
image_sha=$(jq -r .image.sha256 "$config_path")
pvc_name=$(jq -r .disk.pvcName "$config_path")
key_path="$repo_root/$(jq -r .ssh.privateKey "$config_path")"
known_hosts="$repo_root/$(jq -r .ssh.knownHosts "$config_path")"
wait_seconds=$(jq -r .waitSeconds "$config_path")
virtctl_path="$work_dir/virtctl-v1.9.1"
export KUBECONFIG="$work_dir/kubeconfig-lab-k8s-01.yaml"

if [[ "$mode" == --plan ]]; then
  jq '{vmName,namespace,hostname,adminUser,timezone,memory,cores,disk,image,ssh,waitSeconds}' "$config_path"
  printf '\nPlan: use a new cloud-image PVC, preserve the original installer disk and all Rocky/Windows resources.\n'
  printf 'Apply gracefully stops the Ubuntu installer VM if running. No existing disks are overwritten.\n'
  printf 'Cloud-init creates the admin user with key-only SSH and passwordless lab sudo. No console login is needed.\n'
  exit 0
fi
if [[ ! -x "$virtctl_path" || ! -s "$KUBECONFIG" ]]; then
  printf 'Error: task 20 kubeconfig and task 30 virtctl are required.\n' >&2; exit 1
fi
msl_assert_outer_vm
msl_discover_outer_ip
outer_ip="$MSL_OUTER_IP"
ssh_options=("${MSL_OUTER_SSH_OPTS[@]}")
remote_kubectl() { msl_remote_kubectl "$@"; }
namespace_json=$(remote_kubectl get namespace "$namespace" -o json)
vm_json=$(remote_kubectl get vm "$vm_name" -n "$namespace" -o json)
if ! jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac"' <<< "$namespace_json" >/dev/null ||
  ! jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac" and .spec.runStrategy == "Manual" and .metadata.deletionTimestamp == null' <<< "$vm_json" >/dev/null; then
  printf 'Error: refusing an unowned or unexpected Ubuntu VM/namespace.\n' >&2; exit 1
fi
generate_key=false
if [[ "$mode" == --apply ]]; then generate_key=true; fi
msl_ensure_keypair "$key_path" "$known_hosts" microsegmentation-iac-ubuntu "$generate_key" "$(jq -r .ssh.privateKey "$config_path")"
public_key="$MSL_PUBLIC_KEY"
ubuntu_ssh() {
  msl_guest_ssh "$admin_user" "$vm_name" "$namespace" "$key_path" "$known_hosts" "$@"
}
if [[ "$mode" == --ssh ]]; then ubuntu_ssh --local-ssh-opts=-tt; exit; fi

if [[ "$mode" == --apply ]]; then
  siblings=$(remote_kubectl get vmi -n "$namespace" -o json)
  jq -e --arg vm "$vm_name" 'all(.items[]; .metadata.name == $vm)' <<< "$siblings" >/dev/null || {
    printf 'Error: stop Rocky/Windows before provisioning Ubuntu.\n' >&2; exit 1;
  }
  current_disk=$(jq -r '.spec.template.spec.volumes[] | select(.name == "osdisk") | .persistentVolumeClaim.claimName' <<< "$vm_json")
  if [[ "$current_disk" != netpol-client-disk && "$current_disk" != "$pvc_name" ]]; then
    printf 'Error: unexpected existing OS disk; refusing to switch it.\n' >&2; exit 1
  fi
  if [[ "$current_disk" == netpol-client-disk ]] &&
    ! jq -e 'any(.spec.template.spec.domain.devices.disks[]; .name == "installer" and .bootOrder == 1)' <<< "$vm_json" >/dev/null; then
    printf 'Error: original Ubuntu disk is already configured as installed; refusing conversion.\n' >&2; exit 1
  fi
  existing_pvc=$(remote_kubectl get pvc "$pvc_name" -n "$namespace" --ignore-not-found -o json)
  if [[ -n "$existing_pvc" ]]; then
    jq -e --arg sha "$image_sha" --arg size "$(jq -r .disk.size "$config_path")" '
      .metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac" and
      .metadata.annotations["microsegmentation-lab/image-sha256"] == $sha and
      .spec.storageClassName == "local-path" and .spec.volumeMode == "Filesystem" and
      .spec.resources.requests.storage == $size and
      (.status.phase == "Pending" or .status.phase == "Bound")
    ' <<< "$existing_pvc" >/dev/null || { printf 'Error: existing cloud PVC is unrecognized or incompatible; inspect it manually.\n' >&2; exit 1; }
  fi
  upload_complete=$(jq -r '.metadata.annotations["cdi.kubevirt.io/storage.condition.running.reason"] == "Completed" and .status.phase == "Bound"' <<< "${existing_pvc:-"{}"}")
  if [[ "$upload_complete" != true ]]; then
    if [[ "$current_disk" == "$pvc_name" ]]; then
      printf 'Error: refusing to upload over an attached cloud OS disk.\n' >&2; exit 1
    fi
    image_path="$work_dir/ubuntu-cloud-$image_sha.img"
    msl_fetch_image "$(jq -r .image.url "$config_path")" "$image_sha" "$image_path"
    trap msl_upload_tunnel_close EXIT
    msl_find_free_port 18454 18464
    upload_port="$MSL_FREE_PORT"
    msl_upload_tunnel_open "$upload_port"
    if [[ -z "$existing_pvc" ]]; then
      jq -n --arg name "$pvc_name" --arg ns "$namespace" --arg sha "$image_sha" --arg size "$(jq -r .disk.size "$config_path")" \
        '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns,labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac"},annotations:{"microsegmentation-lab/image-sha256":$sha,"cdi.kubevirt.io/storage.bind.immediate.requested":"true"}},spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",resources:{requests:{storage:$size}}}}' |
        ssh "${ssh_options[@]}" "labadmin@$outer_ip" 'sudo -n k3s kubectl create -f -'
    else
      remote_kubectl annotate pvc "$pvc_name" -n "$namespace" cdi.kubevirt.io/storage.bind.immediate.requested=true --overwrite
    fi
    "$virtctl_path" image-upload pvc "$pvc_name" -n "$namespace" --no-create --force-bind \
      --uploadproxy-url="https://127.0.0.1:$upload_port" --insecure --image-path="$image_path" --wait-secs=300
    msl_upload_tunnel_close
    trap - EXIT
  fi

  provisioned=$(jq -r '.metadata.annotations["microsegmentation-lab/provisioning"] // ""' <<< "$vm_json")
  if [[ "$provisioned" != ubuntu-cloud-init ]]; then
    current_vmi=$(remote_kubectl get vmi "$vm_name" -n "$namespace" --ignore-not-found -o name)
    if [[ -n "$current_vmi" ]]; then
      "$virtctl_path" stop "$vm_name" -n "$namespace"
      remote_kubectl wait --for=delete "vmi/$vm_name" -n "$namespace" --timeout=180s
    fi
    vm_json=$(remote_kubectl get vm "$vm_name" -n "$namespace" -o json)
    user_data=$(jq -c --arg key "$public_key" '
      {hostname:.hostname,manage_etc_hosts:true,timezone:.timezone,disable_root:true,ssh_pwauth:false,
      users:[{name:.adminUser,groups:["adm","sudo"],shell:"/bin/bash",lock_passwd:true,sudo:["ALL=(ALL) NOPASSWD:ALL"],ssh_authorized_keys:[$key]}],
      package_update:true,packages:["qemu-guest-agent","openssh-server","curl","ca-certificates"],
      write_files:[{path:"/etc/ssh/sshd_config.d/00-microsegmentation-lab.conf",owner:"root:root",permissions:"0644",content:"PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n"}],
      runcmd:[["systemctl","enable","--now","qemu-guest-agent"],["sshd","-t"],["systemctl","reload","ssh"]]}
    ' "$config_path")
    printf -v user_data '#cloud-config\n%s\n' "$user_data"
    patch=$(jq -cn --argjson vm "$vm_json" --slurpfile config "$config_path" --arg userdata "$user_data" '
      $config[0] as $cfg |
      [{op:"test",path:"/metadata/uid",value:$vm.metadata.uid},{op:"test",path:"/metadata/resourceVersion",value:$vm.metadata.resourceVersion},
      {op:"add",path:"/metadata/annotations",value:(($vm.metadata.annotations // {}) + {"microsegmentation-lab/provisioning":"ubuntu-cloud-init","microsegmentation-lab/image-sha256":$cfg.image.sha256})},
      {op:"replace",path:"/spec/template/spec/domain/devices/disks",value:[{name:"osdisk",disk:{bus:"virtio"},bootOrder:1},{name:"cloudinit",disk:{bus:"virtio"}}]},
      {op:"replace",path:"/spec/template/spec/volumes",value:[{name:"osdisk",persistentVolumeClaim:{claimName:$cfg.disk.pvcName}},{name:"cloudinit",cloudInitNoCloud:{userData:$userdata}}]},
      {op:"replace",path:"/spec/template/spec/domain/devices/interfaces",value:[{name:"default",masquerade:{},ports:[{name:"ssh",port:22,protocol:"TCP"}]}]},
      {op:"replace",path:"/spec/template/spec/domain/cpu/cores",value:$cfg.cores},
      {op:"replace",path:"/spec/template/spec/domain/resources/requests/memory",value:$cfg.memory}]
    ')
    remote_kubectl patch vm "$vm_name" -n "$namespace" --type=json -p "$patch"
  fi
  current_vmi=$(remote_kubectl get vmi "$vm_name" -n "$namespace" --ignore-not-found -o name)
  if [[ -z "$current_vmi" ]]; then "$virtctl_path" start "$vm_name" -n "$namespace"; fi
  remote_kubectl wait --for=create "vmi/$vm_name" -n "$namespace" --timeout=120s
  remote_kubectl wait --for=condition=Ready "vmi/$vm_name" -n "$namespace" --timeout=180s
fi

msl_wait_for_guest_ssh "$admin_user" "$vm_name" "$namespace" "$key_path" "$known_hosts" "$wait_seconds" Ubuntu
printf 'Ubuntu SSH is ready. Waiting for cloud-init completion (cloud-init prints its status below)...\n'
msl_guest_cloudinit_wait "$admin_user" "$vm_name" "$namespace" "$key_path" "$known_hosts" "$wait_seconds"
printf 'Verifying Ubuntu OS, network, and SSH policy...\n'
ubuntu_ssh --command='set -eu; . /etc/os-release; test "$ID" = ubuntu; test "$VERSION_ID" = 24.04; id; cat /etc/os-release; findmnt /; ip -br address; ip route; getent ahostsv4 archive.ubuntu.com; curl --fail --silent --show-error --location --max-time 30 --output /dev/null https://archive.ubuntu.com/ubuntu/; sudo -n true; systemctl is-active ssh qemu-guest-agent; sudo -n /usr/sbin/sshd -T | grep -E "^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin) "; printf "PASS Ubuntu unattended setup and key-based administration\n"'
printf 'Connect interactively: bash scripts/30-create-kubevirt-vms/setup-ubuntu-client.sh --ssh\n'