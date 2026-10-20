#!/usr/bin/env bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mode=${1:-status}
case "$mode" in
  read-only|status|token|verify) [[ $# -le 1 ]] || exit 2 ;;
  admin)
    if [[ $# != 2 || "$2" != --confirm-admin ]]; then
      printf 'Admin grants full cluster control, including secrets and VM deletion. Use: %s admin --confirm-admin\n' "${0##*/}" >&2
      exit 2
    fi ;;
  --help)
    printf 'Usage: %s [read-only|admin --confirm-admin|status|token|verify]\n' "${0##*/}"
    exit 0 ;;
  *) printf 'Error: use --help for permission modes.\n' >&2; exit 2 ;;
esac

dashboard_connect
dashboard_owned namespace lab-dashboard
dashboard_owned serviceaccount dashboard-user -n lab-dashboard
dashboard_owned clusterrole lab-dashboard-access
dashboard_owned clusterrolebinding lab-dashboard-access

if [[ "$mode" == token ]]; then
  umask 077
  token_path="$work_dir/headlamp-token"
  command -v git >/dev/null
  git -C "$repo_root" check-ignore -q work/headlamp-token || { printf 'Error: token path must be Git-ignored.\n' >&2; exit 1; }
  if [[ -L "$token_path" || ( -e "$token_path" && ! -f "$token_path" ) ]]; then
    printf 'Error: refusing an unsafe token path.\n' >&2; exit 1
  fi
  temporary_token=$(mktemp "$work_dir/.headlamp-token.XXXXXX")
  trap 'rm -f -- "$temporary_token"' EXIT
  dashboard_kubectl create token dashboard-user -n lab-dashboard --duration=1h > "$temporary_token"
  [[ -s "$temporary_token" ]]
  mv -f -- "$temporary_token" "$token_path"
  printf 'Login token saved with mode 0600 to %s (requested lifetime: 1 hour). Treat it as a password.\n' "$token_path"
  exit 0
fi

if [[ "$mode" == read-only || "$mode" == admin ]]; then
  rules='[
    {"apiGroups":[""],"resources":["namespaces","nodes","pods","pods/log","services","endpoints","events","persistentvolumes","persistentvolumeclaims","configmaps","replicationcontrollers","resourcequotas","limitranges","serviceaccounts"],"verbs":["get","list","watch"]},
    {"apiGroups":["apps","batch","autoscaling","networking.k8s.io","policy","storage.k8s.io","discovery.k8s.io","events.k8s.io","metrics.k8s.io"],"resources":["*"],"verbs":["get","list","watch"]},
    {"apiGroups":["apiextensions.k8s.io"],"resources":["customresourcedefinitions"],"verbs":["get","list","watch"]},
    {"apiGroups":["kubevirt.io","cdi.kubevirt.io"],"resources":["*"],"verbs":["get","list","watch"]},
    {"apiGroups":["authorization.k8s.io"],"resources":["selfsubjectaccessreviews","selfsubjectrulesreviews"],"verbs":["create"]}
  ]'
  if [[ "$mode" == admin ]]; then
    rules='[{"apiGroups":["*"],"resources":["*"],"verbs":["*"]},{"nonResourceURLs":["*"],"verbs":["*"]}]'
  fi
  jq -n --arg mode "$mode" --argjson rules "$rules" '
    {"microsegmentation-lab/managed-by":"microsegmentation-iac"} as $labels |
    {apiVersion:"v1",kind:"List",items:[
      {apiVersion:"v1",kind:"ServiceAccount",metadata:{name:"dashboard-user",namespace:"lab-dashboard",labels:$labels},automountServiceAccountToken:false},
      {apiVersion:"rbac.authorization.k8s.io/v1",kind:"ClusterRole",metadata:{name:"lab-dashboard-access",labels:$labels,annotations:{"microsegmentation-lab/access-mode":$mode}},rules:$rules},
      {apiVersion:"rbac.authorization.k8s.io/v1",kind:"ClusterRoleBinding",metadata:{name:"lab-dashboard-access",labels:$labels},roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"ClusterRole",name:"lab-dashboard-access"},subjects:[{kind:"ServiceAccount",name:"dashboard-user",namespace:"lab-dashboard"}]}
    ]}' | dashboard_kubectl apply -f -
fi

role_json=$(dashboard_kubectl get clusterrole lab-dashboard-access -o json)
access_mode=$(jq -r '.metadata.annotations["microsegmentation-lab/access-mode"] // "unknown"' <<< "$role_json")
printf 'Headlamp dashboard-user access mode: %s\n' "$access_mode"
if [[ "$mode" == status ]]; then
  printf 'Use verify to test effective permissions, including any extra RBAC grants.\n'
  exit 0
fi
if [[ "$access_mode" != read-only && "$access_mode" != admin ]]; then
  printf 'Error: unknown mode; reapply read-only or admin.\n' >&2; exit 1
fi

check_permission() {
  local expected=$1 actual
  shift
  actual=$(dashboard_kubectl auth can-i "$@" --as=system:serviceaccount:lab-dashboard:dashboard-user \
    --as-group=system:serviceaccounts --as-group=system:serviceaccounts:lab-dashboard --as-group=system:authenticated) || {
    if [[ "$actual" != no ]]; then return 1; fi
  }
  if [[ "$actual" != "$expected" ]]; then
    printf 'Error: expected %s for %s, got %s. Inspect other RBAC bindings.\n' "$expected" "$*" "$actual" >&2
    return 1
  fi
}
check_permission yes list pods --all-namespaces
check_permission yes get nodes
check_permission yes list virtualmachines.kubevirt.io --all-namespaces
expected=no
if [[ "$access_mode" == admin ]]; then expected=yes; fi
check_permission "$expected" list secrets --all-namespaces
check_permission "$expected" delete pods --all-namespaces
check_permission "$expected" create pods/exec -n netpol-test
check_permission "$expected" create serviceaccounts/token -n lab-dashboard
check_permission "$expected" create clusterrolebindings.rbac.authorization.k8s.io
check_permission "$expected" patch virtualmachines.kubevirt.io -n netpol-test
printf 'Effective permission checks passed. Refresh Headlamp after changing modes.\n'