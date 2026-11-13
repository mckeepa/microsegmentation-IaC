#!/usr/bin/env bash

# Start both lab desktops (rocky-desktop and ubuntu-desktop) and open their
# loopback RDP tunnels in the background. Safe to rerun; already-running VMs
# and healthy tunnels are left alone. If the outer VM has lost its NAT
# address/default route (the known OVN uplink problem), the guarded task 20
# repair runs automatically before anything else.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
work_dir="$repo_root/work"
mode=--start
case "${1:---start}" in
  --start|--stop|--status) mode="${1:---start}" ;;
  *) printf 'Usage: %s [--start|--stop|--status]\n' "${0##*/}" >&2; exit 2 ;;
esac
for command_name in jq virsh ssh ssh-keygen git; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'Error: %s required.\n' "$command_name" >&2; exit 1; }
done
source "$repo_root/scripts/lib/common.sh"
msl_init "$repo_root"

desktop_configs=(
  "$repo_root/scripts/32-rocky-desktop/rocky-desktop.json"
  "$repo_root/scripts/33-ubuntu-desktop/ubuntu-desktop.json"
)

port_listening() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

tunnel_pid() {
  local pid_file="$work_dir/rdp-tunnel-$1.pid" pid
  [[ -s "$pid_file" ]] || return 1
  pid=$(< "$pid_file")
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

stop_tunnel() {
  local vm="$1" pid
  if pid=$(tunnel_pid "$vm"); then
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    printf 'Stopped %s RDP tunnel (PID %s).\n' "$vm" "$pid"
  fi
  rm -f -- "$work_dir/rdp-tunnel-$vm.pid"
}

if [[ "$mode" == --stop ]]; then
  for config in "${desktop_configs[@]}"; do
    stop_tunnel "$(jq -r .vmName "$config")"
  done
  printf 'Tunnels closed. The desktop VMs keep running; stop them with virtctl if needed.\n'
  exit 0
fi

if [[ "$mode" == --status ]]; then
  for config in "${desktop_configs[@]}"; do
    vm=$(jq -r .vmName "$config")
    port=$(jq -r .rdpLocalPort "$config")
    if pid=$(tunnel_pid "$vm") && port_listening "$port"; then
      printf '%s: tunnel running (PID %s) on 127.0.0.1:%s\n' "$vm" "$pid" "$port"
    else
      printf '%s: tunnel not running (expected port 127.0.0.1:%s)\n' "$vm" "$port"
    fi
  done
  exit 0
fi

msl_assert_lab_files
outer_state=$(virsh -c qemu:///system domstate "$MSL_OUTER_VM" | tr -d '\r')
if [[ "$outer_state" != running ]]; then
  printf 'Starting outer VM %s...\n' "$MSL_OUTER_VM"
  virsh -c qemu:///system start "$MSL_OUTER_VM"
fi
msl_assert_outer_vm
# After a cold start the DHCP lease/guest agent can take a while to appear.
discover_deadline=$((SECONDS + 180))
until msl_discover_outer_ip 2>/dev/null; do
  (( SECONDS < discover_deadline )) || { printf 'Error: outer guest IP unavailable after 180s.\n' >&2; exit 1; }
  sleep 5
done
printf 'Waiting for outer VM SSH at %s...\n' "$MSL_OUTER_IP"
outer_deadline=$((SECONDS + 300))
repaired=false
until msl_outer_ssh true >/dev/null 2>&1; do
  if [[ "$repaired" != true ]] && (( SECONDS > outer_deadline - 240 )); then
    # SSH is not coming up quickly; attempt the guarded OVN uplink repair once.
    printf 'Outer VM SSH unavailable; attempting the guarded network repair...\n'
    bash "$repo_root/scripts/20-install-k3s-kubevirt/repair-guest-network.sh" --repair || true
    repaired=true
    msl_discover_outer_ip || true
  fi
  (( SECONDS < outer_deadline )) || { printf 'Error: outer VM SSH not ready within 300s.\n' >&2; exit 1; }
  sleep 5
done
printf 'Outer VM SSH is ready.\n'

for config in "${desktop_configs[@]}"; do
  vm=$(jq -r .vmName "$config")
  namespace=$(jq -r .namespace "$config")
  port=$(jq -r .rdpLocalPort "$config")
  key="$repo_root/$(jq -r .sshPrivateKey "$config")"
  known_hosts="$repo_root/$(jq -r .sshKnownHosts "$config")"
  wait_seconds=$(jq -r .waitSeconds "$config")

  vm_json=$(msl_remote_kubectl get vm "$vm" -n "$namespace" --ignore-not-found -o json 2>/dev/null || true)
  if [[ -z "$vm_json" ]]; then
    printf 'Skipping %s: not provisioned yet (run its setup script with --apply first).\n' "$vm"
    continue
  fi
  jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac"' <<< "$vm_json" >/dev/null || {
    printf 'Error: refusing unowned VM %s.\n' "$vm" >&2; exit 1;
  }
  if [[ ! -s "$key" ]]; then
    printf 'Skipping %s: SSH key %s is missing.\n' "$vm" "$key"
    continue
  fi

  vmi=$(msl_remote_kubectl get vmi "$vm" -n "$namespace" --ignore-not-found -o name)
  if [[ -z "$vmi" ]]; then
    printf 'Starting %s...\n' "$vm"
    "$MSL_VIRTCTL" start "$vm" -n "$namespace"
    msl_remote_kubectl wait --for=create "vmi/$vm" -n "$namespace" --timeout=120s
  fi
  msl_remote_kubectl wait --for=condition=Ready "vmi/$vm" -n "$namespace" --timeout=300s
  msl_wait_for_guest_ssh labadmin "$vm" "$namespace" "$key" "$known_hosts" "$wait_seconds" "$vm"

  if pid=$(tunnel_pid "$vm"); then
    if port_listening "$port"; then
      printf '%s: tunnel already running (PID %s) on 127.0.0.1:%s.\n' "$vm" "$pid" "$port"
      continue
    fi
    stop_tunnel "$vm"
  fi
  if port_listening "$port"; then
    printf 'Error: local port %s is already in use by another process.\n' "$port" >&2; exit 1
  fi
  printf 'Opening %s RDP tunnel on 127.0.0.1:%s...\n' "$vm" "$port"
  setsid "$MSL_VIRTCTL" ssh "labadmin@vmi/$vm" -n "$namespace" --identity-file="$key" --known-hosts="$known_hosts" \
    --local-ssh-opts='-o BatchMode=yes' --local-ssh-opts='-o IdentitiesOnly=yes' \
    --local-ssh-opts="-o UserKnownHostsFile=$known_hosts" \
    --local-ssh-opts='-o ConnectTimeout=5' --local-ssh-opts='-o StrictHostKeyChecking=accept-new' \
    --local-ssh-opts=-N --local-ssh-opts="-L127.0.0.1:$port:127.0.0.1:3389" \
    --local-ssh-opts='-o ExitOnForwardFailure=yes' \
    >"$work_dir/rdp-tunnel-$vm.log" 2>&1 < /dev/null &
  printf '%s\n' "$!" > "$work_dir/rdp-tunnel-$vm.pid"
  disown
  for _ in $(seq 1 30); do
    port_listening "$port" && break
    tunnel_pid "$vm" >/dev/null || { cat "$work_dir/rdp-tunnel-$vm.log" >&2; rm -f -- "$work_dir/rdp-tunnel-$vm.pid"; exit 1; }
    sleep 1
  done
  port_listening "$port" || { printf 'Error: %s tunnel did not start listening on %s.\n' "$vm" "$port" >&2; exit 1; }
  printf '%s: tunnel ready on 127.0.0.1:%s.\n' "$vm" "$port"
done

printf '\nConnect with an RDP client as user "desktop" (set a password first with the matching --set-desktop-password):\n'
for config in "${desktop_configs[@]}"; do
  printf '  xfreerdp3 /v:127.0.0.1:%s /u:desktop /d: /dynamic-resolution /clipboard /cert:tofu   # %s\n' \
    "$(jq -r .rdpLocalPort "$config")" "$(jq -r .vmName "$config")"
done
printf 'Tunnels keep running after this script exits. Close them with: %s --stop\n' "${0##*/}"
