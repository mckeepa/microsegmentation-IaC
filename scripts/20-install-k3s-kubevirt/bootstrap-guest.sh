#!/usr/bin/env bash

set -euo pipefail

K3S_VERSION="v1.36.5+k3s1"
K3S_BINARY_SHA256="d73847bcd3c5fccef0115b372e2f9a91f3032dc84bbf71518a4617565294d313"
K3S_INSTALLER_SHA256="46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"
HELM_VERSION="v3.22.1"
HELM_SHA256="896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea"
OVN_VERSION="v1.4.0"
OVN_COMMIT="d6a3812d1bc1c36bf24c7eda0e86e9b13d84907d"
OVN_IMAGE_TAG="release-1.4"
KUBEVIRT_VERSION="v1.9.1"
KUBEVIRT_OPERATOR_SHA256="9ac45a436c49d32e6fc21d542bcb7600b970705297b9e6752f3ef9b0a1d292da"
KUBEVIRT_CR_SHA256="43106136dbce3312bdbfdeae612aacafc6c12da518d233f90645b4685d84a2af"
VIRTCTL_SHA256="c289393c8186a258653594605f5199b4c171a3131e6e409ed204a96b491b782a"
CDI_VERSION="v1.66.1"
CDI_OPERATOR_SHA256="c7d92bd1b2ee1a3952a5990000437c08d58109f31c0bd48ab6188ec27a13e224"
CDI_CR_SHA256="a497f90de608c1df26f9ee4095289373f17132d74a2042ca03e00c17c964f8a7"
OVN_POD_CIDR="10.244.0.0/16"
OVN_NODE_CIDR="10.244.0.0/16/24"
OVN_SERVICE_CIDR="10.96.0.0/16"
OVN_API_SERVER="https://127.0.0.1:6443"
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
K3S_CONTAINERD_CONFIG="/var/lib/rancher/k3s/agent/etc/containerd/config.toml"
LAB_DNS_CONFIG="/etc/systemd/resolved.conf.d/90-lab-k3s-dns.conf"

usage() {
  printf 'Usage: %s [--dry-run]\n' "${0##*/}"
  printf 'Installs pinned K3s, OVN-Kubernetes, KubeVirt, CDI, and virtctl in lab-k8s-01.\n'
}

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--dry-run" ) ]]; then
  usage >&2
  exit 2
fi
if [[ ${1:-} == "--dry-run" ]]; then
  printf 'Pinned bootstrap plan:\n  K3s %s / Kubernetes 1.36.5\n  OVN-Kubernetes %s (image tag %s)\n  KubeVirt %s\n  CDI %s\n  Helm %s\n' \
    "$K3S_VERSION" "$OVN_VERSION" "$OVN_IMAGE_TAG" "$KUBEVIRT_VERSION" "$CDI_VERSION" "$HELM_VERSION"
  printf 'OVN pod CIDR: %s; service CIDR: %s; API endpoint: %s\n' \
    "$OVN_POD_CIDR" "$OVN_SERVICE_CIDR" "$OVN_API_SERVER"
  printf 'No guest changes made.\n'
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  printf 'Error: run this script inside lab-k8s-01 as root (the host setup script uses sudo).\n' >&2
  exit 1
fi
if [[ -z "${LAB_VM_IP:-}" ]]; then
  printf 'Error: LAB_VM_IP must be set to the current libvirt NAT address of lab-k8s-01.\n' >&2
  exit 1
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]] || ! grep -qE '(vmx|svm)' /proc/cpuinfo; then
  printf 'Error: nested KVM is not accessible inside lab-k8s-01. Fix the VM CPU/device configuration first.\n' >&2
  exit 1
fi

for command_name in apt-get curl git openssl python3 sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
done
python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$LAB_VM_IP" || {
  printf 'Error: LAB_VM_IP is not a valid IP address: %s\n' "$LAB_VM_IP" >&2
  exit 1
}

WORK_DIR=$(mktemp -d /var/tmp/microsegmentation-k3s-bootstrap.XXXXXX)
chmod 0700 "$WORK_DIR"
trap 'rm -rf -- "$WORK_DIR"' EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git jq openvswitch-switch python3 containernetworking-plugins
systemctl disable --now openvswitch-switch.service >/dev/null 2>&1 || true
modprobe openvswitch
sysctl -w net.ipv4.ip_forward=1 >/dev/null
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-k3s-ovn.conf
install -d -m 0755 /opt/cni/bin
install -m 0755 /usr/lib/cni/* /opt/cni/bin/
if [[ ! -x /opt/cni/bin/loopback ]]; then
  printf 'Error: the loopback CNI plugin is missing from /opt/cni/bin.\n' >&2
  exit 1
fi

if [[ -e "$K3S_CONFIG" ]]; then
  for setting in 'flannel-backend: "none"' 'disable-kube-proxy: true' 'disable-network-policy: true' 'cluster-cidr: "10.244.0.0/16"' 'service-cidr: "10.96.0.0/16"' '  - 127.0.0.1' "  - \"$LAB_VM_IP\""; do
    if ! grep -Fqx "$setting" "$K3S_CONFIG"; then
      printf 'Error: existing %s differs from pinned OVN bootstrap setting: %s\n' "$K3S_CONFIG" "$setting" >&2
      exit 1
    fi
  done
else
  install -d -m 0755 /etc/rancher/k3s
  cluster_token=$(openssl rand -hex 32)
  cat > "$K3S_CONFIG" <<EOF
token: "$cluster_token"
write-kubeconfig-mode: "0600"
tls-san:
  - 127.0.0.1
  - "$LAB_VM_IP"
cluster-cidr: "$OVN_POD_CIDR"
service-cidr: "$OVN_SERVICE_CIDR"
cluster-dns: "10.96.0.10"
cluster-domain: "cluster.local"
flannel-backend: "none"
disable-kube-proxy: true
disable-network-policy: true
disable:
  - traefik
  - servicelb
EOF
  chmod 0600 "$K3S_CONFIG"
fi

if command -v k3s >/dev/null 2>&1; then
  installed_version=$(k3s --version | awk 'NR == 1 { print $3 }')
  if [[ "$installed_version" != "$K3S_VERSION" ]]; then
    printf 'Error: found K3s %s; expected %s. Refusing an implicit upgrade.\n' "$installed_version" "$K3S_VERSION" >&2
    exit 1
  fi
else
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s" \
    --output "$WORK_DIR/k3s"
  printf '%s  %s\n' "$K3S_BINARY_SHA256" "$WORK_DIR/k3s" | sha256sum --check
  install -m 0755 "$WORK_DIR/k3s" /usr/local/bin/k3s
  curl --fail --location --silent --show-error --retry 3 \
    "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh" \
    --output "$WORK_DIR/k3s-install.sh"
  printf '%s  %s\n' "$K3S_INSTALLER_SHA256" "$WORK_DIR/k3s-install.sh" | sha256sum --check
  INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC=server sh "$WORK_DIR/k3s-install.sh"
fi

systemctl enable --now k3s
deadline=$((SECONDS + 900))
until k3s kubectl get --raw=/readyz >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    journalctl -u k3s --no-pager -n 100 >&2 || true
    printf 'Error: K3s API did not become ready within 15 minutes.\n' >&2
    exit 1
  fi
  sleep 5
done
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

mapfile -t cni_paths < <(python3 - "$K3S_CONTAINERD_CONFIG" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    config = tomllib.load(config_file)

plugins = config.get("plugins", {})
cni = plugins.get("io.containerd.cri.v1.runtime", {}).get("cni")
if cni is None:
    cni = plugins.get("io.containerd.grpc.v1.cri", {}).get("cni", {})
bin_dirs = cni.get("bin_dirs") or ([cni["bin_dir"]] if cni.get("bin_dir") else ["/opt/cni/bin"])
conf_dir = cni.get("conf_dir", "/etc/cni/net.d")
print(bin_dirs[0])
print(conf_dir)
PY
)
if [[ ${#cni_paths[@]} -ne 2 ]]; then
  printf 'Error: unable to determine K3s containerd CNI paths.\n' >&2
  exit 1
fi
if [[ "${cni_paths[0]}" != "/opt/cni/bin" || "${cni_paths[1]}" != "/etc/cni/net.d" ]]; then
  printf 'Error: K3s containerd CNI paths do not match OVN v1.4.0 host mounts. bin=%s conf=%s\n' "${cni_paths[0]}" "${cni_paths[1]}" >&2
  printf 'A custom K3s containerd template is active; refusing to change it automatically.\n' >&2
  exit 1
fi

ensure_ovn_path() {
  local link_path="$1"
  local target_path="$2"
  local resolved_target
  mkdir -p "$(dirname "$link_path")" "$target_path"
  if [[ "$link_path" == "$target_path" ]]; then
    return
  fi
  if [[ -L "$link_path" ]]; then
    resolved_target=$(readlink -f "$link_path" || true)
    if [[ "$resolved_target" == "$target_path" ]]; then
      return
    fi
    printf 'Error: %s already links to %s, not K3s path %s.\n' "$link_path" "$resolved_target" "$target_path" >&2
    return 1
  fi
  if [[ -e "$link_path" ]]; then
    if [[ ! -d "$link_path" || -n "$(find "$link_path" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      printf 'Error: %s already exists and is not empty; refusing to replace it.\n' "$link_path" >&2
      return 1
    fi
    rmdir "$link_path"
  fi
  ln -s "$target_path" "$link_path"
}

ensure_ovn_path /opt/cni/bin "${cni_paths[0]}"
ensure_ovn_path /etc/cni/net.d "${cni_paths[1]}"
mkdir -p /var/run/netns /var/run/openvswitch /var/log/openvswitch /var/log/ovn /var/lib/openvswitch

helm_version="$(helm version --short 2>/dev/null || true)"
if [[ "$helm_version" != "v3.22.1"* ]]; then
  if [[ -n "$helm_version" ]]; then
    printf 'Error: found Helm %s; expected v3.22.1. Refusing an implicit upgrade.\n' "$helm_version" >&2
    exit 1
  fi
  curl --fail --location --silent --show-error --retry 3 \
    https://get.helm.sh/helm-v3.22.1-linux-amd64.tar.gz \
    --output "$WORK_DIR/helm-v3.22.1-linux-amd64.tar.gz"
  printf '%s  %s\n' "$HELM_SHA256" "$WORK_DIR/helm-v3.22.1-linux-amd64.tar.gz" | sha256sum --check
  tar -xzf "$WORK_DIR/helm-v3.22.1-linux-amd64.tar.gz" -C "$WORK_DIR" linux-amd64/helm
  install -m 0755 "$WORK_DIR/linux-amd64/helm" /usr/local/bin/helm
fi

ovn_source="$WORK_DIR/ovn-kubernetes"
if [[ ! -d "$ovn_source/.git" ]]; then
  git clone --quiet --depth 1 --branch "$OVN_VERSION" https://github.com/ovn-kubernetes/ovn-kubernetes.git "$ovn_source"
fi
actual_ovn_commit=$(git -C "$ovn_source" rev-parse HEAD)
if [[ "$actual_ovn_commit" != "$OVN_COMMIT" ]]; then
  printf 'Error: OVN source commit %s does not match pinned commit %s.\n' "$actual_ovn_commit" "$OVN_COMMIT" >&2
  exit 1
fi
ovn_chart="$ovn_source/helm/ovn-kubernetes"
helm dependency build "$ovn_chart"
helm lint "$ovn_chart" \
  --values "$ovn_chart/values-single-node-zone.yaml" \
  --set "k8sAPIServer=$OVN_API_SERVER" \
  --set "podNetwork=$OVN_NODE_CIDR" \
  --set "serviceNetwork=$OVN_SERVICE_CIDR" \
  --set "global.image.tag=$OVN_IMAGE_TAG"
helm upgrade --install ovn-kubernetes "$ovn_chart" \
  --namespace default \
  --values "$ovn_chart/values-single-node-zone.yaml" \
  --set "k8sAPIServer=$OVN_API_SERVER" \
  --set "podNetwork=$OVN_NODE_CIDR" \
  --set "serviceNetwork=$OVN_SERVICE_CIDR" \
  --set "global.image.repository=ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-ubuntu" \
  --set "global.image.tag=$OVN_IMAGE_TAG" \
  --set "global.enableOvnKubeIdentity=false" \
  --set "tags.ovnkube-identity=false" \
  --wait --timeout 20m

node_name=$(hostnamectl --static)
kubectl wait --for=condition=Ready "node/$node_name" --timeout=15m
kubectl -n ovn-kubernetes wait --for=condition=Ready pod --all --timeout=15m

default_gateway=$(ip -4 route show default | awk 'NR == 1 { print $3 }')
if [[ -z "$default_gateway" ]]; then
  printf 'Error: unable to determine the guest default gateway for DNS configuration.\n' >&2
  exit 1
fi
install -d -m 0755 "$(dirname "$LAB_DNS_CONFIG")"
cat > "$LAB_DNS_CONFIG" <<EOF
[Resolve]
DNS=$default_gateway
Domains=~.
EOF
systemctl restart systemd-resolved
if ! getent ahostsv4 github.com >/dev/null 2>&1; then
  printf 'Error: OVN is ready, but DNS cannot resolve github.com via default gateway %s. Check the libvirt NAT DNS forwarder.\n' "$default_gateway" >&2
  exit 1
fi

download_verified() {
  local url="$1"
  local path="$2"
  local checksum="$3"
  curl --fail --location --silent --show-error --retry 3 "$url" --output "$path"
  printf '%s  %s\n' "$checksum" "$path" | sha256sum --check
}

download_verified "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml" "$WORK_DIR/kubevirt-operator.yaml" "$KUBEVIRT_OPERATOR_SHA256"
download_verified "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml" "$WORK_DIR/kubevirt-cr.yaml" "$KUBEVIRT_CR_SHA256"
download_verified "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64" "$WORK_DIR/virtctl" "$VIRTCTL_SHA256"

kubectl apply -f "$WORK_DIR/kubevirt-operator.yaml"
kubectl wait --for=condition=Established crd/kubevirts.kubevirt.io --timeout=5m
kubectl apply -f "$WORK_DIR/kubevirt-cr.yaml"
kubectl -n kubevirt wait --for=condition=Available kubevirt/kubevirt --timeout=20m
install -m 0755 "$WORK_DIR/virtctl" /usr/local/bin/virtctl

download_verified "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml" "$WORK_DIR/cdi-operator.yaml" "$CDI_OPERATOR_SHA256"
download_verified "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml" "$WORK_DIR/cdi-cr.yaml" "$CDI_CR_SHA256"
kubectl apply -f "$WORK_DIR/cdi-operator.yaml"
kubectl wait --for=condition=Established crd/cdis.cdi.kubevirt.io --timeout=5m
kubectl apply -f "$WORK_DIR/cdi-cr.yaml"
kubectl -n cdi wait --for=condition=Available cdi/cdi --timeout=20m

kubectl get nodes -o wide
kubectl get pods -A
printf '\nK3s %s, OVN-Kubernetes %s, KubeVirt %s, CDI %s, and Helm %s are ready.\n' \
  "$K3S_VERSION" "$OVN_VERSION" "$KUBEVIRT_VERSION" "$CDI_VERSION" "$HELM_VERSION"
