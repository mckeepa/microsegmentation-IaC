#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
config="$script_dir/rocky-desktop.json"
mode=--plan
while (( $# > 0 )); do
  case "$1" in
    --config) (( $# >= 2 )) || exit 2; config="$2"; shift 2 ;;
    --plan|--apply|--verify|--ssh|--vnc|--rdp|--set-desktop-password) mode="$1"; shift ;;
    *) printf 'Usage: %s [--config file.json] [--plan|--apply|--verify|--ssh|--vnc|--rdp|--set-desktop-password]\n' "${0##*/}" >&2; exit 2 ;;
  esac
done
for command_name in jq virsh ssh ssh-keygen curl sha256sum timeout git base64; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'Error: %s required.\n' "$command_name" >&2; exit 1; }
done
source "$repo_root/scripts/lib/common.sh"
msl_init "$repo_root"
jq -e '
  .namespace == "rocky-desktop" and .vmName == "rocky-desktop" and .hostname == "rocky-desktop" and
  .adminUser == "labadmin" and .desktopUser == "desktop" and
  (.timezone | type == "string" and test("^[A-Za-z_]+(/[A-Za-z_+-]+)*$")) and
  (.memory | type == "string" and test("^[4-8]Gi$")) and
  (.cores | type == "number" and floor == . and . >= 2 and . <= 4) and
  (.diskSize | type == "string" and test("^[3-5][0-9]Gi$")) and
  (.image.url | type == "string" and startswith("https://download.rockylinux.org/pub/rocky/9/images/x86_64/")) and
  (.image.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
  .sshPrivateKey == "work/rocky-desktop_ed25519" and .sshKnownHosts == "work/rocky-desktop_known_hosts" and
  (.rdpLocalPort | type == "number" and floor == . and . >= 1024 and . <= 65535) and
  (.waitSeconds | type == "number" and floor == . and . >= 300 and . <= 7200)
' "$config" >/dev/null || { printf 'Error: invalid desktop JSON configuration.\n' >&2; exit 2; }
if [[ "$mode" == --plan ]]; then
  jq . "$config"
  printf '\nPlan: separate Rocky 9 cloud VM with XFCE, Firefox, SSH, VNC, and tunneled RDP.\n'
  printf 'No existing guests/disks are changed. RDP password is set directly in the terminal after provisioning.\n'
  exit 0
fi
key="$repo_root/$(jq -r .sshPrivateKey "$config")"
known_hosts="$repo_root/$(jq -r .sshKnownHosts "$config")"
image_sha=$(jq -r .image.sha256 "$config")
wait_seconds=$(jq -r .waitSeconds "$config")
msl_assert_lab_files
msl_assert_outer_vm
msl_discover_outer_ip
virtctl="$MSL_VIRTCTL"
outer_ip="$MSL_OUTER_IP"
ssh_options=("${MSL_OUTER_SSH_OPTS[@]}")
remote_kubectl() { msl_remote_kubectl "$@"; }
namespace_json=$(remote_kubectl get namespace rocky-desktop --ignore-not-found -o json)
if [[ -n "$namespace_json" ]]; then
  jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac"' <<< "$namespace_json" >/dev/null || {
    printf 'Error: refusing unowned namespace.\n' >&2; exit 1;
  }
elif [[ "$mode" != --apply ]]; then
  printf 'Error: desktop not provisioned; run --apply.\n' >&2; exit 1
fi
vm_json=""
if [[ -n "$namespace_json" ]]; then vm_json=$(remote_kubectl get vm rocky-desktop -n rocky-desktop --ignore-not-found -o json); fi
if [[ -n "$vm_json" ]]; then
  jq -e --arg sha "$image_sha" '
    .metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac" and
    .metadata.annotations["microsegmentation-lab/image-sha256"] == $sha and .spec.runStrategy == "Manual" and
    any(.spec.template.spec.volumes[]; .name == "osdisk" and .persistentVolumeClaim.claimName == "rocky-desktop-disk")
  ' <<< "$vm_json" >/dev/null || { printf 'Error: refusing unexpected existing desktop VM.\n' >&2; exit 1; }
fi
generate_key=false
if [[ "$mode" == --apply ]]; then generate_key=true; fi
msl_ensure_keypair "$key" "$known_hosts" microsegmentation-iac-rocky-desktop "$generate_key" work/rocky-desktop_ed25519
public_key="$MSL_PUBLIC_KEY"
desktop_ssh() {
  msl_guest_ssh labadmin rocky-desktop rocky-desktop "$key" "$known_hosts" "$@"
}
case "$mode" in
  --ssh) desktop_ssh --local-ssh-opts=-tt; exit ;;
  --vnc) exec "$virtctl" vnc rocky-desktop -n rocky-desktop ;;
  --rdp)
    port=$(jq -r .rdpLocalPort "$config")
    printf 'RDP tunnel: connect your RDP client to 127.0.0.1:%s as desktop. Keep this terminal open; Ctrl+C closes the tunnel.\n' "$port"
    desktop_ssh --local-ssh-opts=-N --local-ssh-opts="-L127.0.0.1:$port:127.0.0.1:3389" --local-ssh-opts='-o ExitOnForwardFailure=yes'
    exit ;;
  --set-desktop-password)
    [[ -t 0 ]] || { printf 'Error: enter the password directly in an interactive terminal.\n' >&2; exit 1; }
    desktop_ssh --local-ssh-opts=-tt --command='sudo -n passwd desktop'
    exit ;;
esac

if [[ "$mode" == --apply ]]; then
  free_kib=$(ssh "${ssh_options[@]}" "labadmin@$outer_ip" 'df -Pk /' | awk 'NR == 2 {print $4}')
  available_kib=$(ssh "${ssh_options[@]}" "labadmin@$outer_ip" "awk '/MemAvailable:/ {print \$2}' /proc/meminfo")
  disk_gib=$(jq -r '.diskSize | rtrimstr("Gi") | tonumber' "$config")
  memory_gib=$(jq -r '.memory | rtrimstr("Gi") | tonumber' "$config")
  if [[ -z "$vm_json" ]] && (( free_kib < (disk_gib + 10) * 1048576 || available_kib < (memory_gib + 2) * 1048576 )); then
    printf 'Error: insufficient free disk or available memory; existing guests were not changed.\n' >&2; exit 1
  fi
  if [[ -z "$namespace_json" ]]; then
    jq -n '{apiVersion:"v1",kind:"Namespace",metadata:{name:"rocky-desktop",labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac"}}}' |
      ssh "${ssh_options[@]}" "labadmin@$outer_ip" 'sudo -n k3s kubectl create -f -'
  fi
  pvc=$(remote_kubectl get pvc rocky-desktop-disk -n rocky-desktop --ignore-not-found -o json)
  if [[ -n "$pvc" ]]; then
    jq -e --arg sha "$image_sha" --arg size "$(jq -r .diskSize "$config")" '
      .metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac" and
      .metadata.annotations["microsegmentation-lab/image-sha256"] == $sha and .spec.storageClassName == "local-path" and
      .spec.volumeMode == "Filesystem" and .spec.resources.requests.storage == $size
    ' <<< "$pvc" >/dev/null || { printf 'Error: existing desktop PVC does not match.\n' >&2; exit 1; }
  fi
  complete=$(jq -r '.status.phase == "Bound" and .metadata.annotations["cdi.kubevirt.io/storage.condition.running.reason"] == "Completed"' <<< "${pvc:-"{}"}")
  if [[ "$complete" != true ]]; then
    [[ -z "$vm_json" ]] || { printf 'Error: refusing to upload over attached desktop disk.\n' >&2; exit 1; }
    image="$work_dir/rocky-desktop-$image_sha.qcow2"
    [[ ! -L "$image.part" ]] || exit 1
    msl_fetch_image "$(jq -r .image.url "$config")" "$image_sha" "$image"
    trap msl_upload_tunnel_close EXIT
    msl_find_free_port 18465 18475
    port="$MSL_FREE_PORT"
    msl_upload_tunnel_open "$port"
    if [[ -z "$pvc" ]]; then
      jq -n --arg size "$(jq -r .diskSize "$config")" --arg sha "$image_sha" \
        '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:"rocky-desktop-disk",namespace:"rocky-desktop",labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac"},annotations:{"microsegmentation-lab/image-sha256":$sha,"cdi.kubevirt.io/storage.bind.immediate.requested":"true"}},spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",resources:{requests:{storage:$size}}}}' |
        ssh "${ssh_options[@]}" "labadmin@$outer_ip" 'sudo -n k3s kubectl create -f -'
    fi
    "$virtctl" image-upload pvc rocky-desktop-disk -n rocky-desktop --no-create --force-bind \
      --uploadproxy-url="https://127.0.0.1:$port" --insecure --image-path="$image" --wait-secs=300
    msl_upload_tunnel_close; trap - EXIT
  fi
  if [[ -z "$vm_json" ]]; then
    desktop_script=$(jq -Rs . < "$script_dir/configure-desktop.sh")
    cloudinit=$(jq -c --arg key "$public_key" --argjson script "$desktop_script" '
      {hostname:.hostname,timezone:.timezone,manage_etc_hosts:true,disable_root:true,ssh_pwauth:false,
      users:[{name:.adminUser,groups:["wheel"],sudo:["ALL=(ALL) NOPASSWD:ALL"],shell:"/bin/bash",lock_passwd:true,ssh_authorized_keys:[$key]},
      {name:.desktopUser,shell:"/bin/bash",lock_passwd:true}],
      write_files:[{path:"/usr/local/sbin/configure-lab-desktop",owner:"root:root",permissions:"0700",content:$script}],
      runcmd:[["bash","/usr/local/sbin/configure-lab-desktop"]]}
    ' "$config")
    printf -v cloudinit '#cloud-config\n%s\n' "$cloudinit"
    existing_secret=$(remote_kubectl get secret rocky-desktop-cloudinit -n rocky-desktop --ignore-not-found -o json)
    if [[ -n "$existing_secret" ]]; then
      jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac"' <<< "$existing_secret" >/dev/null || {
        printf 'Error: refusing unowned cloud-init Secret.\n' >&2; exit 1;
      }
    fi
    jq -n --arg data "$cloudinit" \
      '{apiVersion:"v1",kind:"Secret",metadata:{name:"rocky-desktop-cloudinit",namespace:"rocky-desktop",labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac"}},type:"Opaque",stringData:{userdata:$data}}' |
      ssh "${ssh_options[@]}" "labadmin@$outer_ip" 'sudo -n k3s kubectl apply -f -'
    jq -n --slurpfile cfg "$config" --arg data "$cloudinit" '$cfg[0] as $cfg |
      {apiVersion:"kubevirt.io/v1",kind:"VirtualMachine",metadata:{name:"rocky-desktop",namespace:"rocky-desktop",labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac","microsegmentation-lab/role":"desktop"},annotations:{"microsegmentation-lab/image-sha256":$cfg.image.sha256}},
      spec:{runStrategy:"Manual",template:{metadata:{labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac","microsegmentation-lab/role":"desktop"}},spec:{domain:{cpu:{cores:$cfg.cores},resources:{requests:{memory:$cfg.memory}},devices:{disks:[{name:"osdisk",disk:{bus:"virtio"},bootOrder:1},{name:"cloudinit",disk:{bus:"virtio"}}],interfaces:[{name:"default",masquerade:{},ports:[{name:"ssh",port:22,protocol:"TCP"}]}]}},networks:[{name:"default",pod:{}}],volumes:[{name:"osdisk",persistentVolumeClaim:{claimName:"rocky-desktop-disk"}},{name:"cloudinit",cloudInitNoCloud:{secretRef:{name:"rocky-desktop-cloudinit"}}}]}}}}' |
      ssh "${ssh_options[@]}" "labadmin@$outer_ip" 'sudo -n k3s kubectl create -f -'
  fi
  vmi=$(remote_kubectl get vmi rocky-desktop -n rocky-desktop --ignore-not-found -o name)
  if [[ -z "$vmi" ]]; then "$virtctl" start rocky-desktop -n rocky-desktop; fi
  remote_kubectl wait --for=create vmi/rocky-desktop -n rocky-desktop --timeout=120s
  remote_kubectl wait --for=condition=Ready vmi/rocky-desktop -n rocky-desktop --timeout=180s
fi
msl_wait_for_guest_ssh labadmin rocky-desktop rocky-desktop "$key" "$known_hosts" "$wait_seconds" desktop
printf 'Desktop SSH is ready. Waiting for cloud-init completion (cloud-init prints its status below)...\n'
msl_guest_cloudinit_wait labadmin rocky-desktop rocky-desktop "$key" "$known_hosts" "$wait_seconds"
printf 'Verifying desktop services...\n'
desktop_ssh --command='set -eu; . /etc/os-release; test "$ID" = rocky; test "${VERSION_ID%%.*}" = 9; cat /etc/os-release; sudo -n true; test "$(getenforce)" = Enforcing; rpm -q xfce4-session firefox xrdp xorgxrdp xrdp-selinux; systemctl is-active sshd qemu-guest-agent xrdp lightdm; ss -H -ltn "sport = :3389" | grep -q "127.0.0.1:3389"; test -z "$(ss -H -ltn "sport = :3389" | grep -v "127.0.0.1:3389")"; firefox --version; printf "PASS Rocky desktop, browser, SELinux, and loopback-only RDP services\n"'
printf 'Next: --set-desktop-password in your terminal, then --rdp and connect to localhost. --vnc and --ssh are also available.\n'