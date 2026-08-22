#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERVISOR="$ROOT/exam/ssh/supervisor/supervisor.py"
RUNNER="$ROOT/exam/supervised-exam.sh"
FAKE_SOURCE="$ROOT/tests/ssh-runner-fake-engine.py"
PYTHON="${PYTHON:-python3}"
TEST_ROOT="$(mktemp -d /tmp/cka-ssh-runner-test.XXXXXXXX)"
case "$TEST_ROOT" in /tmp/cka-ssh-runner-test.*) ;; *) printf 'unsafe test root\n' >&2; exit 1 ;; esac
cleanup() {
  case "$TEST_ROOT" in
    /tmp/cka-ssh-runner-test.*)
      # The fixture intentionally creates 0500/0400 immutable snapshots.
      # Restore owner write permission only inside the validated test root.
      chmod -R u+w -- "$TEST_ROOT" 2>/dev/null || true
      rm -rf -- "$TEST_ROOT"
      ;;
  esac
}
trap cleanup EXIT
install -m 0700 "$FAKE_SOURCE" "$TEST_ROOT/fake-engine"
FAKE="$TEST_ROOT/fake-engine"
PASS=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok %d - %s\n' "$((PASS + 1))" "$1" >&2; exit 1; }

new_case() {
  local name="$1" path
  path="$TEST_ROOT/$name"
  install -d -m 0700 "$path" "$path/state" "$path/work" "$path/work/ts-01"
  printf '%s\n' 'apiVersion: v1' 'kind: Config' > "$path/kubeconfig.yaml"
  printf '%s\n' 'trusted input' > "$path/work/ts-01/in.txt"
  printf '{"schema_version":1,"active_question":"ts-01","questions":[{"question_id":"ts-01","kubeconfig":"%s","work_root":"%s"}]}\n' \
    "$path/kubeconfig.yaml" "$path/work/ts-01" > "$path/input.json"
  printf '%s\n' "$path"
}

sup() {
  local case_root="$1"; shift
  FAKE_ENGINE_DB="$case_root/engine.json" "$PYTHON" "$SUPERVISOR" "$@" --state-root "$case_root/state"
}
fake() { local case_root="$1"; shift; FAKE_ENGINE_DB="$case_root/engine.json" "$FAKE" "$@"; }
field() {
  "$PYTHON" - "$1" "$2" <<'PY'
import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8"))
for key in sys.argv[2].split("."): v=v[key]
print(str(v).lower() if isinstance(v,bool) else v)
PY
}
external_network() { fake "$1" network create --driver bridge "kind-$2"; }
prepare_form() {
  local case_root="$1" run_id="$2" network_id="$3" duration="${4:-60}"
  sup "$case_root" prepare --run-id "$run_id" --engine "$FAKE" --duration-seconds "$duration" \
    --engine-timeout-seconds 2 --base-image fake/base:1 --target-image fake/target:1 \
    --input-manifest "$case_root/input.json" --external-network-id "$network_id" --answer ts-01:answer.txt
}
timer_ready() {
  local case_root="$1" run_id="$2" manifest nonce unit
  manifest="$case_root/state/runs/$run_id/manifest.json"
  nonce="$(field "$manifest" run_nonce)"; unit="cka-ssh-deadline-${run_id}-${nonce:0:12}.timer"
  sup "$case_root" timer-ready --run-id "$run_id" --unit "$unit" --systemctl "$FAKE" >/dev/null
}
guard_ready() {
  local case_root="$1" run_id="$2" manifest nonce unit watcher ready=0
  timer_ready "$case_root" "$run_id"
  manifest="$case_root/state/runs/$run_id/manifest.json"; nonce="$(field "$manifest" run_nonce)"
  unit="cka-ssh-guard-${run_id}-${nonce:0:12}.service"
  sup "$case_root" watch --run-id "$run_id" --engine "$FAKE" --unit "$unit" >/dev/null 2>&1 & watcher=$!
  for _attempt in $(seq 1 100); do
    if sup "$case_root" guard-ready --run-id "$run_id" --unit "$unit" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.02
  done
  kill "$watcher" >/dev/null 2>&1 || true; wait "$watcher" >/dev/null 2>&1 || true
  [ "$ready" -eq 1 ] || fail 'guard did not publish readiness'
}
activate_form() { guard_ready "$1" "$2"; sup "$1" activate --run-id "$2" --engine "$FAKE" >/dev/null; }

printf 'TAP version 13\n'

# The current grader references, per-question answer_files metadata, and
# immutable collection TSV must stay exact; the resulting gated form must be
# constructible without any disposable-cell question.
case_root="$(new_case gated-contract)"
bash "$ROOT/exam/ssh/gated-form.sh" --catalog-out "$case_root/catalog.tsv" >/dev/null
CKA_FORM_CATALOG="$case_root/catalog.tsv" bash "$ROOT/exam/planner.sh" --seed ssh-runner-contract \
  --questions-out "$case_root/questions" --setup-order-out "$case_root/setup-order" >/dev/null
bash "$ROOT/exam/ssh/gated-form.sh" --verify-form "$case_root/questions" >/dev/null
while IFS= read -r qid; do
  qdir="$(find "$ROOT/questions" -mindepth 2 -maxdepth 2 -type d -name "$qid" -print -quit)"
  environment="$(sed -n 's/^environment:[[:space:]]*//p' "$qdir/meta.yaml" | head -1)"
  [ -z "$environment" ] || [ "$environment" = shared-kind ] || fail "gated form selected disposable question $qid"
done < "$case_root/questions"
[ "$(grep -n '^ca-01$' "$case_root/setup-order" | cut -d: -f1)" -lt "$(grep -n '^ca-02$' "$case_root/setup-order" | cut -d: -f1)" ] \
  || fail 'gated RBAC setup order is unsafe'
ok 'grader/meta/answer allowlist exact-set builds a shared-kind-only 17-question form'

# The SSH prepare path uses the same managed-Pod boundary as the local mock:
# mirror Pods and controller-owned Pods are safe, but a pre-existing ownerless
# Pod on a selected drain node makes the run INVALID before setup/session work.
case_root="$(new_case runtime-baseline-unmanaged)"
install -d -m 0700 "$case_root/run" "$case_root/run/logs"
printf 'ca-05\n' > "$case_root/run/questions"
cat > "$case_root/pods.json" <<'JSON'
{"items":[
  {"metadata":{"namespace":"kube-system","name":"kube-proxy","ownerReferences":[{"controller":true}]}},
  {"metadata":{"namespace":"default","name":"foreign-ownerless"}}
]}
JSON
set +e
CKA_SSH_RUNNER_SOURCE_ONLY=1 RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
  source "$RUNNER_UNDER_TEST"
  RUN_ID=runtime-baseline-unmanaged; RUN_DIR="$CASE_ROOT/run"; CKA_CLUSTER_NAME=cka
  kctx(){ cat "$CASE_ROOT/pods.json"; }
  runner_status_write(){ printf "%s|%s\n" "$1" "$2" > "$RUN_DIR/status"; }
  cleanup_selected_questions(){ : > "$CASE_ROOT/cleanup-called"; }
  runner_require_safe_runtime_baseline "$RUN_DIR/questions" before-setup
' > "$case_root/output" 2>&1
runtime_rc=$?
set -e
[ "$runtime_rc" -ne 0 ] || fail 'ownerless Pod baseline was accepted'
grep -q '^INVALID|unsafe shared cluster runtime baseline (before-setup)$' "$case_root/run/status" \
  || fail 'ownerless Pod baseline did not make prepare INVALID'
grep -q 'unmanaged Pods: default/foreign-ownerless' "$case_root/run/logs/runtime-baseline-before-setup.log" \
  || fail 'ownerless Pod diagnostic evidence was not preserved'
[ ! -e "$case_root/cleanup-called" ] || fail 'pre-setup baseline refusal ran question cleanup'
[ ! -e "$case_root/session-called" ] || fail 'pre-setup baseline refusal started a session'
ok 'prepare refuses an ownerless drain-node Pod as INVALID before setup/session'

# A clean baseline allows both system mirror Pods and controller-managed
# candidate workloads. Rechecking after setup still passes and does not alter
# the runner status.
case_root="$(new_case runtime-baseline-managed)"
install -d -m 0700 "$case_root/run" "$case_root/run/logs"
printf 'ca-05\n' > "$case_root/run/questions"
cat > "$case_root/pods.json" <<'JSON'
{"items":[
  {"metadata":{"namespace":"kube-system","name":"kube-apiserver","annotations":{"kubernetes.io/config.mirror":"hash"}}},
  {"metadata":{"namespace":"upkeep","name":"maintenance-app-abc","ownerReferences":[{"controller":true}]}}
]}
JSON
CKA_SSH_RUNNER_SOURCE_ONLY=1 RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
  source "$RUNNER_UNDER_TEST"
  RUN_ID=runtime-baseline-managed; RUN_DIR="$CASE_ROOT/run"; CKA_CLUSTER_NAME=cka
  kctx(){ cat "$CASE_ROOT/pods.json"; }
  runner_status_write(){ : > "$CASE_ROOT/status-called"; }
  cleanup_selected_questions(){ : > "$CASE_ROOT/cleanup-called"; }
  runner_require_safe_runtime_baseline "$RUN_DIR/questions" before-setup
  runner_require_safe_runtime_baseline "$RUN_DIR/questions" after-setup
' >/dev/null
[ ! -e "$case_root/status-called" ] || fail 'clean managed-Pod baseline changed runner status'
[ ! -e "$case_root/cleanup-called" ] || fail 'clean managed-Pod baseline ran cleanup'
ok 'prepare accepts mirror and controller-owned Pods before and after setup'

# A non-file question setup commonly calls cleanup_question, which removes its
# empty work directory. Before freezing the input manifest the runner must
# safely recreate only that missing directory while preserving existing file
# inputs for other questions.
case_root="$(new_case work-root-materialization)"
install -d -m 0700 "$case_root/run/work/ts-02"
printf 'ts-01\nts-02\n' > "$case_root/run/questions"
printf 'keep\n' > "$case_root/run/work/ts-02/input.txt"
rm -rf -- "$case_root/run/work/ts-01"
CKA_SSH_RUNNER_SOURCE_ONLY=1 RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
  source "$RUNNER_UNDER_TEST"
  RUN_ID=work-root-materialization; RUN_DIR="$CASE_ROOT/run"
  runner_materialize_work_roots "$RUN_DIR/questions"
' || fail 'missing question work root was not safely recreated'
[ -d "$case_root/run/work/ts-01" ] && [ ! -L "$case_root/run/work/ts-01" ] \
  || fail 'materialized work root is absent or linked'
[ "$(stat -c %a "$case_root/run/work/ts-01")" = 700 ] \
  || fail 'materialized work root permissions are not private'
[ "$(cat "$case_root/run/work/ts-02/input.txt")" = keep ] \
  || fail 'existing question work input was modified'
ok 'prepare rematerializes setup-removed work roots without changing existing inputs'

case_root="$(new_case work-root-symlink)"
install -d -m 0700 "$case_root/run/work" "$case_root/outside"
printf 'outside-safe\n' > "$case_root/outside/sentinel"
printf 'ts-01\n' > "$case_root/run/questions"
rm -rf -- "$case_root/run/work/ts-01"
ln -s "$case_root/outside" "$case_root/run/work/ts-01"
set +e
CKA_SSH_RUNNER_SOURCE_ONLY=1 RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
  source "$RUNNER_UNDER_TEST"
  RUN_ID=work-root-symlink; RUN_DIR="$CASE_ROOT/run"
  runner_materialize_work_roots "$RUN_DIR/questions"
' >/dev/null 2>&1
work_link_rc=$?
set -e
[ "$work_link_rc" -ne 0 ] || fail 'linked question work root was accepted'
[ "$(cat "$case_root/outside/sentinel")" = outside-safe ] \
  || fail 'linked work-root refusal modified the external target'
grep -Fq '"work_root":os.path.join(sys.argv[3],q)' "$RUNNER" \
  || fail 'input manifest rewrites the validated exact work-root path'
ok 'prepare rejects linked work roots and records exact validated paths'

# If the post-setup recheck detects a late ownerless Pod, the run remains
# INVALID, exact question cleanup is attempted, and the evidence is retained.
case_root="$(new_case runtime-baseline-late-unmanaged)"
install -d -m 0700 "$case_root/run" "$case_root/run/logs"
printf 'ca-05\n' > "$case_root/run/questions"
printf '{"items":[{"metadata":{"namespace":"late","name":"ownerless"}}]}\n' > "$case_root/pods.json"
set +e
CKA_SSH_RUNNER_SOURCE_ONLY=1 RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
  source "$RUNNER_UNDER_TEST"
  RUN_ID=runtime-baseline-late-unmanaged; RUN_DIR="$CASE_ROOT/run"; CKA_CLUSTER_NAME=cka
  kctx(){ cat "$CASE_ROOT/pods.json"; }
  runner_status_write(){ printf "%s|%s\n" "$1" "$2" > "$RUN_DIR/status"; }
  cleanup_selected_questions(){ : > "$CASE_ROOT/cleanup-called"; }
  runner_require_safe_runtime_baseline "$RUN_DIR/questions" after-setup
' >/dev/null 2>&1
late_runtime_rc=$?
set -e
[ "$late_runtime_rc" -ne 0 ] || fail 'late ownerless Pod baseline was accepted'
grep -q '^INVALID|unsafe shared cluster runtime baseline (after-setup)$' "$case_root/run/status" \
  || fail 'late ownerless Pod did not make prepare INVALID'
[ -e "$case_root/cleanup-called" ] || fail 'post-setup baseline refusal skipped question cleanup'
grep -q 'unmanaged Pods: late/ownerless' "$case_root/run/logs/runtime-baseline-after-setup.log" \
  || fail 'late ownerless Pod evidence was not preserved'
ok 'post-setup ownerless Pod invalidates prepare, cleans setup, and preserves evidence'

# Setup-time evidence is snapshotted outside the candidate input tree and is
# materialized read-only into a fresh final-grader state root.  Preflight status
# is intentionally not copied into final grading.
case_root="$(new_case trusted-state)"
install -d -m 0700 "$case_root/run" "$case_root/run/grader-state" \
  "$case_root/run/grader-state/question-data" "$case_root/run/grader-state/question-data/ts-01" \
  "$case_root/run/grader-state/status"
printf 'ts-01\n' > "$case_root/run/questions"
printf 'baseline-v1\n' > "$case_root/run/grader-state/question-data/ts-01/baseline"
printf 'graded:0/10\n' > "$case_root/run/grader-state/status/ts-01"
CKA_SSH_RUNNER_SOURCE_ONLY=1 RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
  source "$RUNNER_UNDER_TEST"
  RUN_ID=trusted-state; RUN_DIR="$CASE_ROOT/run"
  runner_trusted_state_snapshot
  chmod 0400 "$RUN_DIR/questions"
  digest="$(sha256sum "$RUN_DIR/trusted-state-manifest.json")"; digest="${digest%% *}"
  runner_trusted_state_verify "$digest"
  runner_trusted_state_materialize "$digest"
' >/dev/null
[ "$(stat -c %a "$case_root/run/grader-final/question-data/ts-01/baseline")" = 400 ] \
  || fail 'final baseline was not read-only'
[ "$(cat "$case_root/run/grader-final/question-data/ts-01/baseline")" = baseline-v1 ] \
  || fail 'final baseline differs from setup evidence'
[ ! -e "$case_root/run/grader-final/status" ] || fail 'preflight status leaked into final grader state'
install -d -m 0700 "$case_root/run/grader-final/status" \
  || fail 'separate final status path is not writable'
ok 'trusted setup evidence is plan-ready, candidate-separated, and materialized read-only'

# The manifest is bound to both run ID and exact form, and protected bytes are
# checked again rather than trusting path names or permissions alone.
digest="$(sha256sum "$case_root/run/trusted-state-manifest.json")"; digest="${digest%% *}"
if CKA_SSH_RUNNER_SOURCE_ONLY=1 RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" DIGEST="$digest" bash -c '
  source "$RUNNER_UNDER_TEST"
  RUN_ID=another-run; RUN_DIR="$CASE_ROOT/run"
  runner_trusted_state_verify "$DIGEST"
' >/dev/null 2>&1; then fail 'cross-run trusted manifest was accepted'; fi
chmod 0600 "$case_root/run/trusted-state/question-data/ts-01/baseline"
printf 'attacker\n' >> "$case_root/run/trusted-state/question-data/ts-01/baseline"
if CKA_SSH_RUNNER_SOURCE_ONLY=1 RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" DIGEST="$digest" bash -c '
  source "$RUNNER_UNDER_TEST"
  RUN_ID=trusted-state; RUN_DIR="$CASE_ROOT/run"
  runner_trusted_state_verify "$DIGEST"
' >/dev/null 2>&1; then fail 'tampered trusted snapshot was accepted'; fi
ok 'trusted evidence rejects cross-run reuse and byte/mode tamper'

# A symlink anywhere under setup question-data is rejected before a snapshot or
# manifest is allocated.
case_root="$(new_case trusted-symlink)"
install -d -m 0700 "$case_root/run" "$case_root/run/grader-state" \
  "$case_root/run/grader-state/question-data" "$case_root/outside"
printf 'ts-01\n' > "$case_root/run/questions"
printf 'outside\n' > "$case_root/outside/baseline"
ln -s "$case_root/outside" "$case_root/run/grader-state/question-data/ts-01"
if CKA_SSH_RUNNER_SOURCE_ONLY=1 RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
  source "$RUNNER_UNDER_TEST"
  RUN_ID=trusted-symlink; RUN_DIR="$CASE_ROOT/run"
  runner_trusted_state_snapshot
' >/dev/null 2>&1; then fail 'symlinked setup evidence was accepted'; fi
[ ! -e "$case_root/run/trusted-state" ] && [ ! -e "$case_root/run/trusted-state-manifest.json" ] \
  || fail 'rejected symlink left an apparently valid trusted snapshot'
ok 'trusted evidence rejects symlink substitution before allocation'

# A non-canonical kubeconfig path is rejected before any object allocation.
case_root="$(new_case traversal)"; network_id="$(external_network "$case_root" traversal)"
printf '{"schema_version":1,"active_question":"ts-01","questions":[{"question_id":"ts-01","kubeconfig":"%s/../traversal/kubeconfig.yaml","work_root":"%s/work/ts-01"}]}\n' \
  "$case_root" "$case_root" > "$case_root/input.json"
if prepare_form "$case_root" traversal "$network_id" >/dev/null 2>&1; then fail 'kubeconfig traversal was accepted'; fi
container_count="$(FAKE_ENGINE_DB="$case_root/engine.json" "$PYTHON" -c 'import json,os; print(len(json.load(open(os.environ["FAKE_ENGINE_DB"]))["containers"]))')"
[ "$container_count" -eq 0 ] || fail 'traversal rejection allocated candidate containers'
ok 'kubeconfig traversal fails before object allocation'

# Inputs are copied while stopped; an activation attempt without timer/guard
# proof cannot race ahead and start either candidate container.
case_root="$(new_case activation-race)"; network_id="$(external_network "$case_root" race)"
prepare_form "$case_root" activation-race "$network_id" >/dev/null
if sup "$case_root" activate --run-id activation-race --engine "$FAKE" >/dev/null 2>&1; then fail 'activation bypassed timer/guard proof'; fi
FAKE_ENGINE_DB="$case_root/engine.json" "$PYTHON" - <<'PY' || fail 'input copy did not precede every start operation'
import json,os
log=json.load(open(os.environ["FAKE_ENGINE_DB"]))["log"]
cp=[i for i,e in enumerate(log) if e["argv"][:3]==["container","cp","-"]]
starts=[i for i,e in enumerate(log) if e["argv"][:2]==["container","start"]]
if len(cp)!=1 or starts: raise SystemExit(1)
PY
ok 'activation is closed until immutable inputs and both supervisor proofs exist'

# If the independent sealer arrives while the base start command is in flight,
# the narrow seal lock makes start finish before proof creation; the sealer then
# stops both IDs. A base process can therefore never land after seal proof.
case_root="$(new_case seal-start-race)"; network_id="$(external_network "$case_root" sealrace)"
prepare_form "$case_root" seal-start-race "$network_id" >/dev/null; guard_ready "$case_root" seal-start-race
manifest="$case_root/state/runs/seal-start-race/manifest.json"; base_id="$(field "$manifest" objects.base.id)"
set +e
FAKE_ENGINE_DELAY_MATCH="container start $base_id" FAKE_ENGINE_DELAY_SECONDS=1 \
  sup "$case_root" activate --run-id seal-start-race --engine "$FAKE" >/dev/null 2>&1 & activator=$!
sleep 0.2
sup "$case_root" seal --run-id seal-start-race --engine "$FAKE" --reason manual >/dev/null 2>&1; seal_rc=$?
wait "$activator"; activation_rc=$?
set -e
[ "$seal_rc" -eq 0 ] || fail 'concurrent sealer could not prove stopped objects'
FAKE_ENGINE_DB="$case_root/engine.json" BASE_ID="$base_id" "$PYTHON" - <<'PY' || fail 'base remained running or started after concurrent seal'
import json,os
db=json.load(open(os.environ["FAKE_ENGINE_DB"])); base=db["containers"][os.environ["BASE_ID"]]
if base["State"]["Running"]: raise SystemExit(1)
log=db["log"]
starts=[i for i,e in enumerate(log) if e["argv"][:3]==["container","start",os.environ["BASE_ID"]]]
stops=[i for i,e in enumerate(log) if e["argv"][:2]==["container","stop"] and e["argv"][-1]==os.environ["BASE_ID"]]
if len(starts)>1 or (starts and (not stops or starts[0] > stops[-1])): raise SystemExit(1)
PY
ok 'concurrent seal cannot be followed by a late base-container start'

# Protected input bytes are checked after target start but before base access.
case_root="$(new_case input-tamper)"; network_id="$(external_network "$case_root" tamper)"
prepare_form "$case_root" input-tamper "$network_id" >/dev/null
target_id="$(field "$case_root/state/runs/input-tamper/manifest.json" objects.target.id)"
fake "$case_root" debug put-file "$target_id" /home/candidate/.kube/config attacker >/dev/null
guard_ready "$case_root" input-tamper
if sup "$case_root" activate --run-id input-tamper --engine "$FAKE" >/dev/null 2>&1; then fail 'tampered input activated'; fi
if sup "$case_root" authorize-grade --run-id input-tamper --engine "$FAKE" >/dev/null 2>&1; then fail 'tampered input authorized grading'; fi
grep -F '"event":"activation-failed"' "$case_root/state/runs/input-tamper/audit.jsonl" >/dev/null \
  || fail 'activation failure did not persist diagnostic audit evidence'
ok 'input tamper before activation permanently blocks grading'

# Replacing the recorded external attachment with a different network fails
# the exact-ID topology audit; cleanup must never remove either external net.
case_root="$(new_case network-swap)"; network_id="$(external_network "$case_root" original)"; decoy_id="$(external_network "$case_root" decoy)"
prepare_form "$case_root" network-swap "$network_id" >/dev/null
target_id="$(field "$case_root/state/runs/network-swap/manifest.json" objects.target.id)"
fake "$case_root" network disconnect "$network_id" "$target_id" >/dev/null
fake "$case_root" network connect "$decoy_id" "$target_id" >/dev/null
timer_ready "$case_root" network-swap
nonce="$(field "$case_root/state/runs/network-swap/manifest.json" run_nonce)"
unit="cka-ssh-guard-network-swap-${nonce:0:12}.service"
if sup "$case_root" watch --run-id network-swap --engine "$FAKE" --unit "$unit" >/dev/null 2>&1; then fail 'external-network swap passed guard audit'; fi
sup "$case_root" seal --run-id network-swap --engine "$FAKE" --reason activation-failure >/dev/null 2>&1 || true
if sup "$case_root" authorize-grade --run-id network-swap --engine "$FAKE" >/dev/null 2>&1; then fail 'external-network swap authorized grading'; fi
fake "$case_root" network inspect "$network_id" >/dev/null || fail 'supervisor removed the recorded external network'
fake "$case_root" network inspect "$decoy_id" >/dev/null || fail 'supervisor removed an unowned external network'
ok 'external-network swap is INVALID and external networks are never deletion targets'

# A foreign, unlabeled endpoint is invisible to label-based container lists but
# must still invalidate the exact internal network endpoint set.
case_root="$(new_case endpoint-decoy)"; network_id="$(external_network "$case_root" endpoint)"
prepare_form "$case_root" endpoint-decoy "$network_id" >/dev/null
run_network_id="$(field "$case_root/state/runs/endpoint-decoy/manifest.json" objects.network.id)"
decoy_id="$(fake "$case_root" container create --name foreign --hostname foreign --network "$run_network_id" fake/base:1)"
fake "$case_root" container start "$decoy_id" >/dev/null
timer_ready "$case_root" endpoint-decoy
nonce="$(field "$case_root/state/runs/endpoint-decoy/manifest.json" run_nonce)"
unit="cka-ssh-guard-endpoint-decoy-${nonce:0:12}.service"
if sup "$case_root" watch --run-id endpoint-decoy --engine "$FAKE" --unit "$unit" >/dev/null 2>&1; then
  fail 'unlabeled internal-network endpoint passed the guard audit'
fi
sup "$case_root" seal --run-id endpoint-decoy --engine "$FAKE" --reason activation-failure >/dev/null 2>&1 || true
decoy_running="$(FAKE_ENGINE_DB="$case_root/engine.json" DECOY_ID="$decoy_id" "$PYTHON" -c 'import json,os; print(str(json.load(open(os.environ["FAKE_ENGINE_DB"]))["containers"][os.environ["DECOY_ID"]]["State"]["Running"]).lower())')"
[ "$decoy_running" = true ] || fail 'supervisor operated on an unlabeled non-manifest endpoint'
if sup "$case_root" authorize-grade --run-id endpoint-decoy --engine "$FAKE" >/dev/null 2>&1; then
  fail 'unlabeled internal-network endpoint authorized grading'
fi
ok 'internal run network requires the exact target/base endpoint ID set'

# A manual/operator action at the immutable boundary is normalized to deadline
# provenance, so a timer race cannot retain a PASS-eligible manual reason.
case_root="$(new_case manual-boundary)"; network_id="$(external_network "$case_root" boundary)"
prepare_form "$case_root" manual-boundary "$network_id" 5 >/dev/null
manifest="$case_root/state/runs/manual-boundary/manifest.json"; deadline="$(field "$manifest" deadline_epoch)"
while [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.05; done
seal_json="$(sup "$case_root" seal --run-id manual-boundary --engine "$FAKE" --reason manual)" \
  || fail 'boundary seal was not valid'
[ "$(printf '%s' "$seal_json" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["reason"])')" = deadline ] \
  || fail 'at-deadline manual seal retained manual provenance'
auth_json="$(sup "$case_root" authorize-grade --run-id manual-boundary --engine "$FAKE")" \
  || fail 'deadline-normalized diagnostic grade was not authorized'
[ "$(printf '%s' "$auth_json" | "$PYTHON" -c 'import json,sys; print(str(json.load(sys.stdin)["deadline_enforced"]).lower())')" = true ] \
  || fail 'deadline-normalized authorization lost deadline provenance'
ok 'manual seal at/after deadline is immutable deadline provenance'

# The cutoff timestamp, not merely lock acquisition, determines deadline
# provenance.  Here manual seal starts before the boundary while the exact
# base stop is deliberately delayed until after it.
case_root="$(new_case delayed-manual-boundary)"; network_id="$(external_network "$case_root" delayed-boundary)"
prepare_form "$case_root" delayed-manual-boundary "$network_id" 6 >/dev/null
activate_form "$case_root" delayed-manual-boundary
manifest="$case_root/state/runs/delayed-manual-boundary/manifest.json"
deadline="$(field "$manifest" deadline_epoch)"; base_id="$(field "$manifest" objects.base.id)"
while [ "$(date +%s)" -lt "$((deadline - 1))" ]; do sleep 0.05; done
[ "$(date +%s)" -lt "$deadline" ] || fail 'delayed boundary fixture did not begin before deadline'
seal_json="$(FAKE_ENGINE_DELAY_MATCH="container stop --time 0 $base_id" FAKE_ENGINE_DELAY_SECONDS=1.1 \
  sup "$case_root" seal --run-id delayed-manual-boundary --engine "$FAKE" --reason manual)" \
  || fail 'delayed boundary seal was not valid'
[ "$(printf '%s' "$seal_json" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["reason"])')" = deadline ] \
  || fail 'pre-deadline manual request retained manual provenance after cutoff crossed deadline'
sealed_at="$(printf '%s' "$seal_json" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["sealed_at_epoch"])')"
[ "$sealed_at" -ge "$deadline" ] || fail 'delayed boundary fixture did not cross the immutable deadline'
ok 'seal completion crossing deadline cannot retain PASS-eligible manual provenance'

# candidate-entry exposes only the manifest base ID and re-inspects that exact
# object's image, labels, attachments, running state, deadline, and seal gate.
case_root="$(new_case candidate-entry)"; network_id="$(external_network "$case_root" entry)"
prepare_form "$case_root" candidate-entry "$network_id" >/dev/null; activate_form "$case_root" candidate-entry
manifest="$case_root/state/runs/candidate-entry/manifest.json"; base_id="$(field "$manifest" objects.base.id)"
entry_id="$(sup "$case_root" candidate-entry --run-id candidate-entry --engine "$FAKE" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["base_container_id"])')"
[ "$entry_id" = "$base_id" ] || fail 'candidate entry returned a non-manifest base identity'
fake "$case_root" debug mutate-label "$base_id" org.cka-practice.ssh-supervisor.nonce "$(printf '0%.0s' {1..64})"
if sup "$case_root" candidate-entry --run-id candidate-entry --engine "$FAKE" >/dev/null 2>&1; then
  fail 'candidate entry accepted a changed exact-ID identity'
fi
ok 'candidate entry returns and revalidates only the exact manifest base ID'

# A premature user transition must not overwrite RUNNING. Cleanup still seals
# and removes the exact manifest IDs, while preserving the external KIND net.
case_root="$(new_case transition-cleanup)"; network_id="$(external_network "$case_root" transition)"
prepare_form "$case_root" transition-cleanup "$network_id" >/dev/null; activate_form "$case_root" transition-cleanup
mkdir -p "$case_root/runner/run/logs" "$case_root/runner/run/work" "$case_root/runner/state"
printf '\n' > "$case_root/runner/run/questions"
printf 'RUNNING|fixture\n' > "$case_root/runner/run/status"
printf 'transition-cleanup\n' > "$case_root/runner/state/active"
set +e
FAKE_ENGINE_DB="$case_root/engine.json" CKA_SSH_RUNNER_SOURCE_ONLY=1 CKA_SSH_ENGINE="$FAKE" \
  CKA_SSH_SUPERVISOR_STATE_ROOT="$case_root/state" CKA_SSH_RUNNER_STATE_ROOT="$case_root/runner/state" \
  RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
    source "$RUNNER_UNDER_TEST"
    load_run(){ RUN_ID=transition-cleanup; RUN_DIR="$CASE_ROOT/runner/run"; STATUS_PHASE="${STATUS_PHASE_OVERRIDE:-RUNNING}"; }
    cmd_grade
  ' >/dev/null 2>&1
premature_rc=$?
set -e
[ "$premature_rc" -ne 0 ] || fail 'premature grade unexpectedly succeeded'
[ "$(cut -d'|' -f1 "$case_root/runner/run/status")" = RUNNING ] || fail 'premature grade overwrote RUNNING state'
set +e
FAKE_ENGINE_DB="$case_root/engine.json" CKA_SSH_RUNNER_SOURCE_ONLY=1 CKA_SSH_ENGINE="$FAKE" \
  CKA_SSH_SUPERVISOR_STATE_ROOT="$case_root/state" CKA_SSH_RUNNER_STATE_ROOT="$case_root/runner/state" \
  RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
    source "$RUNNER_UNDER_TEST"
    load_run(){ RUN_ID=transition-cleanup; RUN_DIR="$CASE_ROOT/runner/run"; STATUS_PHASE=RUNNING; }
    cmd_cleanup
  ' > "$case_root/cleanup-output" 2>&1
cleanup_rc=$?
set -e
if [ "$cleanup_rc" -ne 0 ]; then
  cat "$case_root/cleanup-output" >&2
  cat "$case_root/runner/run/cleanup.log" >&2 2>/dev/null || true
  fail 'RUNNING cleanup command failed'
fi
FAKE_ENGINE_DB="$case_root/engine.json" EXTERNAL_ID="$network_id" "$PYTHON" - <<'PY' \
  || fail 'cleanup did not remove exact supervised IDs while preserving the external network'
import json,os
db=json.load(open(os.environ["FAKE_ENGINE_DB"]))
if db["containers"] or os.environ["EXTERNAL_ID"] not in db["networks"] or len(db["networks"]) != 1: raise SystemExit(1)
PY
ok 'invalid user transition preserves RUNNING so cleanup seals/removes exact IDs'

# Runner must not reach even the first host grader when authorization fails.
case_root="$(new_case grade-gate)"; mkdir -p "$case_root/run/collected"; printf 'ts-01\n' > "$case_root/run/questions"
cat > "$case_root/fail-session" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = authorize-grade ] && exit 73
exit 99
SH
chmod 0700 "$case_root/fail-session"
set +e
CKA_SSH_RUNNER_SOURCE_ONLY=1 CKA_SSH_SESSION_SCRIPT="$case_root/fail-session" \
  RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
    source "$RUNNER_UNDER_TEST"
    load_run(){ RUN_ID=grade-gate; RUN_DIR="$CASE_ROOT/run"; STATUS_PHASE=COLLECTED; }
    runner_status_write(){ printf "%s" "$1" > "$CASE_ROOT/status-called"; }
    question_dir(){ : > "$CASE_ROOT/grader-called"; return 1; }
    cmd_grade
  ' >/dev/null 2>&1
gate_rc=$?
set -e
[ "$gate_rc" -ne 0 ] || fail 'authorization failure returned success'
[ ! -e "$case_root/grader-called" ] || fail 'host grader was reached without authorization'
[ "$(cat "$case_root/status-called")" = INVALID ] || fail 'authorization failure did not invalidate runner'
ok 'host grader is unreachable until authorize-grade succeeds'

# Deadline provenance permits diagnostic grading but can never result in PASS,
# even when the real runner parses a host grader's perfect score.
case_root="$(new_case timeout-verdict)"; mkdir -p "$case_root/run/collected" "$case_root/run/logs" "$case_root/question"
printf 'ts-01\n' > "$case_root/run/questions"
printf 'id: ts-01\ntitle: timeout fixture\ndomain: troubleshooting\npoints: 10\nminutes: 1\n' > "$case_root/question/meta.yaml"
cat > "$case_root/question/grade.sh" <<'SH'
#!/usr/bin/env bash
set -eu
mkdir -p "$CKA_STATE_DIR/status"
printf 'graded:10/10' > "$CKA_STATE_DIR/status/ts-01"
SH
chmod 0700 "$case_root/question/grade.sh"
cat > "$case_root/deadline-session" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = authorize-grade ]; then
  printf '%s\n' '{"run_id":"timeout","operation":"grade","seal_reason":"deadline","sealed_at_epoch":101,"deadline_epoch":100,"deadline_enforced":true,"manifest_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","seal_proof_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
  exit 0
fi
exit 99
SH
chmod 0700 "$case_root/deadline-session"
CKA_SSH_RUNNER_SOURCE_ONLY=1 CKA_SSH_SESSION_SCRIPT="$case_root/deadline-session" \
  RUNNER_UNDER_TEST="$RUNNER" CASE_ROOT="$case_root" bash -c '
    source "$RUNNER_UNDER_TEST"
    load_run(){ RUN_ID=timeout; RUN_DIR="$CASE_ROOT/run"; STATUS_PHASE=COLLECTED; }
    runner_status_write(){ STATUS_PHASE="$1"; printf "%s" "$1" > "$CASE_ROOT/runner-phase"; }
    question_dir(){ printf "%s\n" "$CASE_ROOT/question"; }
    plan_value(){ printf "%064d\n" 0; }
    runner_trusted_state_materialize(){ mkdir -p "$RUN_DIR/grader-final"; chmod 0700 "$RUN_DIR/grader-final"; }
    cmd_grade
  ' > "$case_root/grade-output"
grep -q '100%.*TIMEOUT' "$case_root/run/score.txt" || fail 'deadline perfect score was not reported TIMEOUT'
! grep -q -- '— PASS' "$case_root/run/score.txt" || fail 'deadline perfect score was reported PASS'
[ "$(cat "$case_root/runner-phase")" = GRADED ] || fail 'deadline diagnostic grading did not complete'
ok 'deadline-sealed perfect diagnostic score remains TIMEOUT/non-pass'

printf '1..%d\n' "$PASS"
