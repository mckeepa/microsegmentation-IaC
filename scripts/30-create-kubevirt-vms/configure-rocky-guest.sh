#!/usr/bin/env bash

set -euo pipefail

if (( EUID != 0 || $# != 1 )); then
  printf 'Usage (as root): %s <SSH-public-key>\n' "${0##*/}" >&2
  exit 2
fi
public_key="$1"
if [[ "$public_key" != ssh-ed25519\ * || "$public_key" == *$'\n'* || "$public_key" == *$'\r'* ]]; then
  printf 'Error: a single Ed25519 public key is required.\n' >&2
  exit 2
fi
source /etc/os-release
if [[ "$ID" != rocky || "${VERSION_ID%%.*}" != 10 ]]; then
  printf 'Error: this bootstrap supports only Rocky Linux 10.\n' >&2
  exit 1
fi

dnf -y install openssh-server qemu-guest-agent sudo
admin_user=labadmin
if ! id "$admin_user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups wheel "$admin_user"
fi
usermod --append --groups wheel "$admin_user"
admin_home=$(getent passwd "$admin_user" | cut -d: -f6)
if [[ "$admin_home" != /home/labadmin || -L "$admin_home" || -L "$admin_home/.ssh" || -L "$admin_home/.ssh/authorized_keys" ]]; then
  printf 'Error: unexpected admin home or symlinked SSH configuration; refusing changes.\n' >&2
  exit 1
fi
install -d -m 0700 -o "$admin_user" -g "$(id -gn "$admin_user")" "$admin_home/.ssh"
touch "$admin_home/.ssh/authorized_keys"
if ! grep -Fqx -- "$public_key" "$admin_home/.ssh/authorized_keys"; then
  printf '%s\n' "$public_key" >> "$admin_home/.ssh/authorized_keys"
fi
chown "$admin_user:$(id -gn "$admin_user")" "$admin_home/.ssh/authorized_keys"
chmod 0600 "$admin_home/.ssh/authorized_keys"
restorecon -RF "$admin_home/.ssh"

sudoers_temp=$(mktemp /etc/sudoers.d/.microsegmentation-lab.XXXXXX)
trap 'rm -f -- "$sudoers_temp"' EXIT
printf 'labadmin ALL=(ALL) NOPASSWD: ALL\n' > "$sudoers_temp"
chmod 0440 "$sudoers_temp"
visudo -cf "$sudoers_temp"
mv -f -- "$sudoers_temp" /etc/sudoers.d/90-microsegmentation-lab
restorecon /etc/sudoers.d/90-microsegmentation-lab
sshd -t
systemctl enable --now sshd qemu-guest-agent
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --add-service=ssh
fi
printf 'PASS labadmin SSH key, passwordless lab sudo, SSH service, and guest agent configured.\n'
printf 'Existing users and SSH password policy are unchanged; verify key access before hardening.\n'