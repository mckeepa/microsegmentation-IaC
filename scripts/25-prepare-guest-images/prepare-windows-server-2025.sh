#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s /path/to/Windows_Server_2025_Evaluation.iso\n' "$0" >&2
  exit 2
fi

if ! command -v file >/dev/null 2>&1; then
  printf 'Error: file is required to identify the Windows ISO.\n' >&2
  exit 1
fi

source_iso=$1
if [[ ! -f "$source_iso" || ! -r "$source_iso" ]]; then
  printf 'Error: ISO file does not exist or is not readable: %s\n' "$source_iso" >&2
  exit 1
fi

if [[ "${source_iso,,}" != *.iso ]]; then
  printf 'Error: expected a file with an .iso extension: %s\n' "$source_iso" >&2
  exit 1
fi

file_description=$(file --brief "$source_iso")
if [[ "$file_description" != *"ISO 9660"* && "$file_description" != *"UDF"* ]]; then
  printf 'Error: file does not appear to be an ISO/UDF image: %s\n' "$file_description" >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
target_iso="$work_dir/windows-server-2025-evaluation.iso"
mkdir -p "$work_dir"

if [[ -e "$target_iso" ]]; then
  printf 'Error: destination already exists: %s\nMove or remove it before retrying.\n' "$target_iso" >&2
  exit 1
fi

cp -- "$source_iso" "$target_iso"
printf 'Staged Windows Server 2025 evaluation ISO in the ignored work/ directory:\n%s\n' "$target_iso"
printf 'Source: %s\nDetected format: %s\n' "$source_iso" "$file_description"
printf 'This helper does not grant a license or independently verify Microsoft media authenticity.\n' >&2
