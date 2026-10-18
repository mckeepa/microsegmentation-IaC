#!/usr/bin/env bash

set -uo pipefail

failures=0
minimum_cpus=8
minimum_memory_kib=$((32 * 1024 * 1024))
minimum_disk_kib=$((150 * 1024 * 1024))

report() {
  local result="$1"
  local message="$2"
  local indicator
  if [[ "$result" == "PASS" ]]; then
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      indicator=$'\033[32m✓\033[0m'
    else
      indicator="✓"
    fi
  elif [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    indicator=$'\033[31m✗\033[0m'
  else
    indicator="✗"
  fi
  printf '%s %-4s %s\n' "$indicator" "$result" "$message"
  if [[ "$result" == "FAIL" ]]; then
    failures=$((failures + 1))
  fi
}

cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '0')
if (( cpu_count >= minimum_cpus )); then
  report PASS "Logical CPUs: $cpu_count | minimum: $minimum_cpus"
else
  report FAIL "Logical CPUs: $cpu_count | minimum: $minimum_cpus"
fi

memory_available_kib=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
memory_available_gib=$(( ${memory_available_kib:-0} / 1024 / 1024 ))
if [[ -n "$memory_available_kib" ]] && (( memory_available_kib >= minimum_memory_kib )); then
  report PASS "Available memory: ${memory_available_gib} GiB | minimum: 32 GiB"
else
  report FAIL "Available memory: ${memory_available_gib} GiB | minimum: 32 GiB"
fi

disk_available_kib=$(df -Pk / | awk 'NR == 2 { print $4 }')
disk_available_gib=$(( ${disk_available_kib:-0} / 1024 / 1024 ))
if [[ -n "$disk_available_kib" ]] && (( disk_available_kib >= minimum_disk_kib )); then
  report PASS "Root filesystem free: ${disk_available_gib} GiB | minimum: 150 GiB"
else
  report FAIL "Root filesystem free: ${disk_available_gib} GiB | minimum: 150 GiB"
fi

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  report PASS "/dev/kvm access: readable and writable | requirement: both"
else
  report FAIL "/dev/kvm access: missing read or write permission | requirement: both"
fi

nested_parameter=""
for candidate in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
  if [[ -r "$candidate" ]]; then
    nested_parameter="$candidate"
    break
  fi
done

if [[ -n "$nested_parameter" ]]; then
  nested_value=$(<"$nested_parameter")
  if [[ "$nested_value" == "Y" || "$nested_value" == "1" ]]; then
    report PASS "Nested virtualization: enabled ($nested_value) | requirement: enabled"
  else
    report FAIL "Nested virtualization: disabled ($nested_value) | requirement: enabled"
  fi
else
  report FAIL "Nested virtualization: setting unavailable | requirement: enabled"
fi

if (( failures > 0 )); then
  printf '\nPreflight failed: %d check(s) need attention.\n' "$failures" >&2
  exit 1
fi

printf '\nPreflight passed. Review the proposed VM allocations before provisioning.\n'