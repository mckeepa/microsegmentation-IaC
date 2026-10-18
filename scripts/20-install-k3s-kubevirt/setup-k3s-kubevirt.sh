#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
vm_name="lab-k8s-01"
vm_user="labadmin"
managed_title="microsegmentation-iac-lab-k8s-01"
dry_run=false

usage() {
  printf 'Usage: %s [--dry-run]\n' "${0##*/}"
  printf 'Provision lab-k8s-01 if needed, then bootstrap K3s, OVN-Kubernetes, KubeVirt, and CDI.\n'
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

for command_name in virsh ssh scp ssh-keygen; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required on the QEMU/KVM host.\n' "$command_name" >&2
    exit 1
  fi
done

if [[ "$dry_run" == true ]]; then
  bash "$repo_root/scripts/10-create-lab-vm/provision-lab-vm.sh" --dry-run
  bash "$script_dir/bootstrap-guest.sh" --dry-run
  exit 0
fi

bash "$repo_root/scripts/00-host-preflight/check-host.sh"
bash "$repo_root/scripts/10-create-lab-vm/provision-lab-vm.sh"

existing_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
if [[ "$existing_title" != "$managed_title" ]]; then
  printf 'Error: refusing to connect to domain %s; project ownership marker is missing.\n' "$vm_name" >&2
  exit 1
fi

ssh_key="$work_dir/${vm_name}_ed25519"
public_key="$ssh_key.pub"
if [[ ! -r "$ssh_key" || ! -r "$public_key" ]]; then
  printf 'Error: provisioned SSH key is missing from %s.\n' "$work_dir" >&2
  exit 1
fi

mac_address=$(virsh -c qemu:///system domiflist "$vm_name" | awk '$3 == "default" { print $5; exit }')
if [[ -z "$mac_address" ]]; then
  printf 'Error: no libvirt default-network interface found on %s.\n' "$vm_name" >&2
  exit 1
fi

guest_ip=""
deadline=$((SECONDS + 1200))
while [[ -z "$guest_ip" ]]; do
  guest_ip=$(virsh -c qemu:///system net-dhcp-leases default | awk -v mac="$mac_address" '$3 == mac && $4 == "ipv4" { split($5, address, "/"); print address[1]; exit }')
  if [[ -n "$guest_ip" ]]; then
    break
  fi
  if (( SECONDS >= deadline )); then
    printf 'Error: no DHCP lease was found for %s within 20 minutes. Check the guest installation and libvirt default network.\n' "$vm_name" >&2
    exit 1
  fi
  sleep 5
done

known_hosts="$work_dir/${vm_name}_known_hosts"
ssh_options=(
  -i "$ssh_key"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$known_hosts"
)

deadline=$((SECONDS + 1200))
until ssh "${ssh_options[@]}" "$vm_user@$guest_ip" true >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    printf 'Error: SSH to %s@%s did not become ready within 20 minutes.\n' "$vm_user" "$guest_ip" >&2
    exit 1
  fi
  sleep 5
done

remote_script="/tmp/bootstrap-k3s-kubevirt.sh"
scp -i "$ssh_key" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts" \
  "$script_dir/bootstrap-guest.sh" "$vm_user@$guest_ip:$remote_script"
ssh "${ssh_options[@]}" "$vm_user@$guest_ip" \
  "sudo -n install -m 0755 '$remote_script' /usr/local/sbin/bootstrap-k3s-kubevirt && sudo -n env LAB_VM_IP='$guest_ip' /usr/local/sbin/bootstrap-k3s-kubevirt"

umask 077
kubeconfig_tmp=$(mktemp "$work_dir/.${vm_name}-kubeconfig.XXXXXX")
trap 'rm -f -- "$kubeconfig_tmp"' EXIT
ssh "${ssh_options[@]}" "$vm_user@$guest_ip" 'sudo -n cat /etc/rancher/k3s/k3s.yaml' > "$kubeconfig_tmp"
sed -i "s|server: https://127.0.0.1:6443|server: https://$guest_ip:6443|" "$kubeconfig_tmp"
if ! grep -Fq "server: https://$guest_ip:6443" "$kubeconfig_tmp"; then
  printf 'Error: kubeconfig API endpoint could not be updated for %s.\n' "$guest_ip" >&2
  exit 1
fi
install -m 0600 "$kubeconfig_tmp" "$work_dir/kubeconfig-${vm_name}.yaml"

printf '\nLab cluster setup completed.\n'
printf 'VM: %s (%s)\n' "$vm_name" "$guest_ip"
printf 'Kubeconfig: %s/work/kubeconfig-%s.yaml\n' "$repo_root" "$vm_name"
printf 'Use: KUBECONFIG=%s/work/kubeconfig-%s.yaml kubectl get nodes\n' "$repo_root" "$vm_name"
