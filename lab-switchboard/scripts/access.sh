#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${1:-} == --help ]]; then
  printf 'Usage: bash lab-switchboard/scripts/access.sh\nRun on the KVM-host laptop and open http://localhost:18088. Ctrl+C closes the tunnel.\n'
  exit 0
fi
[[ $# == 0 ]] || exit 2
source "$project_dir/../scripts/45-monitoring-dashboard/common.sh"
dashboard_connect
read -r -d '' remote_script <<'GUEST' || true
set -euo pipefail
k3s kubectl port-forward --address 127.0.0.1 -n lab-switchboard service/lab-switchboard 18088:80 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true; wait "$forward_pid" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
wait "$forward_pid"
GUEST
printf -v remote_command 'sudo -n bash -c %q' "$remote_script"
printf 'Lab Switchboard: http://localhost:18088\nPassword: lab-switchboard/.local/admin-password (open privately).\nLeave this terminal open. Ctrl+C closes the tunnel.\n'
exec ssh -tt "${ssh_options[@]}" -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:18088:127.0.0.1:18088 "labadmin@$outer_ip" "$remote_command"