#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
vm_name="lab-k8s-01"
vm_user="labadmin"
managed_title="microsegmentation-iac-lab-k8s-01"
namespace="netpol-test"
remote_upload_port=18443
virtctl_sha256="c289393c8186a258653594605f5199b4c171a3131e6e409ed204a96b491b782a"
virtio_disk_image="quay.io/kubevirt/virtio-container-disk"
dry_run=false

usage() {
  printf 'Usage: %s [--dry-run]\n' "${0##*/}"
  printf 'Upload installer media, create prompted KubeVirt installer VMs, and guide a NetworkPolicy test matrix.\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command_name in virsh ssh scp sha256sum stat; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required on the physical QEMU/KVM host.\n' "$command_name" >&2
    exit 1
  fi
done
if ! command -v remote-viewer >/dev/null 2>&1; then
  printf 'Error: remote-viewer is required to open KubeVirt installer consoles. Install the virt-viewer package.\n' >&2
  exit 1
fi

host_kubeconfig="$work_dir/kubeconfig-${vm_name}.yaml"
ssh_key="$work_dir/${vm_name}_ed25519"
known_hosts="$work_dir/${vm_name}_known_hosts"
virtctl_path="$work_dir/virtctl-v1.9.1"
ubuntu_iso="$work_dir/ubuntu-24.04.5-live-server-amd64.iso"
rocky_iso="$work_dir/Rocky-10-latest-x86_64-minimal.iso"
windows_iso="$work_dir/windows-server-2025-evaluation.iso"
media_files=("$ubuntu_iso" "$rocky_iso" "$windows_iso")
media_names=("Ubuntu Server 24.04.5" "Rocky Linux 10" "Windows Server 2025 Evaluation")
for index in "${!media_files[@]}"; do
  if [[ ! -s "${media_files[$index]}" ]]; then
    printf 'Error: %s media is missing or incomplete: %s\n' "${media_names[$index]}" "${media_files[$index]}" >&2
    if [[ "$index" == 1 ]]; then
      printf 'Finish scripts/25-prepare-guest-images/download-rocky-10.sh first; use the final work/Rocky-10-latest-x86_64-minimal.iso, not a hidden temporary download.\n' >&2
    fi
    exit 1
  fi
done
if [[ ! -r "$host_kubeconfig" || ! -r "$ssh_key" ]]; then
  printf 'Error: task 20 kubeconfig or generated SSH key is missing. Run task 20 and task 10 first.\n' >&2
  exit 1
fi

vm_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
if [[ "$vm_title" != "$managed_title" ]]; then
  printf 'Error: VM %s is not marked as managed by this project.\n' "$vm_name" >&2
  exit 1
fi
guest_ip=$(virsh -c qemu:///system domifaddr "$vm_name" --source lease | awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }')
if [[ -z "$guest_ip" ]]; then
  printf 'Error: no DHCP lease found for %s.\n' "$vm_name" >&2
  exit 1
fi
ssh_options=(
  -i "$ssh_key"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$known_hosts"
)
destination="$vm_user@$guest_ip"

if [[ "$dry_run" == true ]]; then
  printf '\nDry run: no resources will be created.\n'
  printf 'Namespace: %s\n' "$namespace"
  printf 'Installer media:\n'
  for index in "${!media_files[@]}"; do
    printf '  %s: %s (%s bytes)\n' "${media_names[$index]}" "${media_files[$index]}" "$(stat -c %s "${media_files[$index]}")"
  done
  printf 'Planned guests (created one at a time with confirmation): netpol-client, netpol-server-rocky, netpol-server-windows.\n'
  printf 'OS installation and guest-side probe results remain interactive; Windows VirtIO driver loading is manual.\n'
  exit 0
fi

bash "$repo_root/scripts/20-install-k3s-kubevirt/check-cluster-status.sh"

namespace_exists=$(ssh "${ssh_options[@]}" "$destination" \
  "sudo -n k3s kubectl get namespace '$namespace' -o name 2>/dev/null || true")
if [[ -n "$namespace_exists" ]]; then
  printf 'Error: namespace %s already exists. Inspect its VMs, DataVolumes, and PVCs, then remove or recover them before starting a new run.\n' "$namespace" >&2
  exit 1
fi
for vm in netpol-client netpol-server-rocky netpol-server-windows; do
  existing=$(ssh "${ssh_options[@]}" "$destination" \
    "sudo -n k3s kubectl get vm -n '$namespace' '$vm' -o name 2>/dev/null || true")
  if [[ -n "$existing" ]]; then
    printf 'Error: %s already exists in namespace %s; refusing to overwrite its disk.\n' "$vm" "$namespace" >&2
    exit 1
  fi
done

read -r -p "This imports installer media and creates persistent VM disks in $namespace. Continue? [y/N] " overall_confirmation
if [[ ! "${overall_confirmation,,}" =~ ^(y|yes)$ ]]; then
  printf 'No changes made.\n'
  exit 0
fi

namespace_exists=$(ssh "${ssh_options[@]}" "$destination" \
  "sudo -n k3s kubectl get namespace '$namespace' -o name 2>/dev/null || true")
if [[ -n "$namespace_exists" ]]; then
  printf 'Error: namespace %s already exists. Inspect its VMs/PVCs and clean them up manually before starting a new run.\n' "$namespace" >&2
  exit 1
fi
ssh "${ssh_options[@]}" "$destination" \
  "sudo -n k3s kubectl create namespace '$namespace'"

scp -i "$ssh_key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  -o "UserKnownHostsFile=$known_hosts" \
  "$destination:/usr/local/bin/virtctl" "$virtctl_path"
chmod 0700 "$virtctl_path"
actual_virtctl_sha256=$(sha256sum "$virtctl_path" | awk '{print $1}')
if [[ "$actual_virtctl_sha256" != "$virtctl_sha256" ]]; then
  printf 'Error: copied virtctl checksum mismatch; expected %s, found %s.\n' "$virtctl_sha256" "$actual_virtctl_sha256" >&2
  exit 1
fi

local_upload_port=""
for candidate in $(seq 18443 18453); do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then
    local_upload_port="$candidate"
    break
  fi
done
if [[ -z "$local_upload_port" ]]; then
  printf 'Error: no free local port available for the CDI upload tunnel.\n' >&2
  exit 1
fi

remote_pf_pid=""
tunnel_pid=""
cleanup_tunnel() {
  if [[ -n "${namespace:-}" ]]; then
    ssh "${ssh_options[@]}" "$destination" \
      "sudo -n k3s kubectl delete networkpolicy --all -n '$namespace' --ignore-not-found=true" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$tunnel_pid" ]]; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
  fi
  if [[ -n "$remote_pf_pid" ]]; then
    ssh "${ssh_options[@]}" "$destination" \
      "sudo -n kill '$remote_pf_pid'" >/dev/null 2>&1 || true
  fi
}
trap cleanup_tunnel EXIT
trap 'exit 130' INT TERM

remote_pf_pid=$(ssh "${ssh_options[@]}" "$destination" \
  "sudo -n bash -c 'nohup k3s kubectl port-forward --address 127.0.0.1 -n cdi svc/cdi-uploadproxy $remote_upload_port:443 >/tmp/netpol-cdi-uploadproxy.log 2>&1 </dev/null & echo \\$!'" | tr -d '\r')
if [[ ! "$remote_pf_pid" =~ ^[0-9]+$ ]]; then
  printf 'Error: could not start the CDI upload-proxy port-forward in the VM.\n' >&2
  exit 1
fi
ssh "${ssh_options[@]}" -N \
  -L "127.0.0.1:${local_upload_port}:127.0.0.1:${remote_upload_port}" \
  "$destination" >"$work_dir/.netpol-upload-tunnel.log" 2>&1 &
tunnel_pid=$!
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$local_upload_port") 2>/dev/null; then
    break
  fi
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    printf 'Error: SSH tunnel to CDI upload-proxy did not start. See %s/.netpol-upload-tunnel.log.\n' "$work_dir" >&2
    exit 1
  fi
  sleep 1
done
if ! (exec 3<>"/dev/tcp/127.0.0.1/$local_upload_port") 2>/dev/null; then
  printf 'Error: CDI upload-proxy is not reachable through the SSH tunnel.\n' >&2
  exit 1
fi

remote_kubectl() {
  local remote_command='sudo -n k3s kubectl'
  local argument quoted
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    remote_command+=" $quoted"
  done
  ssh "${ssh_options[@]}" "$destination" "$remote_command"
}

apply_remote_manifest() {
  local manifest_path="$1"
  ssh "${ssh_options[@]}" "$destination" 'sudo -n k3s kubectl apply -f -' < "$manifest_path"
}

upload_iso() {
  local label="$1"
  local pvc_name="$2"
  local image_path="$3"
  local bytes size_gib

  if ! confirm "Upload $label to a CDI PVC named $pvc_name?"; then
    return 1
  fi
  bytes=$(stat -c %s "$image_path")
  size_gib=$(( (bytes + 1073741823) / 1073741824 ))
  KUBECONFIG="$host_kubeconfig" "$virtctl_path" image-upload pvc "$pvc_name" \
    --namespace="$namespace" \
    --size="${size_gib}Gi" \
    --storage-class=local-path \
    --access-mode=ReadWriteOnce \
    --volume-mode=Filesystem \
    --force-bind \
    --uploadproxy-url="https://127.0.0.1:${local_upload_port}" \
    --insecure \
    --image-path="$image_path"
}

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

create_disk() {
  local vm_name="$1"
  local storage="$2"
  local manifest
  manifest=$(mktemp "$work_dir/.${vm_name}-disk.XXXXXX.yaml")
  cat > "$manifest" <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${vm_name}-disk
  namespace: ${namespace}
spec:
  source:
    blank: {}
  storage:
    storageClassName: local-path
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: ${storage}
EOF
  apply_remote_manifest "$manifest"
  rm -f -- "$manifest"
}

make_vm_manifest() {
  local vm_name="$1"
  local role="$2"
  local memory="$3"
  local cores="$4"
  local installer_pvc="$5"
  local install_phase="$6"
  local windows="$7"
  local manifest
  manifest=$(mktemp "$work_dir/.${vm_name}-vm.XXXXXX.yaml")
  cat > "$manifest" <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${vm_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ${vm_name}
    microsegmentation-lab/role: ${role}
spec:
  runStrategy: Manual
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${vm_name}
        microsegmentation-lab/role: ${role}
        microsegmentation-lab/os: ${vm_name#netpol-}
    spec:
      domain:
        cpu:
          cores: ${cores}
        resources:
          requests:
            memory: ${memory}
        devices:
          disks:
EOF
  if [[ "$install_phase" == true ]]; then
    cat >> "$manifest" <<EOF
            - name: installer
              cdrom:
                bus: sata
                readonly: true
              bootOrder: 1
            - name: osdisk
              disk:
                bus: virtio
              bootOrder: 2
EOF
  else
    cat >> "$manifest" <<EOF
            - name: osdisk
              disk:
                bus: virtio
              bootOrder: 1
EOF
  fi
  if [[ "$windows" == true ]]; then
    cat >> "$manifest" <<EOF
            - name: virtio-drivers
              cdrom:
                bus: sata
                readonly: true
EOF
  fi
  cat >> "$manifest" <<EOF
          interfaces:
            - name: default
              masquerade: {}
EOF
  if [[ "$role" == server && "$windows" == true ]]; then
    cat >> "$manifest" <<EOF
              ports:
                - name: allowed-http
                  port: 80
                  protocol: TCP
                - name: denied-http
                  port: 8081
                  protocol: TCP
EOF
  elif [[ "$role" == server ]]; then
    cat >> "$manifest" <<EOF
              ports:
                - name: allowed-http
                  port: 8080
                  protocol: TCP
                - name: denied-http
                  port: 8081
                  protocol: TCP
EOF
  fi
  cat >> "$manifest" <<EOF
      networks:
        - name: default
          pod: {}
      volumes:
EOF
  if [[ "$install_phase" == true ]]; then
    cat >> "$manifest" <<EOF
        - name: installer
          persistentVolumeClaim:
            claimName: ${installer_pvc}
EOF
  fi
  cat >> "$manifest" <<EOF
        - name: osdisk
          dataVolume:
            name: ${vm_name}-disk
EOF
  if [[ "$windows" == true ]]; then
    cat >> "$manifest" <<EOF
        - name: virtio-drivers
          containerDisk:
            image: ${virtio_disk_image}
EOF
  fi
  printf '%s\n' "$manifest"
}

wait_vmi_running() {
  local vm_name="$1"
  local deadline=$((SECONDS + 600))
  local phase
  while (( SECONDS < deadline )); do
    phase=$(remote_kubectl get vmi "$vm_name" -n "$namespace" -o 'jsonpath={.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == Running ]]; then
      return 0
    fi
    sleep 3
  done
  printf 'Error: VMI %s did not reach Running within 10 minutes.\n' "$vm_name" >&2
  remote_kubectl get vmi "$vm_name" -n "$namespace" -o wide || true
  return 1
}

stop_vm() {
  local vm_name="$1"
  local exists
  exists=$(remote_kubectl get vmi "$vm_name" -n "$namespace" -o name 2>/dev/null || true)
  if [[ -n "$exists" ]]; then
    KUBECONFIG="$host_kubeconfig" "$virtctl_path" stop "$vm_name" --namespace="$namespace" || true
    local deadline=$((SECONDS + 180))
    while (( SECONDS < deadline )); do
      exists=$(remote_kubectl get vmi "$vm_name" -n "$namespace" -o name 2>/dev/null || true)
      [[ -z "$exists" ]] && return 0
      sleep 3
    done
    printf 'Error: VMI %s did not stop within 3 minutes.\n' "$vm_name" >&2
    return 1
  fi
}

start_vm() {
  local vm_name="$1"
  local phase
  phase=$(remote_kubectl get vmi "$vm_name" -n "$namespace" -o 'jsonpath={.status.phase}' 2>/dev/null || true)
  if [[ "$phase" != Running ]]; then
    KUBECONFIG="$host_kubeconfig" "$virtctl_path" start "$vm_name" --namespace="$namespace"
  fi
  wait_vmi_running "$vm_name"
}

install_guest() {
  local vm_name="$1"
  local role="$2"
  local os_label="$3"
  local memory="$4"
  local cores="$5"
  local disk_size="$6"
  local iso_label="$7"
  local iso_path="$8"
  local iso_pvc="$9"
  local windows="${10}"
  local install_manifest final_manifest guest_version driver_version="not applicable"

  if ! confirm "Prepare and start the ${os_label} installer VM ${vm_name}?"; then
    printf 'Skipped %s.\n' "$vm_name"
    return 2
  fi
  upload_iso "$iso_label" "$iso_pvc" "$iso_path" || return 2
  create_disk "$vm_name" "$disk_size"
  install_manifest=$(make_vm_manifest "$vm_name" "$role" "$memory" "$cores" "$iso_pvc" true "$windows")
  apply_remote_manifest "$install_manifest"
  rm -f -- "$install_manifest"
  start_vm "$vm_name"

  printf '\nOpening VNC for %s. Complete the OS installation in the viewer.\n' "$vm_name"
  if [[ "$windows" == true ]]; then
    printf 'Windows: load the viostor driver from the attached VirtIO CD-ROM to see the boot disk; install NetKVM before testing.\n'
  fi
  while true; do
    KUBECONFIG="$host_kubeconfig" "$virtctl_path" vnc "$vm_name" --namespace="$namespace" || true
    if confirm "Is ${os_label} installed, and have you shut the guest down?"; then
      break
    fi
    printf 'Reopening the installer console.\n'
  done

  read -r -p "Enter the installed ${os_label} release/version for the report: " guest_version
  if [[ -z "$guest_version" ]]; then
    guest_version="not recorded"
  fi
  if [[ "$windows" == true ]]; then
    read -r -p 'Enter the installed VirtIO storage/network driver versions (or not installed): ' driver_version
    [[ -n "$driver_version" ]] || driver_version="not recorded"
  fi
  printf -- '- Guest %s: %s (%s)\n' "$vm_name" "$guest_version" "$driver_version" >> "$report_path"

  stop_vm "$vm_name"
  final_manifest=$(make_vm_manifest "$vm_name" "$role" "$memory" "$cores" "$iso_pvc" false "$windows")
  apply_remote_manifest "$final_manifest"
  rm -f -- "$final_manifest"
  remote_kubectl delete pvc "$iso_pvc" -n "$namespace" --wait=true
  start_vm "$vm_name"
  printf 'Installed VM %s is running from its persistent disk.\n' "$vm_name"
}

record_result() {
  local description="$1"
  local expected="$2"
  local answer
  read -r -p "$description Expected: $expected. Did it match? [y/N] " answer
  if [[ "${answer,,}" == y || "${answer,,}" == yes ]]; then
    printf -- '- PASS: %s\n' "$description" >> "$report_path"
    printf 'PASS\n'
  else
    printf -- '- FAIL/UNCONFIRMED: %s\n' "$description" >> "$report_path"
    overall_status=1
    printf 'FAIL/UNCONFIRMED\n'
  fi
}

open_vnc() {
  local vm_name="$1"
  printf 'Opening %s console. Close the viewer when finished.\n' "$vm_name"
  KUBECONFIG="$host_kubeconfig" "$virtctl_path" vnc "$vm_name" --namespace="$namespace" || true
}

get_launcher_ip() {
  local vm_name="$1"
  remote_kubectl get pods -n "$namespace" -l "kubevirt.io/domain=$vm_name" \
    -o 'jsonpath={.items[0].status.podIP}'
}

prepare_linux_service() {
  local server_vm="$1"
  local service_port="$2"
  local deny_port="$3"
  printf '\nIn the %s guest, install Python 3 and run both listeners:\n' "$server_vm"
  printf '  sudo dnf install -y python3\n'
  printf '  nohup python3 -m http.server %s --bind 0.0.0.0 >/tmp/netpol-allow.log 2>&1 &\n' "$service_port"
  printf '  nohup python3 -m http.server %s --bind 0.0.0.0 >/tmp/netpol-deny.log 2>&1 &\n' "$deny_port"
  open_vnc "$server_vm"
  confirm 'Have both HTTP listeners started in the server guest?' || return 1
}

prepare_windows_service() {
  local server_vm="$1"
  printf '\nIn elevated PowerShell on %s, install IIS and expose a second test site:\n' "$server_vm"
  printf '  Install-WindowsFeature Web-Server -IncludeManagementTools\n'
  printf '  New-WebBinding -Name "Default Web Site" -Protocol http -Port 8081 -IPAddress "*"\n'
  printf '  New-NetFirewallRule -DisplayName "NetpolLabHTTP" -Direction Inbound -Protocol TCP -LocalPort 80,8081 -Action Allow\n'
  open_vnc "$server_vm"
  confirm 'Does IIS respond on ports 80 and 8081 inside the Windows guest?' || return 1
}

prepare_client_curl() {
  printf '\nIn the Ubuntu client guest, ensure curl is installed: sudo apt-get update && sudo apt-get install -y curl\n'
  open_vnc netpol-client
  confirm 'Is curl available in the Ubuntu client guest?' || return 1
}

apply_network_policies() {
  local server_port="$1"
  remote_apply_manifest_from_stdin <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress-egress
  namespace: ${namespace}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-dns
  namespace: ${namespace}
spec:
  podSelector:
    matchLabels:
      microsegmentation-lab/role: client
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kubevirt-control
  namespace: ${namespace}
spec:
  podSelector:
    matchExpressions:
      - key: microsegmentation-lab/role
        operator: In
        values:
          - client
          - server
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kubevirt
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-server-egress
  namespace: ${namespace}
spec:
  podSelector:
    matchLabels:
      microsegmentation-lab/role: client
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              microsegmentation-lab/role: server
      ports:
        - protocol: TCP
          port: ${server_port}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-server-ingress
  namespace: ${namespace}
spec:
  podSelector:
    matchLabels:
      microsegmentation-lab/role: server
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              microsegmentation-lab/role: client
      ports:
        - protocol: TCP
          port: ${server_port}
EOF
}

remote_apply_manifest_from_stdin() {
  ssh "${ssh_options[@]}" "$destination" 'sudo -n k3s kubectl apply -f -'
}

remove_server_allow_policies() {
  remote_kubectl delete networkpolicy allow-client-server-egress allow-client-server-ingress \
    -n "$namespace" --ignore-not-found=true
}

restart_vm() {
  local vm_name="$1"
  stop_vm "$vm_name"
  start_vm "$vm_name"
}

run_matrix() {
  local server_vm="$1"
  local server_kind="$2"
  local service_port="$3"
  local deny_port=8081
  local server_ip

  if [[ "$server_vm" == "netpol-server-rocky" ]]; then
    stop_vm netpol-server-windows
  else
    stop_vm netpol-server-rocky
  fi
  start_vm "$server_vm"
  start_vm netpol-client
  server_ip=$(get_launcher_ip "$server_vm")
  if [[ -z "$server_ip" ]]; then
    printf 'Error: could not find launcher pod IP for %s.\n' "$server_vm" >&2
    return 1
  fi

  if [[ "$server_kind" == windows ]]; then
    prepare_windows_service "$server_vm"
  else
    prepare_linux_service "$server_vm" "$service_port" "$deny_port"
  fi
  prepare_client_curl

  printf '\nBaseline, before NetworkPolicy:\n  curl --connect-timeout 5 http://%s:%s/\n  curl --connect-timeout 5 http://%s:%s/\n' "$server_ip" "$service_port" "$server_ip" "$deny_port"
  open_vnc netpol-client
  record_result "${server_vm} baseline TCP/${service_port} before policy" 'request succeeds'
  record_result "${server_vm} baseline TCP/${deny_port} before policy" 'request succeeds'

  if [[ "$server_kind" == windows ]]; then
    printf '\nWindows server: applying allow policy for port 80 and denying port 8081.\n'
  fi
  apply_network_policies "$service_port"
  printf '\nWith default-deny and explicit allow policies:\n  curl --connect-timeout 5 http://%s:%s/\n  curl --connect-timeout 5 http://%s:%s/\n' "$server_ip" "$service_port" "$server_ip" "$deny_port"
  open_vnc netpol-client
  record_result "${server_vm} allowed client-to-server TCP/${service_port}" 'request succeeds'
  record_result "${server_vm} unallowed client-to-server TCP/${deny_port}" 'request fails or times out'

  remove_server_allow_policies
  printf '\nAfter removing the explicit client/server allow policies, test again:\n  curl --connect-timeout 5 http://%s:%s/\n' "$server_ip" "$service_port"
  open_vnc netpol-client
  record_result "${server_vm} formerly allowed connection after allow removal" 'request fails or times out'

  apply_network_policies "$service_port"
  restart_vm "$server_vm"
  restart_vm netpol-client
  server_ip=$(get_launcher_ip "$server_vm")
  if [[ "$server_kind" == windows ]]; then
    printf 'Confirm IIS is still listening after restart.\n'
    open_vnc "$server_vm"
    confirm 'Is IIS still listening on ports 80 and 8081?' || return 1
  else
    prepare_linux_service "$server_vm" "$service_port" "$deny_port"
  fi
  printf '\nAfter VM restart and policy re-application:\n  curl --connect-timeout 5 http://%s:%s/\n' "$server_ip" "$service_port"
  open_vnc netpol-client
  record_result "${server_vm} allowed connection after VMI restart" 'request succeeds'
  remove_server_allow_policies
  remote_kubectl delete networkpolicy default-deny-ingress-egress allow-client-dns \
    -n "$namespace" --ignore-not-found=true
}

if [[ "$dry_run" == true ]]; then
  printf 'Dry run only; no VM, PVC, namespace, or policy changes made.\n'
  exit 0
fi

if [[ ! -t 0 ]]; then
  printf 'Error: the full installer/test workflow requires an interactive terminal.\n' >&2
  exit 1
fi

printf 'Installer media and test VMs remain disposable. OS installation is manual in each VNC window; Windows VirtIO driver selection is manual.\n'
printf 'A report will be written under work/. Test outcomes are recorded from your confirmation, not inferred from NetworkPolicy objects.\n'

report_path="$work_dir/isolation-test-$(date +%Y%m%d-%H%M%S).md"
overall_status=0
{
  printf '# Kubernetes isolation test run\n\n'
  printf -- '- Date: %s\n' "$(date --iso-8601=seconds)"
  printf -- '- Git revision: %s\n' "$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || printf unknown)"
  printf -- '- K3s: v1.36.5+k3s1\n- OVN-Kubernetes: v1.4.0\n- KubeVirt: v1.9.1\n- CDI: v1.66.1\n'
  printf -- '- Namespace: %s\n- Binding: masquerade over OVN default pod network\n\n' "$namespace"
  printf '## Media SHA-256\n'
  for media_file in "${media_files[@]}"; do
    printf -- '- %s: `%s`\n' "$(basename "$media_file")" "$(sha256sum "$media_file" | awk '{print $1}')"
  done
  printf '\n## Guest versions and test results\n'
} > "$report_path"

remote_kubectl create namespace "$namespace"

install_guest netpol-client client ubuntu 2Gi 2 10Gi \
  'Ubuntu Server 24.04.5' "$ubuntu_iso" ubuntu-installer-iso false || {
    printf 'The Ubuntu client installer was skipped or failed; stopping before policy tests.\n' >&2
    exit 1
  }
install_guest netpol-server-rocky server rocky 2Gi 2 10Gi \
  'Rocky Linux 10' "$rocky_iso" rocky-installer-iso false || {
    printf 'The Rocky server installer was skipped or failed; skipping Linux tests.\n' >&2
    exit 1
  }
stop_vm netpol-server-rocky
install_guest netpol-server-windows server windows 4Gi 2 40Gi \
  'Windows Server 2025 Evaluation' "$windows_iso" windows-installer-iso true || {
    printf 'The Windows installer was skipped or failed. Linux test resources remain in the cluster.\n' >&2
    exit 1
  }
stop_vm netpol-server-windows

run_matrix netpol-server-rocky linux 8080
stop_vm netpol-server-rocky
run_matrix netpol-server-windows windows 80
stop_vm netpol-server-windows

if (( overall_status == 0 )); then
  printf '\nAll user-confirmed test cases passed. Report: %s\n' "$report_path"
else
  printf '\nOne or more test cases failed or were unconfirmed. Report: %s\n' "$report_path" >&2
fi
exit "$overall_status"
