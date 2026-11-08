#!/usr/bin/env bash

# resume-lab.sh - one-command recovery after the laptop or the outer VM has
# been stopped and restarted. Safe by default: it starts the outer VM only
# after a prompt (or --start-vm), repairs the known OVN route loss through the
# existing guarded checker, waits for infrastructure pods to recover, prints
# the VM inventory, and lists the exact next commands. Nested guests are only
# started when explicitly requested with --start-fleet / --start-desktop.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
start_vm=false
start_fleet=false
start_desktop=false

usage() {
  printf 'Usage: %s [--start-vm] [--start-fleet] [--start-desktop]\n' "${0##*/}"
  printf 'Recover the lab after a laptop or outer-VM restart.\n'
  printf '  --start-vm       start the outer VM without prompting if it is off\n'
  printf '  --start-fleet    reconcile task 34 fleet VMs to their declared runState\n'
  printf '  --start-desktop  start the task 32 Rocky desktop VM\n'
}

while (( $# > 0 )); do
  case "$1" in
    --start-vm) start_vm=true; shift ;;
    --start-fleet) start_fleet=true; shift ;;
    --start-desktop) start_desktop=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for command_name in jq virsh ssh; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'Error: %s required.\n' "$command_name" >&2; exit 1; }
done
source "$repo_root/scripts/lib/common.sh"
msl_init "$repo_root"

printf '=== Step 1/4: outer VM %s ===\n' "$MSL_OUTER_VM"
title=$(virsh -c qemu:///system desc "$MSL_OUTER_VM" --title 2>/dev/null || true)
[[ "$title" == "$MSL_MANAGED_TITLE" ]] || { printf 'Error: VM %s is missing or not project-managed; see scripts/10-create-lab-vm.\n' "$MSL_OUTER_VM" >&2; exit 1; }
state=$(virsh -c qemu:///system domstate "$MSL_OUTER_VM" | tr -d '\r')
if [[ "$state" != running ]]; then
  if [[ "$start_vm" != true ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Outer VM is $state. Start it now? [Y/n] " answer
      case "${answer,,}" in ""|y|yes) start_vm=true ;; esac
    fi
  fi
  if [[ "$start_vm" != true ]]; then
    printf 'Outer VM left %s. Rerun with --start-vm to start it.\n' "$state"
    exit 1
  fi
  virsh -c qemu:///system start "$MSL_OUTER_VM"
fi

printf 'Waiting for outer VM SSH (DHCP addresses can change after a restart)...\n'
deadline=$((SECONDS + 600))
next_status_at=$((SECONDS + 30))
while true; do
  if msl_discover_outer_ip 2>/dev/null &&
     ssh "${MSL_OUTER_SSH_OPTS[@]}" "labadmin@$MSL_OUTER_IP" true >/dev/null 2>&1; then
    printf 'Outer VM SSH ready at %s.\n' "$MSL_OUTER_IP"
    break
  fi
  (( SECONDS < deadline )) || { printf 'Error: outer VM SSH not ready within 10 minutes; run the task 20 cluster checker for its guarded network repair.\n' >&2; exit 1; }
  if (( SECONDS >= next_status_at )); then
    printf 'Still waiting for outer VM SSH (address so far: %s)...\n' "${MSL_OUTER_IP:-none}"
    next_status_at=$((SECONDS + 30))
  fi
  sleep 5
done

printf '\n=== Step 2/4: cluster health (includes the guarded OVN route repair) ===\n'
cluster_ok=false
if bash "$repo_root/scripts/20-install-k3s-kubevirt/check-cluster-status.sh"; then
  cluster_ok=true
else
  # After a route repair, CDI/KubeVirt pods that crash-looped while the route
  # was missing need their CrashLoopBackOff timers (up to ~5 min) to expire.
  printf 'Cluster check failed; waiting up to 10 minutes for infrastructure pods to recover...\n'
  deadline=$((SECONDS + 600))
  while (( SECONDS < deadline )); do
    unhealthy=$(msl_remote_kubectl get pods -A --no-headers 2>/dev/null |
      awk '{split($3,r,"/"); if (($4!="Running" && $4!="Completed") || ($4=="Running" && r[1]!=r[2])) print $2}' | tr '\n' ' ')
    if [[ -z "$unhealthy" ]]; then
      printf 'All pods recovered; rerunning the cluster check...\n'
      bash "$repo_root/scripts/20-install-k3s-kubevirt/check-cluster-status.sh" && cluster_ok=true
      break
    fi
    printf 'Still recovering: %s\n' "$unhealthy"
    sleep 30
  done
fi
if [[ "$cluster_ok" != true ]]; then
  printf 'Error: cluster is not healthy; follow the task 20 troubleshooting steps before starting guests.\n' >&2
  exit 1
fi

printf '\n=== Step 3/4: nested VM inventory ===\n'
bash "$repo_root/scripts/list-vms.sh"

printf '\n=== Step 4/4: optional guest starts ===\n'
if [[ "$start_fleet" == true ]]; then
  printf 'Reconciling fleet VMs to their declared runState...\n'
  bash "$repo_root/scripts/34-vm-fleet/setup-vm-fleet.sh" --apply
else
  printf 'Fleet VMs not touched (use --start-fleet to reconcile them to fleet.json).\n'
fi
if [[ "$start_desktop" == true ]]; then
  export KUBECONFIG="$repo_root/work/kubeconfig-lab-k8s-01.yaml"
  "$repo_root/work/virtctl-v1.9.1" start rocky-desktop -n rocky-desktop 2>/dev/null ||
    printf 'Desktop start skipped (already running or not provisioned).\n'
  printf 'Desktop starting; verify with: bash scripts/32-rocky-desktop/setup-rocky-desktop.sh --verify\n'
else
  printf 'Rocky desktop not touched (use --start-desktop to start it).\n'
fi

printf '\nLab resumed. Common next commands:\n'
printf '  Dashboards (reopen after every restart; tunnels are not boot services):\n'
printf '    bash scripts/45-monitoring-dashboard/access-dashboards.sh --host   # Headlamp 18080, Cockpit 19090\n'
printf '    bash lab-switchboard/scripts/access.sh                             # Switchboard 18088\n'
printf '    bash scripts/45-monitoring-dashboard/dashboard-permissions.sh token  # fresh Headlamp token\n'
printf '  Guest access: see scripts/README.md#vm-access-ssh-and-rdp\n'
printf '  Desktop RDP: bash scripts/32-rocky-desktop/setup-rocky-desktop.sh --rdp\n'
printf '  Microsegmentation next steps: doco/IMPLEMENTATION-STATUS.md (latest handoff)\n'
