# shellcheck shell=bash
# Shared helpers for microsegmentation-IaC task scripts.
# Source this file; do not execute it. Callers must run `set -euo pipefail` themselves.
#
# Conventions:
# - All functions and globals use the msl_/MSL_ prefix (microsegmentation lab).
# - The outer lab VM is the single managed QEMU/KVM guest running K3s/KubeVirt.
# - Guest SSH always goes through `virtctl ssh` (the Kubernetes API), never a
#   public listener. virtctl's --known-hosts flag is ignored by its local-ssh
#   wrapper, so every connection also pins -o UserKnownHostsFile explicitly.

MSL_OUTER_VM="lab-k8s-01"
MSL_MANAGED_TITLE="microsegmentation-iac-lab-k8s-01"
MSL_MANAGED_LABEL="microsegmentation-lab/managed-by"
MSL_MANAGED_OWNER="microsegmentation-iac"
MSL_OUTER_IP=""
MSL_PUBLIC_KEY=""
MSL_FREE_PORT=""
MSL_UPLOAD_TUNNEL_PID=""
MSL_UPLOAD_REMOTE_PID=""
MSL_UPLOAD_TMP_DIR=""

# msl_init <repo_root>: set derived paths. Call once after sourcing.
msl_init() {
  MSL_REPO_ROOT="$1"
  MSL_WORK_DIR="$MSL_REPO_ROOT/work"
  MSL_VIRTCTL="$MSL_WORK_DIR/virtctl-v1.9.1"
  MSL_OUTER_KEY="$MSL_WORK_DIR/${MSL_OUTER_VM}_ed25519"
  MSL_OUTER_KNOWN_HOSTS="$MSL_WORK_DIR/${MSL_OUTER_VM}_known_hosts"
  MSL_OUTER_SSH_OPTS=(-i "$MSL_OUTER_KEY" -o IdentitiesOnly=yes -o BatchMode=yes
    -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$MSL_OUTER_KNOWN_HOSTS")
}

# msl_require_commands <command>...: fail unless every command is available.
msl_require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf 'Error: %s is required on the physical host.\n' "$command_name" >&2
      return 1
    }
  done
}

# msl_assert_outer_vm: the managed outer VM must exist, carry the project title,
# and be running.
msl_assert_outer_vm() {
  local title state
  title=$(virsh -c qemu:///system desc "$MSL_OUTER_VM" --title 2>/dev/null || true)
  if [[ "$title" != "$MSL_MANAGED_TITLE" ]]; then
    printf 'Error: VM %s is not marked as managed by this project.\n' "$MSL_OUTER_VM" >&2
    return 1
  fi
  state=$(virsh -c qemu:///system domstate "$MSL_OUTER_VM" | tr -d '\r')
  if [[ "$state" != running ]]; then
    printf 'Error: VM %s must be running; current state: %s.\n' "$MSL_OUTER_VM" "$state" >&2
    return 1
  fi
}

# msl_assert_lab_files: kubeconfig and virtctl from tasks 20/30 must exist.
msl_assert_lab_files() {
  export KUBECONFIG="$MSL_WORK_DIR/kubeconfig-${MSL_OUTER_VM}.yaml"
  if [[ ! -x "$MSL_VIRTCTL" || ! -s "$KUBECONFIG" ]]; then
    printf 'Error: task 20 kubeconfig and task 30 virtctl are required.\n' >&2
    return 1
  fi
}

# msl_discover_outer_ip: resolve the outer VM IPv4 address via the DHCP lease,
# falling back to the QEMU guest agent. Sets MSL_OUTER_IP.
msl_discover_outer_ip() {
  MSL_OUTER_IP=$(virsh -c qemu:///system domifaddr "$MSL_OUTER_VM" --source lease 2>/dev/null |
    awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }' || true)
  if [[ -z "$MSL_OUTER_IP" ]]; then
    local outer_mac interfaces
    outer_mac=$(virsh -c qemu:///system domiflist "$MSL_OUTER_VM" | awk '$3 == "default" { print tolower($5); exit }')
    interfaces=$(virsh -c qemu:///system qemu-agent-command "$MSL_OUTER_VM" '{"execute":"guest-network-get-interfaces"}')
    MSL_OUTER_IP=$(jq -r --arg mac "$outer_mac" '[.return[]
      | select((."hardware-address" // "" | ascii_downcase) == $mac)
      | .["ip-addresses"][]?
      | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("169.254.") | not))
      | .["ip-address"]] | first // empty' <<< "$interfaces")
  fi
  if [[ -z "$MSL_OUTER_IP" ]]; then
    printf 'Error: outer guest IP unavailable.\n' >&2
    return 1
  fi
}

# msl_outer_ssh <command>: run one shell command on the outer VM.
msl_outer_ssh() {
  ssh "${MSL_OUTER_SSH_OPTS[@]}" "labadmin@$MSL_OUTER_IP" "$1"
}

# msl_remote_kubectl <kubectl-args>...: run kubectl inside the outer VM with
# each argument safely quoted.
msl_remote_kubectl() {
  local remote_command='sudo -n k3s kubectl' argument quoted
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    remote_command+=" $quoted"
  done
  ssh "${MSL_OUTER_SSH_OPTS[@]}" "labadmin@$MSL_OUTER_IP" "$remote_command"
}

# msl_guest_ssh <user> <vm> <namespace> <key> <known_hosts> [virtctl-args]...:
# key-authenticated SSH to a nested guest through the Kubernetes API.
msl_guest_ssh() {
  local user="$1" vm="$2" namespace="$3" key="$4" known_hosts="$5"
  shift 5
  "$MSL_VIRTCTL" ssh "$user@vmi/$vm" -n "$namespace" --identity-file="$key" --known-hosts="$known_hosts" \
    --local-ssh-opts='-o BatchMode=yes' --local-ssh-opts='-o IdentitiesOnly=yes' \
    --local-ssh-opts="-o UserKnownHostsFile=$known_hosts" \
    --local-ssh-opts='-o ConnectTimeout=5' --local-ssh-opts='-o StrictHostKeyChecking=accept-new' "$@"
}

# msl_guest_ssh_strict: like msl_guest_ssh but requires a pinned host key.
msl_guest_ssh_strict() {
  local user="$1" vm="$2" namespace="$3" key="$4" known_hosts="$5"
  shift 5
  "$MSL_VIRTCTL" ssh "$user@vmi/$vm" -n "$namespace" --identity-file="$key" --known-hosts="$known_hosts" \
    --local-ssh-opts='-o BatchMode=yes' --local-ssh-opts='-o IdentitiesOnly=yes' \
    --local-ssh-opts="-o UserKnownHostsFile=$known_hosts" \
    --local-ssh-opts='-o StrictHostKeyChecking=yes' "$@"
}

# msl_ssh_error_summary <ssh-output>: pick the most informative line from a
# failed SSH attempt. virtctl's local-ssh wrapper always ends with a generic
# "exit status N" line (often preceded by "Connection closed by UNKNOWN" proxy
# noise), so prefer the last line above those (the real OpenSSH or API-proxy
# error) and fall back to the last line when nothing else exists.
msl_ssh_error_summary() {
  local summary
  summary=$(grep -v -e '^exit status [0-9]*$' -e '^Connection closed by UNKNOWN' \
    -e '^[[:space:]]*$' <<< "$1" | tail -n 1)
  [[ -n "$summary" ]] || summary=$(tail -n 1 <<< "$1")
  printf '%s' "$summary"
}

# msl_wait_for_guest_ssh <user> <vm> <namespace> <key> <known_hosts> <timeout_s> <label>:
# retry guest SSH until it succeeds, printing a heartbeat every 30 seconds with
# the elapsed time, VMI phase, and the most recent SSH error.
msl_wait_for_guest_ssh() {
  local user="$1" vm="$2" namespace="$3" key="$4" known_hosts="$5" timeout_s="$6" label="$7"
  local deadline=$((SECONDS + timeout_s)) wait_started=$SECONDS next_status_at=$((SECONDS + 30))
  local ssh_error vmi_phase
  printf 'Waiting up to %s seconds for %s key-authenticated SSH...\n' "$timeout_s" "$label"
  until ssh_error=$(msl_guest_ssh "$user" "$vm" "$namespace" "$key" "$known_hosts" --command=true 2>&1 >/dev/null); do
    if (( SECONDS >= deadline )); then
      printf 'Error: %s SSH not ready within %ss; no disks were changed. Last SSH error: %s\n' \
        "$label" "$timeout_s" "$(msl_ssh_error_summary "$ssh_error")" >&2
      return 1
    fi
    if (( SECONDS >= next_status_at )); then
      vmi_phase=$(msl_remote_kubectl get vmi "$vm" -n "$namespace" --ignore-not-found -o jsonpath='{.status.phase}' 2>/dev/null || true)
      printf 'Still waiting (%ss elapsed): VMI phase %s; SSH not ready: %s\n' \
        "$((SECONDS - wait_started))" "${vmi_phase:-unknown}" "$(msl_ssh_error_summary "$ssh_error")"
      next_status_at=$((SECONDS + 30))
    fi
    sleep 5
  done
}

# msl_guest_cloudinit_wait <user> <vm> <namespace> <key> <known_hosts> <timeout_s>:
# wait for guest cloud-init completion with a strictly pinned host key and an
# overall timeout guarding a hung guest.
msl_guest_cloudinit_wait() {
  local user="$1" vm="$2" namespace="$3" key="$4" known_hosts="$5" timeout_s="$6"
  timeout --foreground "$timeout_s" "$MSL_VIRTCTL" ssh "$user@vmi/$vm" -n "$namespace" \
    --identity-file="$key" --known-hosts="$known_hosts" --local-ssh-opts='-o BatchMode=yes' \
    --local-ssh-opts='-o IdentitiesOnly=yes' --local-ssh-opts="-o UserKnownHostsFile=$known_hosts" \
    --local-ssh-opts='-o StrictHostKeyChecking=yes' \
    --command='sudo -n cloud-init status --wait --long'
}

# msl_ensure_keypair <key_path> <known_hosts> <comment> <generate> <relative_key>:
# refuse symlinked key material; optionally generate a new Ed25519 keypair
# (relative_key must be Git-ignored). Sets MSL_PUBLIC_KEY.
msl_ensure_keypair() {
  local key_path="$1" known_hosts="$2" comment="$3" generate="$4" relative_key="$5"
  umask 077
  if [[ -L "$key_path" || -L "$key_path.pub" || -L "$known_hosts" ]]; then
    printf 'Error: refusing symlinked key/known-hosts files.\n' >&2
    return 1
  fi
  if [[ "$generate" == true && ! -e "$key_path" ]]; then
    git -C "$MSL_REPO_ROOT" check-ignore -q "$relative_key" || {
      printf 'Error: private key path must be Git-ignored: %s\n' "$relative_key" >&2
      return 1
    }
    if [[ -e "$key_path.pub" ]]; then
      printf 'Error: public key exists without its private key; restore the matching pair.\n' >&2
      return 1
    fi
    ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$key_path"
  fi
  if [[ ! -s "$key_path" ]]; then
    printf 'Error: private key missing: %s\n' "$key_path" >&2
    return 1
  fi
  chmod 0600 "$key_path"
  MSL_PUBLIC_KEY=$(ssh-keygen -y -P '' -f "$key_path" | awk '{ print $1 " " $2 }')
  if [[ "$MSL_PUBLIC_KEY" != ssh-ed25519\ * ]]; then
    printf 'Error: an Ed25519 key is required.\n' >&2
    return 1
  fi
}

# msl_fetch_image <url> <sha256> <cache_path>: download-and-verify a guest
# image into the local cache, verifying the checksum before and after reuse.
msl_fetch_image() {
  local url="$1" sha="$2" cache_path="$3"
  if [[ -L "$cache_path" ]]; then
    printf 'Error: symlinked image cache: %s\n' "$cache_path" >&2
    return 1
  fi
  if [[ ! -s "$cache_path" ]]; then
    curl --fail --location --show-error --continue-at - --retry 3 --output "$cache_path.part" "$url"
    printf '%s  %s\n' "$sha" "$cache_path.part" | sha256sum --check -
    mv -- "$cache_path.part" "$cache_path"
  fi
  printf '%s  %s\n' "$sha" "$cache_path" | sha256sum --check -
}

# msl_find_free_port <start> <end>: first TCP port free on both the host and
# the outer VM. Sets MSL_FREE_PORT.
msl_find_free_port() {
  local start="$1" end="$2" candidate remote_listeners
  MSL_FREE_PORT=""
  for candidate in $(seq "$start" "$end"); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then continue; fi
    remote_listeners=$(msl_outer_ssh "ss -H -ltn 'sport = :$candidate'")
    if [[ -z "$remote_listeners" ]]; then
      MSL_FREE_PORT="$candidate"
      break
    fi
  done
  if [[ -z "$MSL_FREE_PORT" ]]; then
    printf 'Error: no free upload port available.\n' >&2
    return 1
  fi
}

# msl_upload_tunnel_open <port>: forward 127.0.0.1:<port> on this host to the
# CDI upload proxy inside the cluster. Sets MSL_UPLOAD_TUNNEL_PID and
# MSL_UPLOAD_REMOTE_PID. Pair with msl_upload_tunnel_close (also safe in traps).
msl_upload_tunnel_open() {
  local port="$1" remote_command quoted attempt
  MSL_UPLOAD_TMP_DIR=$(mktemp -d "$MSL_WORK_DIR/.upload-tunnel.XXXXXX")
  printf -v remote_command 'nohup k3s kubectl port-forward --address 127.0.0.1 -n cdi svc/cdi-uploadproxy %s:443 >/dev/null 2>&1 </dev/null & echo $!' "$port"
  printf -v quoted '%q' "$remote_command"
  MSL_UPLOAD_REMOTE_PID=$(msl_outer_ssh "sudo -n bash -c $quoted" | tr -d '\r')
  if [[ ! "$MSL_UPLOAD_REMOTE_PID" =~ ^[0-9]+$ ]]; then
    printf 'Error: invalid upload-proxy PID.\n' >&2
    return 1
  fi
  ssh "${MSL_OUTER_SSH_OPTS[@]}" -N -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:$port:127.0.0.1:$port" "labadmin@$MSL_OUTER_IP" \
    >"$MSL_UPLOAD_TMP_DIR/upload.log" 2>&1 &
  MSL_UPLOAD_TUNNEL_PID=$!
  for attempt in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then break; fi
    if ! kill -0 "$MSL_UPLOAD_TUNNEL_PID" 2>/dev/null; then
      cat "$MSL_UPLOAD_TMP_DIR/upload.log" >&2
      return 1
    fi
    sleep 1
  done
  kill -0 "$MSL_UPLOAD_TUNNEL_PID" 2>/dev/null || {
    cat "$MSL_UPLOAD_TMP_DIR/upload.log" >&2
    return 1
  }
}

# msl_upload_tunnel_close: stop the local forwarder and the remote port-forward.
msl_upload_tunnel_close() {
  if [[ -n "$MSL_UPLOAD_TUNNEL_PID" ]]; then
    kill "$MSL_UPLOAD_TUNNEL_PID" 2>/dev/null || true
    wait "$MSL_UPLOAD_TUNNEL_PID" 2>/dev/null || true
    MSL_UPLOAD_TUNNEL_PID=""
  fi
  if [[ -n "$MSL_UPLOAD_REMOTE_PID" ]]; then
    msl_outer_ssh "sudo -n kill '$MSL_UPLOAD_REMOTE_PID'" >/dev/null 2>&1 || true
    MSL_UPLOAD_REMOTE_PID=""
  fi
  if [[ -n "$MSL_UPLOAD_TMP_DIR" ]]; then
    rm -rf -- "$MSL_UPLOAD_TMP_DIR"
    MSL_UPLOAD_TMP_DIR=""
  fi
}
