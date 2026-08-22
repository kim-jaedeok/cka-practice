#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../lib/cell.sh"

qid="${1:-ca-11}"
[ "$qid" = ca-11 ]
cell_manifest_load "$qid"
[ "$CELL_PROFILE" = kubeadm-ha ] && [ "$CELL_STATUS" = PREPARING ]

cp1="$(cell_role_node_name "$CELL_CLUSTER_NAME" cp1)"
cp2="$(cell_role_node_name "$CELL_CLUSTER_NAME" cp2)"
cp3="$(cell_role_node_name "$CELL_CLUSTER_NAME" cp3)"
worker1="$(cell_role_node_name "$CELL_CLUSTER_NAME" worker1)"
worker2="$(cell_role_node_name "$CELL_CLUSTER_NAME" worker2)"
worker3="$(cell_role_node_name "$CELL_CLUSTER_NAME" worker3)"

for worker in "$worker1" "$worker2" "$worker3"; do
  cell_kubectl "$qid" label node "$worker" cka-practice/survival=true --overwrite >/dev/null
done
cell_kubectl "$qid" apply -f "$SCRIPT_DIR/fixtures/ha-survival.yaml" >/dev/null
cell_kubectl "$qid" -n ha-survival rollout status deploy/survival-web --timeout=180s >/dev/null
cell_kubectl "$qid" -n ha-survival wait --for=condition=Ready pod/network-client --timeout=180s >/dev/null

survival_uid="$(cell_kubectl "$qid" -n ha-survival get deploy survival-web \
  -o jsonpath='{.metadata.uid}')"
cp1_uid="$(cell_kubectl "$qid" get node "$cp1" -o jsonpath='{.metadata.uid}')"
ca_sha="$(cell_exec "$qid" cp1 sha256sum /etc/kubernetes/pki/ca.crt | awk '{print $1}')"
endpoint="$(cell_kubectl "$qid" -n kube-system get cm kubeadm-config \
  -o jsonpath='{.data.ClusterConfiguration}' | sed -n 's/^[[:space:]]*controlPlaneEndpoint:[[:space:]]*"\{0,1\}\([^"[:space:]]*\).*/\1/p')"
load_balancer_host="$CELL_CLUSTER_NAME-external-load-balancer"
load_balancer_ip="$(cell_exec "$qid" cp1 getent ahostsv4 "$load_balancer_host" \
  | awk 'NR == 1 {print $1}')"
[[ "$survival_uid" =~ ^[0-9a-f-]{36}$ ]]
[[ "$cp1_uid" =~ ^[0-9a-f-]{36}$ ]]
[[ "$ca_sha" =~ ^[0-9a-f]{64}$ ]]
[ "$endpoint" = "$CELL_CLUSTER_NAME-external-load-balancer:6443" ]
[[ "$load_balancer_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]

# An etcd leader election, API recovery and KIND load-balancer backend health
# update can overlap after a control-plane member stops. Keep every trusted API
# operation independently bounded and retry only idempotent reads/deletes; a
# control plane that never answers still fails preparation.
cell_api_wait() {
  local attempt response
  for attempt in $(seq 1 60); do
    response="$(cell_kubectl "$qid" --request-timeout=5s \
      get --raw=/readyz 2>/dev/null || true)"
    [ "$response" = ok ] && return 0
    sleep 2
  done
  return 1
}

cell_etcd_members_wait() { # <expected-member-name>...
  local attempt etcd_json
  for attempt in $(seq 1 60); do
    etcd_json="$(cell_kubectl "$qid" --request-timeout=10s -n kube-system \
      exec "etcd-$cp1" -- \
      etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
        --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
        member list --write-out=json 2>/dev/null || true)"
    if printf '%s' "$etcd_json" | python3 -c '
import json, sys
expected = sorted(sys.argv[1:])
try:
    members = json.load(sys.stdin).get("members", [])
except (AttributeError, json.JSONDecodeError):
    raise SystemExit(1)
actual = sorted(member.get("name", "") for member in members)
voting = all(not member.get("isLearner", False) for member in members)
raise SystemExit(0 if actual == expected and voting else 1)
' "$@"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

cell_node_delete_retry() { # <node-name>
  local node="$1" attempt
  for attempt in $(seq 1 30); do
    if cell_kubectl "$qid" --request-timeout=10s delete node "$node" \
        --ignore-not-found --wait=true --timeout=30s >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Remove one member at a time while quorum is still available.  The reset
# operation is real kubeadm; the follow-up scrub closes documented reset gaps.
for role in cp3 cp2; do
  cell_exec_script "$qid" "$role" "$SCRIPT_DIR/blank-node.sh" \
    "$CELL_RUN_ID" "$qid" "$role" "$load_balancer_host" "$load_balancer_ip"
  cell_api_wait || die "API did not recover after resetting $role"
  case "$role" in
    cp3)
      cell_etcd_members_wait "$cp1" "$cp2" \
        || die "etcd membership was not exactly cp1/cp2 after resetting cp3"
      cell_node_delete_retry "$cp3" \
        || die "failed to delete the reset cp3 Node object"
      ;;
    cp2)
      cell_etcd_members_wait "$cp1" \
        || die "etcd membership was not exactly cp1 after resetting cp2"
      cell_node_delete_retry "$cp2" \
        || die "failed to delete the reset cp2 Node object"
      ;;
  esac
done
cell_api_wait || die "single-control-plane API did not recover"
cell_etcd_members_wait "$cp1" \
  || die "single-member etcd invariant did not converge"

evidence="$(cell_evidence_path "$qid")"
tmp="$(mktemp "$(dirname "$evidence")/.evidence.XXXXXX")"
chmod 0600 "$tmp"
{
  printf 'cp1_node_uid=%s\n' "$cp1_uid"
  printf 'cluster_ca_sha256=%s\n' "$ca_sha"
  printf 'survival_deployment_uid=%s\n' "$survival_uid"
  printf 'control_plane_endpoint=%s\n' "$endpoint"
} > "$tmp"
mv -f -- "$tmp" "$evidence"

# The protected baseline must still answer after the two control-plane resets.
survival_ready=0
for _ in $(seq 1 30); do
  if cell_kubectl "$qid" --request-timeout=10s -n ha-survival \
      exec network-client -- \
      wget -qO- --timeout=5 http://survival-web >/dev/null 2>&1; then
    survival_ready=1
    break
  fi
  sleep 2
done
[ "$survival_ready" -eq 1 ]
