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
wait_interval=5
status_interval=30
wait_window=1200

for command_name in virsh ssh; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required on the QEMU/KVM host.\n' "$command_name" >&2
    exit 1
  fi
done

if ! virsh -c qemu:///system dominfo "$vm_name" >/dev/null 2>&1; then
  printf 'Error: VM %s does not exist. Run scripts/10-create-lab-vm/provision-lab-vm.sh first.\n' "$vm_name" >&2
  exit 1
fi
existing_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
if [[ "$existing_title" != "$managed_title" ]]; then
  printf 'Error: VM %s is not marked as managed by this project; refusing to connect.\n' "$vm_name" >&2
  exit 1
fi
if [[ ! -r "$ssh_key" ]]; then
  printf 'Error: SSH private key is missing: %s\n' "$ssh_key" >&2
  exit 1
fi

prompt_restart() {
  local answer
  if [[ ! -t 0 ]]; then
    printf 'Error: VM %s is stopped, but no interactive terminal is available to restart it.\n' "$vm_name" >&2
    return 1
  fi

  while true; do
    read -r -p "VM $vm_name is $(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r'). Start it now? [Y/n] " answer
    case "${answer,,}" in
      ""|y|yes)
        virsh -c qemu:///system start "$vm_name"
        return
        ;;
      n|no)
        printf 'Leaving VM stopped.\n'
        return 1
        ;;
      *)
        printf 'Answer yes or no.\n'
        ;;
    esac
  done
}

prompt_continue_waiting() {
  local answer
  if [[ ! -t 0 ]]; then
    printf 'Error: SSH was not ready within 20 minutes and no interactive terminal is available.\n' >&2
    return 1
  fi

  while true; do
    read -r -p 'SSH is not ready yet. Continue waiting for another 20 minutes? [Y/n] ' answer
    case "${answer,,}" in
      ""|y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf 'Answer yes or no.\n' ;;
    esac
  done
}

vm_state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
if [[ "$vm_state" != "running" ]]; then
  prompt_restart || exit 1
fi

ssh_options=(
  -i "$ssh_key"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$known_hosts"
)

declare -i next_status_at=$((SECONDS + status_interval))
declare -i deadline=$((SECONDS + wait_window))
printf 'Waiting for %s to finish booting and accept SSH as %s.\n' "$vm_name" "$vm_user"

while true; do
  vm_state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
  guest_ip=""
  case "$vm_state" in
    "shut off"|crashed)
      prompt_restart || exit 1
      deadline=$((SECONDS + wait_window))
      next_status_at=$((SECONDS + status_interval))
      ;;
    running)
      guest_ip=$(virsh -c qemu:///system domifaddr "$vm_name" --source lease 2>/dev/null | awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }' || true)
      if [[ -n "$guest_ip" ]] && ssh "${ssh_options[@]}" "$vm_user@$guest_ip" true >/dev/null 2>&1; then
        printf 'SSH is ready: %s@%s\nConnecting...\n' "$vm_user" "$guest_ip"
        exec ssh -t "${ssh_options[@]}" "$vm_user@$guest_ip"
      fi
      ;;
    *)
      printf 'VM state: %s\n' "$vm_state"
      ;;
  esac

  if (( SECONDS >= next_status_at )); then
    if [[ -n "${guest_ip:-}" ]]; then
      printf 'Still waiting: VM state %s, address %s; SSH is not ready.\n' "$vm_state" "$guest_ip"
    else
      printf 'Still waiting: VM state %s; no DHCP lease yet.\n' "$vm_state"
    fi
    next_status_at=$((SECONDS + status_interval))
  fi

  if (( SECONDS >= deadline )); then
    if ! prompt_continue_waiting; then
      printf 'Stopped waiting. The VM was not shut down by this script.\n' >&2
      exit 1
    fi
    deadline=$((SECONDS + wait_window))
    next_status_at=$((SECONDS + status_interval))
  fi

  sleep "$wait_interval"
done
