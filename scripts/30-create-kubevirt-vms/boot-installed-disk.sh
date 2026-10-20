#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
outer_vm="lab-k8s-01"
namespace="netpol-test"
dry_run=false

if (( $# < 1 || $# > 2 )); then
  printf 'Usage: %s <netpol-server-rocky|netpol-client|netpol-server-windows> [--dry-run]\n' "${0##*/}" >&2
  exit 2
fi
target_vm="$1"
case "$target_vm" in
  netpol-server-rocky|netpol-client|netpol-server-windows) ;;
  *) printf 'Error: unrecognized task 30 VM: %s\n' "$target_vm" >&2; exit 2 ;;
esac
if (( $# == 2 )); then
  if [[ "$2" != --dry-run ]]; then
    printf 'Error: unknown option: %s\n' "$2" >&2
    exit 2
  fi
  dry_run=true
fi

for command_name in virsh ssh jq awk; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Error: %s is required on the physical host.\n' "$command_name" >&2
    exit 1
  }
done
if [[ "$(virsh -c qemu:///system desc "$outer_vm" --title)" != microsegmentation-iac-lab-k8s-01 ||
      "$(virsh -c qemu:///system domstate "$outer_vm")" != running ]]; then
  printf 'Error: the project-managed outer VM must be running.\n' >&2
  exit 1
fi
guest_ip=$(virsh -c qemu:///system domifaddr "$outer_vm" --source lease |
  awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }')
if [[ -z "$guest_ip" ]]; then
  guest_mac=$(virsh -c qemu:///system domiflist "$outer_vm" |
    awk '$3 == "default" { print tolower($5); exit }')
  interface_json=$(virsh -c qemu:///system qemu-agent-command "$outer_vm" \
    '{"execute":"guest-network-get-interfaces"}')
  guest_ip=$(jq -r --arg mac "$guest_mac" \
    '[.return[] | select((."hardware-address" // "" | ascii_downcase) == $mac) | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("169.254.") | not)) | .["ip-address"]] | first // empty' \
    <<< "$interface_json")
fi
if [[ -z "$guest_ip" || ! -r "$work_dir/${outer_vm}_ed25519" ]]; then
  printf 'Error: guest address or project SSH key unavailable.\n' >&2
  exit 1
fi
ssh_options=(
  -i "$work_dir/${outer_vm}_ed25519"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$work_dir/${outer_vm}_known_hosts"
)
remote_kubectl() {
  local remote_command='sudo -n k3s kubectl'
  local argument quoted
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    remote_command+=" $quoted"
  done
  ssh "${ssh_options[@]}" "labadmin@$guest_ip" "$remote_command"
}

namespace_json=$(remote_kubectl get namespace "$namespace" -o json)
vm_json=$(remote_kubectl get vm "$target_vm" -n "$namespace" -o json)
if ! jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac"' \
  <<< "$namespace_json" >/dev/null ||
  ! jq -e --arg name "$target_vm" '
    .metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac" and
    .spec.runStrategy == "Manual" and
    (.metadata.deletionTimestamp == null) and
    ([.spec.template.spec.domain.devices.disks[] | select(.name == "osdisk" and .disk.bus == "virtio")] | length) == 1 and
    ([.spec.template.spec.domain.devices.disks[] | select(.name == "installer" and .cdrom.readonly == true)] | length) == 1 and
    any(.spec.template.spec.volumes[]; .name == "osdisk" and .persistentVolumeClaim.claimName == ($name + "-disk"))
  ' <<< "$vm_json" >/dev/null; then
  printf 'Error: ownership or expected installer/disk configuration does not match; refusing changes.\n' >&2
  exit 1
fi

patch_json=$(jq -c '
  .spec.template.spec.domain.devices.disks as $disks |
  [$disks | to_entries[] | select(.value.name == "osdisk") | .key][0] as $os_index |
  [$disks | to_entries[] | select(.value.name == "installer") | .key][0] as $iso_index |
  [
    {op:"test", path:"/metadata/uid", value:.metadata.uid},
    {op:"test", path:"/metadata/resourceVersion", value:.metadata.resourceVersion},
    {op:"test", path:"/spec/template/spec/domain/devices/disks", value:$disks},
    {op:"add", path:("/spec/template/spec/domain/devices/disks/" + ($os_index | tostring) + "/bootOrder"), value:1},
    {op:"add", path:("/spec/template/spec/domain/devices/disks/" + ($iso_index | tostring) + "/bootOrder"), value:2}
  ]
' <<< "$vm_json")
if [[ "$dry_run" == true ]]; then
  printf 'Dry run: %s will boot osdisk first and installer second after a full stop/start. No resources changed.\n' "$target_vm"
  printf '%s\n' "$patch_json" | jq .
  exit 0
fi
existing_vmi=$(remote_kubectl get vmi "$target_vm" -n "$namespace" --ignore-not-found -o name)
if [[ -n "$existing_vmi" ]]; then
  printf 'Error: %s still has a VMI. Shut down and stop it, then retry; this helper never interrupts a guest.\n' "$target_vm" >&2
  exit 1
fi
remote_kubectl patch vm "$target_vm" -n "$namespace" --type=json -p "$patch_json"
updated_vm=$(remote_kubectl get vm "$target_vm" -n "$namespace" -o json)
jq -e '
  any(.spec.template.spec.domain.devices.disks[]; .name == "osdisk" and .bootOrder == 1) and
  any(.spec.template.spec.domain.devices.disks[]; .name == "installer" and .bootOrder == 2)
' <<< "$updated_vm" >/dev/null
printf 'PASS %s now boots from osdisk first. Installer media and PVCs are preserved; the VM remains stopped.\n' "$target_vm"