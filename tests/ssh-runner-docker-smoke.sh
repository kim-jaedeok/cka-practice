#!/usr/bin/env bash
set -Eeuo pipefail

# This is deliberately opt-in: it exercises the real persistent user-systemd
# supervisor, designated-host SSH hop, KIND data path, immutable input copy,
# answer collection, grade gate, and exact-ID cleanup.
if [ "${CKA_SSH_RUNNER_DOCKER_SMOKE:-0}" != 1 ]; then
  printf 'SKIP: set CKA_SSH_RUNNER_DOCKER_SMOKE=1 for the full KIND/input/collect smoke\n'
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="$ROOT/exam/ssh/session.sh"
BASE_IMAGE="${CKA_SSH_BASE_IMAGE:-cka-practice/ssh-base:v1}"
TARGET_IMAGE="${CKA_SSH_TARGET_IMAGE:-cka-practice/ssh-target:v1}"
CLUSTER_NAME="${CKA_CLUSTER_NAME:-cka}"
TEST_ROOT="$(mktemp -d /tmp/cka-ssh-runner-docker.XXXXXXXX)"
STATE_ROOT="$TEST_ROOT/state"
RUN_ID="runner-smoke-$$"

case "$TEST_ROOT" in /tmp/cka-ssh-runner-docker.*) ;; *) printf 'unsafe test root\n' >&2; exit 1 ;; esac
install -d -m 0700 "$STATE_ROOT" "$TEST_ROOT/work/smoke"

cleanup() {
  CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" seal \
    --run-id "$RUN_ID" --reason operator >/dev/null 2>&1 || true
  CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" cleanup \
    --run-id "$RUN_ID" >/dev/null 2>&1 || true
  case "$TEST_ROOT" in /tmp/cka-ssh-runner-docker.*) rm -rf -- "$TEST_ROOT" ;; esac
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || { printf 'Docker is required\n' >&2; exit 1; }
command -v kind >/dev/null 2>&1 || { printf 'kind is required\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'Python 3 is required\n' >&2; exit 1; }
docker info >/dev/null
docker image inspect "$BASE_IMAGE" "$TARGET_IMAGE" >/dev/null \
  || { printf 'Build SSH images first with exam/ssh/build.sh\n' >&2; exit 1; }
docker container inspect "${CLUSTER_NAME}-control-plane" >/dev/null \
  || { printf 'Create the KIND cluster first: cka setup\n' >&2; exit 1; }

# This is a hard prerequisite check. It may report the explicit one-time
# `preflight --install-linger` command, but the smoke never installs or falls
# back to an in-process timer on its own.
CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" preflight >/dev/null

kind get kubeconfig --internal --name "$CLUSTER_NAME" > "$TEST_ROOT/kubeconfig.yaml"
chmod 0600 "$TEST_ROOT/kubeconfig.yaml"
printf 'immutable-seed\n' > "$TEST_ROOT/work/smoke/seed.txt"
network_id="$(docker container inspect "${CLUSTER_NAME}-control-plane" | python3 -c '
import json,re,sys
r=json.load(sys.stdin)
n=(r[0].get("NetworkSettings") or {}).get("Networks") or {}
ids={v.get("NetworkID") for v in n.values() if isinstance(v,dict)}
if len(ids)!=1 or not re.fullmatch(r"[0-9a-f]{64}",next(iter(ids)) or ""): raise SystemExit(1)
print(next(iter(ids)))
')" || { printf 'Cannot resolve the exact KIND network ID\n' >&2; exit 1; }

python3 - "$TEST_ROOT/input.json" "$TEST_ROOT/kubeconfig.yaml" "$TEST_ROOT/work/smoke" <<'PY'
import json, os, sys
value={"schema_version":1,"active_question":"smoke","questions":[{
    "question_id":"smoke","kubeconfig":os.path.realpath(sys.argv[2]),
    "work_root":os.path.realpath(sys.argv[3])}]}
payload=(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode()
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o400)
with os.fdopen(fd,"wb") as handle:
    handle.write(payload); handle.flush(); os.fsync(handle.fileno())
PY

CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" start \
  --run-id "$RUN_ID" --duration-seconds 120 \
  --input-manifest "$TEST_ROOT/input.json" --external-network-id "$network_id" \
  --answer smoke:proof.txt --base-image "$BASE_IMAGE" --target-image "$TARGET_IMAGE" >/dev/null

entry="$(CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" candidate-entry --run-id "$RUN_ID")"
base_id="$(printf '%s' "$entry" | python3 -c 'import json,re,sys; v=json.load(sys.stdin)["base_container_id"]; print(v) if re.fullmatch(r"[0-9a-f]{64}",v) else sys.exit(1)')"
docker container exec --user candidate "$base_id" ssh -o BatchMode=yes cka-target '
  set -eu
  test "$(cat /home/candidate/.kube/active-question)" = smoke
  test "$(cat /home/candidate/cka/smoke/seed.txt)" = immutable-seed
  kubectl --request-timeout=10s get namespace kube-system >/dev/null
  printf "collected-via-designated-host\n" > /home/candidate/cka/smoke/proof.txt
'

CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" seal --run-id "$RUN_ID" --reason manual >/dev/null
CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" collect \
  --run-id "$RUN_ID" --destination "$TEST_ROOT/collected" >/dev/null
CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" authorize-grade --run-id "$RUN_ID" >/dev/null
[ "$(cat "$TEST_ROOT/collected/smoke/proof.txt")" = collected-via-designated-host ] \
  || { printf 'Collected answer differs from the designated-host write\n' >&2; exit 1; }

CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" cleanup --run-id "$RUN_ID" >/dev/null
docker network inspect "$network_id" >/dev/null \
  || { printf 'Supervisor removed the external KIND network\n' >&2; exit 1; }

trap - EXIT
case "$TEST_ROOT" in /tmp/cka-ssh-runner-docker.*) rm -rf -- "$TEST_ROOT" ;; esac
printf 'PASS: full supervised KIND/input/SSH/collect/authorize/cleanup smoke\n'
