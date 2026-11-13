#!/usr/bin/env bash

# Installs the default Ubuntu GNOME desktop with loopback-only xrdp on a fleet
# VM. Run by cloud-init on first boot with the desktop login user as $1
# (the fleet admin user; RDP uses the password set by --set-password).
# Adapted from the proven task 33 recipe (scripts/33-ubuntu-desktop/).

set -euo pipefail

desktop_user="${1:?Usage: ${0##*/} <desktop-login-user>}"
if (( EUID != 0 )); then printf 'Error: root is required.\n' >&2; exit 1; fi
source /etc/os-release
if [[ "$ID" != ubuntu || "${VERSION_ID%%.*}" != 24 ]]; then
  printf 'Error: this desktop configuration requires Ubuntu 24.04.\n' >&2; exit 1
fi
id "$desktop_user" >/dev/null
home_dir=$(getent passwd "$desktop_user" | cut -d: -f6)
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y install ubuntu-desktop-minimal xrdp xorgxrdp dbus-x11

sed -i '/^\[Globals\]/,/^\[/ s/^port=3389$/port=tcp:\/\/127.0.0.1:3389/' /etc/xrdp/xrdp.ini
grep -qx 'port=tcp://127.0.0.1:3389' /etc/xrdp/xrdp.ini
# xrdp's Xsession reads .xsessionrc; these variables select the full Ubuntu
# GNOME session instead of a bare fallback session.
printf 'export GNOME_SHELL_SESSION_MODE=ubuntu\nexport XDG_CURRENT_DESKTOP=ubuntu:GNOME\nexport XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg\n' \
  > "$home_dir/.xsessionrc"
chown "$desktop_user:$desktop_user" "$home_dir/.xsessionrc"
chmod 0644 "$home_dir/.xsessionrc"
# Suppress GNOME's colord authentication popups inside xrdp sessions and skip
# the first-login initial-setup wizard.
cat > /etc/polkit-1/rules.d/45-lab-desktop-colord.rules <<EOF
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") === 0 &&
      subject.user === "$desktop_user") {
    return polkit.Result.YES;
  }
});
EOF
chmod 0644 /etc/polkit-1/rules.d/45-lab-desktop-colord.rules
install -d -m 0700 -o "$desktop_user" -g "$desktop_user" "$home_dir/.config"
printf 'yes\n' > "$home_dir/.config/gnome-initial-setup-done"
chown "$desktop_user:$desktop_user" "$home_dir/.config/gnome-initial-setup-done"
systemctl enable --now xrdp
systemctl set-default graphical.target
systemctl start graphical.target
printf 'PASS GNOME desktop and loopback-only xrdp configured for %s.\n' "$desktop_user"
