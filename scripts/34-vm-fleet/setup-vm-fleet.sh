#!/usr/bin/env bash

# Declarative manager for nested KubeVirt lab VMs defined in fleet.json.
# Each entry references an approved blueprint (blueprints/*.json), gets its own
# namespace derived from its app label (namespace-per-app segmentation), a
# cloud-image OS disk uploaded through CDI, cloud-init key-only administration,
# and microsegmentation labels for later policy selection.
#
# The manager only creates or reconciles project-owned resources. It never
# deletes VMs, disks, or namespaces; removing an entry from fleet.json leaves
# the cluster resource in place for explicit manual review.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
config="$script_dir/fleet.json"
blueprint_dir="$script_dir/blueprints"
mode=--plan
target=""

usage() {
  printf 'Usage: %s [--config file.json] [--plan|--apply|--verify|--status] [--ssh <name>] [--start <name>] [--stop <name>] [--set-password <name>] [--cockpit <name>] [--rdp <name>] [--vnc <name>]\n' "${0##*/}"
}

while (( $# > 0 )); do
  case "$1" in
    --config) (( $# >= 2 )) || { usage >&2; exit 2; }; config="$2"; shift 2 ;;
    --plan|--apply|--verify|--status) mode="$1"; shift ;;
    --ssh|--start|--stop|--set-password|--cockpit|--rdp|--vnc)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      mode="$1"; target="$2"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for command_name in jq virsh ssh ssh-keygen curl sha256sum timeout git; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'Error: %s required.\n' "$command_name" >&2; exit 1; }
done
source "$repo_root/scripts/lib/common.sh"
msl_init "$repo_root"

# --- Static validation -------------------------------------------------------

jq -e '
  (.namespacePrefix | type == "string" and test("^[a-z][a-z0-9]{0,11}$")) and
  (.defaults.adminUser | type == "string" and test("^[a-z_][a-z0-9_-]{0,30}$")) and .defaults.adminUser != "root" and
  (.defaults.timezone | type == "string" and test("^[A-Za-z_]+(/[A-Za-z_+-]+)*$")) and
  (.defaults.waitSeconds | type == "number" and floor == . and . >= 300 and . <= 7200) and
  (.vms | type == "array" and length >= 1 and length <= 16) and
  (.vms | map(.name) | length == (unique | length)) and
  all(.vms[];
    (.name | type == "string" and test("^[a-z][a-z0-9-]{0,30}$")) and
    (.blueprint | type == "string" and test("^[a-z][a-z0-9-]{0,30}$")) and
    (.cpu | type == "number" and floor == . and . >= 1 and . <= 8) and
    (.memory | type == "string" and test("^[1-9][0-9]?Gi$")) and
    (.disk | type == "string" and test("^[1-9][0-9]?Gi$")) and
    (.labels | type == "object") and
    (.labels.app | type == "string" and test("^[a-z][a-z0-9-]{0,20}$")) and
    (.labels | to_entries | all(.[];
      (.key | test("^[a-z][a-z0-9-]{0,30}$")) and ((.value | type) == "string" and (.value | test("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,61}$"))))) and
    ((.ports // []) | type == "array" and all(.[]; type == "number" and floor == . and . >= 1 and . <= 65535 and . != 9090 and . != 3389)) and
    ((.waitSeconds // null) == null or (.waitSeconds | type == "number" and floor == . and . >= 300 and . <= 7200)) and
    (.runState == "running" or .runState == "stopped") and
    (.owner | type == "string" and length > 0 and length <= 63) and
    (.purpose | type == "string" and length > 0 and length <= 200))
' "$config" >/dev/null || { printf 'Error: invalid fleet configuration: %s\n' "$config" >&2; exit 2; }

namespace_prefix=$(jq -r .namespacePrefix "$config")
admin_user=$(jq -r .defaults.adminUser "$config")
timezone=$(jq -r .defaults.timezone "$config")
wait_seconds=$(jq -r .defaults.waitSeconds "$config")
mapfile -t fleet_names < <(jq -r '.vms[].name' "$config")

vm_config() { jq -c --arg name "$1" '.vms[] | select(.name == $name)' "$config"; }
vm_namespace() { printf '%s-%s' "$namespace_prefix" "$(jq -r .labels.app <<< "$1")"; }
vm_wait_seconds() { jq -r --argjson d "$wait_seconds" '.waitSeconds // $d' <<< "$1"; }

blueprint_json() {
  local id="$1" path
  path="$blueprint_dir/$id.json"
  if [[ ! -s "$path" ]]; then
    printf 'Error: blueprint %s is not an approved blueprint (missing %s).\n' "$id" "$path" >&2
    return 1
  fi
  jq -e --arg id "$id" '
    .blueprint == $id and
    (.osFamily | type == "string") and (.osId | type == "string") and
    (.osVersionPrefix | type == "string") and
    (.image.url | type == "string" and startswith("https://")) and
    (.image.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.image.cachePrefix | type == "string" and test("^[a-z][a-z0-9-]{0,30}$")) and
    (.image.extension | type == "string" and test("^[a-z0-9]{1,8}$")) and
    (.packages | type == "array" and length >= 1) and
    (.sudoGroup | type == "string") and (.sshService | type == "string") and
    (.agentService | type == "string") and
    ((.desktop // null) == null or (
      (.desktop.session | type == "string" and test("^[a-z][a-z0-9-]{0,20}$")) and
      (.desktop.minCpu | type == "number" and floor == . and . >= 1 and . <= 8) and
      (.desktop.minMemory | type == "string" and test("^[1-9][0-9]?Gi$")) and
      (.desktop.minDisk | type == "string" and test("^[1-9][0-9]?Gi$")) and
      (.desktop.configure | type == "string" and test("^[a-z][a-z0-9-]{0,40}[.]sh$"))))
  ' "$path" >/dev/null || { printf 'Error: invalid blueprint file: %s\n' "$path" >&2; return 1; }
  local configure
  configure=$(jq -r '.desktop.configure // empty' "$path")
  if [[ -n "$configure" && ! -s "$blueprint_dir/$configure" ]]; then
    printf 'Error: blueprint %s desktop configure script missing: %s\n' "$id" "$blueprint_dir/$configure" >&2
    return 1
  fi
  jq -c . "$path"
}

# Validate every referenced blueprint up front; desktop blueprints additionally
# enforce their minimum CPU/memory/disk so a desktop VM is never undersized.
for name in "${fleet_names[@]}"; do
  vm_json=$(vm_config "$name")
  bp=$(blueprint_json "$(jq -r .blueprint <<< "$vm_json")")
  jq -e --argjson vm "$vm_json" '
    (.desktop // null) == null or (
      $vm.cpu >= .desktop.minCpu and
      ($vm.memory | rtrimstr("Gi") | tonumber) >= (.desktop.minMemory | rtrimstr("Gi") | tonumber) and
      ($vm.disk | rtrimstr("Gi") | tonumber) >= (.desktop.minDisk | rtrimstr("Gi") | tonumber))
  ' <<< "$bp" >/dev/null || {
    printf 'Error: %s is below the desktop blueprint minimum (%s): needs cpu >= %s, memory >= %s, disk >= %s.\n' \
      "$name" "$(jq -r .blueprint <<< "$bp")" "$(jq -r .desktop.minCpu <<< "$bp")" \
      "$(jq -r .desktop.minMemory <<< "$bp")" "$(jq -r .desktop.minDisk <<< "$bp")" >&2
    exit 2
  }
done

if [[ -n "$target" ]]; then
  printf '%s\n' "${fleet_names[@]}" | grep -qx "$target" || {
    printf 'Error: %s is not defined in %s.\n' "$target" "$config" >&2; exit 2;
  }
fi

if [[ "$mode" == --plan ]]; then
  printf 'Fleet plan (%s):\n' "$config"
  printf '%-16s %-14s %-12s %-4s %-6s %-6s %-9s %s\n' NAME BLUEPRINT NAMESPACE CPU MEM DISK RUNSTATE LABELS
  for name in "${fleet_names[@]}"; do
    vm_json=$(vm_config "$name")
    printf '%-16s %-14s %-12s %-4s %-6s %-6s %-9s %s\n' \
      "$name" "$(jq -r .blueprint <<< "$vm_json")" "$(vm_namespace "$vm_json")" \
      "$(jq -r .cpu <<< "$vm_json")" "$(jq -r .memory <<< "$vm_json")" "$(jq -r .disk <<< "$vm_json")" \
      "$(jq -r .runState <<< "$vm_json")" "$(jq -r '.labels | to_entries | map("\(.key)=\(.value)") | join(",")' <<< "$vm_json")"
  done
  printf '\nApply creates namespaces per app label, uploads checksum-pinned cloud images, and\n'
  printf 'provisions key-only cloud-init administration. Nothing is deleted by this tool;\n'
  printf 'removing an entry leaves its cluster resources for explicit manual review.\n'
  exit 0
fi

# --- Cluster preconditions ---------------------------------------------------

msl_assert_lab_files
msl_assert_outer_vm
msl_discover_outer_ip

# assert_owned <json> <what>: refuse resources not labeled as project-managed.
assert_owned() {
  jq -e --arg label "$MSL_MANAGED_LABEL" --arg owner "$MSL_MANAGED_OWNER" \
    '.metadata.labels[$label] == $owner' <<< "$1" >/dev/null || {
    printf 'Error: refusing unowned %s.\n' "$2" >&2
    return 1
  }
}

guest_key() { printf '%s/%s_ed25519' "$work_dir" "$1"; }
guest_known_hosts() { printf '%s/%s_known_hosts' "$work_dir" "$1"; }

verify_vm() {
  local name="$1" vm_json blueprint namespace bp desktop_checks verify_command
  vm_json=$(vm_config "$name")
  namespace=$(vm_namespace "$vm_json")
  bp=$(blueprint_json "$(jq -r .blueprint <<< "$vm_json")")
  desktop_checks=""
  if jq -e '.desktop != null' <<< "$bp" >/dev/null; then
    # Desktop blueprints: xrdp and the display manager are active, and the RDP
    # port listens on the guest loopback only (reachable solely via --rdp).
    desktop_checks='systemctl is-active xrdp display-manager; ss -H -ltn "sport = :3389" | grep -q "127.0.0.1:3389"; test -z "$(ss -H -ltn "sport = :3389" | grep -v "127.0.0.1:3389")"; '
  fi
  printf -v verify_command 'set -eu; . /etc/os-release; test "$ID" = %q; case "$VERSION_ID" in %q*) ;; *) exit 1 ;; esac; hostname | grep -qx %q; id; findmnt /; ip -br address; sudo -n true; systemctl is-active %q %q; sudo -n /usr/sbin/sshd -T | grep -qx "passwordauthentication no"; sudo -n /usr/sbin/sshd -T | grep -qx "permitrootlogin no"; %sprintf "PASS fleet VM %q (%q) OS, SSH policy, sudo, and services\\n"' \
    "$(jq -r .osId <<< "$bp")" "$(jq -r .osVersionPrefix <<< "$bp")" "$name" \
    "$(jq -r .sshService <<< "$bp")" "$(jq -r .agentService <<< "$bp")" "$desktop_checks" "$name" "$(jq -r .blueprint <<< "$bp")"
  msl_guest_ssh "$admin_user" "$name" "$namespace" "$(guest_key "$name")" "$(guest_known_hosts "$name")" \
    --command="$verify_command"
}

if [[ "$mode" == --status ]]; then
  for name in "${fleet_names[@]}"; do
    namespace=$(vm_namespace "$(vm_config "$name")")
    printf -- '--- %s (namespace %s) ---\n' "$name" "$namespace"
    msl_remote_kubectl get vm,vmi "$name" -n "$namespace" --ignore-not-found 2>/dev/null ||
      printf 'not created\n'
  done
  exit 0
fi

if [[ "$mode" == --ssh || "$mode" == --start || "$mode" == --stop || "$mode" == --set-password || "$mode" == --cockpit || "$mode" == --rdp || "$mode" == --vnc ]]; then
  vm_json=$(vm_config "$target")
  namespace=$(vm_namespace "$vm_json")
  live_vm=$(msl_remote_kubectl get vm "$target" -n "$namespace" --ignore-not-found -o json)
  [[ -n "$live_vm" ]] || { printf 'Error: %s is not provisioned; run --apply first.\n' "$target" >&2; exit 1; }
  assert_owned "$live_vm" "VM $namespace/$target"
  case "$mode" in
    --ssh) msl_guest_ssh "$admin_user" "$target" "$namespace" "$(guest_key "$target")" "$(guest_known_hosts "$target")" --local-ssh-opts=-tt; exit ;;
    --start) exec "$MSL_VIRTCTL" start "$target" -n "$namespace" ;;
    --stop) exec "$MSL_VIRTCTL" stop "$target" -n "$namespace" ;;
    --vnc) exec "$MSL_VIRTCTL" vnc "$target" -n "$namespace" ;;
    --rdp)
      # Loopback-to-loopback tunnel, like --cockpit: xrdp in a desktop-blueprint
      # guest listens only on 127.0.0.1:3389 and is reached inside SSH.
      bp=$(blueprint_json "$(jq -r .blueprint <<< "$vm_json")")
      jq -e '.desktop != null' <<< "$bp" >/dev/null || {
        printf 'Error: %s uses the headless %s blueprint; RDP needs a desktop blueprint (ubuntu-desktop, rocky-desktop).\n' \
          "$target" "$(jq -r .blueprint <<< "$bp")" >&2
        exit 2
      }
      msl_find_free_port 13391 13401
      printf 'RDP for %s (%s): connect your RDP client to 127.0.0.1:%s as %s.\n' \
        "$target" "$(jq -r .desktop.session <<< "$bp")" "$MSL_FREE_PORT" "$admin_user"
      printf 'RDP needs an OS password: set one first with %s --set-password %s if you have not.\n' "${0##*/}" "$target"
      printf 'Keep this terminal open; Ctrl+C closes the tunnel without stopping the VM.\n'
      msl_guest_ssh "$admin_user" "$target" "$namespace" "$(guest_key "$target")" "$(guest_known_hosts "$target")" \
        --local-ssh-opts=-N --local-ssh-opts="-L127.0.0.1:$MSL_FREE_PORT:127.0.0.1:3389" \
        --local-ssh-opts='-o ExitOnForwardFailure=yes'
      exit ;;
    --set-password)
      # Console-recovery password for the admin user. SSH stays key-only
      # regardless (password authentication is disabled in sshd).
      [[ -t 0 ]] || { printf 'Error: enter the password directly in an interactive terminal.\n' >&2; exit 1; }
      msl_guest_ssh "$admin_user" "$target" "$namespace" "$(guest_key "$target")" "$(guest_known_hosts "$target")" \
        --local-ssh-opts=-tt --command="sudo -n passwd $admin_user"
      printf 'Password updated for %s on %s. It is used for virtctl console/VNC, Cockpit, and desktop RDP login; SSH remains key-only.\n' "$admin_user" "$target"
      exit ;;
    --cockpit)
      # Loopback-to-loopback tunnel, like the desktop RDP helper: Cockpit in
      # the guest listens only on 127.0.0.1:9090 and is reached inside SSH.
      msl_find_free_port 19091 19101
      printf 'Cockpit for %s: open https://127.0.0.1:%s and log in as %s.\n' "$target" "$MSL_FREE_PORT" "$admin_user"
      printf 'Cockpit needs an OS password: set one first with %s --set-password %s if you have not.\n' "${0##*/}" "$target"
      printf 'Keep this terminal open; Ctrl+C closes the tunnel without stopping the VM.\n'
      msl_guest_ssh "$admin_user" "$target" "$namespace" "$(guest_key "$target")" "$(guest_known_hosts "$target")" \
        --local-ssh-opts=-N --local-ssh-opts="-L127.0.0.1:$MSL_FREE_PORT:127.0.0.1:9090" \
        --local-ssh-opts='-o ExitOnForwardFailure=yes'
      exit ;;
  esac
fi

if [[ "$mode" == --verify ]]; then
  failures=0
  for name in "${fleet_names[@]}"; do
    vm_json=$(vm_config "$name")
    if [[ "$(jq -r .runState <<< "$vm_json")" != running ]]; then
      printf 'SKIP %s: declared runState is stopped.\n' "$name"
      continue
    fi
    verify_vm "$name" || failures=$((failures + 1))
  done
  (( failures == 0 )) || { printf 'Error: %s fleet VM(s) failed verification.\n' "$failures" >&2; exit 1; }
  exit 0
fi

# --- Apply -------------------------------------------------------------------

for name in "${fleet_names[@]}"; do
  vm_json=$(vm_config "$name")
  namespace=$(vm_namespace "$vm_json")
  blueprint_id=$(jq -r .blueprint <<< "$vm_json")
  bp=$(blueprint_json "$blueprint_id")
  image_sha=$(jq -r .image.sha256 <<< "$bp")
  disk_size=$(jq -r .disk <<< "$vm_json")
  run_state=$(jq -r .runState <<< "$vm_json")
  vm_wait=$(vm_wait_seconds "$vm_json")
  desktop_session=$(jq -r '.desktop.session // empty' <<< "$bp")
  key=$(guest_key "$name")
  known_hosts=$(guest_known_hosts "$name")
  pvc_name="$name-disk"
  secret_name="$name-cloudinit"
  printf '=== %s (%s -> namespace %s) ===\n' "$name" "$blueprint_id" "$namespace"

  msl_ensure_keypair "$key" "$known_hosts" "microsegmentation-iac-fleet-$name" true "work/${name}_ed25519"

  namespace_json=$(msl_remote_kubectl get namespace "$namespace" --ignore-not-found -o json)
  if [[ -n "$namespace_json" ]]; then
    assert_owned "$namespace_json" "namespace $namespace"
  else
    jq -n --arg ns "$namespace" --arg app "$(jq -r .labels.app <<< "$vm_json")" \
      '{apiVersion:"v1",kind:"Namespace",metadata:{name:$ns,labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac","microsegmentation-lab/app":$app}}}' |
      msl_outer_ssh 'sudo -n k3s kubectl create -f -'
  fi

  live_vm=$(msl_remote_kubectl get vm "$name" -n "$namespace" --ignore-not-found -o json)
  if [[ -n "$live_vm" ]]; then
    jq -e --arg sha "$image_sha" --arg pvc "$pvc_name" '
      .metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac" and
      .metadata.annotations["microsegmentation-lab/image-sha256"] == $sha and .spec.runStrategy == "Manual" and
      any(.spec.template.spec.volumes[]; .name == "osdisk" and .persistentVolumeClaim.claimName == $pvc)
    ' <<< "$live_vm" >/dev/null || { printf 'Error: refusing unexpected existing VM %s/%s.\n' "$namespace" "$name" >&2; exit 1; }
  fi

  pvc=$(msl_remote_kubectl get pvc "$pvc_name" -n "$namespace" --ignore-not-found -o json)
  if [[ -n "$pvc" ]]; then
    jq -e --arg sha "$image_sha" --arg size "$disk_size" '
      .metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac" and
      .metadata.annotations["microsegmentation-lab/image-sha256"] == $sha and
      .spec.storageClassName == "local-path" and .spec.volumeMode == "Filesystem" and
      .spec.resources.requests.storage == $size
    ' <<< "$pvc" >/dev/null || { printf 'Error: existing PVC %s/%s does not match the fleet entry.\n' "$namespace" "$pvc_name" >&2; exit 1; }
  fi
  upload_complete=$(jq -r '.status.phase == "Bound" and .metadata.annotations["cdi.kubevirt.io/storage.condition.running.reason"] == "Completed"' <<< "${pvc:-"{}"}")

  if [[ "$upload_complete" != true ]]; then
    if [[ -n "$live_vm" ]]; then
      printf 'Error: refusing to upload over the attached OS disk of %s.\n' "$name" >&2; exit 1
    fi
    # Capacity guard: this VM's disk plus 10 GiB reserve, and memory plus 2 GiB.
    free_kib=$(msl_outer_ssh 'df -Pk /' | awk 'NR == 2 {print $4}')
    available_kib=$(msl_outer_ssh "awk '/MemAvailable:/ {print \$2}' /proc/meminfo")
    disk_gib=${disk_size%Gi}
    memory_gib=$(jq -r '.memory | rtrimstr("Gi") | tonumber' <<< "$vm_json")
    if (( free_kib < (disk_gib + 10) * 1048576 || available_kib < (memory_gib + 2) * 1048576 )); then
      printf 'Error: insufficient free disk or available memory for %s; existing guests were not changed.\n' "$name" >&2
      exit 1
    fi
    image="$work_dir/$(jq -r .image.cachePrefix <<< "$bp")-$image_sha.$(jq -r .image.extension <<< "$bp")"
    msl_fetch_image "$(jq -r .image.url <<< "$bp")" "$image_sha" "$image"
    trap msl_upload_tunnel_close EXIT
    msl_find_free_port 18476 18486
    msl_upload_tunnel_open "$MSL_FREE_PORT"
    if [[ -z "$pvc" ]]; then
      jq -n --arg name "$pvc_name" --arg ns "$namespace" --arg sha "$image_sha" --arg size "$disk_size" \
        '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns,labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac"},annotations:{"microsegmentation-lab/image-sha256":$sha,"cdi.kubevirt.io/storage.bind.immediate.requested":"true"}},spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",resources:{requests:{storage:$size}}}}' |
        msl_outer_ssh 'sudo -n k3s kubectl create -f -'
    else
      msl_remote_kubectl annotate pvc "$pvc_name" -n "$namespace" cdi.kubevirt.io/storage.bind.immediate.requested=true --overwrite
    fi
    "$MSL_VIRTCTL" image-upload pvc "$pvc_name" -n "$namespace" --no-create --force-bind \
      --uploadproxy-url="https://127.0.0.1:$MSL_FREE_PORT" --insecure --image-path="$image" --wait-secs=300
    msl_upload_tunnel_close
    trap - EXIT
  fi

  if [[ -z "$live_vm" ]]; then
    # Desktop blueprints ship a configure script that cloud-init runs on first
    # boot with the admin user as the desktop login user.
    desktop_script=null
    if [[ -n "$desktop_session" ]]; then
      desktop_script=$(jq -Rs . < "$blueprint_dir/$(jq -r .desktop.configure <<< "$bp")")
    fi
    user_data=$(jq -cn --argjson vm "$vm_json" --argjson bp "$bp" --argjson desktop_script "$desktop_script" \
      --arg key "$MSL_PUBLIC_KEY" --arg admin "$admin_user" --arg tz "$timezone" '
      {hostname:$vm.name,manage_etc_hosts:true,timezone:$tz,disable_root:true,ssh_pwauth:false,
       users:[{name:$admin,groups:[$bp.sudoGroup],shell:"/bin/bash",lock_passwd:true,sudo:["ALL=(ALL) NOPASSWD:ALL"],ssh_authorized_keys:[$key]}],
       package_update:true,packages:$bp.packages,
       write_files:([{path:"/etc/ssh/sshd_config.d/00-microsegmentation-lab.conf",owner:"root:root",permissions:"0644",
         content:"PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n"},
        {path:"/etc/systemd/system/cockpit.socket.d/listen.conf",owner:"root:root",permissions:"0644",
         content:"[Socket]\nListenStream=\nListenStream=127.0.0.1:9090\nFreeBind=yes\n"},
        {path:"/etc/cloud/cloud.cfg.d/99-microsegmentation-lab-network.cfg",owner:"root:root",permissions:"0644",
         content:"# KubeVirt masquerade NICs get a MAC derived from the launcher pod IP, which\n# changes on every VM restart; cloud-init must not render a MAC-pinned config.\nnetwork: {config: disabled}\n"},
        {path:"/etc/netplan/90-microsegmentation-lab.yaml",owner:"root:root",permissions:"0600",
         content:"# Match the NIC by name, never by MAC: the KubeVirt masquerade MAC changes on\n# every restart. Harmless on NetworkManager guests, which ignore netplan.\nnetwork:\n  version: 2\n  ethernets:\n    lab-nic:\n      match: {name: \"en*\"}\n      dhcp4: true\n      dhcp6: true\n"}]
        + (if $desktop_script != null then
            [{path:"/usr/local/sbin/configure-lab-desktop",owner:"root:root",permissions:"0700",content:$desktop_script}]
          else [] end)),
       runcmd:([["systemctl","enable","--now",$bp.agentService],["systemctl","daemon-reload"],["systemctl","enable","--now","cockpit.socket"],
        ["rm","-f","/etc/netplan/50-cloud-init.yaml"],
        ["sshd","-t"],["systemctl","reload",$bp.sshService]]
        + (if $desktop_script != null then [["bash","/usr/local/sbin/configure-lab-desktop",$admin]] else [] end))}
    ')
    printf -v user_data '#cloud-config\n%s\n' "$user_data"
    existing_secret=$(msl_remote_kubectl get secret "$secret_name" -n "$namespace" --ignore-not-found -o json)
    if [[ -n "$existing_secret" ]]; then assert_owned "$existing_secret" "Secret $namespace/$secret_name"; fi
    jq -n --arg name "$secret_name" --arg ns "$namespace" --arg data "$user_data" \
      '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:$ns,labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac"}},type:"Opaque",stringData:{userdata:$data}}' |
      msl_outer_ssh 'sudo -n k3s kubectl apply -f -'
    jq -n --argjson vm "$vm_json" --arg ns "$namespace" --arg sha "$image_sha" \
      --arg pvc "$pvc_name" --arg secret "$secret_name" --arg bp_id "$blueprint_id" --arg session "$desktop_session" '
      ($vm.labels + {"microsegmentation-lab/managed-by":"microsegmentation-iac","microsegmentation-lab/role":"fleet","microsegmentation-lab/blueprint":$bp_id}
        + (if $session != "" then {"microsegmentation-lab/desktop":$session} else {} end)) as $labels |
      ([{name:"ssh",port:22,protocol:"TCP"}] + [($vm.ports // [])[] | {name:("port-" + (. | tostring)),port:.,protocol:"TCP"}]) as $ports |
      {apiVersion:"kubevirt.io/v1",kind:"VirtualMachine",
       metadata:{name:$vm.name,namespace:$ns,labels:$labels,
         annotations:{"microsegmentation-lab/image-sha256":$sha,"microsegmentation-lab/owner":$vm.owner,"microsegmentation-lab/purpose":$vm.purpose}},
       spec:{runStrategy:"Manual",
         template:{metadata:{labels:$labels},
           spec:{domain:{cpu:{cores:$vm.cpu},resources:{requests:{memory:$vm.memory}},
               devices:{disks:[{name:"osdisk",disk:{bus:"virtio"},bootOrder:1},{name:"cloudinit",disk:{bus:"virtio"}}],
                 interfaces:[{name:"default",masquerade:{},ports:$ports}]}},
             networks:[{name:"default",pod:{}}],
             volumes:[{name:"osdisk",persistentVolumeClaim:{claimName:$pvc}},
               {name:"cloudinit",cloudInitNoCloud:{secretRef:{name:$secret}}}]}}}}' |
      msl_outer_ssh 'sudo -n k3s kubectl create -f -'
  fi

  live_vmi=$(msl_remote_kubectl get vmi "$name" -n "$namespace" --ignore-not-found -o name)
  if [[ "$run_state" == running ]]; then
    if [[ -z "$live_vmi" ]]; then "$MSL_VIRTCTL" start "$name" -n "$namespace"; fi
    msl_remote_kubectl wait --for=create "vmi/$name" -n "$namespace" --timeout=120s
    msl_remote_kubectl wait --for=condition=Ready "vmi/$name" -n "$namespace" --timeout=300s
    msl_wait_for_guest_ssh "$admin_user" "$name" "$namespace" "$key" "$known_hosts" "$vm_wait" "$name"
    printf '%s SSH is ready. Waiting for cloud-init completion (cloud-init prints its status below)...\n' "$name"
    msl_guest_cloudinit_wait "$admin_user" "$name" "$namespace" "$key" "$known_hosts" "$vm_wait"
    printf 'Verifying %s...\n' "$name"
    verify_vm "$name"
  else
    if [[ -n "$live_vmi" ]]; then
      "$MSL_VIRTCTL" stop "$name" -n "$namespace"
      msl_remote_kubectl wait --for=delete "vmi/$name" -n "$namespace" --timeout=180s
    fi
    printf '%s reconciled to stopped.\n' "$name"
  fi
done
printf 'Fleet apply complete. Interactive access: %s --ssh <name>; desktop blueprints also support --rdp/--vnc.\n' "${0##*/}"
