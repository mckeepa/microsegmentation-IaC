#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
virtctl_path="$work_dir/virtctl-v1.9.1"
export KUBECONFIG="$work_dir/kubeconfig-lab-k8s-01.yaml"
key_path="$work_dir/netpol-server-rocky_ed25519"
known_hosts="$work_dir/netpol-server-rocky_known_hosts"
mode="${1:---verify}"
bootstrap_user="${2:-}"

case "$mode" in
  --prepare|--verify|--harden)
    if (( $# > 1 )); then printf 'Error: unexpected arguments.\n' >&2; exit 2; fi
    ;;
  --bootstrap-user)
    if (( $# != 2 )) || [[ ! "$bootstrap_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      printf 'Error: supply an existing Rocky administrator username.\n' >&2
      exit 2
    fi
    ;;
  *)
    printf 'Usage: %s [--prepare|--verify|--harden|--bootstrap-user <existing-admin>]\n' "${0##*/}" >&2
    exit 2
    ;;
esac
for command_name in ssh ssh-keygen jq base64 git awk virsh; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Error: %s is required.\n' "$command_name" >&2
    exit 1
  }
done
if [[ ! -x "$virtctl_path" || ! -s "$KUBECONFIG" ]]; then
  printf 'Error: task 20 kubeconfig and verified task 30 virtctl are required.\n' >&2
  exit 1
fi
if ! git -C "$repo_root" check-ignore -q work/netpol-server-rocky_ed25519; then
  printf 'Error: work/ must be ignored by Git before creating an automation key.\n' >&2
  exit 1
fi

umask 077
mkdir -p "$work_dir"
if [[ -L "$key_path" || -L "$key_path.pub" || -L "$known_hosts" ]]; then
  printf 'Error: refusing symlinked automation key or known-hosts files.\n' >&2
  exit 1
fi
if [[ ! -e "$key_path" ]]; then
  if [[ -e "$key_path.pub" ]]; then
    printf 'Error: public key exists without its private key; restore the matching keypair.\n' >&2
    exit 1
  fi
  ssh-keygen -q -t ed25519 -N '' -C microsegmentation-iac-rocky -f "$key_path"
fi
public_key=$(ssh-keygen -y -P '' -f "$key_path" | awk '{ print $1 " " $2 }')
if [[ "$public_key" != ssh-ed25519\ * ]]; then
  printf 'Error: existing automation key must be Ed25519.\n' >&2
  exit 1
fi
if [[ -e "$key_path.pub" ]]; then
  saved_key=$(awk '{ print $1 " " $2 }' "$key_path.pub")
  if [[ "$saved_key" != "$public_key" ]]; then
    printf 'Error: existing automation keypair does not match.\n' >&2
    exit 1
  fi
else
  printf '%s\n' "$public_key" > "$key_path.pub"
fi
chmod 0600 "$key_path" "$key_path.pub"

if [[ "$mode" == --prepare ]]; then
  printf 'Prepared dedicated Rocky SSH keypair under ignored work/. No guest changes made.\n'
  printf 'Bootstrap once with: bash scripts/30-create-kubevirt-vms/setup-rocky-access.sh --bootstrap-user <existing-admin>\n'
  exit 0
fi

if [[ "$(virsh -c qemu:///system desc lab-k8s-01 --title)" != microsegmentation-iac-lab-k8s-01 ||
      "$(virsh -c qemu:///system domstate lab-k8s-01)" != running ]]; then
  printf 'Error: the project-managed outer VM must be running.\n' >&2
  exit 1
fi
outer_ip=$(virsh -c qemu:///system domifaddr lab-k8s-01 --source lease |
  awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }')
if [[ -z "$outer_ip" ]]; then
  outer_mac=$(virsh -c qemu:///system domiflist lab-k8s-01 |
    awk '$3 == "default" { print tolower($5); exit }')
  interface_json=$(virsh -c qemu:///system qemu-agent-command lab-k8s-01 \
    '{"execute":"guest-network-get-interfaces"}')
  outer_ip=$(jq -r --arg mac "$outer_mac" \
    '[.return[] | select((."hardware-address" // "" | ascii_downcase) == $mac) | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("169.254.") | not)) | .["ip-address"]] | first // empty' \
    <<< "$interface_json")
fi
if [[ -z "$outer_ip" ]]; then
  printf 'Error: outer guest address unavailable.\n' >&2
  exit 1
fi
ownership_json=$(ssh -i "$work_dir/lab-k8s-01_ed25519" \
  -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$work_dir/lab-k8s-01_known_hosts" \
  "labadmin@$outer_ip" \
  'sudo -n k3s kubectl get namespace netpol-test -o json && sudo -n k3s kubectl get vm netpol-server-rocky -n netpol-test -o json')
if ! jq -s -e '
  length == 2 and all(.[]; .metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac") and
  .[1].spec.runStrategy == "Manual" and .[1].metadata.deletionTimestamp == null and
  any(.[1].spec.template.spec.volumes[]; .name == "osdisk" and .persistentVolumeClaim.claimName == "netpol-server-rocky-disk") and
  any(.[1].spec.template.spec.domain.devices.disks[]; .name == "osdisk" and .bootOrder == 1) and
  any(.[1].spec.template.spec.domain.devices.interfaces[]; .name == "default" and any(.ports[]?; .port == 22 and (.protocol // "TCP") == "TCP"))
' <<< "$ownership_json" >/dev/null; then
  printf 'Error: expected managed Rocky VM, disk-first boot, or SSH forwarding is missing.\n' >&2
  exit 1
fi

if [[ "$mode" == --bootstrap-user ]]; then
  if [[ ! -t 0 ]]; then
    printf 'Error: bootstrap requires an interactive terminal for existing SSH/sudo credentials.\n' >&2
    exit 1
  fi
  payload=$(base64 -w0 "$script_dir/configure-rocky-guest.sh")
  printf -v guest_command 'printf %%s %q | base64 --decode | bash -s -- %q' "$payload" "$public_key"
  printf -v bootstrap_command 'sudo bash -o pipefail -c %q' "$guest_command"
  "$virtctl_path" ssh "$bootstrap_user@vmi/netpol-server-rocky" -n netpol-test \
    --identity-file="$key_path" --known-hosts="$known_hosts" \
    --local-ssh-opts=-tt --local-ssh-opts='-o StrictHostKeyChecking=accept-new' \
    --command="$bootstrap_command"
  mode=--harden
fi

rocky_ssh() {
  "$virtctl_path" ssh labadmin@vmi/netpol-server-rocky -n netpol-test \
    --identity-file="$key_path" --known-hosts="$known_hosts" \
    --local-ssh-opts='-o BatchMode=yes' --local-ssh-opts='-o IdentitiesOnly=yes' \
    --local-ssh-opts='-o ConnectTimeout=10' \
    --local-ssh-opts='-o StrictHostKeyChecking=accept-new' --command="$1"
}
verify_command='set -eu; . /etc/os-release; test "$ID" = rocky; test "${VERSION_ID%%.*}" = 10; id; cat /etc/os-release; findmnt /; ip -br address; ip route; getent ahostsv4 download.rockylinux.org; curl --fail --silent --show-error --location --max-time 30 --output /dev/null https://download.rockylinux.org/pub/rocky/10/; sudo -n true; systemctl is-active sshd qemu-guest-agent; printf "PASS Rocky OS, storage, network, DNS, HTTPS, key-only client access, sudo, and services\n"'
rocky_ssh "$verify_command"

if [[ "$mode" == --harden ]]; then
  harden_command='set -eu; install -d -m 0755 /etc/ssh/sshd_config.d; config=/etc/ssh/sshd_config.d/00-microsegmentation-lab.conf; desired=$(printf "PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n"); if test -e "$config"; then test ! -L "$config" && test "$(cat "$config")" = "$desired" || { printf "Unexpected existing lab SSH policy; refusing overwrite\n" >&2; exit 1; }; else umask 022; printf "%s\n" "$desired" > "$config"; trap '\''rm -f "$config"'\'' ERR; fi; sshd -t; policy=$(sshd -T); printf "%s\n" "$policy" | grep -qx "pubkeyauthentication yes"; printf "%s\n" "$policy" | grep -qx "passwordauthentication no"; printf "%s\n" "$policy" | grep -qx "kbdinteractiveauthentication no"; printf "%s\n" "$policy" | grep -qx "permitrootlogin no"; systemctl reload sshd; trap - ERR'
  printf -v harden_remote 'sudo -n bash -c %q' "$harden_command"
  rocky_ssh "$harden_remote"
  rocky_ssh "$verify_command"
  printf 'PASS password and root SSH logins disabled after verified key access. Console login is unchanged.\n'
fi