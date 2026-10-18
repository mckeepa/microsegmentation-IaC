#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
work_dir="$repo_root/work"
vm_name="lab-k8s-01"
vm_user="labadmin"
managed_title="microsegmentation-iac-lab-k8s-01"
ssh_key="$work_dir/${vm_name}_ed25519"
known_hosts="$work_dir/${vm_name}_known_hosts"

for command_name in virsh ssh; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required on the QEMU/KVM host.\n' "$command_name" >&2
    exit 1
  fi
done

if ! virsh -c qemu:///system dominfo "$vm_name" >/dev/null 2>&1; then
  printf 'Error: VM %s does not exist. Run the task 10 provisioner first.\n' "$vm_name" >&2
  exit 1
fi
existing_title=$(virsh -c qemu:///system desc "$vm_name" --title 2>/dev/null || true)
if [[ "$existing_title" != "$managed_title" ]]; then
  printf 'Error: VM %s is not marked as managed by this project; refusing to connect.\n' "$vm_name" >&2
  exit 1
fi
vm_state=$(virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')
if [[ "$vm_state" != "running" ]]; then
  printf 'Error: VM %s is %s. Start it with scripts/10-create-lab-vm/login-lab-vm.sh.\n' "$vm_name" "$vm_state" >&2
  exit 1
fi
if [[ ! -r "$ssh_key" ]]; then
  printf 'Error: SSH private key is missing: %s\n' "$ssh_key" >&2
  exit 1
fi

guest_ip=$(virsh -c qemu:///system domifaddr "$vm_name" --source lease | awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }')
if [[ -z "$guest_ip" ]]; then
  printf 'Error: no DHCP lease found for %s. Wait for the guest to boot, then retry.\n' "$vm_name" >&2
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

printf 'Cluster status from %s (%s):\n' "$vm_name" "$guest_ip"
ssh "${ssh_options[@]}" "$vm_user@$guest_ip" \
  "sudo -n env CHECK_VM_IP='$guest_ip' bash -s" <<'REMOTE'
set -uo pipefail

expected_k3s_version="v1.36.5+k3s1"
expected_ovn_version="1.4.0"
expected_ovn_image_tag="release-1.4"
expected_kubevirt_version="v1.9.1"
expected_cdi_version="v1.66.1"
expected_pod_cidr="10.244.0.0/16/24"
expected_service_cidr="10.96.0.0/16"
status=0

pass() { printf 'PASS %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  status=1
}

check_k3s_version() {
  sudo -n k3s --version | grep -Fq "$expected_k3s_version"
}

check_k3s_config() {
  local setting
  for setting in \
    'flannel-backend: "none"' \
    'disable-kube-proxy: true' \
    'disable-network-policy: true' \
    'cluster-cidr: "10.244.0.0/16"' \
    'service-cidr: "10.96.0.0/16"' \
    '  - 127.0.0.1' \
    "  - \"$CHECK_VM_IP\""; do
    grep -Fqx "$setting" /etc/rancher/k3s/config.yaml || return 1
  done
}

check_ovn_cni() {
  sudo -n test -x /opt/cni/bin/loopback &&
    sudo -n test -x /opt/cni/bin/ovn-k8s-cni-overlay &&
    sudo -n test -f /etc/cni/net.d/10-ovn-kubernetes.conf
}

check_ovn_config() {
  sudo -n k3s kubectl get configmap ovn-config -n ovn-kubernetes -o json |
    jq -e --arg pod "$expected_pod_cidr" --arg service "$expected_service_cidr" \
      '.data.net_cidr == $pod and .data.svc_cidr == $service and .data.k8s_apiserver == "https://127.0.0.1:6443"' >/dev/null
}

check_ovn_release() {
  sudo -n env KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm list -n default -o json |
    jq -e --arg chart "ovn-kubernetes-$expected_ovn_version" \
      'any(.[]; .name == "ovn-kubernetes" and .status == "deployed" and .chart == $chart)' >/dev/null
}

check_ovn_values() {
  sudo -n env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
    helm get values ovn-kubernetes -n default --all -o json |
    jq -e --arg tag "$expected_ovn_image_tag" \
      '.global.enableOvnKubeIdentity == false and .tags["ovnkube-identity"] == false and .global.image.tag == $tag' >/dev/null
}

check_ready_node() {
  sudo -n k3s kubectl get nodes -o json |
    jq -e '(.items | length) == 1 and all(.items[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))' >/dev/null
}

check_ready_pods() {
  sudo -n k3s kubectl get pods -A -o json |
    jq -e '[.items[] | select(.status.phase != "Succeeded")] as $pods |
      ($pods | length) > 0 and
      all($pods[]; .status.phase == "Running" and
        ((.status.containerStatuses // []) | length) > 0 and
        all(.status.containerStatuses[]; .ready == true))' >/dev/null
}

check_kubevirt() {
  local phase image
  phase=$(sudo -n k3s kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}') || return 1
  image=$(sudo -n k3s kubectl get deployment virt-operator -n kubevirt -o jsonpath='{.spec.template.spec.containers[0].image}') || return 1
  [[ "$phase" == "Deployed" && "$image" == "quay.io/kubevirt/virt-operator:$expected_kubevirt_version" ]]
}

check_cdi() {
  local phase image
  phase=$(sudo -n k3s kubectl get cdi cdi -n cdi -o jsonpath='{.status.phase}') || return 1
  image=$(sudo -n k3s kubectl get deployment cdi-operator -n cdi -o jsonpath='{.spec.template.spec.containers[0].image}') || return 1
  [[ "$phase" == "Deployed" && "$image" == "quay.io/kubevirt/cdi-operator:$expected_cdi_version" ]]
}

printf '\n--- Cluster resources ---\n'
sudo -n k3s kubectl get nodes -o wide || status=1
sudo -n k3s kubectl get pods -A || status=1

printf '\n--- Configuration and health checks ---\n'
check_k3s_version && pass "K3s version $expected_k3s_version" || fail "K3s version $expected_k3s_version"
check_k3s_config && pass 'K3s custom-CNI settings and API TLS SAN' || fail 'K3s custom-CNI settings or API TLS SAN'
check_ovn_cni && pass 'OVN overlay and standard loopback CNI plugins/config' || fail 'OVN CNI files or standard loopback plugin'
check_ovn_config && pass "OVN pod/service CIDRs and API endpoint" || fail 'OVN ConfigMap CIDRs or API endpoint'
check_ovn_release && pass "OVN Helm release $expected_ovn_version" || fail "OVN Helm release $expected_ovn_version"
check_ovn_values && pass 'OVN identity disabled and image tag pinned' || fail 'OVN Helm values do not match bootstrap settings'
check_ready_node && pass 'Single Kubernetes node is Ready' || fail 'Single Kubernetes node is not Ready'
check_ready_pods && pass 'All pods are Running and ready' || fail 'One or more pods are not Running and ready'
check_kubevirt && pass "KubeVirt $expected_kubevirt_version is Deployed" || fail "KubeVirt $expected_kubevirt_version is not Deployed or version mismatches"
check_cdi && pass "CDI $expected_cdi_version is Deployed" || fail "CDI $expected_cdi_version is not Deployed or version mismatches"

if (( status == 0 )); then
  printf '\nCluster health and pinned configuration checks passed.\n'
else
  printf '\nCluster health/configuration checks failed. Inspect the resources above and run the task 20 troubleshooting commands.\n' >&2
fi
exit "$status"
REMOTE
