#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
vm_name="lab-k8s-01"
vm_user="labadmin"
managed_title="microsegmentation-iac-lab-k8s-01"
ssh_key="$work_dir/${vm_name}_ed25519"
known_hosts="$work_dir/${vm_name}_known_hosts"
repair=false

usage() {
  printf 'Usage: %s [--diagnose|--repair]\n' "${0##*/}"
  printf 'Diagnose or repair a missing libvirt NAT address/default route after OVN bridges the guest uplink.\n'
  printf 'Default mode is diagnose-only. --repair applies the current DHCP lease to the verified OVS bridge.\n'
}

case "${1:---diagnose}" in
  --diagnose)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    ;;
  --repair)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    repair=true
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

for command_name in virsh ssh jq python3 base64 awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required on the physical QEMU/KVM host.\n' "$command_name" >&2
    exit 1
  fi
done

if [[ ! -r "$ssh_key" ]]; then
  printf 'Error: SSH private key is missing: %s\n' "$ssh_key" >&2
  exit 1
fi
if [[ ! -r "$known_hosts" ]]; then
  install -m 0600 /dev/null "$known_hosts"
fi
if ! virsh -c qemu:///system dominfo "$vm_name" >/dev/null 2>&1; then
  printf 'Error: VM %s does not exist.\n' "$vm_name" >&2
  exit 1
fi
existing_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
if [[ "$existing_title" != "$managed_title" ]]; then
  printf 'Error: VM %s is not marked as managed by this project; refusing recovery.\n' "$vm_name" >&2
  exit 1
fi
vm_state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
if [[ "$vm_state" != running ]]; then
  printf 'Error: VM %s must be running; current state: %s.\n' "$vm_name" "$vm_state" >&2
  exit 1
fi

mac_address=$(virsh -c qemu:///system domiflist "$vm_name" | awk '$3 == "default" { print tolower($5); exit }')
if [[ ! "$mac_address" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
  printf 'Error: could not identify a valid MAC address for the managed libvirt NAT interface.\n' >&2
  exit 1
fi
guest_ip=$(virsh -c qemu:///system net-dhcp-leases default |
  awk -v mac="$mac_address" 'tolower($3) == mac && $4 == "ipv4" { split($5, address, "/"); print address[1]; exit }')

network_xml=$(virsh -c qemu:///system net-dumpxml default)
read -r gateway prefix < <(python3 -c '
import ipaddress
import sys
import xml.etree.ElementTree as ET

root = ET.fromstring(sys.stdin.read())
interface = root.find("./ip")
if interface is None or not interface.get("address"):
    raise SystemExit("libvirt default network has no IPv4 gateway")
gateway = ipaddress.ip_address(interface.get("address"))
mask = interface.get("netmask")
prefix = interface.get("prefix")
network = ipaddress.ip_network(f"{gateway}/{mask or prefix}", strict=False)
print(gateway, network.prefixlen)
' <<< "$network_xml") || {
  printf 'Error: could not determine the libvirt NAT gateway and prefix.\n' >&2
  exit 1
}
interface_json=$(virsh -c qemu:///system qemu-agent-command "$vm_name" \
  '{"execute":"guest-network-get-interfaces"}') || {
  printf 'Error: no DHCP lease and QEMU guest agent is unavailable for guest MAC %s.\n' "$mac_address" >&2
  exit 1
}
if [[ -z "$guest_ip" ]]; then
  guest_ip=$(jq -r --arg mac "$mac_address" \
    '.return[] | select((."hardware-address" // "" | ascii_downcase) == $mac) | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("169.254.") | not)) | .["ip-address"]' \
    <<< "$interface_json" | awk 'NR == 1 { print; exit }')
fi
if [[ ! "$guest_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  printf 'Error: neither DHCP lease nor guest-agent data provides an IPv4 address for guest MAC %s.\n' "$mac_address" >&2
  exit 1
fi
if ! python3 -c 'import ipaddress,sys; ipaddress.ip_interface(sys.argv[1])' "$guest_ip/$prefix" 2>/dev/null; then
  printf 'Error: DHCP address %s is invalid for the libvirt network prefix /%s.\n' "$guest_ip" "$prefix" >&2
  exit 1
fi
if ! python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)' \
  "$gateway" "$guest_ip/$prefix"; then
  printf 'Error: DHCP address %s is outside the libvirt network containing gateway %s/%s.\n' "$guest_ip" "$gateway" "$prefix" >&2
  exit 1
fi

qga_command() {
  local request
  request=$(jq -cn --arg command "$1" \
    '{execute:"guest-exec",arguments:{path:"/bin/sh",arg:["-c",$command],"capture-output":true}}')
  virsh -c qemu:///system qemu-agent-command "$vm_name" "$request"
}

qga_run() {
  local command_text="$1"
  local response pid status_request status_response exited exit_code output error_output
  response=$(qga_command "$command_text") || return 1
  pid=$(jq -er '.return.pid' <<< "$response") || return 1
  for _ in $(seq 1 60); do
    status_request=$(jq -cn --argjson pid "$pid" \
      '{execute:"guest-exec-status",arguments:{pid:$pid}}')
    status_response=$(virsh -c qemu:///system qemu-agent-command "$vm_name" "$status_request") || return 1
    exited=$(jq -r '.return.exited // false' <<< "$status_response")
    if [[ "$exited" == true ]]; then
      exit_code=$(jq -r '.return.exitcode // 1' <<< "$status_response")
      output=$(jq -r '.return["out-data"] // ""' <<< "$status_response" | base64 --decode)
      error_output=$(jq -r '.return["err-data"] // ""' <<< "$status_response" | base64 --decode)
      [[ -z "$output" ]] || printf '%s' "$output"
      if [[ -n "$error_output" ]]; then
        printf '%s' "$error_output" >&2
      fi
      return "$exit_code"
    fi
    sleep 1
  done
  printf 'Error: guest-agent command did not finish within 60 seconds.\n' >&2
  return 1
}

nic_candidates=$(jq -r --arg mac "$mac_address" \
  '.return[] | select((."hardware-address" // "" | ascii_downcase) == $mac) | .name' \
  <<< "$interface_json")
if [[ -z "$nic_candidates" ]]; then
  printf 'Error: QEMU guest agent does not report the libvirt NIC MAC %s.\n' "$mac_address" >&2
  exit 1
fi

bridges=$(qga_run 'ovs-vsctl --timeout=5 list-br') || {
  printf 'Error: could not list OVS bridges inside the guest.\n' >&2
  exit 1
}
nic_name=""
bridge=""
while IFS= read -r candidate_nic; do
  [[ -n "$candidate_nic" ]] || continue
  if [[ ! "$candidate_nic" =~ ^[[:alnum:]_.-]+$ ]]; then
    printf 'Error: unsafe guest NIC name reported by QEMU guest agent: %s\n' "$candidate_nic" >&2
    exit 1
  fi
  while IFS= read -r candidate_bridge; do
    [[ -n "$candidate_bridge" ]] || continue
    [[ "$candidate_bridge" =~ ^[[:alnum:]_.-]+$ ]] || continue
    [[ "$candidate_nic" != "$candidate_bridge" ]] || continue
    bridge_ports=$(qga_run "ovs-vsctl --timeout=5 list-ports '$candidate_bridge'") || continue
    if grep -Fxq "$candidate_nic" <<< "$bridge_ports"; then
      if [[ -n "$nic_name" ]]; then
        printf 'Error: MAC %s maps to multiple OVS uplink ports; refusing to guess.\n' "$mac_address" >&2
        exit 1
      fi
      nic_name="$candidate_nic"
      bridge="$candidate_bridge"
    fi
  done <<< "$bridges"
done <<< "$nic_candidates"
if [[ -z "$nic_name" || -z "$bridge" ]]; then
  printf 'Error: could not map libvirt MAC %s to a unique physical NIC and OVS bridge. No changes made.\n' "$mac_address" >&2
  exit 1
fi

routes=$(qga_run 'ip -4 route show') || {
  printf 'Error: could not read the guest IPv4 routing table through QEMU guest agent.\n' >&2
  exit 1
}
bridge_addresses=$(qga_run "ip -o -4 address show dev '$bridge'") || {
  printf 'Error: OVS bridge %s is not available inside the guest.\n' "$bridge" >&2
  exit 1
}

printf 'Guest: %s (%s)\n' "$vm_name" "$vm_state"
printf 'Libvirt DHCP address: %s/%s; NAT gateway: %s\n' "$guest_ip" "$prefix" "$gateway"
printf 'Guest uplink: %s enslaved to OVS bridge %s\n' "$nic_name" "$bridge"
printf 'Guest IPv4 routes:\n%s\n' "${routes:-  (none)}"
printf 'OVS bridge IPv4 addresses:\n%s\n' "${bridge_addresses:-  (none)}"

if grep -Eq '^default([[:space:]]|$)' <<< "$routes"; then
  printf 'Diagnosis: a default route already exists; no route change is needed.\n'
  if [[ "$repair" == true ]]; then
    ssh_options=(
      -i "$ssh_key"
      -o IdentitiesOnly=yes
      -o BatchMode=yes
      -o ConnectTimeout=5
      -o StrictHostKeyChecking=accept-new
      -o "UserKnownHostsFile=$known_hosts"
    )
    if ssh "${ssh_options[@]}" "$vm_user@$guest_ip" true >/dev/null 2>&1; then
      printf 'PASS: SSH is reachable at %s; no changes made.\n' "$guest_ip"
      exit 0
    fi
    printf 'Error: a default route exists, but SSH is still unavailable. No changes made.\n' >&2
    exit 1
  fi
  exit 0
fi

if [[ "$repair" != true ]]; then
  printf '\nDiagnosis: the guest has no IPv4 default route; SSH cannot reliably use its libvirt DHCP lease.\n'
  printf 'No changes made. Run: bash scripts/20-install-k3s-kubevirt/repair-guest-network.sh --repair\n'
  exit 0
fi

printf '\nRepairing the OVS bridge with the current DHCP lease and libvirt gateway...\n'
qga_run "ip address replace '$guest_ip/$prefix' dev '$bridge' && ip route replace default via '$gateway' dev '$bridge'"

repaired_routes=$(qga_run 'ip -4 route show')
if ! grep -Fq "default via $gateway dev $bridge" <<< "$repaired_routes"; then
  printf 'Error: expected default route was not installed. Current routes:\n%s\n' "$repaired_routes" >&2
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
if ! ssh "${ssh_options[@]}" "$vm_user@$guest_ip" true >/dev/null 2>&1; then
  printf 'The guest route is repaired, but SSH to %s is still unavailable. Inspect sshd and the guest firewall.\n' "$guest_ip" >&2
  exit 1
fi

printf 'PASS: default route restored and SSH is reachable at %s.\n' "$guest_ip"
printf 'Now rerun: bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh\n'