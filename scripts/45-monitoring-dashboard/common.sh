#!/usr/bin/env bash

dashboard_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$dashboard_dir/../.." && pwd)
work_dir="$repo_root/work"

dashboard_connect() {
  local command_name outer_mac interfaces
  for command_name in virsh jq ssh; do
    command -v "$command_name" >/dev/null || { printf 'Error: %s is required.\n' "$command_name" >&2; return 1; }
  done
  if [[ "$(virsh -c qemu:///system desc lab-k8s-01 --title)" != microsegmentation-iac-lab-k8s-01 ||
        "$(virsh -c qemu:///system domstate lab-k8s-01)" != running ]]; then
    printf 'Error: the project-managed lab-k8s-01 must be running.\n' >&2; return 1
  fi
  outer_ip=$(virsh -c qemu:///system domifaddr lab-k8s-01 --source lease |
    awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }')
  if [[ -z "$outer_ip" ]]; then
    outer_mac=$(virsh -c qemu:///system domiflist lab-k8s-01 | awk '$3 == "default" { print tolower($5); exit }')
    interfaces=$(virsh -c qemu:///system qemu-agent-command lab-k8s-01 '{"execute":"guest-network-get-interfaces"}')
    outer_ip=$(jq -r --arg mac "$outer_mac" '[.return[] | select((."hardware-address" // "" | ascii_downcase) == $mac) | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("169.254.") | not)) | .["ip-address"]] | first // empty' <<< "$interfaces")
  fi
  if [[ ! "$outer_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf 'Error: no usable lab VM IPv4 address. See task 20 network diagnostics.\n' >&2; return 1
  fi
  ssh_options=(-i "$work_dir/lab-k8s-01_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes
    -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$work_dir/lab-k8s-01_known_hosts")
  ssh "${ssh_options[@]}" "labadmin@$outer_ip" 'sudo -n true'
}

dashboard_ssh() {
  ssh "${ssh_options[@]}" "labadmin@$outer_ip" "$@"
}

dashboard_kubectl() {
  local remote_command='sudo -n k3s kubectl' argument quoted
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    remote_command+=" $quoted"
  done
  dashboard_ssh "$remote_command"
}

dashboard_owned() {
  local resource_json
  resource_json=$(dashboard_kubectl get "$@" --ignore-not-found -o json) || return
  if [[ -n "$resource_json" ]] && ! jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac"' <<< "$resource_json" >/dev/null; then
    printf 'Error: refusing an unowned resource: %s\n' "$*" >&2; return 1
  fi
}