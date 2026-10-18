#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir="$repo_root/work"
vm_name="lab-k8s-01"
managed_title="microsegmentation-iac-lab-k8s-01"
disk_volume="lab-k8s-01.qcow2"
execute=false

usage() {
  printf 'Usage: %s [--dry-run|--execute]\n' "${0##*/}"
  printf 'Preview or remove the project-managed lab VM and generated connection files.\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      execute=false
      shift
      ;;
    --execute)
      execute=true
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

if ! command -v virsh >/dev/null 2>&1; then
  printf 'Error: virsh is required on the QEMU/KVM host.\n' >&2
  exit 1
fi

vm_exists=false
vm_state="absent"
attached_disk=""
managed_disk_path=""
if virsh -c qemu:///system dominfo "$vm_name" >/dev/null 2>&1; then
  vm_exists=true
  existing_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
  if [[ "$existing_title" != "$managed_title" ]]; then
    printf 'Error: domain %s is not marked as managed by this project; refusing to alter it.\n' "$vm_name" >&2
    exit 1
  fi

  vm_state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
  attached_disk=$(virsh -c qemu:///system domblklist "$vm_name" --details | awk '$2 == "disk" { print $4; exit }')
  if [[ -z "$attached_disk" ]]; then
    printf 'Error: no VM disk could be identified for %s; refusing to remove the domain.\n' "$vm_name" >&2
    exit 1
  fi
  managed_disk_path=$(virsh -c qemu:///system vol-path --pool default "$disk_volume" 2>/dev/null || true)
  if [[ -n "$managed_disk_path" && "$attached_disk" != "$managed_disk_path" ]]; then
    printf 'Error: %s disk does not match the expected default-pool volume %s; refusing to delete storage.\n' "$vm_name" "$disk_volume" >&2
    exit 1
  fi
fi

printf 'Cleanup plan:\n'
if [[ "$vm_exists" == true ]]; then
  printf '  VM: %s (state: %s)\n' "$vm_name" "$vm_state"
  if [[ -n "$managed_disk_path" ]]; then
    printf '  VM disk: %s\n' "$managed_disk_path"
  else
    printf '  VM disk: no matching default-pool volume found; it will not be removed\n'
  fi
else
  printf '  VM: %s is already absent\n' "$vm_name"
fi
printf '  Generated SSH keys, known-hosts file, seed ISO, and exported kubeconfig under %s\n' "$work_dir"
printf '  Downloaded guest OS ISOs will be retained.\n'

if [[ "$execute" == false ]]; then
  printf 'Dry run only. No VM or files were changed. Use --execute to continue.\n'
  exit 0
fi

if [[ ! -t 0 ]]; then
  printf 'Error: --execute requires an interactive terminal for confirmation.\n' >&2
  exit 1
fi
printf 'This permanently deletes the lab VM disk and its contents. Type "delete %s" to continue: ' "$vm_name"
IFS= read -r confirmation
if [[ "$confirmation" != "delete $vm_name" ]]; then
  printf 'Confirmation did not match; no changes made.\n' >&2
  exit 1
fi

if [[ "$vm_exists" == true ]]; then
  if [[ "$vm_state" != "shut off" ]]; then
    virsh -c qemu:///system shutdown "$vm_name"
    deadline=$((SECONDS + 120))
    while [[ "$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')" != "shut off" ]]; do
      if (( SECONDS >= deadline )); then
        printf 'Error: %s did not shut down within 2 minutes; it was not force-stopped or deleted.\n' "$vm_name" >&2
        exit 1
      fi
      sleep 2
    done
  fi

  virsh -c qemu:///system undefine "$vm_name"
  if [[ -n "$managed_disk_path" ]]; then
    virsh -c qemu:///system vol-delete --pool default "$disk_volume"
  fi
fi

rm -f -- \
  "$work_dir/${vm_name}_ed25519" \
  "$work_dir/${vm_name}_ed25519.pub" \
  "$work_dir/${vm_name}_known_hosts" \
  "$work_dir/${vm_name}-cidata.iso" \
  "$work_dir/kubeconfig-${vm_name}.yaml"

printf 'Cleanup completed. The Ubuntu ISO was retained. You can rerun task 10, then task 20.\n'