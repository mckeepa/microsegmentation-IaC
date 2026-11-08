#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/../45-monitoring-dashboard/common.sh"
config="$script_dir/windows-server.json"
mode=--plan
retry_clean_disk=false
while (( $# > 0 )); do
  case "$1" in
    --config) (( $# >= 2 )) || exit 2; config="$2"; shift 2 ;;
    --plan|--prepare|--apply|--verify|--ssh|--vnc) mode="$1"; shift ;;
    --retry-clean-disk)
      (( $# >= 2 )) || { printf 'Error: --retry-clean-disk requires a PVC name.\n' >&2; exit 2; }
      retry_clean_disk=true
      retry_disk="$2"
      shift 2 ;;
    *) printf 'Usage: %s [--config file.json] [--plan|--prepare|--apply|--verify|--ssh|--vnc] [--retry-clean-disk <pvc-name>]\n' "${0##*/}" >&2; exit 2 ;;
  esac
done
if [[ "$retry_clean_disk" == true ]]; then
  [[ "$retry_disk" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { printf 'Error: invalid clean disk name.\n' >&2; exit 2; }
fi
for program in jq node ssh-keygen xmllint git openssl; do
  command -v "$program" >/dev/null || { printf 'Error: %s is required.\n' "$program" >&2; exit 1; }
done
jq -e '
  .namespace == "netpol-test" and .vmName == "netpol-server-windows" and
  (.hostname | type == "string" and test("^[a-zA-Z][a-zA-Z0-9-]{0,14}$")) and
  .edition == "Standard Evaluation with Desktop Experience" and .imageIndex == 2 and
  (.acceptEvaluationTerms | type == "boolean") and .adminUser == "Administrator" and
  .adminPasswordFile == "work/windows-administrator-password" and .memory == "4Gi" and .cores == 2 and
  .disk.pvcName == "netpol-server-windows-unattended-disk" and .disk.size == "40Gi" and .disk.bus == "sata" and
  .installerPvc == "windows-installer-iso" and
  .virtioImage == "quay.io/kubevirt/virtio-container-disk@sha256:06a32bc8a4d84d2d8d86ef06ba92dad00d78d1b34cec2ee48e17a2fbe438a094" and
  .sshPrivateKey == "work/netpol-server-windows_ed25519" and .sshKnownHosts == "work/netpol-server-windows_known_hosts" and
  (.waitSeconds | type == "number" and floor == . and . >= 600 and . <= 7200)
' "$config" >/dev/null || { printf 'Error: invalid Windows JSON configuration.\n' >&2; exit 2; }
if [[ "$mode" == --plan ]]; then
  jq . "$config"
  printf '\nPlan: install only onto the new 40 GiB SATA Windows PVC; original Windows/Linux disks are preserved.\n'
  printf 'Apply gracefully stops Ubuntu and the Rocky desktop, prepares private Administrator credentials, and starts licensed evaluation setup.\n'
  exit 0
fi
if [[ "$mode" == --apply || "$mode" == --prepare ]]; then
  jq -e '.acceptEvaluationTerms == true' "$config" >/dev/null || { printf 'Error: evaluation terms require explicit acceptance in the config.\n' >&2; exit 1; }
fi
virtctl="$work_dir/virtctl-v1.9.1"
export KUBECONFIG="$work_dir/kubeconfig-lab-k8s-01.yaml"
key="$work_dir/netpol-server-windows_ed25519"
known_hosts="$work_dir/netpol-server-windows_known_hosts"
password_path="$work_dir/windows-administrator-password"
for private_path in work/windows-administrator-password work/windows-unattended/secret.json work/netpol-server-windows_ed25519; do
  git -C "$repo_root" check-ignore -q "$private_path" || { printf 'Error: credentials must be Git-ignored.\n' >&2; exit 1; }
done
umask 077
[[ ! -L "$key" && ! -L "$key.pub" && ! -L "$known_hosts" && ! -L "$password_path" ]] || exit 1
if [[ "$mode" == --prepare || "$mode" == --apply ]]; then
  if [[ ! -e "$key" ]]; then
    [[ ! -e "$key.pub" ]] || { printf 'Error: public key exists without private key.\n' >&2; exit 1; }
    ssh-keygen -q -t ed25519 -N '' -C microsegmentation-iac-windows -f "$key"
  fi
  node "$script_dir/prepare-windows-unattended.mjs" "$config"
  xmllint --noout "$work_dir/windows-unattended/autounattend.xml" 2>"$work_dir/windows-unattended/xml-validation.log" || {
    printf 'Error: answer-file validation failed; inspect the private validation log locally.\n' >&2; exit 1;
  }
  if [[ "$mode" == --prepare ]]; then exit 0; fi
fi
[[ -x "$virtctl" && -s "$KUBECONFIG" && -s "$key" ]] || { printf 'Error: VM client, kubeconfig, or Windows key unavailable.\n' >&2; exit 1; }
dashboard_connect
dashboard_owned namespace netpol-test
vm_json=$(dashboard_kubectl get vm netpol-server-windows -n netpol-test -o json)
jq -e '.metadata.labels["microsegmentation-lab/managed-by"] == "microsegmentation-iac" and .spec.runStrategy == "Manual" and .metadata.deletionTimestamp == null' <<< "$vm_json" >/dev/null || exit 1
windows_ssh() {
  # Pin the project known-hosts file: virtctl's --known-hosts flag is ignored
  # by its local-ssh wrapper.
  "$virtctl" ssh Administrator@vmi/netpol-server-windows -n netpol-test --identity-file="$key" --known-hosts="$known_hosts" \
    --local-ssh-opts='-o BatchMode=yes' --local-ssh-opts='-o IdentitiesOnly=yes' \
    --local-ssh-opts="-o UserKnownHostsFile=$known_hosts" \
    --local-ssh-opts='-o ConnectTimeout=5' --local-ssh-opts='-o StrictHostKeyChecking=accept-new' "$@"
}
encoded_powershell() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0; }
if [[ "$mode" == --ssh ]]; then windows_ssh --local-ssh-opts=-tt; exit; fi
if [[ "$mode" == --vnc ]]; then exec "$virtctl" vnc netpol-server-windows -n netpol-test; fi
provisioning=$(jq -r '.metadata.annotations["microsegmentation-lab/provisioning"] // ""' <<< "$vm_json")
if [[ "$mode" == --apply ]]; then
  existing_vmi=$(dashboard_kubectl get vmi netpol-server-windows -n netpol-test --ignore-not-found -o name)
  [[ -z "$existing_vmi" ]] || { printf 'Error: Windows is already running; stop and inspect it before preparing installation.\n' >&2; exit 1; }
  installer=$(dashboard_kubectl get pvc windows-installer-iso -n netpol-test -o json)
  jq -e '.status.phase == "Bound" and .metadata.annotations["cdi.kubevirt.io/storage.condition.running.reason"] == "Completed"' <<< "$installer" >/dev/null || exit 1
  running=$(dashboard_kubectl get vmi -A -o json)
  jq -e '.items | length == 0' <<< "$running" >/dev/null || { printf 'Error: stop other nested guests before Windows setup.\n' >&2; exit 1; }
  resources=$(dashboard_ssh "awk '/MemAvailable:/ {print \$2}' /proc/meminfo; df -Pk / | awk 'NR == 2 {print \$4}'")
  read -r available_kib <<< "$resources"
  free_kib=$(tail -n 1 <<< "$resources")
  (( available_kib >= 6 * 1048576 && free_kib >= 50 * 1048576 )) || { printf 'Error: at least 6 GiB available RAM and 50 GiB guest disk free required.\n' >&2; exit 1; }
  dashboard_owned secret windows-unattended-seed -n netpol-test
  dashboard_ssh 'sudo -n k3s kubectl apply -f -' < "$work_dir/windows-unattended/secret.json"
  if [[ "$provisioning" != windows-unattended ]]; then
    jq -e 'any(.spec.template.spec.volumes[]; .name == "osdisk" and .persistentVolumeClaim.claimName == "netpol-server-windows-disk") and any(.spec.template.spec.domain.devices.disks[]; .name == "installer" and .bootOrder == 1)' <<< "$vm_json" >/dev/null || {
      printf 'Error: refusing conversion of an unexpected/already-installed Windows disk.\n' >&2; exit 1;
    }
    new_disk=$(dashboard_kubectl get pvc netpol-server-windows-unattended-disk -n netpol-test --ignore-not-found -o json)
    if [[ -n "$new_disk" ]]; then
      printf 'Error: unattended disk already exists without a recognized VM marker; inspect it before retrying. No disk overwritten.\n' >&2; exit 1
    fi
    jq -n '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:"netpol-server-windows-unattended-disk",namespace:"netpol-test",labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac"}},spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",resources:{requests:{storage:"40Gi"}}}}' |
      dashboard_ssh 'sudo -n k3s kubectl create -f -'
  fi
  if [[ "$retry_clean_disk" == true ]]; then
    current_osdisk=$(jq -r '.spec.template.spec.volumes[] | select(.name == "osdisk") | .persistentVolumeClaim.claimName' <<< "$vm_json")
    [[ "$current_osdisk" != "$retry_disk" ]] || { printf 'Error: the clean retry disk is already active.\n' >&2; exit 1; }
    existing_retry=$(dashboard_kubectl get pvc "$retry_disk" -n netpol-test --ignore-not-found -o json)
    if [[ -n "$existing_retry" ]]; then
      printf 'Error: clean retry disk %s already exists; inspect it before using it.\n' "$retry_disk" >&2; exit 1
    fi
    jq -n --arg disk "$retry_disk" '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$disk,namespace:"netpol-test",labels:{"microsegmentation-lab/managed-by":"microsegmentation-iac"}},spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",resources:{requests:{storage:"40Gi"}}}}' |
      dashboard_ssh 'sudo -n k3s kubectl create -f -'
  fi
  vm_json=$(dashboard_kubectl get vm netpol-server-windows -n netpol-test -o json)
  patch=$(jq -cn --argjson vm "$vm_json" --slurpfile cfg "$config" --arg disk "${retry_disk:-netpol-server-windows-unattended-disk}" '$cfg[0] as $cfg |
    [{op:"test",path:"/metadata/uid",value:$vm.metadata.uid},{op:"test",path:"/metadata/resourceVersion",value:$vm.metadata.resourceVersion},
    {op:"add",path:"/metadata/annotations",value:(($vm.metadata.annotations // {}) + {"microsegmentation-lab/provisioning":"windows-unattended"})},
    {op:"replace",path:"/spec/template/spec/domain/devices/disks",value:[{name:"installer",cdrom:{bus:"sata",readonly:true},bootOrder:1},{name:"osdisk",disk:{bus:"sata"},bootOrder:2},{name:"virtio-drivers",cdrom:{bus:"sata",readonly:true}},{name:"answer",cdrom:{bus:"sata",readonly:true}}]},
    {op:"replace",path:"/spec/template/spec/volumes",value:[{name:"installer",persistentVolumeClaim:{claimName:$cfg.installerPvc}},{name:"osdisk",persistentVolumeClaim:{claimName:$disk}},{name:"virtio-drivers",containerDisk:{image:$cfg.virtioImage}},{name:"answer",sysprep:{secret:{name:"windows-unattended-seed"}}}]},
    {op:"replace",path:"/spec/template/spec/domain/devices/interfaces",value:[{name:"default",masquerade:{},ports:[{name:"ssh",port:22,protocol:"TCP"},{name:"allowed-http",port:80,protocol:"TCP"},{name:"denied-http",port:8081,protocol:"TCP"}]}]}]
  ')
  dashboard_kubectl patch vm netpol-server-windows -n netpol-test --type=json -p "$patch"
fi
if [[ "$mode" == --apply ]]; then
  instance=$(dashboard_kubectl get vmi netpol-server-windows -n netpol-test --ignore-not-found -o name)
  if [[ -z "$instance" ]]; then "$virtctl" start netpol-server-windows -n netpol-test; fi
  dashboard_kubectl wait --for=create vmi/netpol-server-windows -n netpol-test --timeout=120s
  dashboard_kubectl wait --for=condition=Ready vmi/netpol-server-windows -n netpol-test --timeout=180s
fi
deadline=$((SECONDS + $(jq -r .waitSeconds "$config")))
printf 'Waiting for unattended Windows setup and key-authenticated Administrator SSH...\n'
until windows_ssh --command=whoami >/dev/null 2>&1; do
  (( SECONDS < deadline )) || { printf 'Error: setup is not verified; inspect VNC and Windows setup logs. Credentials remain in the private file; no disks were deleted.\n' >&2; exit 1; }
  sleep 10
done
verify=$(encoded_powershell '$ErrorActionPreference="Stop"; if(-not(Test-Path C:\ProgramData\microsegmentation-iac\setup-complete)){throw "Guest setup incomplete"}; Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture; Get-Service sshd,QEMU-GA | Format-Table Name,Status; if((Get-Service sshd).Status -ne "Running" -or (Get-Service QEMU-GA).Status -ne "Running"){throw "Required services not running"}; Get-NetIPConfiguration; Write-Output "PASS Windows unattended installation and Administrator key access"')
windows_ssh --command="powershell.exe -NoProfile -EncodedCommand $verify"
vm_json=$(dashboard_kubectl get vm netpol-server-windows -n netpol-test -o json)
if [[ "$mode" == --apply ]] && jq -e 'any(.spec.template.spec.volumes[]; .name == "answer")' <<< "$vm_json" >/dev/null; then
  "$virtctl" stop netpol-server-windows -n netpol-test
  dashboard_kubectl wait --for=delete vmi/netpol-server-windows -n netpol-test --timeout=180s
  vm_json=$(dashboard_kubectl get vm netpol-server-windows -n netpol-test -o json)
  patch=$(jq -cn --argjson vm "$vm_json" '[{op:"test",path:"/metadata/resourceVersion",value:$vm.metadata.resourceVersion},
    {op:"replace",path:"/spec/template/spec/domain/devices/disks",value:[$vm.spec.template.spec.domain.devices.disks[] | select(.name != "answer") | if .name == "osdisk" then .bootOrder=1 elif .name == "installer" then .bootOrder=2 else . end]},
    {op:"replace",path:"/spec/template/spec/volumes",value:[$vm.spec.template.spec.volumes[] | select(.name != "answer")]}]')
  dashboard_kubectl patch vm netpol-server-windows -n netpol-test --type=json -p "$patch"
  dashboard_kubectl delete secret windows-unattended-seed -n netpol-test
  "$virtctl" start netpol-server-windows -n netpol-test
  printf 'Disk-first boot configured and password-bearing answer media detached.\n'
fi
printf 'Username: Administrator (console: .\\Administrator). Password: open work/windows-administrator-password privately; mode 0600.\n'