#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:---plan}
[[ $# -le 1 ]] || exit 2
case "$mode" in
  --help|--plan)
    printf '%s\n' \
      'Usage: bash lab-switchboard/scripts/deploy.sh [--plan|--install-builder|--apply|--verify]' \
      'Run on the physical KVM host with the existing task 10/20 SSH setup.' \
      '--install-builder installs Podman in the managed outer Ubuntu VM.' \
      '--apply builds/imports the image, deploys scoped RBAC and a ClusterIP service, and checks readiness.' \
      'A random portal password is saved privately to lab-switchboard/.local/admin-password; it is never printed.'
    exit 0 ;;
  --install-builder|--apply|--verify) ;;
  *) printf 'Error: unknown mode. Use --help.\n' >&2; exit 2 ;;
esac
source "$project_dir/../scripts/45-monitoring-dashboard/common.sh"
dashboard_connect
if [[ "$mode" == --install-builder ]]; then
  dashboard_ssh 'sudo -n bash -s' <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --no-install-recommends -y podman
podman --version
GUEST
  exit 0
fi
owned() {
  local resource
  resource=$(dashboard_kubectl get "$@" --ignore-not-found -o json)
  if [[ -n "$resource" ]] && ! jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "lab-switchboard"' <<< "$resource" >/dev/null; then
    printf 'Error: refusing an unowned resource: %s\n' "$*" >&2; return 1
  fi
}
if [[ "$mode" == --apply ]]; then
  for namespace in netpol-test rocky-desktop; do
    dashboard_owned namespace "$namespace"
    dashboard_kubectl get namespace "$namespace" -o name >/dev/null
    owned role lab-switchboard -n "$namespace"
    owned rolebinding lab-switchboard -n "$namespace"
  done
  owned namespace lab-switchboard
  for resource in serviceaccount deployment service; do owned "$resource" lab-switchboard -n lab-switchboard; done
  owned secret lab-switchboard-login -n lab-switchboard
  owned configmap lab-switchboard-config -n lab-switchboard
  dashboard_ssh 'command -v podman >/dev/null' || { printf 'Error: run --install-builder first.\n' >&2; exit 1; }
  dashboard_kubectl apply --dry-run=client -f - < "$project_dir/k8s/deployment.yaml"
  dashboard_kubectl apply --dry-run=client -f - < "$project_dir/k8s/rbac.yaml"
  umask 077
  [[ ! -L "$project_dir/.local" ]] || { printf 'Error: symlinked .local directory.\n' >&2; exit 1; }
  mkdir -p "$project_dir/.local"
  chmod 0700 "$project_dir/.local"
  password_file="$project_dir/.local/admin-password"
  [[ ! -L "$password_file" && ( ! -e "$password_file" || -f "$password_file" ) ]] || exit 1
  git -C "$project_dir" check-ignore -q .local/admin-password || { printf 'Error: credential storage must be Git-ignored.\n' >&2; exit 1; }
  if [[ ! -s "$password_file" ]]; then
    openssl rand -base64 32 | tr -d '\n' > "$password_file"
  fi
  chmod 0600 "$password_file"
  [[ $(wc -c < "$password_file") -ge 24 ]] || { printf 'Error: portal password is too short.\n' >&2; exit 1; }
  tar -C "$project_dir" -czf - Containerfile package.json package-lock.json src public config |
    dashboard_ssh 'sudo -n podman build --format docker -t docker.io/library/lab-switchboard:0.1.0 -'
  dashboard_ssh 'sudo -n bash -o pipefail -c "podman save --format docker-archive docker.io/library/lab-switchboard:0.1.0 | k3s ctr images import -"'
  dashboard_kubectl create namespace lab-switchboard --dry-run=client -o json |
    jq '.metadata.labels = {"app.kubernetes.io/part-of":"lab-switchboard","microsegmentation-lab/managed-by":"microsegmentation-iac","pod-security.kubernetes.io/enforce":"restricted"}' |
    dashboard_kubectl apply -f -
  dashboard_kubectl create secret generic lab-switchboard-login -n lab-switchboard --from-file=password=/dev/stdin --dry-run=client -o json < "$password_file" |
    jq '.metadata.labels = {"app.kubernetes.io/part-of":"lab-switchboard"}' | dashboard_kubectl apply -f -
  dashboard_kubectl create configmap lab-switchboard-config -n lab-switchboard --from-file=lab.json=/dev/stdin --dry-run=client -o json < "$project_dir/config/lab.json" |
    jq '.metadata.labels = {"app.kubernetes.io/part-of":"lab-switchboard"}' | dashboard_kubectl apply -f -
  dashboard_kubectl apply -f - < "$project_dir/k8s/rbac.yaml"
  dashboard_kubectl apply -f - < "$project_dir/k8s/deployment.yaml"
  dashboard_kubectl rollout restart deployment/lab-switchboard -n lab-switchboard
fi
dashboard_kubectl rollout status deployment/lab-switchboard -n lab-switchboard --timeout=240s
[[ $(dashboard_kubectl get service lab-switchboard -n lab-switchboard -o jsonpath='{.spec.type}') == ClusterIP ]]
check_permission() {
  local expected=$1 actual
  shift
  actual=$(dashboard_kubectl auth can-i "$@" --as=system:serviceaccount:lab-switchboard:lab-switchboard \
    --as-group=system:serviceaccounts --as-group=system:serviceaccounts:lab-switchboard --as-group=system:authenticated) || [[ "$actual" == no ]]
  [[ "$actual" == "$expected" ]] || { printf 'Error: expected %s permission for %s, got %s.\n' "$expected" "$*" "$actual" >&2; return 1; }
}
check_vm_action() {
  local expected=$1 namespace=$2 action=$3 actual
  actual=$(jq -n --arg namespace "$namespace" --arg action "$action" \
    '{apiVersion:"authorization.k8s.io/v1",kind:"SelfSubjectAccessReview",spec:{resourceAttributes:{namespace:$namespace,verb:"update",group:"subresources.kubevirt.io",resource:"virtualmachines",subresource:$action}}}' |
    dashboard_kubectl create --validate=false -f - -o json --as=system:serviceaccount:lab-switchboard:lab-switchboard \
      --as-group=system:serviceaccounts --as-group=system:serviceaccounts:lab-switchboard --as-group=system:authenticated |
    jq -r '.status.allowed')
  [[ "$actual" == "$expected" ]] || { printf 'Error: unexpected %s authorization in %s: %s.\n' "$action" "$namespace" "$actual" >&2; return 1; }
}
for namespace in netpol-test rocky-desktop; do
  check_permission yes list virtualmachines.kubevirt.io -n "$namespace"
  check_vm_action true "$namespace" start
  check_vm_action true "$namespace" stop
  check_permission no get secrets -n "$namespace"
  check_permission no patch virtualmachines.kubevirt.io -n "$namespace"
done
check_vm_action false kube-system start
check_permission no create pods -n lab-switchboard
printf 'Lab Switchboard deployment and RBAC checks passed. Open access.sh for laptop access.\n'