#!/usr/bin/env bash
set -Eeuo pipefail

# Destructive, opt-in end-to-end gate.  It refuses a host with any existing
# KIND cluster, creates the canonical question-compatible cluster on the
# canonical KIND network with a unique run label, and removes only identities whose exact
# ownership is revalidated at teardown.
if [ "${CKA_SSH_SUPERVISED_LIVE:-0}" != 1 ]; then
  printf 'SKIP: set CKA_SSH_SUPERVISED_LIVE=1 on a clean disposable host\n'
  # A required live gate must not be mistaken for a passing execution when
  # its explicit opt-in was omitted.
  exit 77
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGINAL_HOME="$HOME"
TEST_ROOT="$(mktemp -d /tmp/cka-ssh-supervised-live.XXXXXXXX)"
case "$TEST_ROOT" in
  /tmp/cka-ssh-supervised-live.*) ;;
  *) printf 'unsafe live-test root\n' >&2; exit 1 ;;
esac
TEST_ROOT_REAL="$(realpath -e -- "$TEST_ROOT")"
[ "$TEST_ROOT_REAL" = "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ] \
  || { printf 'live-test root is not a canonical directory\n' >&2; exit 1; }

RUN_ID="sshlive-$(date -u +%m%d%H%M%S)-$$"
CLUSTER_NAME="cka"
# cloud-provider-kind v0.11.1 starts LoadBalancer proxy containers on the
# canonical KIND network unless its own process inherits an experimental
# override.  Use the supported shared name and make exclusivity a hard
# clean-host precondition instead of depending on process-environment coupling.
# https://github.com/kubernetes-sigs/cloud-provider-kind/blob/v0.11.1/pkg/loadbalancer/server.go
# https://github.com/kubernetes-sigs/cloud-provider-kind/blob/v0.11.1/pkg/constants/constants.go
NETWORK_NAME="kind"
NETWORK_ID=""
PROVIDER_WAS_RUNNING=0
PROVIDER_LIFECYCLE_IN_SCOPE=0
RUNNER_CLEANED=0
OWNED_NODE_IDS=()
RECORDED_NODE_IDS=()
DURATION="${CKA_SSH_SUPERVISED_LIVE_DURATION_SECONDS:-90}"
[[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 45 ] && [ "$DURATION" -le 180 ] \
  || { printf 'live deadline must be 45..180 seconds\n' >&2; exit 1; }

export HOME="$TEST_ROOT/home"
export KUBECONFIG="$TEST_ROOT/kubeconfig"
export CKA_ROOT="$ROOT"
export CKA_CLUSTER_NAME="$CLUSTER_NAME"
export CKA_CONTEXT="kind-$CLUSTER_NAME"
export CKA_STATE_DIR="$TEST_ROOT/lab-state"
export CKA_WORK_DIR="$TEST_ROOT/lab-work"
export CKA_SSH_RUNNER_STATE_ROOT="$TEST_ROOT/runner-state"
export CKA_SSH_SUPERVISOR_STATE_ROOT="$TEST_ROOT/supervisor-state"
export CLOUD_PROVIDER_KIND_BIN="${CLOUD_PROVIDER_KIND_BIN:-$ORIGINAL_HOME/.local/bin/cloud-provider-kind}"
export CLOUD_PROVIDER_KIND_STATE_ROOT="${CLOUD_PROVIDER_KIND_STATE_ROOT:-${XDG_RUNTIME_DIR:-$ORIGINAL_HOME/.local/state}/cka-practice}"
install -d -m 0700 "$HOME" "$CKA_STATE_DIR" "$CKA_WORK_DIR" \
  "$CKA_SSH_RUNNER_STATE_ROOT" "$CKA_SSH_SUPERVISOR_STATE_ROOT"
: > "$KUBECONFIG"; chmod 0600 "$KUBECONFIG"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/cell.sh
source "$ROOT/lib/cell.sh"
# shellcheck source=ssh-live-volume-lifecycle.sh
source "$ROOT/tests/ssh-live-volume-lifecycle.sh"

NODE_VOLUME_JOURNAL="$TEST_ROOT/kind-node-volumes.v1"

# The live gate creates its own KIND cluster outside the ordinary question
# runtime, so enforce the same host-filesystem safety floor before the first
# Docker object is allocated.
cell_host_storage_preflight || {
  printf 'ssh supervised live: insufficient host filesystem space\n' >&2
  exit 1
}

die_live() { printf 'ssh supervised live: %s\n' "$*" >&2; exit 1; }

network_owned() {
  local inspect_json
  [ -n "$NETWORK_ID" ] || return 1
  inspect_json="$(docker network inspect "$NETWORK_ID" 2>/dev/null)" || return 1
  python3 - "$NETWORK_NAME" "$RUN_ID" "$NETWORK_ID" "$inspect_json" <<'PY'
import json,re,sys
r=json.loads(sys.argv[4])
if len(r)!=1: raise SystemExit(1)
v=r[0]; labels=v.get("Labels") or {}
if v.get("Id") != sys.argv[3] or v.get("Name") != sys.argv[1]: raise SystemExit(1)
if labels.get("org.cka-practice.ssh-live.run") != sys.argv[2]: raise SystemExit(1)
if not re.fullmatch(r"[0-9a-f]{64}",str(v.get("Id",""))): raise SystemExit(1)
PY
}

capture_owned_nodes() {
  local id inspect_json ids_output
  ids_output="$(docker container ls --all --quiet --no-trunc \
    --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME")" || return 1
  OWNED_NODE_IDS=()
  if [ -n "$ids_output" ]; then mapfile -t OWNED_NODE_IDS <<< "$ids_output"; fi
  [ "${#OWNED_NODE_IDS[@]}" -le 3 ] || return 1
  for id in "${OWNED_NODE_IDS[@]}"; do
    [[ "$id" =~ ^[0-9a-f]{64}$ ]] || return 1
    inspect_json="$(docker container inspect "$id")" || return 1
    python3 - "$CLUSTER_NAME" "$NETWORK_ID" "$inspect_json" <<'PY' || return 1
import json,re,sys
records=json.loads(sys.argv[3])
if len(records) != 1: raise SystemExit(1)
r=records[0]; cluster=sys.argv[1]; network=sys.argv[2]
cid=r.get("Id",""); name=str(r.get("Name","")).removeprefix("/")
allowed={f"{cluster}-control-plane",f"{cluster}-worker",f"{cluster}-worker2"}
labels=(r.get("Config") or {}).get("Labels") or {}
networks=(r.get("NetworkSettings") or {}).get("Networks") or {}
ids={item.get("NetworkID") for item in networks.values() if isinstance(item,dict)}
if not re.fullmatch(r"[0-9a-f]{64}",cid) or name not in allowed: raise SystemExit(1)
if labels.get("io.x-k8s.kind.cluster") != cluster or ids != {network}: raise SystemExit(1)
PY
  done
}

record_current_nodes() {
  capture_owned_nodes || return 1
  RECORDED_NODE_IDS=("${OWNED_NODE_IDS[@]}")
}

node_inventory_matches_record() {
  local id
  capture_owned_nodes || return 1
  [ "${#OWNED_NODE_IDS[@]}" -eq "${#RECORDED_NODE_IDS[@]}" ] || return 1
  declare -A current=()
  for id in "${OWNED_NODE_IDS[@]}"; do current["$id"]=1; done
  for id in "${RECORDED_NODE_IDS[@]}"; do [ -n "${current[$id]+x}" ] || return 1; done
}

node_inventory_is_recorded_subset() {
  local id
  capture_owned_nodes || return 1
  declare -A recorded=()
  for id in "${RECORDED_NODE_IDS[@]}"; do recorded["$id"]=1; done
  for id in "${OWNED_NODE_IDS[@]}"; do
    [ -n "${recorded[$id]+present}" ] || return 1
  done
}

remove_exact_nodes() {
  local id failed=0
  if [ "${#RECORDED_NODE_IDS[@]}" -eq 0 ]; then
    # Recovery for a partially-created KIND cluster: capture once only after
    # the unique run-labelled network and exact KIND labels/names are proven.
    record_current_nodes || return 1
  fi
  # A retry may observe a strict subset after a previous exact-ID deletion
  # succeeded. Unknown same-cluster IDs still fail closed.
  node_inventory_is_recorded_subset || return 1
  for id in "${RECORDED_NODE_IDS[@]}"; do
    if docker container inspect "$id" >/dev/null 2>&1; then
      docker container stop --time 0 "$id" >/dev/null 2>&1 || failed=1
      docker container rm "$id" >/dev/null 2>&1 || failed=1
    elif ! docker info >/dev/null 2>&1; then
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || return 1
  local remaining
  remaining="$(docker container ls --all --quiet --no-trunc \
    --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME")" || return 1
  OWNED_NODE_IDS=()
  if [ -n "$remaining" ]; then mapfile -t OWNED_NODE_IDS <<< "$remaining"; fi
  [ "${#OWNED_NODE_IDS[@]}" -eq 0 ]
}

seal_exact_node_volumes() {
  [ "${#RECORDED_NODE_IDS[@]}" -gt 0 ] || return 1
  ssh_live_volume_journal_seal "$NODE_VOLUME_JOURNAL" "${RECORDED_NODE_IDS[@]}"
}

cleanup_live() {
  local rc=0 active="" endpoints=""
  set +e
  if [ -f "$CKA_SSH_RUNNER_STATE_ROOT/active" ] && [ ! -L "$CKA_SSH_RUNNER_STATE_ROOT/active" ]; then
    active="$(<"$CKA_SSH_RUNNER_STATE_ROOT/active")"
    if [ "$active" = "$RUN_ID" ]; then
      bash "$ROOT/cka" exam-ssh cleanup >/dev/null 2>&1 || rc=1
    else
      printf 'REFUSE: runner active record is not this live run\n' >&2; rc=1
    fi
  fi
  if [ "$RUNNER_CLEANED" -eq 0 ] \
      && [ -f "$CKA_SSH_SUPERVISOR_STATE_ROOT/runs/$RUN_ID/manifest.json" ]; then
    CKA_SSH_SUPERVISOR_STATE_ROOT="$CKA_SSH_SUPERVISOR_STATE_ROOT" \
      bash "$ROOT/exam/ssh/session.sh" seal --run-id "$RUN_ID" --reason operator >/dev/null 2>&1 || true
    CKA_SSH_SUPERVISOR_STATE_ROOT="$CKA_SSH_SUPERVISOR_STATE_ROOT" \
      bash "$ROOT/exam/ssh/session.sh" cleanup --run-id "$RUN_ID" >/dev/null 2>&1 || rc=1
  fi
  if [ -n "$NETWORK_ID" ]; then
    if network_owned; then
      if [ "${#RECORDED_NODE_IDS[@]}" -eq 0 ]; then record_current_nodes || rc=1; fi
      if node_inventory_is_recorded_subset; then
        cloud_provider_kind_cleanup_cluster_loadbalancers "$CLUSTER_NAME" >/dev/null 2>&1 || rc=1
        if [ "${#RECORDED_NODE_IDS[@]}" -gt 0 ]; then
          # Revalidate the sealed mount set, volume generation, and complete
          # attachment allowlist immediately before deleting exact node IDs.
          # A prior partial cleanup may have removed a node/volume, but it may
          # never cause a replacement generation to be adopted.
          if [ ! -e "$NODE_VOLUME_JOURNAL" ]; then
            seal_exact_node_volumes || rc=1
          fi
          ssh_live_volume_verify "$NODE_VOLUME_JOURNAL" 1 \
            "${RECORDED_NODE_IDS[@]}" || rc=1
        fi
        if [ "$rc" -eq 0 ]; then
          remove_exact_nodes || rc=1
        fi
        if [ "$rc" -eq 0 ] && [ "${#RECORDED_NODE_IDS[@]}" -gt 0 ]; then
          ssh_live_volume_remove_sealed "$NODE_VOLUME_JOURNAL" \
            "${RECORDED_NODE_IDS[@]}" || rc=1
        fi
      else
        printf 'REFUSE: dedicated KIND node inventory differs from recorded exact IDs\n' >&2
        rc=1
      fi
      endpoints="$(docker network inspect "$NETWORK_ID" --format '{{len .Containers}}' 2>/dev/null)"
      if [ "$endpoints" = 0 ]; then
        docker network rm "$NETWORK_ID" >/dev/null 2>&1 || rc=1
      elif docker network inspect "$NETWORK_ID" >/dev/null 2>&1; then
        printf 'REFUSE: dedicated network still has %s endpoint(s)\n' "${endpoints:-unknown}" >&2
        rc=1
      fi
    elif docker network inspect "$NETWORK_ID" >/dev/null 2>&1; then
      printf 'REFUSE: dedicated network identity/label changed\n' >&2
      rc=1
    fi
  fi
  if [ "$PROVIDER_LIFECYCLE_IN_SCOPE" -eq 1 ] && [ "$PROVIDER_WAS_RUNNING" -eq 0 ]; then
    cloud_provider_kind_stop_if_no_clusters >/dev/null 2>&1 || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'PRESERVED: incomplete live cleanup audit at %s\n' "$TEST_ROOT" >&2
    return "$rc"
  fi
  case "$TEST_ROOT" in
    /tmp/cka-ssh-supervised-live.*)
      if [ -d "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ] \
          && [ "$(realpath -e -- "$TEST_ROOT" 2>/dev/null)" = "$TEST_ROOT_REAL" ]; then
        chmod -R u+w -- "$TEST_ROOT" 2>/dev/null || true
        rm -rf -- "$TEST_ROOT" || rc=1
      else
        printf 'REFUSE: live-test root identity changed\n' >&2; rc=1
      fi
      ;;
    *) printf 'REFUSE: unsafe live-test cleanup root\n' >&2; rc=1 ;;
  esac
  return "$rc"
}

on_exit() {
  local original_rc=$?
  trap - EXIT INT TERM
  cleanup_live || { [ "$original_rc" -ne 0 ] || original_rc=1; }
  exit "$original_rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for binary in docker kind kubectl python3 systemctl systemd-run timeout; do
  command -v "$binary" >/dev/null 2>&1 || die_live "$binary is required"
done
docker info >/dev/null 2>&1 || die_live 'Docker engine is not reachable'
existing_output="$(kind get clusters 2>/dev/null)" \
  || die_live 'cannot inventory existing KIND clusters'
EXISTING_CLUSTERS=()
while IFS= read -r cluster; do
  [ -n "$cluster" ] && [ "$cluster" != 'No kind clusters found.' ] \
    && EXISTING_CLUSTERS+=("$cluster")
done <<< "$existing_output"
[ "${#EXISTING_CLUSTERS[@]}" -eq 0 ] \
  || die_live 'refusing a host with an existing KIND cluster; use a disposable host/distro'
# `kind get clusters` can be empty while a prior failed run has retained node
# containers.  The canonical cluster name is shared with question fixtures, so
# reject any such labelled object before this run allocates a Docker network.
canonical_orphans="$(docker container ls --all --quiet --no-trunc \
  --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME")" \
  || die_live 'cannot inventory canonical KIND node containers'
[ -z "$canonical_orphans" ] \
  || die_live 'refusing canonical KIND node containers not reported by kind; use a clean disposable host/distro'
# The canonical network cannot safely be adopted: it may belong to an
# unreported/partially removed cluster, and cleanup is allowed to delete only
# the exact network ID created and run-labelled below.  Use Docker's documented
# JSON formatting and compare the complete name instead of its partial-match
# `name` filter.
# https://docs.docker.com/reference/cli/docker/network/ls/#name
NETWORK_INVENTORY="$TEST_ROOT/docker-networks.jsonl"
docker network ls --no-trunc --format json > "$NETWORK_INVENTORY" \
  || die_live 'cannot inventory the canonical KIND network'
canonical_networks="$(python3 - "$NETWORK_NAME" "$NETWORK_INVENTORY" <<'PY'
import json,re,sys
target=sys.argv[1]
with open(sys.argv[2],encoding="utf-8") as stream:
    for line in stream:
        record=json.loads(line)
        if record.get("Name") == target:
            network_id=str(record.get("ID", ""))
            if not re.fullmatch(r"[0-9a-f]{64}", network_id): raise SystemExit(1)
            print(network_id)
PY
)" || die_live 'canonical KIND network inventory is invalid'
[ -z "$canonical_networks" ] \
  || die_live 'refusing a host with a pre-existing canonical KIND network; use a clean disposable host/distro'
if _cloud_provider_kind_process_owned; then
  PROVIDER_WAS_RUNNING=1
elif _cloud_provider_kind_untracked_process_exists; then
  die_live 'refusing a host with an untracked cloud-provider-kind process'
fi
docker image inspect "${CKA_SSH_BASE_IMAGE:-cka-practice/ssh-base:v1}" \
  "${CKA_SSH_TARGET_IMAGE:-cka-practice/ssh-target:v1}" >/dev/null 2>&1 \
  || die_live 'build the designated-host images first: bash exam/ssh/build.sh'
CKA_SSH_SUPERVISOR_STATE_ROOT="$CKA_SSH_SUPERVISOR_STATE_ROOT" \
  bash "$ROOT/exam/ssh/session.sh" preflight >/dev/null

NETWORK_ID="$(docker network create --driver bridge \
  --label "org.cka-practice.ssh-live.run=$RUN_ID" "$NETWORK_NAME")"
[[ "$NETWORK_ID" =~ ^[0-9a-f]{64}$ ]] || die_live 'Docker returned an invalid dedicated network ID'
network_owned || die_live 'dedicated network identity/label mismatch'

cat > "$TEST_ROOT/kind.yaml" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
  - role: worker
  - role: worker
YAML
chmod 0600 "$TEST_ROOT/kind.yaml"
kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" \
  --config "$TEST_ROOT/kind.yaml" \
  --kubeconfig "$KUBECONFIG"
record_current_nodes || die_live 'cannot bind exact KIND node IDs to the dedicated network'
[ "${#RECORDED_NODE_IDS[@]}" -eq 3 ] || die_live 'dedicated cluster did not create exactly three nodes'
seal_exact_node_volumes || die_live 'cannot seal exact KIND node anonymous volume generations'
PROVIDER_LIFECYCLE_IN_SCOPE=1
bash "$ROOT/cluster/setup-cluster.sh"

bash "$ROOT/cka" exam-ssh prepare --run-id "$RUN_ID" --seed ssh-supervised-live-v1 \
  --duration-seconds "$DURATION"
RUN_DIR="$CKA_SSH_RUNNER_STATE_ROOT/runs/$RUN_ID"
[ "$(grep -c . "$RUN_DIR/questions")" -eq 17 ] || die_live 'runner did not create a 17-question form'
python3 - "$RUN_DIR/questions" "$RUN_DIR/work" "$RUN_DIR/input-manifest.json" <<'PY' \
  || die_live 'runner input manifest does not bind 17 exact real question work roots'
import json, os, pathlib, stat, sys

questions = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
work_root = pathlib.Path(sys.argv[2])
manifest = json.load(open(sys.argv[3], encoding="utf-8"))
entries = manifest.get("questions", [])
if [entry.get("question_id") for entry in entries] != questions:
    raise SystemExit(1)
for entry, question_id in zip(entries, questions):
    expected = work_root / question_id
    if entry.get("work_root") != str(expected):
        raise SystemExit(1)
    metadata = expected.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(1)
    if expected.resolve(strict=True) != expected:
        raise SystemExit(1)
PY

# Apply repository canonical solutions before candidate access starts.  This
# proves the final host graders can reproduce a perfect diagnostic score from
# the immutable evidence snapshot and the collected allowlisted files.
while IFS= read -r qid; do
  [ -n "$qid" ] || continue
  qdir="$(qdir_of "$qid")" || die_live "question directory missing: $qid"
  timeout --signal=TERM --kill-after=5s 240s env \
    CKA_WORK_DIR="$RUN_DIR/work" CKA_STATE_DIR="$RUN_DIR/grader-state" \
    bash "$qdir/solve.sh" > "$RUN_DIR/logs/$qid-live-solve.log" 2>&1 \
    || die_live "canonical solve failed: $qid"
done < "$RUN_DIR/questions"
while IFS= read -r qid; do
  [ -n "$qid" ] || continue
  qdir="$(qdir_of "$qid")"; expected="$(meta_get "$qdir" points)"
  timeout --signal=TERM --kill-after=5s 120s env \
    CKA_WORK_DIR="$RUN_DIR/work" CKA_STATE_DIR="$RUN_DIR/grader-state" \
    bash "$qdir/grade.sh" > "$RUN_DIR/logs/$qid-live-grade.log" 2>&1 \
    || die_live "canonical grade failed: $qid"
  [ "$(cat "$RUN_DIR/grader-state/status/$qid" 2>/dev/null)" = "graded:$expected/$expected" ] \
    || die_live "canonical solution was not full score: $qid"
done < "$RUN_DIR/questions"

bash "$ROOT/cka" exam-ssh start
SUPERVISOR_MANIFEST="$CKA_SSH_SUPERVISOR_STATE_ROOT/runs/$RUN_ID/manifest.json"
read -r BASE_ID TARGET_ID INTERNAL_NETWORK_ID NONCE DEADLINE < <(python3 - "$SUPERVISOR_MANIFEST" <<'PY'
import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8")); o=v["objects"]
print(o["base"]["id"],o["target"]["id"],o["network"]["id"],v["run_nonce"],v["deadline_epoch"])
PY
)
for value in "$BASE_ID" "$TARGET_ID" "$INTERNAL_NETWORK_ID" "$NONCE"; do
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || die_live 'supervisor manifest contains a non-exact identity'
done
GUARD_UNIT="cka-ssh-guard-${RUN_ID}-${NONCE:0:12}.service"

docker container exec --user candidate "$BASE_ID" ssh -o BatchMode=yes -o ConnectTimeout=10 cka-target \
  'kubectl --request-timeout=10s get namespace kube-system >/dev/null'

OLD_PID="$(systemctl --user show --property MainPID --value "$GUARD_UNIT")"
[[ "$OLD_PID" =~ ^[1-9][0-9]*$ ]] || die_live 'guard has no live MainPID before fault injection'
systemctl --user kill --kill-whom=main --signal=KILL "$GUARD_UNIT"
NEW_PID=""
for _attempt in $(seq 1 100); do
  candidate_pid="$(systemctl --user show --property MainPID --value "$GUARD_UNIT" 2>/dev/null || true)"
  if [[ "$candidate_pid" =~ ^[1-9][0-9]*$ ]] && [ "$candidate_pid" != "$OLD_PID" ] \
      && systemctl --user is-active --quiet "$GUARD_UNIT"; then
    NEW_PID="$candidate_pid"; break
  fi
  sleep 0.1
done
[ -n "$NEW_PID" ] || die_live 'restartable guard did not recover after SIGKILL'

# No manual seal is issued.  The independent timer/guard must create deadline
# provenance and stop both exact container IDs within the hard boundary.
SEALED=0
for _attempt in $(seq 1 $((DURATION + 20))); do
  phase="$(CKA_SSH_SUPERVISOR_STATE_ROOT="$CKA_SSH_SUPERVISOR_STATE_ROOT" \
    bash "$ROOT/exam/ssh/session.sh" status --run-id "$RUN_ID" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("phase",""))' 2>/dev/null || true)"
  if [ "$phase" = SEALED ]; then SEALED=1; break; fi
  sleep 1
done
[ "$SEALED" -eq 1 ] || die_live 'unattended short deadline did not seal the run'
python3 - "$CKA_SSH_SUPERVISOR_STATE_ROOT/runs/$RUN_ID/seal-proof.json" "$RUN_ID" "$DEADLINE" <<'PY' \
  || die_live 'deadline seal proof is invalid or late'
import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8"))
if v.get("run_id") != sys.argv[2] or v.get("reason") != "deadline" or v.get("valid") is not True: raise SystemExit(1)
if v.get("sealed_at_epoch") > int(sys.argv[3])+1: raise SystemExit(1)
PY
for id in "$BASE_ID" "$TARGET_ID"; do
  [ "$(docker container inspect --format '{{.State.Running}}' "$id")" = false ] \
    || die_live "deadline left candidate container running: $id"
done

# Synchronize only the outer runner phase with the already-proven deadline,
# then exercise actual collect, final grading, TIMEOUT verdict, and cleanup.
bash "$ROOT/cka" exam-ssh seal
bash "$ROOT/cka" exam-ssh collect
bash "$ROOT/cka" exam-ssh grade | tee "$TEST_ROOT/final-grade.out"
grep -Eq 'score: [0-9]+/[0-9]+ \(100%\).*TIMEOUT' "$RUN_DIR/score.txt" \
  || die_live 'perfect deadline diagnostic result was not TIMEOUT/non-pass'
python3 - "$RUN_DIR/grade-authorization.json" "$RUN_ID" <<'PY' \
  || die_live 'runner lost deadline provenance at final grade'
import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8"))
if v.get("run_id") != sys.argv[2] or v.get("seal_reason") != "deadline" or v.get("deadline_enforced") is not True:
    raise SystemExit(1)
PY
bash "$ROOT/cka" exam-ssh cleanup
RUNNER_CLEANED=1
[ ! -e "$CKA_SSH_RUNNER_STATE_ROOT/active" ] || die_live 'runner active record survived cleanup'
[ ! -e "$CKA_SSH_SUPERVISOR_STATE_ROOT/active.json" ] || die_live 'supervisor active record survived cleanup'
for id in "$BASE_ID" "$TARGET_ID"; do
  ! docker container inspect "$id" >/dev/null 2>&1 || die_live "cleanup retained supervisor container: $id"
done
! docker network inspect "$INTERNAL_NETWORK_ID" >/dev/null 2>&1 \
  || die_live 'cleanup retained supervisor internal network'
docker network inspect "$NETWORK_ID" >/dev/null 2>&1 \
  || die_live 'runner cleanup removed the external dedicated KIND network'
node_inventory_matches_record && [ "${#RECORDED_NODE_IDS[@]}" -eq 3 ] \
  || die_live 'runner cleanup changed dedicated KIND node ownership'
systemctl --user is-active --quiet "$GUARD_UNIT" \
  && die_live 'guard unit remained active after runner cleanup'

printf 'PASS: actual 17-question cka exam-ssh deadline/guard/TIMEOUT/cleanup lifecycle\n'
