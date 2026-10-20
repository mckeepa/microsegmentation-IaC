#!/usr/bin/env bash

set -euo pipefail
mode=${1:---host}
case "$mode" in
  --help)
    printf 'Usage: %s [--host | --laptop user@physical-host]\n' "${0##*/}"
    printf 'Run --host on the KVM host; leave running. From the laptop, use --laptop with its SSH destination.\n'
    exit 0 ;;
  --laptop)
    if [[ $# != 2 || ! "$2" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]]; then
      printf 'Error: supply an SSH destination such as paul@192.168.1.20 (or an SSH config alias).\n' >&2; exit 2
    fi
    printf 'Leave this tunnel open. Headlamp: http://localhost:18080  Cockpit: https://localhost:19090\n'
    exec ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -L 127.0.0.1:18080:127.0.0.1:18080 -L 127.0.0.1:19090:127.0.0.1:19090 "$2" ;;
  --host) [[ $# -le 1 ]] || exit 2 ;;
  *) printf 'Error: use --help for access modes.\n' >&2; exit 2 ;;
esac

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
dashboard_connect
printf 'Opening host-only listeners. Headlamp: http://localhost:18080  Cockpit: https://localhost:19090\n'
printf 'On a separate laptop, tunnel these two ports through this physical host. See the task README.\n'
printf 'Press Ctrl+C to stop. Restart this helper if the Headlamp pod restarts.\n'
read -r -d '' remote_script <<'GUEST' || true
set -euo pipefail
k3s kubectl port-forward --address 127.0.0.1 -n lab-dashboard service/headlamp 18080:80 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true; wait "$forward_pid" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
wait "$forward_pid"
GUEST
printf -v remote_command 'sudo -n bash -c %q' "$remote_script"
exec ssh -tt "${ssh_options[@]}" -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:18080:127.0.0.1:18080 -L 127.0.0.1:19090:127.0.0.1:9090 \
  "labadmin@$outer_ip" "$remote_command"