#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

vm_name="lab-k8s-01"
managed_title="microsegmentation-iac-lab-k8s-01"
minimum_vm_gib=24
host_reserve_gib=8
dry_run=false
target_gib=""

usage() {
  printf 'Usage: %s [total-memory-gib] [--dry-run]\n' "${0##*/}"
  printf 'Display host/VM memory and interactively set the managed VM next-boot allocation.\n'
}
for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=true ;;
    --help|-h) usage; exit 0 ;;
    *)
      if [[ -n "$target_gib" || ! "$argument" =~ ^[1-9][0-9]{0,3}$ ]]; then usage >&2; exit 2; fi
      target_gib="$argument"
      ;;
  esac
done
for command_name in virsh xmllint awk; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Error: %s is required on the physical QEMU/KVM host.\n' "$command_name" >&2; exit 1;
  }
done
if ! virsh -c qemu:///system dominfo "$vm_name" >/dev/null 2>&1; then
  printf 'Error: managed VM %s does not exist.\n' "$vm_name" >&2; exit 1
fi
if [[ "$(virsh -c qemu:///system desc "$vm_name" --title)" != "$managed_title" ]]; then
  printf 'Error: ownership marker mismatch; refusing to change memory.\n' >&2; exit 1
fi
state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
case "$state" in
  running|"shut off") ;;
  *) printf 'Error: resolve VM state %s manually before changing memory.\n' "$state" >&2; exit 1 ;;
esac
configured_xml=$(virsh -c qemu:///system dumpxml "$vm_name" --inactive)

xml_memory_kib() {
  local xml="$1" element="$2" amount unit
  amount=$(xmllint --xpath "string(/domain/$element)" - <<< "$xml")
  unit=$(xmllint --xpath "string(/domain/$element/@unit)" - <<< "$xml")
  [[ "$amount" =~ ^[1-9][0-9]{0,12}$ ]] || { printf 'Error: cannot parse VM memory.\n' >&2; return 1; }
  case "$unit" in
    ""|KiB|kib) printf '%s\n' "$amount" ;;
    MiB|mib) printf '%s\n' "$((amount * 1024))" ;;
    GiB|gib) printf '%s\n' "$((amount * 1048576))" ;;
    *) printf 'Error: unsupported memory unit %s; inspect VM XML.\n' "$unit" >&2; return 1 ;;
  esac
}
configured_kib=$(xml_memory_kib "$configured_xml" currentMemory)
maximum_kib=$(xml_memory_kib "$configured_xml" memory)
if [[ "$(xmllint --xpath 'count(/domain/maxMemory | /domain/devices/memory | /domain/memoryBacking/hugepages | /domain/cpu/numa)' - <<< "$configured_xml")" != 0 ]]; then
  printf 'Error: hot-plug, hugepage, or NUMA memory configuration requires manual review.\n' >&2; exit 1
fi
live_kib=0
if [[ "$state" == running ]]; then
  live_xml=$(virsh -c qemu:///system dumpxml "$vm_name")
  live_kib=$(xml_memory_kib "$live_xml" currentMemory)
fi
gib() { awk -v kib="$1" 'BEGIN { printf "%.1f", kib / 1048576 }'; }
read_host_memory() {
  host_total_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  host_available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  host_free_kib=$(awk '/^MemFree:/ {print $2}' /proc/meminfo)
  [[ "$host_total_kib" =~ ^[1-9][0-9]*$ && "$host_available_kib" =~ ^[0-9]+$ && "$host_free_kib" =~ ^[0-9]+$ ]] || {
    printf 'Error: cannot read physical-host memory.\n' >&2; return 1;
  }
}
read_host_memory
printf 'Physical HOST memory:\n'
printf '  Total RAM: %s GiB\n  Available RAM: %s GiB (includes reclaimable cache)\n  Completely free RAM: %s GiB\n' \
  "$(gib "$host_total_kib")" "$(gib "$host_available_kib")" "$(gib "$host_free_kib")"
printf '\nManaged VM: %s (%s)\n' "$vm_name" "$state"
if [[ "$state" == running ]]; then printf '  Current live allocation: %s GiB\n' "$(gib "$live_kib")"; fi
printf '  Next-boot allocation: %s GiB\n  Configured maximum: %s GiB\n' "$(gib "$configured_kib")" "$(gib "$maximum_kib")"
printf '  Minimum lab allocation: %s GiB; required host reserve: %s GiB\n' "$minimum_vm_gib" "$host_reserve_gib"
printf '\nThis reallocates existing RAM; it cannot increase physical-host RAM. Swap is not counted.\n'
printf 'Increasing VM memory will not fix a physical-host MemAvailable preflight failure.\n'
printf 'Only persistent next-boot settings change. No live resize, shutdown, or restart is performed.\n'

if [[ -z "$target_gib" ]]; then
  [[ -t 0 ]] || { printf 'Error: an interactive terminal is required to choose the memory setting.\n' >&2; exit 1; }
  while true; do
    if ! read -r -p "New TOTAL memory for $vm_name in GiB (minimum $minimum_vm_gib; Enter cancels): " target_gib; then
      printf '\nCancelled; no changes made.\n'; exit 1
    fi
    if [[ -z "$target_gib" ]]; then printf 'Cancelled; no changes made.\n'; exit 0; fi
    if [[ "$target_gib" =~ ^[1-9][0-9]{0,3}$ ]]; then break; fi
    printf 'Enter a positive whole number of GiB, such as 24 or 32.\n'
  done
fi
target_kib=$((target_gib * 1048576))
reserve_kib=$((host_reserve_gib * 1048576))
check_capacity() {
  local increase_kib="$target_kib"
  if (( target_gib < minimum_vm_gib )); then
    printf 'Error: the lab minimum is %s GiB; refusing an undersized VM.\n' "$minimum_vm_gib" >&2; return 1
  fi
  if (( target_kib + reserve_kib > host_total_kib )); then
    printf 'Error: requested memory would leave less than %s GiB of total host RAM outside this VM.\n' "$host_reserve_gib" >&2; return 1
  fi
  if [[ "$state" == running ]]; then
    increase_kib=$((target_kib - live_kib))
    if (( increase_kib < 0 )); then increase_kib=0; fi
  fi
  if (( increase_kib + reserve_kib > host_available_kib )); then
    printf 'Error: current host availability cannot cover the additional allocation and %s GiB reserve. Close workloads and retry.\n' "$host_reserve_gib" >&2
    return 1
  fi
}
check_capacity
printf '\nProposed next-boot memory: %s GiB (new total, not additional RAM).\n' "$target_gib"
if (( target_kib == configured_kib && target_kib == maximum_kib )); then
  printf 'Already configured; no changes required.\n'; exit 0
fi
if [[ "$dry_run" == true ]]; then
  printf 'Dry run: would set persistent memory and maximum to %s GiB; no changes made.\n' "$target_gib"
  exit 0
fi
[[ -t 0 ]] || { printf 'Error: interactive approval is required; use --dry-run for unattended previews.\n' >&2; exit 1; }
printf 'A full outer-VM stop/start is needed later, interrupting the cluster and nested guests.\n'
printf 'Do not stop the lab while Windows installation or other guest writes are in progress.\n'
if ! read -r -p "Apply $target_gib GiB to the NEXT BOOT of $vm_name? [y/N] " answer; then
  printf '\nCancelled; no changes made.\n'; exit 1
fi
case "${answer,,}" in
  y|yes) ;;
  *) printf 'Cancelled; no changes made.\n'; exit 0 ;;
esac
read_host_memory
check_capacity
if [[ "$(virsh -c qemu:///system desc "$vm_name" --title)" != "$managed_title" ||
      "$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')" != "$state" ||
      "$(virsh -c qemu:///system dumpxml "$vm_name" --inactive)" != "$configured_xml" ]]; then
  printf 'Error: VM ownership/state/configuration changed during the prompt; rerun before applying.\n' >&2; exit 1
fi
if (( target_kib < configured_kib )); then
  virsh -c qemu:///system setmem "$vm_name" "$target_kib" --config
fi
if ! virsh -c qemu:///system setmaxmem "$vm_name" "$target_kib" --config; then
  printf 'Error: maximum-memory update failed. Inspect persistent settings before retrying; live memory is unchanged.\n' >&2; exit 1
fi
if ! virsh -c qemu:///system setmem "$vm_name" "$target_kib" --config; then
  printf 'Error: maximum updated but allocation update failed. Inspect persistent settings before retrying; live memory is unchanged.\n' >&2; exit 1
fi
updated_xml=$(virsh -c qemu:///system dumpxml "$vm_name" --inactive)
[[ "$(xml_memory_kib "$updated_xml" currentMemory)" == "$target_kib" && "$(xml_memory_kib "$updated_xml" memory)" == "$target_kib" ]] || {
  printf 'Error: persistent memory verification failed; inspect the VM configuration.\n' >&2; exit 1;
}
printf 'PASS next-boot memory set to %s GiB. Live allocation is unchanged; no guests were restarted.\n' "$target_gib"
printf 'Recheck host capacity before the later full stop/start; this snapshot is not a future capacity guarantee.\n'