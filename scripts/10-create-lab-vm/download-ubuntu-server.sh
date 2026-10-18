#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
release_url="https://releases.ubuntu.com/24.04"
keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"

if ! command -v curl >/dev/null 2>&1; then
  printf 'Error: curl is required.\n' >&2
  exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
  printf 'Error: sha256sum is required.\n' >&2
  exit 1
fi
if ! command -v gpgv >/dev/null 2>&1; then
  printf "Error: gpgv is required to verify Ubuntu's signed checksums.\n" >&2
  exit 1
fi
if [[ ! -r "$keyring" ]]; then
  printf 'Error: Ubuntu archive keyring not found at %s. Install the ubuntu-keyring package.\n' "$keyring" >&2
  exit 1
fi

mkdir -p "$work_dir"
temp_dir=$(mktemp -d "$work_dir/.ubuntu-server-download.XXXXXX")
trap 'rm -rf -- "$temp_dir"' EXIT

curl --fail --location --silent --show-error --retry 3 \
  "$release_url/SHA256SUMS" \
  --output "$temp_dir/SHA256SUMS"
curl --fail --location --silent --show-error --retry 3 \
  "$release_url/SHA256SUMS.gpg" \
  --output "$temp_dir/SHA256SUMS.gpg"

gpgv --keyring "$keyring" "$temp_dir/SHA256SUMS.gpg" "$temp_dir/SHA256SUMS"

iso_name=$(awk '
  $2 ~ /^\*?ubuntu-24\.04(\.[0-9]+)?-live-server-amd64\.iso$/ {
    name = $2
    sub(/^\*/, "", name)
    print name
  }
' "$temp_dir/SHA256SUMS" | sort -V | tail -n 1)

if [[ -z "$iso_name" ]]; then
  printf 'Error: no Ubuntu Server 24.04 amd64 ISO found in the signed checksum list.\n' >&2
  exit 1
fi

mapfile -t checksums < <(awk -v image="$iso_name" '$2 == image || $2 == "*" image { print $1 }' "$temp_dir/SHA256SUMS")
if [[ ${#checksums[@]} -ne 1 || ! "${checksums[0]}" =~ ^[[:xdigit:]]{64}$ ]]; then
  printf 'Error: expected exactly one valid SHA-256 checksum for %s.\n' "$iso_name" >&2
  exit 1
fi

iso_path="$work_dir/$iso_name"
if [[ -e "$iso_path" ]]; then
  if printf '%s  %s\n' "${checksums[0]}" "$iso_path" | sha256sum --check --status; then
    printf 'Already downloaded and verified: %s\n' "$iso_path"
    exit 0
  fi
  printf 'Error: %s exists but does not match the verified checksum. Move or remove it before retrying.\n' "$iso_path" >&2
  exit 1
fi

printf 'Downloading %s to the ignored work/ directory...\n' "$iso_name"
curl --fail --location --show-error --retry 3 \
  "$release_url/$iso_name" \
  --output "$temp_dir/$iso_name"

printf '%s  %s\n' "${checksums[0]}" "$temp_dir/$iso_name" | sha256sum --check
mv -- "$temp_dir/$iso_name" "$iso_path"
printf 'Verified ISO ready for Virtual Machine Manager: %s\n' "$iso_path"
