#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
base_url="https://download.rockylinux.org/pub/rocky/10/isos/x86_64"
key_url="https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-10"
key_fingerprint="FC226859C0860BF0DDB95B085B106C736FEDFC85"
iso_name="Rocky-10-latest-x86_64-minimal.iso"

for command_name in curl sha256sum gpg gpgv awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required.\n' "$command_name" >&2
    exit 1
  fi
done

mkdir -p "$work_dir"
temp_dir=$(mktemp -d "$work_dir/.rocky-10-download.XXXXXX")
trap 'rm -rf -- "$temp_dir"' EXIT

curl --fail --location --silent --show-error --retry 3 \
  "$base_url/$iso_name.CHECKSUM" \
  --output "$temp_dir/CHECKSUM"
curl --fail --location --silent --show-error --retry 3 \
  "$base_url/$iso_name.CHECKSUM.asc" \
  --output "$temp_dir/CHECKSUM.asc"
curl --fail --location --silent --show-error --retry 3 \
  "$key_url" \
  --output "$temp_dir/RPM-GPG-KEY-Rocky-10"

fingerprint=$(gpg --show-keys --with-colons --fingerprint "$temp_dir/RPM-GPG-KEY-Rocky-10" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
if [[ "$fingerprint" != "$key_fingerprint" ]]; then
  printf 'Error: Rocky Linux 10 signing-key fingerprint mismatch.\nExpected: %s\nFound:    %s\n' "$key_fingerprint" "$fingerprint" >&2
  exit 1
fi

gpg --batch --yes --dearmor \
  --output "$temp_dir/rocky-keyring.gpg" \
  "$temp_dir/RPM-GPG-KEY-Rocky-10"
gpgv --keyring "$temp_dir/rocky-keyring.gpg" \
  "$temp_dir/CHECKSUM.asc" \
  "$temp_dir/CHECKSUM"

checksum=$(awk -v image="$iso_name" '$0 ~ "^SHA256 \\(" image "\\) = " { print $NF }' "$temp_dir/CHECKSUM")
if [[ ! "$checksum" =~ ^[[:xdigit:]]{64}$ ]]; then
  printf 'Error: a valid SHA-256 checksum for %s was not found.\n' "$iso_name" >&2
  exit 1
fi

iso_path="$work_dir/$iso_name"
if [[ -e "$iso_path" ]]; then
  if printf '%s  %s\n' "$checksum" "$iso_path" | sha256sum --check --status; then
    printf 'Already downloaded and verified: %s\n' "$iso_path"
    exit 0
  fi
  printf 'Error: %s exists but does not match the current signed checksum. Move it aside before retrying.\n' "$iso_path" >&2
  exit 1
fi

printf 'Downloading %s to the ignored work/ directory...\n' "$iso_name"
curl --fail --location --show-error --retry 3 \
  "$base_url/$iso_name" \
  --output "$temp_dir/$iso_name"
printf '%s  %s\n' "$checksum" "$temp_dir/$iso_name" | sha256sum --check
mv -- "$temp_dir/$iso_name" "$iso_path"
printf 'Verified Rocky Linux 10 ISO ready for KubeVirt: %s\n' "$iso_path"
