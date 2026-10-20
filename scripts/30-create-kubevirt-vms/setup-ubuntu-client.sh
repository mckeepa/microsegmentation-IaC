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
if [[ "$(virsh -c qemu:///system desc lab-k8s-01 --title)" != microsegmentation-iac-lab-k8s-01 ||
      "$(virsh -c qemu:///system domstate lab-k8s-01)" != running ]]; then
  printf 'Error: the managed outer VM must be running.\n' >&2; exit 1
fi
outer_ip=$(virsh -c qemu:///system domifaddr lab-k8s-01 --source lease |
  awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }')
if [[ -z "$outer_ip" ]]; then
  outer_mac=$(virsh -c qemu:///system domiflist lab-k8s-01 | awk '$3 == "default" { print tolower($5); exit }')
  interfaces=$(virsh -c qemu:///system qemu-agent-command lab-k8s-01 '{"execute":"guest-network-get-interfaces"}')
  outer_ip=$(jq -r --arg mac "$outer_mac" '[.return[] | select((."hardware-address" // "" | ascii_downcase) == $mac) | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("169.254.") | not)) | .["ip-address"]] | first // empty' <<< "$interfaces")
fi
if [[ -z "$outer_ip" ]]; then printf 'Error: outer guest IP unavailable.\n' >&2; exit 1; fi
ssh_options=(-i "$work_dir/lab-k8s-01_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes
  -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$work_dir/lab-k8s-01_known_hosts")
remote_kubectl() {
  local remote_command='sudo -n k3s kubectl' argument quoted
  for argument in "$@"; do printf -v quoted '%q' "$argument"; remote_command+=" $quoted"; done
  ssh "${ssh_options[@]}" "labadmin@$outer_ip" "$remote_command"
}
namespace_json=$(remote_kubectl get namespace "$namespace" -o json)
vm_json=$(remote_kubectl get vm "$vm_name" -n "$namespace" -o json)
if ! jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac"' <<< "$namespace_json" >/dev/null ||
  ! jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac" and .spec.runStrategy == "Manual" and .metadata.deletionTimestamp == null' <<< "$vm_json" >/dev/null; then
  printf 'Error: refusing an unowned or unexpected Ubuntu VM/namespace.\n' >&2; exit 1
fi
umask 077
if [[ -L "$key_path" || -L "$key_path.pub" || -L "$known_hosts" ]]; then
  printf 'Error: refusing symlinked key/known-hosts files.\n' >&2; exit 1
fi
if [[ "$mode" == --apply && ! -e "$key_path" ]]; then
  git -C "$repo_root" check-ignore -q "$(jq -r .ssh.privateKey "$config_path")" || {
    printf 'Error: private key path must be Git-ignored.\n' >&2; exit 1;
  }
  if [[ -e "$key_path.pub" ]]; then printf 'Error: public key exists without its private key.\n' >&2; exit 1; fi
  ssh-keygen -q -t ed25519 -N '' -C microsegmentation-iac-ubuntu -f "$key_path"
fi
if [[ ! -s "$key_path" ]]; then printf 'Error: automation key missing; run --apply first.\n' >&2; exit 1; fi
chmod 0600 "$key_path"
public_key=$(ssh-keygen -y -P '' -f "$key_path" | awk '{ print $1 " " $2 }')
if [[ "$public_key" != ssh-ed25519\ * ]]; then printf 'Error: an Ed25519 key is required.\n' >&2; exit 1; fi
ubuntu_ssh() {
  "$virtctl_path" ssh "$admin_user@vmi/$vm_name" -n "$namespace" --identity-file="$key_path" --known-hosts="$known_hosts" \
    --local-ssh-opts='-o BatchMode=yes' --local-ssh-opts='-o IdentitiesOnly=yes' \
    --local-ssh-opts='-o ConnectTimeout=5' --local-ssh-opts='-o StrictHostKeyChecking=accept-new' "$@"
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
    if [[ -L "$image_path" ]]; then printf 'Error: symlinked image cache.\n' >&2; exit 1; fi
    if [[ ! -s "$image_path" ]]; then
      curl --fail --location --show-error --retry 3 --output "$image_path.part" "$(jq -r .image.url "$config_path")"
      printf '%s  %s\n' "$image_sha" "$image_path.part" | sha256sum --check -
      mv -- "$image_path.part" "$image_path"
    fi
    printf '%s  %s\n' "$image_sha" "$image_path" | sha256sum --check -
    temporary_dir=$(mktemp -d "$work_dir/.ubuntu-cloud.XXXXXX")
    upload_pid=""
    remote_upload_pid=""
    cleanup_upload() {
      if [[ -n "$upload_pid" ]]; then kill "$upload_pid" 2>/dev/null || true; wait "$upload_pid" 2>/dev/null || true; fi
      if [[ -n "$remote_upload_pid" ]]; then
        ssh "${ssh_options[@]}" "labadmin@$outer_ip" "sudo -n kill '$remote_upload_pid'" >/dev/null 2>&1 || true
      fi
      rm -rf -- "$temporary_dir"
    }
    trap cleanup_upload EXIT
    upload_port=""
    for candidate in $(seq 18454 18464); do
      if (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then continue; fi
      remote_listeners=$(ssh "${ssh_options[@]}" "labadmin@$outer_ip" "ss -H -ltn 'sport = :$candidate'")
      if [[ -z "$remote_listeners" ]]; then upload_port="$candidate"; break; fi
    done
    if [[ -z "$upload_port" ]]; then printf 'Error: no free upload port available.\n' >&2; exit 1; fi
    printf -v remote_upload_command 'nohup k3s kubectl port-forward --address 127.0.0.1 -n cdi svc/cdi-uploadproxy %s:443 >/dev/null 2>&1 </dev/null & echo $!' "$upload_port"
    printf -v quoted_upload_command '%q' "$remote_upload_command"
    remote_upload_pid=$(ssh "${ssh_options[@]}" "labadmin@$outer_ip" "sudo -n bash -c $quoted_upload_command" | tr -d '\r')
    if [[ ! "$remote_upload_pid" =~ ^[0-9]+$ ]]; then printf 'Error: invalid upload-proxy PID.\n' >&2; exit 1; fi
    ssh "${ssh_options[@]}" -N -o ExitOnForwardFailure=yes -L "127.0.0.1:$upload_port:127.0.0.1:$upload_port" "labadmin@$outer_ip" >"$temporary_dir/upload.log" 2>&1 &
    upload_pid=$!
    for attempt in $(seq 1 30); do
      if (exec 3<>"/dev/tcp/127.0.0.1/$upload_port") 2>/dev/null; then break; fi
      if ! kill -0 "$upload_pid" 2>/dev/null; then cat "$temporary_dir/upload.log" >&2; exit 1; fi
      sleep 1
    done
    kill -0 "$upload_pid" 2>/dev/null || { cat "$temporary_dir/upload.log" >&2; exit 1; }
    if [[ -z "$existing_pvc" ]]; then
      jq -n --arg name "$pvc_name" --arg ns "$namespace" --arg sha "$image_sha" --arg size "$(jq -r .disk.size "$config_path")" \
        '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns,labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac"},annotations:{"microsegmentation-lab/image-sha256":$sha,"cdi.kubevirt.io/storage.bind.immediate.requested":"true"}},spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",resources:{requests:{storage:$size}}}}' |
        ssh "${ssh_options[@]}" "labadmin@$outer_ip" 'sudo -n k3s kubectl create -f -'
    else
      remote_kubectl annotate pvc "$pvc_name" -n "$namespace" cdi.kubevirt.io/storage.bind.immediate.requested=true --overwrite
    fi
    "$virtctl_path" image-upload pvc "$pvc_name" -n "$namespace" --no-create --force-bind \
      --uploadproxy-url="https://127.0.0.1:$upload_port" --insecure --image-path="$image_path" --wait-secs=300
    cleanup_upload
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

deadline=$((SECONDS + wait_seconds))
printf 'Waiting up to %s seconds for Ubuntu key-authenticated SSH...\n' "$wait_seconds"
until ubuntu_ssh --command=true >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then printf 'Error: Ubuntu SSH not ready; inspect VMI and cloud-init logs. No disks deleted.\n' >&2; exit 1; fi
  sleep 5
done
timeout --foreground "$wait_seconds" "$virtctl_path" ssh "$admin_user@vmi/$vm_name" -n "$namespace" \
  --identity-file="$key_path" --known-hosts="$known_hosts" --local-ssh-opts='-o BatchMode=yes' \
  --local-ssh-opts='-o IdentitiesOnly=yes' --local-ssh-opts='-o StrictHostKeyChecking=yes' \
  --command='sudo -n cloud-init status --wait --long'
ubuntu_ssh --command='set -eu; . /etc/os-release; test "$ID" = ubuntu; test "$VERSION_ID" = 24.04; id; cat /etc/os-release; findmnt /; ip -br address; ip route; getent ahostsv4 archive.ubuntu.com; curl --fail --silent --show-error --location --max-time 30 --output /dev/null https://archive.ubuntu.com/ubuntu/; sudo -n true; systemctl is-active ssh qemu-guest-agent; sudo -n /usr/sbin/sshd -T | grep -E "^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin) "; printf "PASS Ubuntu unattended setup and key-based administration\n"'
printf 'Connect interactively: bash scripts/30-create-kubevirt-vms/setup-ubuntu-client.sh --ssh\n'