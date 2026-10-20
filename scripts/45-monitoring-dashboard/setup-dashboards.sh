bash scripts/45-monitoring-dashboard/dashboard-permissions.sh token#!/usr/bin/env bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mode=${1:---plan}
if [[ $# -gt 1 ]]; then printf 'Error: expected one mode.\n' >&2; exit 2; fi
case "$mode" in
  --plan|--help)
    printf '%s\n' \
      'Usage: bash setup-dashboards.sh [--plan|--apply|--verify|--set-cockpit-password|--generate-cockpit-password|--enable-cockpit-sudo]' \
      'Install Ubuntu cockpit from configured apt repositories; create locked cockpit-monitor (no sudo).' \
      'Bind cockpit.socket to guest loopback only; keep HTTPS enabled.' \
      'Deploy Headlamp v0.46.0 in lab-dashboard with a ClusterIP service and no backend admin grant.' \
      'Create/reset dashboard-user to read-only. No ingress, NodePort, LAN bridge, or test-policy changes.' \
      'Use --set-cockpit-password interactively, or --generate-cockpit-password to save a random password in work/.' \
      'Optional: --enable-cockpit-sudo grants the managed cockpit-monitor account Ubuntu sudo group membership.' \
      'Then use access-dashboards.sh for SSH tunnels.'
    exit 0 ;;
  --apply|--verify|--set-cockpit-password|--generate-cockpit-password|--enable-cockpit-sudo) ;;
  *) printf 'Error: unknown mode. Use --help.\n' >&2; exit 2 ;;
esac

dashboard_connect
if [[ "$mode" == --enable-cockpit-sudo ]]; then
  dashboard_ssh 'sudo -n bash -s' <<'GUEST'
set -euo pipefail
if [[ ! -f /var/lib/microsegmentation-iac/cockpit-monitor ]] || ! id cockpit-monitor >/dev/null 2>&1; then
  printf 'Error: run --apply first to create the managed Cockpit account.\n' >&2; exit 1
fi
getent group sudo >/dev/null
visudo --check >/dev/null
usermod -aG sudo cockpit-monitor
id -nG cockpit-monitor | tr ' ' '\n' | grep -qx sudo
printf 'cockpit-monitor is in the sudo group. Log out of Cockpit and log back in to use administrative access.\n'
GUEST
  exit 0
fi

if [[ "$mode" == --set-cockpit-password ]]; then
  exec ssh -t "${ssh_options[@]}" "labadmin@$outer_ip" 'sudo -n passwd cockpit-monitor'
fi

if [[ "$mode" == --generate-cockpit-password ]]; then
  set +x
  for command_name in openssl git; do
    command -v "$command_name" >/dev/null || { printf 'Error: %s is required.\n' "$command_name" >&2; exit 1; }
  done
  password_path="$work_dir/cockpit-monitor-password"
  if [[ ! -d "$work_dir" || -L "$work_dir" || -L "$password_path" ||
        ( -e "$password_path" && ! -f "$password_path" ) ]]; then
    printf 'Error: refusing an unsafe password storage path.\n' >&2; exit 1
  fi
  git -C "$repo_root" check-ignore -q work/cockpit-monitor-password || {
    printf 'Error: password path must be Git-ignored and untracked.\n' >&2; exit 1;
  }
  dashboard_ssh 'test -f /var/lib/microsegmentation-iac/cockpit-monitor && id cockpit-monitor >/dev/null' || {
    printf 'Error: run --apply first to create the managed Cockpit account.\n' >&2; exit 1;
  }
  umask 077
  temporary_password=$(mktemp "$work_dir/.cockpit-monitor-password.XXXXXX")
  trap 'printf "Password reset did not complete; recovery credential retained at %s (mode 0600).\n" "$temporary_password" >&2' EXIT
  openssl rand -base64 32 > "$temporary_password"
  { printf 'cockpit-monitor:'; cat -- "$temporary_password"; } |
    dashboard_ssh 'sudo -n chpasswd'
  dashboard_ssh 'sudo -n passwd -S cockpit-monitor' | awk '$2 != "P" { exit 1 }'
  mv -f -- "$temporary_password" "$password_path"
  trap - EXIT
  printf 'Cockpit password reset for cockpit-monitor. Saved with mode 0600 to %s.\n' "$password_path"
  exit 0
fi

if [[ "$mode" == --apply ]]; then
  dashboard_owned namespace lab-dashboard
  for resource in 'serviceaccount headlamp' 'deployment headlamp' 'service headlamp'; do
    read -r kind name <<< "$resource"
    dashboard_owned "$kind" "$name" -n lab-dashboard
  done
  dashboard_ssh 'sudo -n bash -s' <<'GUEST'
set -euo pipefail
socket_path=/etc/systemd/system/cockpit.socket.d/90-microsegmentation-iac.conf
account_marker=/var/lib/microsegmentation-iac/cockpit-monitor
socket_config=$'[Socket]\nListenStream=\nListenStream=127.0.0.1:9090'
if [[ -e "$socket_path" ]] && [[ "$(< "$socket_path")" != "$socket_config" ]]; then
  printf 'Error: existing Cockpit socket override differs; inspect it before proceeding.\n' >&2; exit 1
fi
if [[ -f /lib/systemd/system/cockpit.socket && ! -e "$socket_path" ]]; then
  printf 'Error: Cockpit is already installed outside this workflow; review its configuration first.\n' >&2; exit 1
fi
if id cockpit-monitor >/dev/null 2>&1 && [[ ! -f "$account_marker" ]]; then
  printf 'Error: refusing an existing unmanaged cockpit-monitor account.\n' >&2; exit 1
fi
install -d -m 0755 /etc/systemd/system/cockpit.socket.d
printf '%s\n' "$socket_config" > "$socket_path"
systemctl daemon-reload
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --no-install-recommends -y cockpit
if ! id cockpit-monitor >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --comment 'Lab dashboard monitor' cockpit-monitor
  install -d -m 0755 /var/lib/microsegmentation-iac
  touch "$account_marker"
fi
usermod -aG adm,systemd-journal cockpit-monitor
systemctl daemon-reload
systemctl stop cockpit.service cockpit.socket
systemctl enable --now cockpit.socket
GUEST
  dashboard_kubectl apply -f - < "$dashboard_dir/headlamp.yaml"
  bash "$dashboard_dir/dashboard-permissions.sh" read-only
fi

dashboard_ssh 'sudo -n bash -s' <<'GUEST'
set -euo pipefail
systemctl is-active --quiet cockpit.socket
listeners=$(ss -H -ltn 'sport = :9090')
[[ -n "$listeners" ]]
awk '$4 != "127.0.0.1:9090" { invalid=1 } END { exit invalid }' <<< "$listeners"
curl --fail --silent --show-error --insecure --output /dev/null https://127.0.0.1:9090/
if [[ "$(passwd -S cockpit-monitor | awk '{print $2}')" != P ]]; then
  printf 'Cockpit login is locked: run --set-cockpit-password interactively.\n'
fi
GUEST
dashboard_kubectl rollout status deployment/headlamp -n lab-dashboard --timeout=180s
service_type=$(dashboard_kubectl get service headlamp -n lab-dashboard -o jsonpath='{.spec.type}')
[[ "$service_type" == ClusterIP ]] || { printf 'Error: Headlamp must use ClusterIP.\n' >&2; exit 1; }
backend_admin=$(dashboard_kubectl auth can-i '*' '*' --as=system:serviceaccount:lab-dashboard:headlamp) || {
  [[ "$backend_admin" == no ]] || exit 1
}
[[ "$backend_admin" == no ]] || { printf 'Error: Headlamp backend unexpectedly has admin permissions.\n' >&2; exit 1; }
bash "$dashboard_dir/dashboard-permissions.sh" verify
printf 'Dashboard checks passed. Run access-dashboards.sh on the physical host.\n'