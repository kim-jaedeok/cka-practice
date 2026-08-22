#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERVISOR="$ROOT/exam/ssh/supervisor/supervisor.py"
FAKE_SOURCE="$ROOT/tests/ssh-supervisor-fake-engine.py"
PYTHON="${PYTHON:-python3}"
TEST_ROOT="$(mktemp -d /tmp/cka-ssh-supervisor-test.XXXXXXXX)"

case "$TEST_ROOT" in /tmp/cka-ssh-supervisor-test.*) ;; *) printf 'unsafe test root\n' >&2; exit 1 ;; esac
cleanup() {
  case "$TEST_ROOT" in /tmp/cka-ssh-supervisor-test.*) rm -rf -- "$TEST_ROOT" ;; esac
}
trap cleanup EXIT

install -m 0700 "$FAKE_SOURCE" "$TEST_ROOT/fake-engine"
FAKE="$TEST_ROOT/fake-engine"
PASS=0

ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok %d - %s\n' "$((PASS + 1))" "$1" >&2; exit 1; }

new_case() {
  local name="$1"
  local path="$TEST_ROOT/$name"
  install -d -m 0700 "$path" "$path/state"
  printf '%s\n' "$path"
}

sup() {
  local case_root="$1"; shift
  FAKE_ENGINE_DB="$case_root/engine.json" "$PYTHON" "$SUPERVISOR" "$@" \
    --state-root "$case_root/state"
}

fake() {
  local case_root="$1"; shift
  FAKE_ENGINE_DB="$case_root/engine.json" "$FAKE" "$@"
}

json_file() {
  local path="$1" expression="$2"
  "$PYTHON" - "$path" "$expression" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2].split("."):
    value = value[key]
if isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
PY
}

prepare() {
  local case_root="$1" run_id="$2" duration="$3" timeout="${4:-1}"
  shift 4 2>/dev/null || true
  sup "$case_root" prepare --run-id "$run_id" --engine "$FAKE" \
    --duration-seconds "$duration" --engine-timeout-seconds "$timeout" \
    --base-image fake/base:1 --target-image fake/target:1 "$@"
}

timer_ready() {
  local case_root="$1" run_id="$2" manifest="$case_root/state/runs/$run_id/manifest.json" nonce unit
  nonce="$(json_file "$manifest" run_nonce)"
  unit="cka-ssh-deadline-${run_id}-${nonce:0:12}.timer"
  sup "$case_root" timer-ready --run-id "$run_id" --unit "$unit" --systemctl "$FAKE" >/dev/null
}

activate() {
  local case_root="$1" run_id="$2" manifest nonce unit watcher ready
  timer_ready "$case_root" "$run_id"
  manifest="$case_root/state/runs/$run_id/manifest.json"
  nonce="$(json_file "$manifest" run_nonce)"
  unit="cka-ssh-guard-${run_id}-${nonce:0:12}.service"
  sup "$case_root" watch --run-id "$run_id" --engine "$FAKE" --unit "$unit" >/dev/null 2>&1 & watcher=$!
  ready=0
  for _attempt in $(seq 1 50); do
    if sup "$case_root" guard-ready --run-id "$run_id" --unit "$unit" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.02
  done
  [ "$ready" -eq 1 ] || fail 'fake restartable guard did not publish readiness'
  kill "$watcher" >/dev/null 2>&1 || true
  wait "$watcher" >/dev/null 2>&1 || true
  sup "$case_root" activate --run-id "$run_id" --engine "$FAKE" >/dev/null
}

running() {
  local case_root="$1" object_id="$2"
  FAKE_ENGINE_DB="$case_root/engine.json" "$PYTHON" - "$object_id" <<'PY'
import json, os, sys
db = json.load(open(os.environ["FAKE_ENGINE_DB"], encoding="utf-8"))
print(str(db["containers"][sys.argv[1]]["State"]["Running"]).lower())
PY
}

printf 'TAP version 13\n'

# Stopped creation, immutable IDs, rename resistance, and valid seal.
case_root="$(new_case rename)"; run_id="rename"
prepare "$case_root" "$run_id" 30 1 >/dev/null
manifest="$case_root/state/runs/$run_id/manifest.json"
target_id="$(json_file "$manifest" objects.target.id)"; base_id="$(json_file "$manifest" objects.base.id)"
network_id="$(json_file "$manifest" objects.network.id)"
[ "${#target_id}" -eq 64 ] && [ "$(running "$case_root" "$target_id")" = false ] \
  && [ "$(running "$case_root" "$base_id")" = false ] || fail 'objects were not created stopped by full ID'
FAKE_ENGINE_DB="$case_root/engine.json" TARGET_ID="$target_id" BASE_ID="$base_id" NETWORK_ID="$network_id" \
  "$PYTHON" - <<'PY' || fail 'stopped create topology did not match Docker endpoint semantics'
import json, os
db = json.load(open(os.environ["FAKE_ENGINE_DB"], encoding="utf-8"))
network_id = os.environ["NETWORK_ID"]
network = db["networks"][network_id]
if network["Containers"]:
    raise SystemExit(1)
for object_id in (os.environ["TARGET_ID"], os.environ["BASE_ID"]):
    container = db["containers"][object_id]
    if container["HostConfig"]["NetworkMode"] != network_id:
        raise SystemExit(1)
    attachments = container["NetworkSettings"]["Networks"]
    if set(attachments) != {network["Name"]} or attachments[network["Name"]]["NetworkID"] != "":
        raise SystemExit(1)
PY
[ "$(stat -c '%a' "$manifest")" = 400 ] || fail 'manifest is not mode 0400'
activate "$case_root" "$run_id"
grep -F '"event":"target-host-bound"' "$case_root/state/runs/$run_id/audit.jsonl" >/dev/null \
  || fail 'activation did not audit the exact target-host binding'
FAKE_ENGINE_DB="$case_root/engine.json" "$PYTHON" - <<'PY' \
  || fail 'activation omitted target listener or exact base host-binding checks'
import json, os
log = json.load(open(os.environ["FAKE_ENGINE_DB"], encoding="utf-8"))["log"]
commands = [" ".join(entry["argv"]) for entry in log]
if not any("sport = :22" in command for command in commands):
    raise SystemExit(1)
if not any("/etc/hosts" in command and "cka-target" in command for command in commands):
    raise SystemExit(1)
keyscan = [entry["argv"] for entry in log if any("ssh-keyscan" in argument for argument in entry["argv"])]
if len(keyscan) != 1 or "-lc" in keyscan[0] or "-c" not in keyscan[0]:
    raise SystemExit(1)
keyscan_script = keyscan[0][-1]
if "for attempt in 1 2 3" not in keyscan_script or "ssh-keyscan -4 -T 2" not in keyscan_script:
    raise SystemExit(1)
keygen = [entry["argv"] for entry in log if any("ssh-keygen" in argument for argument in entry["argv"])]
if len(keygen) != 1 or "-lc" in keygen[0] or "-c" not in keygen[0]:
    raise SystemExit(1)
PY
fake "$case_root" container rename "$target_id" attacker-renamed-target
sup "$case_root" seal --run-id "$run_id" --engine "$FAKE" --reason manual >/dev/null
sup "$case_root" authorize-grade --run-id "$run_id" --engine "$FAKE" >/dev/null
[ "$(running "$case_root" "$target_id")" = false ] && [ "$(running "$case_root" "$base_id")" = false ] \
  || fail 'rename bypassed immutable-ID seal'
sup "$case_root" cleanup --run-id "$run_id" --engine "$FAKE" >/dev/null
ok 'create-before-start accepts declared stopped attachments and seals by immutable ID'

# A same-label decoy is detected but never becomes a lifecycle target.
case_root="$(new_case decoy)"; run_id="decoy"
prepare "$case_root" "$run_id" 30 1 >/dev/null; activate "$case_root" "$run_id"
manifest="$case_root/state/runs/$run_id/manifest.json"; nonce="$(json_file "$manifest" run_nonce)"
network_id="$(json_file "$manifest" objects.network.id)"
decoy_id="$(fake "$case_root" container create --name decoy --hostname decoy --network "$network_id" \
  --label "org.cka-practice.ssh-supervisor.run=$run_id" \
  --label "org.cka-practice.ssh-supervisor.nonce=$nonce" \
  --label org.cka-practice.ssh-supervisor.role=target fake/target:1)"
fake "$case_root" container start "$decoy_id" >/dev/null
if sup "$case_root" seal --run-id "$run_id" --engine "$FAKE" --reason manual >/dev/null 2>&1; then
  fail 'same-label decoy was accepted as a valid topology'
fi
[ "$(running "$case_root" "$decoy_id")" = true ] || fail 'supervisor operated on a non-manifest decoy'
if sup "$case_root" authorize-grade --run-id "$run_id" --engine "$FAKE" >/dev/null 2>&1; then
  fail 'invalid decoy run authorized grading'
fi
ok 'decoy topology fails closed while operations remain manifest-ID-only'

# Concurrent starts are serialized by the kernel-held active-run lock.
case_root="$(new_case concurrent)"
set +e
prepare "$case_root" concurrent-a 30 1 >/dev/null 2>&1 & first=$!
prepare "$case_root" concurrent-b 30 1 >/dev/null 2>&1 & second=$!
wait "$first"; first_rc=$?; wait "$second"; second_rc=$?
set -e
if ! { [ "$first_rc" -eq 0 ] && [ "$second_rc" -ne 0 ]; } \
   && ! { [ "$second_rc" -eq 0 ] && [ "$first_rc" -ne 0 ]; }; then
  fail "concurrent starts were not single-winner ($first_rc/$second_rc)"
fi
ok 'concurrent start has exactly one winner'

# A crash during allocation leaves no startable candidate and recovery removes
# only the exact fsynced object IDs before releasing the active-run record.
case_root="$(new_case allocation-crash)"; run_id="allocation-crash"
FAKE_ENGINE_DB="$case_root/engine.json" FAKE_ENGINE_HANG_MATCH='container create' FAKE_ENGINE_HANG_SECONDS=60 \
  "$PYTHON" "$SUPERVISOR" prepare --state-root "$case_root/state" --run-id "$run_id" \
  --engine "$FAKE" --duration-seconds 30 --engine-timeout-seconds 10 \
  --base-image fake/base:1 --target-image fake/target:1 >/dev/null 2>&1 & allocator=$!
journal="$case_root/state/runs/$run_id/allocation.jsonl"
recorded=0
for _attempt in $(seq 1 100); do
  if [ -f "$journal" ] && grep -q '"kind":"network"' "$journal"; then recorded=1; break; fi
  sleep 0.02
done
[ "$recorded" -eq 1 ] || fail 'allocation crash fixture did not fsync its network ID'
kill -9 "$allocator" >/dev/null 2>&1 || true; wait "$allocator" >/dev/null 2>&1 || true
if sup "$case_root" recover --run-id "$run_id" --engine "$FAKE" >/dev/null 2>&1; then
  fail 'incomplete allocation recovery was considered a valid run'
fi
[ ! -e "$case_root/state/active.json" ] || fail 'recovered allocation kept a stale active-run record'
network_count="$(FAKE_ENGINE_DB="$case_root/engine.json" "$PYTHON" - <<'PY'
import json, os
print(len(json.load(open(os.environ["FAKE_ENGINE_DB"], encoding="utf-8"))["networks"]))
PY
)"
[ "$network_count" -eq 0 ] || fail 'allocation recovery leaked a recorded network'
ok 'crash during stopped allocation recovers exact journaled objects'

# A daemon-side create can succeed even when the CLI fails before returning
# its ID.  The fsynced pre-create intent must discover and remove that orphan.
for orphan_kind in network target; do
  case_root="$(new_case "post-create-$orphan_kind")"; run_id="post-create-$orphan_kind"
  set +e
  FAKE_ENGINE_POST_CREATE_FAIL_KIND="$orphan_kind" \
    prepare "$case_root" "$run_id" 30 1 >/dev/null 2>&1
  prepare_rc=$?
  set -e
  [ "$prepare_rc" -ne 0 ] || fail "post-create $orphan_kind failure was accepted"
  journal="$case_root/state/runs/$run_id/allocation.jsonl"
  grep -F '"event":"intent"' "$journal" | grep -F "\"kind\":\"$orphan_kind\"" >/dev/null \
    || fail "post-create $orphan_kind had no durable intent"
  if sup "$case_root" recover --run-id "$run_id" --engine "$FAKE" >/dev/null 2>&1; then
    fail "post-create $orphan_kind recovery was considered valid"
  fi
  FAKE_ENGINE_DB="$case_root/engine.json" "$PYTHON" - <<'PY' \
    || fail "post-create orphan was not removed"
import json, os
db = json.load(open(os.environ["FAKE_ENGINE_DB"], encoding="utf-8"))
if db["containers"] or db["networks"]:
    raise SystemExit(1)
PY
  [ ! -e "$case_root/state/active.json" ] || fail "post-create recovery kept the active record"
done
ok 'pre-create intents recover daemon success before immutable-ID output'

# Guard crash followed by restart seals an overdue run immediately.
case_root="$(new_case crash)"; run_id="crash"
# DrvFS/desktop WSL can spend more than two seconds in the fake-engine process
# boundary during a valid activation. Keep the deadline short while leaving
# enough room to test the guard crash rather than setup latency.
prepare "$case_root" "$run_id" 5 1 >/dev/null; activate "$case_root" "$run_id"
nonce="$(json_file "$case_root/state/runs/$run_id/manifest.json" run_nonce)"
unit="cka-ssh-guard-${run_id}-${nonce:0:12}.service"
sup "$case_root" watch --run-id "$run_id" --engine "$FAKE" --unit "$unit" >/dev/null 2>&1 & watcher=$!
sleep 0.2; kill -9 "$watcher" >/dev/null 2>&1 || true; wait "$watcher" >/dev/null 2>&1 || true
deadline="$(json_file "$case_root/state/runs/$run_id/manifest.json" deadline_epoch)"
while [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.1; done
sup "$case_root" watch --run-id "$run_id" --engine "$FAKE" --unit "$unit" >/dev/null
target_id="$(json_file "$case_root/state/runs/$run_id/manifest.json" objects.target.id)"
[ "$(running "$case_root" "$target_id")" = false ] || fail 'restarted guard did not seal overdue target'
ok 'crashed guard restart enforces the immutable deadline'

# Restart recovery catches a supervisor crash between target and base start.
case_root="$(new_case partial-activation)"; run_id="partial-activation"
prepare "$case_root" "$run_id" 30 1 >/dev/null; timer_ready "$case_root" "$run_id"
manifest="$case_root/state/runs/$run_id/manifest.json"; nonce="$(json_file "$manifest" run_nonce)"
unit="cka-ssh-guard-${run_id}-${nonce:0:12}.service"
sup "$case_root" watch --run-id "$run_id" --engine "$FAKE" --unit "$unit" >/dev/null 2>&1 & watcher=$!
for _attempt in $(seq 1 50); do
  sup "$case_root" guard-ready --run-id "$run_id" --unit "$unit" >/dev/null 2>&1 && break
  sleep 0.02
done
kill "$watcher" >/dev/null 2>&1 || true; wait "$watcher" >/dev/null 2>&1 || true
target_id="$(json_file "$manifest" objects.target.id)"; base_id="$(json_file "$manifest" objects.base.id)"
fake "$case_root" container start "$target_id" >/dev/null
if sup "$case_root" watch --run-id "$run_id" --engine "$FAKE" --unit "$unit" >/dev/null 2>&1; then
  fail 'partial activation recovery was considered valid'
fi
[ "$(running "$case_root" "$target_id")" = false ] && [ "$(running "$case_root" "$base_id")" = false ] \
  || fail 'guard restart did not seal partial activation'
ok 'guard restart immediately seals a crash during activation'

# Two sealers racing are idempotent and publish one proof.
case_root="$(new_case race)"; run_id="race"
prepare "$case_root" "$run_id" 30 1 >/dev/null; activate "$case_root" "$run_id"
sup "$case_root" seal --run-id "$run_id" --engine "$FAKE" --reason manual >/dev/null & first=$!
sup "$case_root" seal --run-id "$run_id" --engine "$FAKE" --reason manual >/dev/null & second=$!
wait "$first"; wait "$second"
[ "$(find "$case_root/state/runs/$run_id" -maxdepth 1 -name 'seal-proof.json' -type f | wc -l)" -eq 1 ] \
  || fail 'seal race published more than one proof'
ok 'concurrent target-to-base seal is idempotent'

# Cleanup is a durable transaction: a successful first deletion followed by
# an engine failure remains safely retryable by the exact manifest IDs.
case_root="$(new_case cleanup-retry)"; run_id="cleanup-retry"
prepare "$case_root" "$run_id" 30 1 >/dev/null; activate "$case_root" "$run_id"
sup "$case_root" seal --run-id "$run_id" --engine "$FAKE" --reason manual >/dev/null
manifest="$case_root/state/runs/$run_id/manifest.json"
target_id="$(json_file "$manifest" objects.target.id)"; base_id="$(json_file "$manifest" objects.base.id)"
set +e
FAKE_ENGINE_FAIL_MATCH="container rm $base_id" \
  sup "$case_root" cleanup --run-id "$run_id" --engine "$FAKE" >/dev/null 2>&1
cleanup_rc=$?
set -e
[ "$cleanup_rc" -ne 0 ] || fail 'injected mid-cleanup failure was accepted'
[ -f "$case_root/state/runs/$run_id/cleanup-intent.json" ] \
  && [ "$(stat -c '%a' "$case_root/state/runs/$run_id/cleanup-intent.json")" = 400 ] \
  || fail 'cleanup did not persist its transaction intent before deletion'
FAKE_ENGINE_DB="$case_root/engine.json" TARGET_ID="$target_id" BASE_ID="$base_id" "$PYTHON" - <<'PY' \
  || fail 'mid-cleanup fixture did not delete only the first exact ID'
import json, os
db = json.load(open(os.environ["FAKE_ENGINE_DB"], encoding="utf-8"))
if os.environ["TARGET_ID"] in db["containers"] or os.environ["BASE_ID"] not in db["containers"]:
    raise SystemExit(1)
PY
sup "$case_root" cleanup --run-id "$run_id" --engine "$FAKE" >/dev/null
# A lost successful response is retryable after the active record is gone.
sup "$case_root" cleanup --run-id "$run_id" --engine "$FAKE" >/dev/null
FAKE_ENGINE_DB="$case_root/engine.json" "$PYTHON" - <<'PY' \
  || fail 'cleanup retry leaked a managed resource'
import json, os
db = json.load(open(os.environ["FAKE_ENGINE_DB"], encoding="utf-8"))
if db["containers"] or db["networks"]:
    raise SystemExit(1)
PY
[ ! -e "$case_root/state/active.json" ] || fail 'cleanup retry kept the active record'
ok 'durable cleanup intent makes partial exact-ID deletion retryable'

# A hung stop is bounded, kill is attempted, and the incident permanently blocks grade.
case_root="$(new_case hang)"; run_id="hang"
prepare "$case_root" "$run_id" 30 0.2 >/dev/null; activate "$case_root" "$run_id"
started="$(date +%s)"
set +e
FAKE_ENGINE_HANG_MATCH='container stop' FAKE_ENGINE_HANG_SECONDS=60 \
  sup "$case_root" seal --run-id "$run_id" --engine "$FAKE" --reason manual >/dev/null 2>&1
seal_rc=$?
set -e
elapsed=$(( $(date +%s) - started ))
[ "$seal_rc" -ne 0 ] && [ "$elapsed" -lt 5 ] || fail 'engine hang was unbounded or accepted'
if sup "$case_root" authorize-grade --run-id "$run_id" --engine "$FAKE" >/dev/null 2>&1; then
  fail 'engine hang incident authorized grading'
fi
ok 'bounded engine hang fallback remains INVALID'

# Manifest corruption is recovered from the independent exact-ID ledger, never graded.
case_root="$(new_case corrupt)"; run_id="corrupt"
prepare "$case_root" "$run_id" 30 1 >/dev/null; activate "$case_root" "$run_id"
manifest="$case_root/state/runs/$run_id/manifest.json"; target_id="$(json_file "$manifest" objects.target.id)"
chmod 0600 "$manifest"
printf '{"run_id":"cross-run"}\n' > "$manifest"
chmod 0400 "$manifest"
if sup "$case_root" recover --run-id "$run_id" --engine "$FAKE" >/dev/null 2>&1; then
  fail 'corrupt manifest recovery was considered valid'
fi
[ "$(running "$case_root" "$target_id")" = false ] || fail 'corrupt-manifest emergency recovery did not stop exact target ID'
if sup "$case_root" authorize-grade --run-id "$run_id" --engine "$FAKE" >/dev/null 2>&1; then
  fail 'corrupt manifest authorized grading'
fi
ok 'corrupt manifest seals from independent ledger and fails closed'

# Cross-run ownership mismatch must not stop an object no longer provably owned.
case_root="$(new_case mismatch)"; run_id="mismatch"
prepare "$case_root" "$run_id" 30 1 >/dev/null; activate "$case_root" "$run_id"
manifest="$case_root/state/runs/$run_id/manifest.json"; target_id="$(json_file "$manifest" objects.target.id)"
fake "$case_root" debug mutate-label "$target_id" org.cka-practice.ssh-supervisor.nonce "$(printf '0%.0s' {1..64})"
if sup "$case_root" seal --run-id "$run_id" --engine "$FAKE" --reason manual >/dev/null 2>&1; then
  fail 'cross-run identity mismatch was accepted'
fi
[ "$(running "$case_root" "$target_id")" = true ] || fail 'mismatched object was operated on without ownership proof'
if sup "$case_root" authorize-grade --run-id "$run_id" --engine "$FAKE" >/dev/null 2>&1; then
  fail 'cross-run mismatch authorized grading'
fi
ok 'cross-run mismatch is fail-closed and never an operation target'

# Collection and grading are gated by a valid seal proof and immutable allowlist.
case_root="$(new_case collect)"; run_id="collect"
prepare "$case_root" "$run_id" 30 1 --answer ca-01:answer.txt >/dev/null; activate "$case_root" "$run_id"
if sup "$case_root" collect --run-id "$run_id" --engine "$FAKE" --destination "$case_root/too-early" >/dev/null 2>&1; then
  fail 'collection succeeded before seal proof'
fi
target_id="$(json_file "$case_root/state/runs/$run_id/manifest.json" objects.target.id)"
fake "$case_root" debug put-file "$target_id" /home/candidate/cka/ca-01/answer.txt 'candidate-answer'
sup "$case_root" seal --run-id "$run_id" --engine "$FAKE" --reason manual >/dev/null
sup "$case_root" collect --run-id "$run_id" --engine "$FAKE" --destination "$case_root/answers" >/dev/null
[ "$(cat "$case_root/answers/ca-01/answer.txt")" = candidate-answer ] || fail 'allowlisted answer was not safely collected'
sup "$case_root" authorize-grade --run-id "$run_id" --engine "$FAKE" >/dev/null
ok 'seal proof gates bounded allowlist collection and host grading'

# Engine output is spooled under a live cap.  A candidate-controlled docker cp
# flood must terminate without materializing the complete archive in host RSS.
case_root="$(new_case collect-flood)"; run_id="collect-flood"
prepare "$case_root" "$run_id" 30 5 --answer ca-01:answer.txt >/dev/null; activate "$case_root" "$run_id"
sup "$case_root" seal --run-id "$run_id" --engine "$FAKE" --reason manual >/dev/null
started="$(date +%s)"
set +e
FAKE_ENGINE_CP_FLOOD_BYTES=$((42 * 1024 * 1024)) \
  sup "$case_root" collect --run-id "$run_id" --engine "$FAKE" --destination "$case_root/flood" \
  >"$case_root/flood.out" 2>&1
flood_rc=$?
set -e
elapsed=$(( $(date +%s) - started ))
[ "$flood_rc" -ne 0 ] && [ "$elapsed" -lt 8 ] \
  || fail 'candidate-controlled archive flood was unbounded or accepted'
grep -F 'output exceeded its bounded contract' "$case_root/flood.out" >/dev/null \
  || fail 'archive flood did not trip the live engine-output cap'
[ "$(json_file "$case_root/state/runs/$run_id/status.json" phase)" = SEALED ] \
  || fail 'failed archive flood advanced collection state'
[ ! -e "$case_root/flood/ca-01/answer.txt" ] || fail 'archive flood materialized an answer'
ok 'docker cp output flood is killed before unbounded host-memory collection'

printf '1..%d\n' "$PASS"
