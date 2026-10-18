#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
vm_name="lab-k8s-01"
vm_user="labadmin"
vm_memory_mib=24576
vm_vcpus=8
vm_disk_gib=100
managed_title="microsegmentation-iac-lab-k8s-01"
dry_run=false

usage() {
  printf 'Usage: %s [--dry-run]\n' "${0##*/}"
  printf 'Provision the single Ubuntu Server guest used by the K3s/KubeVirt lab.\n'
}

report_vm_status() {
  local state lease_info guest_ip ssh_key known_hosts
  ssh_key="$work_dir/${vm_name}_ed25519"
  known_hosts="$work_dir/${vm_name}_known_hosts"
  state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
  printf 'VM state: %s\n' "$state"

  lease_info=$(virsh -c qemu:///system domifaddr "$vm_name" --source lease 2>/dev/null || true)
  guest_ip=$(awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }' <<< "$lease_info")
  if [[ -n "$guest_ip" ]]; then
    printf 'VM IP address: %s\n' "$guest_ip"
    if [[ -r "$ssh_key" ]]; then
      printf 'SSH login: ssh -i %q -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=%q %q@%q\n' \
        "$ssh_key" "$known_hosts" "$vm_user" "$guest_ip"
    else
      printf 'SSH private key is missing: %s\n' "$ssh_key"
    fi
  else
    printf 'VM IP address: no DHCP lease yet; Ubuntu may still be booting.\n'
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
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

for command_name in virsh virt-install xorriso openssl ssh-keygen; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required on the QEMU/KVM host.\n' "$command_name" >&2
    exit 1
  fi
done

if virsh -c qemu:///system dominfo "$vm_name" >/dev/null 2>&1; then
  existing_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
  if [[ "$existing_title" != "$managed_title" ]]; then
    printf 'Error: libvirt domain %s already exists and is not marked as managed by this project. Refusing to alter it.\n' "$vm_name" >&2
    exit 1
  fi
  state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
  if [[ "$dry_run" == true ]]; then
    printf 'Dry run: managed VM %s exists in state %s; no changes made.\n' "$vm_name" "$state"
    exit 0
  fi
  if [[ "$state" == "shut off" ]]; then
    virsh -c qemu:///system start "$vm_name"
  elif [[ "$state" != "running" ]]; then
    printf 'Error: managed domain %s is in unexpected state: %s\n' "$vm_name" "$state" >&2
    exit 1
  fi
  printf 'Managed VM is provisioned: %s\n' "$vm_name"
  report_vm_status
  exit 0
fi

network_info=$(virsh -c qemu:///system net-info default)
if ! grep -q 'Active:.*yes' <<< "$network_info"; then
  printf 'Error: libvirt network "default" must be active.\n' >&2
  exit 1
fi

available_bytes=$(virsh -c qemu:///system pool-info --bytes default | awk -F: '/Available:/ { gsub(/[[:space:]]/, "", $2); print $2 }')
minimum_bytes=$((150 * 1024 * 1024 * 1024))
if [[ -z "$available_bytes" ]] || (( available_bytes < minimum_bytes )); then
  printf 'Error: libvirt storage pool "default" needs at least 150 GiB free.\n' >&2
  exit 1
fi

if ! bash "$repo_root/scripts/00-host-preflight/check-host.sh"; then
  printf 'Error: host preflight failed; resolve it before provisioning.\n' >&2
  exit 1
fi

iso_path=$(find "$work_dir" -maxdepth 1 -type f -name 'ubuntu-24.04.*-live-server-amd64.iso' -print -quit 2>/dev/null || true)
if [[ -z "$iso_path" ]]; then
  if [[ "$dry_run" == true ]]; then
    printf 'Error: Ubuntu Server ISO is missing. Run scripts/10-create-lab-vm/download-ubuntu-server.sh first.\n' >&2
    exit 1
  fi
  bash "$script_dir/download-ubuntu-server.sh"
  iso_path=$(find "$work_dir" -maxdepth 1 -type f -name 'ubuntu-24.04.*-live-server-amd64.iso' -print -quit)
fi

temporary_dir=$(mktemp -d "$work_dir/.lab-k8s-01-provision.XXXXXX")
trap 'rm -rf -- "$temporary_dir"' EXIT
seed_dir="$temporary_dir/cidata"
mkdir -m 0700 "$seed_dir"

if [[ "$dry_run" == true ]]; then
  ssh_key="$temporary_dir/lab-k8s-01_ed25519"
  seed_iso="$temporary_dir/lab-k8s-01-cidata.iso"
else
  ssh_key="$work_dir/lab-k8s-01_ed25519"
  seed_iso="$work_dir/lab-k8s-01-cidata.iso"
fi

if [[ ! -f "$ssh_key" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C "$vm_name" -f "$ssh_key"
fi
if [[ ! -f "$ssh_key.pub" ]]; then
  ssh-keygen -y -f "$ssh_key" > "$ssh_key.pub"
fi
chmod 0600 "$ssh_key"

public_key=$(<"$ssh_key.pub")
password_hash=$(openssl rand -hex 32 | openssl passwd -6 -stdin)
cat > "$seed_dir/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  source:
    id: ubuntu-server
  identity:
    hostname: $vm_name
    username: $vm_user
    password: '$password_hash'
  ssh:
    install-server: true
    authorized-keys:
      - $public_key
    allow-pw: false
  storage:
    layout:
      name: lvm
      sizing-policy: all
  packages:
    - qemu-guest-agent
    - curl
    - ca-certificates
    - git
    - python3
    - jq
  late-commands:
    - curtin in-target --target=/target -- env DEBIAN_FRONTEND=noninteractive apt-get update
    - curtin in-target --target=/target -- env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    - |
      curtin in-target --target=/target -- bash -c 'printf "%s\\n" "$vm_user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-labadmin && chmod 0440 /etc/sudoers.d/90-labadmin && visudo -cf /etc/sudoers.d/90-labadmin && systemctl enable qemu-guest-agent.service'
  updates: security
  shutdown: reboot
EOF
cat > "$seed_dir/meta-data" <<EOF
instance-id: $vm_name
local-hostname: $vm_name
EOF

if [[ "$dry_run" == false ]]; then
  rm -f -- "$seed_iso"
fi
xorriso -as mkisofs -quiet -volid cidata -joliet -rock -output "$seed_iso" "$seed_dir"

virt_install_args=(
  --connect qemu:///system
  --name "$vm_name"
  --memory "$vm_memory_mib"
  --vcpus "$vm_vcpus"
  --cpu host-passthrough
  --osinfo ubuntu24.04
  --metadata "title=$managed_title,description=Managed by microsegmentation-IaC"
  --disk "pool=default,size=$vm_disk_gib,format=qcow2,bus=virtio"
  --disk "path=$seed_iso,device=cdrom,bus=sata,readonly=on"
  --network network=default,model=virtio
  --location "$iso_path,kernel=casper/vmlinuz,initrd=casper/initrd"
  --extra-args 'autoinstall console=ttyS0,115200n8'
  --graphics none
  --console pty,target_type=serial
  --boot hd,cdrom
  --noautoconsole
)

if [[ "$dry_run" == true ]]; then
  printf 'Dry run only. No VM or persistent SSH key will be created.\n'
  virt-install "${virt_install_args[@]}" --dry-run --print-xml
  exit 0
fi

virt-install "${virt_install_args[@]}"
virsh -c qemu:///system autostart "$vm_name"
printf '\nProvisioned %s. SSH key: %s\n' "$vm_name" "$ssh_key"
report_vm_status
printf 'The setup orchestrator will wait for Ubuntu autoinstall and SSH before installing K3s.\n'