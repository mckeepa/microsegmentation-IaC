#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
vm_name="lab-k8s-01"
managed_title="microsegmentation-iac-lab-k8s-01"
disk_target="vda"
dry_run=false

usage() {
  printf 'Usage: %s <total-size-gib> [--dry-run]\n' "${0##*/}"
  printf 'Increase the managed lab VM disk and grow its Ubuntu root filesystem online.\n'
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 2
fi
target_gib="$1"
if [[ ! "$target_gib" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Error: total size must be a positive whole number of GiB.\n' >&2
  usage >&2
  exit 2
fi
if [[ $# -eq 2 ]]; then
  if [[ "$2" != --dry-run ]]; then
    usage >&2
    exit 2
  fi
  dry_run=true
fi

for command_name in virsh jq python3 awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required on the QEMU/KVM host.\n' "$command_name" >&2
    exit 1
  fi
done

if ! virsh -c qemu:///system dominfo "$vm_name" >/dev/null 2>&1; then
  printf 'Error: managed VM %s does not exist.\n' "$vm_name" >&2
  exit 1
fi
existing_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
if [[ "$existing_title" != "$managed_title" ]]; then
  printf 'Error: VM %s is not marked as managed by this project; refusing to resize it.\n' "$vm_name" >&2
  exit 1
fi
vm_state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
if [[ "$vm_state" != running ]]; then
  printf 'Error: VM %s must be running for live resize; current state: %s.\n' "$vm_name" "$vm_state" >&2
  exit 1
fi

disk_info=$(virsh -c qemu:///system domblklist "$vm_name" --details)
disk_path=$(awk -v target="$disk_target" '$3 == target && $1 == "file" && $2 == "disk" { print $4; exit }' <<< "$disk_info")
if [[ -z "$disk_path" || "$disk_path" != */lab-k8s-01.qcow2 ]]; then
  printf 'Error: expected the managed QCOW2 system disk at target %s; found: %s.\n' "$disk_target" "${disk_path:-none}" >&2
  exit 1
fi

current_bytes=$(virsh -c qemu:///system domblkinfo "$vm_name" "$disk_target" |
  awk '$1 == "Capacity:" { print $2; exit }')
if [[ ! "$current_bytes" =~ ^[0-9]+$ ]]; then
  printf 'Error: could not read the current virtual capacity for %s.\n' "$disk_target" >&2
  exit 1
fi
target_bytes=$((target_gib * 1024 * 1024 * 1024))
current_gib=$(((current_bytes + 1024 * 1024 * 1024 - 1) / (1024 * 1024 * 1024)))
if (( target_bytes < current_bytes )); then
  printf 'Error: requested total size %s GiB is smaller than current capacity %s GiB; shrinking is not supported.\n' \
    "$target_gib" "$current_gib" >&2
  exit 1
fi

pool_info=$(virsh -c qemu:///system pool-info --bytes default)
pool_available=$(awk -F: '/Available:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<< "$pool_info")
minimum_pool_available=$((150 * 1024 * 1024 * 1024))
if [[ ! "$pool_available" =~ ^[0-9]+$ ]] || (( pool_available < minimum_pool_available )); then
  printf 'Error: libvirt default storage needs at least 150 GiB free before resizing; current free space is %s GiB.\n' \
    "$(( ${pool_available:-0} / 1024 / 1024 / 1024 ))" >&2
  exit 1
fi

interface_json=$(virsh -c qemu:///system qemu-agent-command "$vm_name" \
  '{"execute":"guest-network-get-interfaces"}') || {
  printf 'Error: QEMU guest agent is unavailable; it is required to grow the guest partition and filesystem.\n' >&2
  exit 1
}

guest_root=$(virsh -c qemu:///system qemu-agent-command "$vm_name" \
  '{"execute":"guest-exec","arguments":{"path":"/bin/sh","arg":["-c","findmnt -n -o SOURCE /"],"capture-output":true}}')
guest_exec_pid=$(jq -er '.return.pid' <<< "$guest_root")
guest_root=""
for _ in $(seq 1 30); do
  guest_exec_status=$(virsh -c qemu:///system qemu-agent-command "$vm_name" \
    "$(jq -cn --argjson pid "$guest_exec_pid" '{execute:"guest-exec-status",arguments:{pid:$pid}}')")
  if [[ $(jq -r '.return.exited // false' <<< "$guest_exec_status") == true ]]; then
    guest_root=$(jq -r '.return["out-data"] // ""' <<< "$guest_exec_status" | base64 --decode | tr -d '\r\n')
    break
  fi
  sleep 1
done
if [[ "$guest_root" != /dev/mapper/ubuntu--vg-ubuntu--lv ]]; then
  printf 'Error: expected the known Ubuntu LVM root, found %s; refusing to resize guest partitions automatically.\n' \
    "${guest_root:-unknown}" >&2
  exit 1
fi

if [[ "$dry_run" == true ]]; then
  printf 'Dry run: no disk or guest filesystem changes will be made.\n'
  printf 'VM: %s (%s)\nDisk: %s (%s)\n' "$vm_name" "$vm_state" "$disk_path" "$disk_target"
  printf 'Current virtual capacity: %s GiB\nRequested total capacity: %s GiB\n' "$current_gib" "$target_gib"
  if (( target_bytes > current_bytes )); then
    printf 'Planned host operation: virsh blockresize %s %s --size %sG\n' "$vm_name" "$disk_path" "$target_gib"
  else
    printf 'Virtual disk already has the requested capacity; guest partition/LVM/filesystem growth will still be checked.\n'
  fi
  printf 'Planned guest operation: growpart /dev/vda 3; pvresize /dev/vda3; lvextend -r -l +100%%FREE /dev/ubuntu-vg/ubuntu-lv\n'
  exit 0
fi

if (( target_bytes > current_bytes )); then
  printf 'Resizing live disk from %s GiB to %s GiB...\n' "$current_gib" "$target_gib"
  virsh -c qemu:///system blockresize "$vm_name" "$disk_path" --size "${target_gib}G"
else
  printf 'Virtual disk already meets requested size (%s GiB); continuing guest filesystem growth/verification.\n' "$target_gib"
fi

guest_resize_command='set -e; command -v growpart >/dev/null; command -v pvresize >/dev/null; command -v lvextend >/dev/null; command -v resize2fs >/dev/null; growpart /dev/vda 3; pvresize /dev/vda3; lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv; df -h /'
guest_resize_request=$(jq -cn --arg command "$guest_resize_command" \
  '{execute:"guest-exec",arguments:{path:"/bin/sh",arg:["-c",$command],"capture-output":true}}')
guest_resize_response=$(virsh -c qemu:///system qemu-agent-command "$vm_name" "$guest_resize_request")
guest_resize_pid=$(jq -er '.return.pid' <<< "$guest_resize_response")
for _ in $(seq 1 180); do
  guest_resize_status=$(virsh -c qemu:///system qemu-agent-command "$vm_name" \
    "$(jq -cn --argjson pid "$guest_resize_pid" '{execute:"guest-exec-status",arguments:{pid:$pid}}')")
  if [[ $(jq -r '.return.exited // false' <<< "$guest_resize_status") == true ]]; then
    guest_exit_code=$(jq -r '.return.exitcode // 1' <<< "$guest_resize_status")
    guest_output=$(jq -r '.return["out-data"] // ""' <<< "$guest_resize_status" | base64 --decode)
    guest_error=$(jq -r '.return["err-data"] // ""' <<< "$guest_resize_status" | base64 --decode)
    [[ -z "$guest_output" ]] || printf '%s' "$guest_output"
    [[ -z "$guest_error" ]] || printf '%s' "$guest_error" >&2
    if [[ "$guest_exit_code" != 0 ]]; then
      printf 'Error: virtual disk is %s GiB, but guest partition/LVM/filesystem growth failed. Fix the reported guest error and rerun this script with the same total size; it is safe to resume.\n' "$target_gib" >&2
      exit "$guest_exit_code"
    fi
    break
  fi
  sleep 1
done
if [[ $(jq -r '.return.exited // false' <<< "$guest_resize_status") != true ]]; then
  printf 'Error: guest partition/LVM/filesystem resize did not finish within 180 seconds. Rerun with the same target size to resume.\n' >&2
  exit 1
fi

printf 'Disk resize completed. Confirm free space with df -h / inside the guest.\n'