#!/usr/bin/env bash

# Installs the XFCE desktop with loopback-only xrdp on a Rocky 9 fleet VM.
# Run by cloud-init on first boot with the desktop login user as $1
# (the fleet admin user; RDP uses the password set by --set-password).
# Adapted from the proven task 32 recipe (scripts/32-rocky-desktop/).

set -euo pipefail

desktop_user="${1:?Usage: ${0##*/} <desktop-login-user>}"
if (( EUID != 0 )); then printf 'Error: root is required.\n' >&2; exit 1; fi
source /etc/os-release
if [[ "$ID" != rocky || "${VERSION_ID%%.*}" != 9 ]]; then
  printf 'Error: this desktop configuration requires Rocky Linux 9.\n' >&2; exit 1
fi
id "$desktop_user" >/dev/null
home_dir=$(getent passwd "$desktop_user" | cut -d: -f6)
dnf -y install dnf-plugins-core epel-release
dnf config-manager --set-enabled crb
dnf -y install xfce4-session xfce4-panel xfce4-settings xfce4-terminal xfdesktop xfwm4 \
  Thunar firefox lightdm lightdm-gtk xorg-x11-server-Xorg xorg-x11-xinit \
  xrdp xorgxrdp xrdp-selinux dbus-x11

sed -i '/^\[Globals\]/,/^\[/ s/^port=3389$/port=tcp:\/\/127.0.0.1:3389/' /etc/xrdp/xrdp.ini
grep -qx 'port=tcp://127.0.0.1:3389' /etc/xrdp/xrdp.ini
printf '#!/bin/sh\nexec startxfce4\n' > "$home_dir/.Xclients"
cp "$home_dir/.Xclients" "$home_dir/.xsession"
chown "$desktop_user:$desktop_user" "$home_dir/.Xclients" "$home_dir/.xsession"
chmod 0755 "$home_dir/.Xclients" "$home_dir/.xsession"
restorecon -RF "$home_dir"
install -d -m 0755 /etc/lightdm/lightdm.conf.d
printf '[Seat:*]\nuser-session=xfce\n' > /etc/lightdm/lightdm.conf.d/50-lab-desktop.conf
systemctl enable --now xrdp
systemctl enable lightdm
systemctl set-default graphical.target
systemctl start graphical.target
test "$(getenforce)" = Enforcing
printf 'PASS XFCE desktop and loopback-only xrdp configured for %s.\n' "$desktop_user"
