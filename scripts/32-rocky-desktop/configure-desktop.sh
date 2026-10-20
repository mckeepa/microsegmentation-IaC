#!/usr/bin/env bash

set -euo pipefail

if (( EUID != 0 )); then printf 'Error: root is required.\n' >&2; exit 1; fi
source /etc/os-release
if [[ "$ID" != rocky || "${VERSION_ID%%.*}" != 9 ]]; then
  printf 'Error: this desktop configuration requires Rocky Linux 9.\n' >&2; exit 1
fi
dnf -y install dnf-plugins-core epel-release
dnf config-manager --set-enabled crb
dnf -y install xfce4-session xfce4-panel xfce4-settings xfce4-terminal xfdesktop xfwm4 \
  Thunar firefox lightdm lightdm-gtk xorg-x11-server-Xorg xorg-x11-xinit \
  xrdp xorgxrdp xrdp-selinux qemu-guest-agent openssh-server openssl dbus-x11

install -d -m 0755 /etc/ssh/sshd_config.d
printf 'PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' \
  > /etc/ssh/sshd_config.d/00-microsegmentation-lab.conf
sshd -t
sed -i '/^\[Globals\]/,/^\[/ s/^port=3389$/port=tcp:\/\/127.0.0.1:3389/' /etc/xrdp/xrdp.ini
grep -qx 'port=tcp://127.0.0.1:3389' /etc/xrdp/xrdp.ini
printf '#!/bin/sh\nexec startxfce4\n' > /home/desktop/.Xclients
cp /home/desktop/.Xclients /home/desktop/.xsession
chown desktop:desktop /home/desktop/.Xclients /home/desktop/.xsession
chmod 0755 /home/desktop/.Xclients /home/desktop/.xsession
restorecon -RF /home/desktop
install -d -m 0755 /etc/lightdm/lightdm.conf.d
printf '[Seat:*]\nuser-session=xfce\n' > /etc/lightdm/lightdm.conf.d/50-lab-desktop.conf
systemctl enable --now sshd qemu-guest-agent xrdp
systemctl enable lightdm
systemctl set-default graphical.target
systemctl start graphical.target
systemctl reload sshd
test "$(getenforce)" = Enforcing
printf 'PASS XFCE, Firefox, console display manager, and loopback-only xrdp configured.\n'