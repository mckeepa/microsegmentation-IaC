#!/usr/bin/env bash

set -euo pipefail

if (( EUID != 0 )); then printf 'Error: root is required.\n' >&2; exit 1; fi
source /etc/os-release
if [[ "$ID" != ubuntu || "${VERSION_ID%%.*}" != 24 ]]; then
  printf 'Error: this desktop configuration requires Ubuntu 24.04.\n' >&2; exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y install ubuntu-desktop-minimal xrdp xorgxrdp qemu-guest-agent \
  openssh-server openssl dbus-x11

install -d -m 0755 /etc/ssh/sshd_config.d
printf 'PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' \
  > /etc/ssh/sshd_config.d/00-microsegmentation-lab.conf
sshd -t
sed -i '/^\[Globals\]/,/^\[/ s/^port=3389$/port=tcp:\/\/127.0.0.1:3389/' /etc/xrdp/xrdp.ini
grep -qx 'port=tcp://127.0.0.1:3389' /etc/xrdp/xrdp.ini
# xrdp's Xsession reads .xsessionrc; these variables select the full Ubuntu
# GNOME session instead of a bare fallback session.
printf 'export GNOME_SHELL_SESSION_MODE=ubuntu\nexport XDG_CURRENT_DESKTOP=ubuntu:GNOME\nexport XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg\n' \
  > /home/desktop/.xsessionrc
chown desktop:desktop /home/desktop/.xsessionrc
chmod 0644 /home/desktop/.xsessionrc
# Suppress GNOME's colord authentication popups inside xrdp sessions and skip
# the first-login initial-setup wizard.
cat > /etc/polkit-1/rules.d/45-lab-desktop-colord.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") === 0 &&
      subject.user === "desktop") {
    return polkit.Result.YES;
  }
});
EOF
chmod 0644 /etc/polkit-1/rules.d/45-lab-desktop-colord.rules
install -d -m 0700 -o desktop -g desktop /home/desktop/.config
printf 'yes\n' > /home/desktop/.config/gnome-initial-setup-done
chown desktop:desktop /home/desktop/.config/gnome-initial-setup-done
systemctl enable --now ssh qemu-guest-agent xrdp
systemctl set-default graphical.target
systemctl start graphical.target
systemctl reload ssh
printf 'PASS GNOME desktop, console display manager, and loopback-only xrdp configured.\n'
