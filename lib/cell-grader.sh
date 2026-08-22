#!/usr/bin/env bash
# Read-only grading helpers for disposable cells.  Source lib/grader.sh first.

if ! declare -F grade_invalid >/dev/null 2>&1; then
  printf '%s\n' "lib/cell-grader.sh requires lib/grader.sh" >&2
  return 1 2>/dev/null || exit 1
fi
source "$CKA_ROOT/lib/cell.sh"

_CELL_GRADER_ERROR=""
_CELL_GRADER_KUBECONFIG=""
_CELL_GRADER_QID=""
_CELL_GRADER_TMP=""
_CELL_GRADER_API_ABSENT=0

_cell_grader_cleanup_tmp() {
  case "${_CELL_GRADER_TMP:-}" in
    /tmp/cka-cell-grader.*)
      [ -L "$_CELL_GRADER_TMP" ] || rm -f -- "$_CELL_GRADER_TMP"
      ;;
  esac
}

_cell_grader_sync_bootstrap_kubeconfig() {
  local qid="$1" original external tmp
  original="$(cell_kubeconfig_path "$qid")" || return 1
  cell_exec "$qid" cp1 test -s /etc/kubernetes/admin.conf >/dev/null 2>&1 || return 1
  external="$(kubectl --kubeconfig "$original" config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)" || return 1
  [[ "$external" =~ ^https://127\.0\.0\.1:[0-9]+$ ]] || return 1
  tmp="$(mktemp "/tmp/cka-cell-grader.${qid}.XXXXXX")" || return 1
  _CELL_GRADER_TMP="$tmp"
  trap _cell_grader_cleanup_tmp EXIT
  chmod 0600 "$tmp" || return 1
  cell_exec "$qid" cp1 cat /etc/kubernetes/admin.conf > "$tmp" || return 1
  kubectl --kubeconfig "$tmp" config set-cluster kubernetes \
    --server="$external" >/dev/null || return 1
  _CELL_GRADER_KUBECONFIG="$tmp"
}

cell_grader_bind() { # must run immediately before grade_init
  local qid="$1"
  _CELL_GRADER_QID="$qid"
  _CELL_GRADER_ERROR=""
  _CELL_GRADER_API_ABSENT=0
  _CELL_GRADER_KUBECONFIG="$(cell_kubeconfig_path "$qid" 2>/dev/null || true)"
  if ! cell_runtime_readonly_ok; then
    _CELL_GRADER_ERROR="cell runtime missing, unsafe, or non-native"
  elif ! cell_manifest_load "$qid"; then
    _CELL_GRADER_ERROR="cell manifest missing or invalid: $qid"
  elif [ ! -r "$_CELL_GRADER_KUBECONFIG" ] || [ -L "$_CELL_GRADER_KUBECONFIG" ]; then
    _CELL_GRADER_ERROR="cell kubeconfig missing or unsafe: $qid"
  elif [ "$CELL_PROFILE" = kubeadm-bootstrap ] \
      && cell_exec "$qid" cp1 test -s /etc/kubernetes/admin.conf >/dev/null 2>&1; then
    _cell_grader_sync_bootstrap_kubeconfig "$qid" \
      || _CELL_GRADER_ERROR="cannot construct protected bootstrap grader kubeconfig"
  fi
}

# Override common.sh's shared kind-cka context.  No disposable-cell grader may
# accidentally observe or repair the shared practice cluster.
kctx() {
  [ -n "$_CELL_GRADER_KUBECONFIG" ] || return 1
  [ "$_CELL_GRADER_API_ABSENT" -eq 0 ] || return 1
  # A blank-node exercise deliberately has no API server before it is solved.
  # Every grader request therefore needs an authoritative bound; otherwise a
  # dead forwarded port can stall the whole live gate indefinitely.
  kubectl --kubeconfig "$_CELL_GRADER_KUBECONFIG" --request-timeout=8s "$@"
}

# grade_init calls the dynamically resolved cluster_ready function. A solved
# or HA cell has an authoritative admin.conf, so tolerate bounded transient
# failures on the Docker-published API port. A deliberately blank bootstrap
# node has no admin.conf and must remain a fast, single-probe baseline.
cluster_ready() {
  local attempts=1 attempt
  if [ -n "$_CELL_GRADER_QID" ] \
      && cell_exec "$_CELL_GRADER_QID" cp1 \
        test -s /etc/kubernetes/admin.conf >/dev/null 2>&1; then
    attempts=30
  fi
  for attempt in $(seq 1 "$attempts"); do
    if kubectl --kubeconfig "$_CELL_GRADER_KUBECONFIG" \
        --request-timeout=3s get nodes >/dev/null 2>&1; then
      return 0
    fi
    [ "$attempt" -eq "$attempts" ] || sleep 1
  done
  return 1
}

cell_grade_validate() { # <expected-profile> [allow-api-absent]
  local expected="$1" allow_api_absent="${2:-0}" reason
  if [ -n "$_CELL_GRADER_ERROR" ]; then
    grade_invalid "$_CELL_GRADER_ERROR" || true
    return 0
  fi
  if ! cell_manifest_load "$_CELL_GRADER_QID" \
      || [ "$CELL_PROFILE" != "$expected" ] || [ "$CELL_STATUS" != READY ]; then
    grade_invalid "cell profile/state mismatch: $_CELL_GRADER_QID/$expected" || true
    return 0
  fi
  if ! cell_verify_topology "$_CELL_GRADER_QID"; then
    grade_invalid "cell immutable topology/ownership validation failed" || true
    return 0
  fi

  # ca-12 deliberately starts with no API server.  A missing or half-built API
  # is a valid candidate state, not an infrastructure fault.  Only the exact
  # generic API reason is cleared; missing kubectl or broken cell ownership is
  # still INVALID.
  if [ "$allow_api_absent" = 1 ] && [ "$_G_INVALID" -eq 1 ] \
      && [ "${#_G_INVALID_REASONS[@]}" -eq 1 ]; then
    reason="${_G_INVALID_REASONS[0]}"
    case "$reason" in
      "cluster API unavailable or context missing:"*)
        _G_INVALID=0
        _G_INVALID_REASONS=()
        _CELL_GRADER_API_ABSENT=1
        ;;
    esac
  fi
}

cell_node_out() { # <role> <shell command>
  local role="$1" command="$2"
  cell_exec "$_CELL_GRADER_QID" "$role" bash -c "$command"
}

cell_api_ready() {
  kctx --request-timeout=5s get --raw=/readyz 2>/dev/null | grep -Fxq ok
}

cell_exact_ready_nodes() { # <roles...>
  local json role cluster expected=""
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  cluster="$CELL_CLUSTER_NAME"
  for role in "$@"; do
    expected+="$(cell_role_node_name "$cluster" "$role")"$'\n'
  done
  json="$(kctx get nodes -o json 2>/dev/null)" || return 1
  EXPECTED_NODES="$expected" python3 -c '
import json, os, sys
obj = json.load(sys.stdin)
expected = {line for line in os.environ["EXPECTED_NODES"].splitlines() if line}
items = obj.get("items", [])
actual = {item.get("metadata", {}).get("name") for item in items}
ready = all(any(
    c.get("type") == "Ready" and c.get("status") == "True"
    for c in item.get("status", {}).get("conditions", [])
) for item in items)
raise SystemExit(0 if actual == expected and ready else 1)
' <<< "$json"
}

cell_worker_tls_bootstrapped() { # <role>
  local role="$1" node subject
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  node="$(cell_role_node_name "$CELL_CLUSTER_NAME" "$role")" || return 1
  subject="$(cell_node_out "$role" '
    set -e
    test -s /var/lib/kubelet/pki/kubelet-client-current.pem
    test -s /etc/kubernetes/kubelet.conf
    openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject
  ')" || return 1
  printf '%s' "$subject" | grep -Fq 'system:nodes' \
    && printf '%s' "$subject" | grep -Fq "system:node:$node"
}

cell_kube_system_ready() {
  local nodes desired ready available
  nodes="$(kctx get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')" || return 1
  desired="$(kctx -n kube-system get ds kindnet -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)" || return 1
  ready="$(kctx -n kube-system get ds kindnet -o jsonpath='{.status.numberReady}' 2>/dev/null)" || return 1
  available="$(kctx -n kube-system get deploy coredns -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" || return 1
  [ "$desired" = "$nodes" ] && [ "$ready" = "$nodes" ] && [ "${available:-0}" -ge 1 ]
}

cell_bootstrap_workload_exact() {
  local json cluster worker1 worker2
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  cluster="$CELL_CLUSTER_NAME"
  worker1="$(cell_role_node_name "$cluster" worker1)"
  worker2="$(cell_role_node_name "$cluster" worker2)"
  json="$(kctx -n bootstrap-check get deploy,service,pod \
    -l app=bootstrap-web -o json 2>/dev/null)" || return 1
  EXPECTED_WORKERS="$worker1,$worker2" python3 -c '
import json, os, sys
items = json.load(sys.stdin).get("items", [])
deploys = [x for x in items if x.get("kind") == "Deployment"]
services = [x for x in items if x.get("kind") == "Service"]
pods = [x for x in items if x.get("kind") == "Pod"]
if len(deploys) != 1 or len(services) != 1 or len(pods) != 2:
    raise SystemExit(1)
d = deploys[0]
if d.get("metadata", {}).get("name") != "bootstrap-web":
    raise SystemExit(1)
status = d.get("status", {})
if not (status.get("observedGeneration") == d.get("metadata", {}).get("generation")
        and status.get("readyReplicas") == 2 and status.get("availableReplicas") == 2):
    raise SystemExit(1)
s = services[0]
if s.get("metadata", {}).get("name") != "bootstrap-web" or s.get("spec", {}).get("selector") != {"app": "bootstrap-web"}:
    raise SystemExit(1)
expected = set(os.environ["EXPECTED_WORKERS"].split(","))
actual = {p.get("spec", {}).get("nodeName") for p in pods}
pods_ok = all(
    p.get("status", {}).get("phase") == "Running"
    and any(c.get("type") == "Ready" and c.get("status") == "True"
            for c in p.get("status", {}).get("conditions", []))
    and p.get("spec", {}).get("containers", [{}])[0].get("image") == "nginx:1.29"
    for p in pods
)
raise SystemExit(0 if actual == expected and pods_ok else 1)
' <<< "$json"
}

cell_bootstrap_service_works() {
  local image phase node cluster worker1 worker2 output
  image="$(kctx -n bootstrap-check get pod network-client -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)"
  phase="$(kctx -n bootstrap-check get pod network-client -o jsonpath='{.status.phase}' 2>/dev/null)"
  node="$(kctx -n bootstrap-check get pod network-client -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  cluster="$CELL_CLUSTER_NAME"
  worker1="$(cell_role_node_name "$cluster" worker1)"
  worker2="$(cell_role_node_name "$cluster" worker2)"
  [ "$image" = busybox:1.36 ] && [ "$phase" = Running ] \
    && { [ "$node" = "$worker1" ] || [ "$node" = "$worker2" ]; } || return 1
  output="$(kctx -n bootstrap-check exec network-client -- \
    wget -qO- --timeout=5 http://bootstrap-web 2>/dev/null)" || return 1
  printf '%s' "$output" | grep -Fqi '<html'
}

cell_control_planes_joined() {
  local role node json taints
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  for role in cp1 cp2 cp3; do
    node="$(cell_role_node_name "$CELL_CLUSTER_NAME" "$role")"
    json="$(kctx get node "$node" -o json 2>/dev/null)" || return 1
    printf '%s' "$json" | python3 -c '
import json, sys
labels = json.load(sys.stdin).get("metadata", {}).get("labels", {})
raise SystemExit(0 if "node-role.kubernetes.io/control-plane" in labels else 1)
' || return 1
    taints="$(kctx get node "$node" -o jsonpath='{range .spec.taints[*]}{.key}{"|"}{.effect}{"\n"}{end}' 2>/dev/null)" || return 1
    printf '%s\n' "$taints" | grep -Fxq 'node-role.kubernetes.io/control-plane|NoSchedule' || return 1
  done
}

cell_control_plane_static_pods_ready() {
  local role node component tuple
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  for role in cp1 cp2 cp3; do
    node="$(cell_role_node_name "$CELL_CLUSTER_NAME" "$role")"
    for component in kube-apiserver kube-controller-manager kube-scheduler etcd; do
      tuple="$(kctx -n kube-system get pod "$component-$node" \
        -o jsonpath='{.spec.nodeName}{"|"}{.status.phase}{"|"}{.status.containerStatuses[0].ready}' \
        2>/dev/null)" || return 1
      [ "$tuple" = "$node|Running|true" ] || return 1
    done
  done
}

cell_etcd_three_healthy_members() {
  local role node json names="" expected=""
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  node="$(cell_role_node_name "$CELL_CLUSTER_NAME" cp1)"
  json="$(kctx -n kube-system exec "etcd-$node" -- \
    etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
      --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
      member list --write-out=json 2>/dev/null)" || return 1
  for role in cp1 cp2 cp3; do
    expected+="$(cell_role_node_name "$CELL_CLUSTER_NAME" "$role")"$'\n'
  done
  EXPECTED_ETCD="$expected" python3 -c '
import json, os, sys
members = json.load(sys.stdin).get("members", [])
expected = {x for x in os.environ["EXPECTED_ETCD"].splitlines() if x}
actual = {m.get("name") for m in members}
ok = len(members) == 3 and actual == expected and all(not m.get("isLearner", False) for m in members)
raise SystemExit(0 if ok else 1)
' <<< "$json" || return 1
  for role in cp1 cp2 cp3; do
    node="$(cell_role_node_name "$CELL_CLUSTER_NAME" "$role")"
    kctx -n kube-system exec "etcd-$node" -- \
      etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
        --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
        endpoint health >/dev/null 2>&1 || return 1
  done
}

cell_control_plane_endpoint_exact() {
  local endpoint role actual config
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  endpoint="$(cell_evidence_get "$_CELL_GRADER_QID" control_plane_endpoint)" || return 1
  [ "$endpoint" = "$CELL_CLUSTER_NAME-external-load-balancer:6443" ] || return 1
  for role in cp1 cp2 cp3; do
    actual="$(cell_node_out "$role" \
      "kubectl --kubeconfig=/etc/kubernetes/admin.conf config view --minify -o jsonpath='{.clusters[0].cluster.server}'")" \
      || return 1
    [ "$actual" = "https://$endpoint" ] || return 1
  done
  config="$(kctx -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null)" || return 1
  printf '%s\n' "$config" | grep -Eq "^[[:space:]]*controlPlaneEndpoint:[[:space:]]*\"?$endpoint\"?[[:space:]]*$"
}

cell_lb_path_ready() {
  local port server
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  cell_verify_container_id "$_CELL_GRADER_QID" lb || return 1
  port="$(_cell_docker container inspect --format \
    '{{(index (index .HostConfig.PortBindings "6443/tcp") 0).HostPort}}' \
    "${CELL_CONTAINER_IDS[lb]}" 2>/dev/null)" || return 1
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  server="$(kctx config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)" || return 1
  [ "$server" = "https://127.0.0.1:$port" ] && cell_api_ready
}

cell_ha_baseline_preserved() {
  local expected_uid expected_ca current_uid current_ca cp1
  cell_manifest_load "$_CELL_GRADER_QID" || return 1
  cp1="$(cell_role_node_name "$CELL_CLUSTER_NAME" cp1)"
  expected_uid="$(cell_evidence_get "$_CELL_GRADER_QID" cp1_node_uid)" || return 1
  expected_ca="$(cell_evidence_get "$_CELL_GRADER_QID" cluster_ca_sha256)" || return 1
  current_uid="$(kctx get node "$cp1" -o jsonpath='{.metadata.uid}' 2>/dev/null)" || return 1
  current_ca="$(cell_node_out cp1 'sha256sum /etc/kubernetes/pki/ca.crt | cut -d" " -f1')" || return 1
  [ "$current_uid" = "$expected_uid" ] && [ "$current_ca" = "$expected_ca" ]
}

cell_ha_survival_preserved() {
  local expected current output
  expected="$(cell_evidence_get "$_CELL_GRADER_QID" survival_deployment_uid)" || return 1
  current="$(kctx -n ha-survival get deploy survival-web -o jsonpath='{.metadata.uid}' 2>/dev/null)" || return 1
  [ "$current" = "$expected" ] || return 1
  deploy_ready ha-survival survival-web 2 || return 1
  output="$(kctx -n ha-survival exec network-client -- \
    wget -qO- --timeout=5 http://survival-web 2>/dev/null)" || return 1
  printf '%s' "$output" | grep -Fqi '<html'
}
