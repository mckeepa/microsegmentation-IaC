#!/usr/bin/env bash

# list-vms.sh - inventory of nested KubeVirt VMs across all namespaces.
# Shows status, readiness, cluster-reachable IP, sizing, and labels, with
# optional label filtering, e.g.:
#   bash scripts/list-vms.sh
#   bash scripts/list-vms.sh --running
#   bash scripts/list-vms.sh -l app=web
#   bash scripts/list-vms.sh -l tier=backend,env=test --running
#
# Read-only: it never creates, starts, stops, or deletes anything.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
selector=""
running_only=false

usage() {
  printf 'Usage: %s [--running] [-l key=value[,key=value...]]\n' "${0##*/}"
  printf 'List nested KubeVirt VMs with status, IP, sizing, and labels.\n'
  printf '  --running   show only VMs whose instance is currently running\n'
  printf '  -l          Kubernetes label selector applied to the VM objects\n'
}

while (( $# > 0 )); do
  case "$1" in
    --running) running_only=true; shift ;;
    -l|--selector)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      selector="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ -n "$selector" && ! "$selector" =~ ^[A-Za-z0-9._/-]+(=|!=)[A-Za-z0-9._-]*(,[A-Za-z0-9._/-]+(=|!=)[A-Za-z0-9._-]*)*$ ]]; then
  printf 'Error: selector must look like key=value[,key=value...].\n' >&2
  exit 2
fi

for command_name in jq virsh ssh column; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'Error: %s required.\n' "$command_name" >&2; exit 1; }
done
source "$repo_root/scripts/lib/common.sh"
msl_init "$repo_root"
msl_assert_outer_vm
msl_discover_outer_ip

vm_args=(get vm -A -o json)
if [[ -n "$selector" ]]; then vm_args+=(-l "$selector"); fi
vms=$(msl_remote_kubectl "${vm_args[@]}")
vmis=$(msl_remote_kubectl get vmi -A -o json)

count=$(jq '.items | length' <<< "$vms")
if (( count == 0 )); then
  printf 'No VMs match%s.\n' "${selector:+ selector \"$selector\"}"
  exit 0
fi

# Colorize the STATUS column after alignment (escape codes are zero-width but
# would break column's width calculation if added earlier). Only when stdout
# is a terminal, so piped/captured output stays plain text.
colorize_status() {
  if [[ -t 1 ]]; then
    local green=$'\033[32m' red=$'\033[31m' reset=$'\033[0m'
    sed -E "s/ Running / ${green}Running${reset} /; s/ Stopped / ${red}Stopped${reset} /"
  else
    cat
  fi
}

{
  printf 'NAMESPACE\tNAME\tSTATUS\tREADY\tIP\tCPU\tMEMORY\tPORTS\tACCESS\tLABELS\n'
  jq -r --argjson vmis "$vmis" --arg running "$running_only" '
    def service_name(p):
      if p == 22 then "ssh"
      elif p == 80 then "http"
      elif p == 443 then "https"
      elif p == 3389 then "rdp"
      elif p == 5432 then "postgres"
      elif p == 8080 or p == 8081 then "http"
      else (p | tostring) end;
    ($vmis.items | map({key: (.metadata.namespace + "/" + .metadata.name), value: .}) | from_entries) as $live |
    .items[]
    | . as $vm
    | ($live[$vm.metadata.namespace + "/" + $vm.metadata.name] // null) as $vmi
    | ($vm.status.printableStatus // "Unknown") as $status
    | select($running == "false" or ($vmi != null and $vmi.status.phase == "Running"))
    | (($vm.spec.template.spec.domain.devices.interfaces[0].ports // []) | map(.port)) as $ports
    | (if ($ports | length) == 0 then "all" else ($ports | map("\(.)/\(service_name(.))") | join(",")) end) as $ports_text
    | ((($vm.metadata.labels // {})["microsegmentation-lab/role"] == "desktop")) as $is_desktop
    | ((if ($ports | index(22)) != null or ($ports | length) == 0 then ["ssh (virtctl helper)"] else [] end)
       + (if $is_desktop then ["rdp (ssh tunnel)", "vnc (console)"] else [] end)
       + ($ports | map(select(. != 22) | service_name(.) + " :" + (. | tostring)) | unique)
      | join("; ") | if . == "" then "none declared" else . end) as $access
    | [
        $vm.metadata.namespace,
        $vm.metadata.name,
        $status,
        (if $vmi == null then "-" else ([$vmi.status.conditions[]? | select(.type == "Ready")][0].status // "-") end),
        (if $vmi == null then "-" else ($vmi.status.interfaces[0].ipAddress // "-") end),
        ($vm.spec.template.spec.domain.cpu.cores // "-" | tostring),
        ($vm.spec.template.spec.domain.resources.requests.memory // "-"),
        $ports_text,
        $access,
        (($vm.metadata.labels // {})
          | del(."microsegmentation-lab/managed-by")
          | to_entries
          | map(select(.key | startswith("kubevirt.io") | not))
          | map("\(.key)=\(.value)")
          | join(",")
          | if . == "" then "-" else . end)
      ]
    | @tsv
  ' <<< "$vms"
} | column -t -s $'\t' | colorize_status

printf '\nIP is the cluster-reachable launcher pod address; inside every guest, ip a shows the NAT-internal 10.0.2.2 instead.\n'
printf 'PORTS lists the NAT-forwarded guest ports ("all" = no restriction declared); ACCESS is how to connect.\n'
printf 'SSH helpers: fleet VMs use scripts/34-vm-fleet/setup-vm-fleet.sh --ssh <name>; others are listed in scripts/README.md#vm-access-ssh-and-rdp.\n'
printf 'RDP exists only on the desktop and only through its SSH tunnel: scripts/32-rocky-desktop/setup-rocky-desktop.sh --rdp\n'
