#!/usr/bin/env bash
# Opt-in, designated-host SSH exam runner.  This is intentionally separate
# from mock-exam.sh: only shared-kind, API-safe questions can enter this path.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKA_ROOT="${CKA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export CKA_ROOT
# shellcheck source=../lib/common.sh
source "$CKA_ROOT/lib/common.sh"

SESSION="${CKA_SSH_SESSION_SCRIPT:-$SCRIPT_DIR/ssh/session.sh}"
GATED_FORM="${CKA_SSH_GATED_FORM_SCRIPT:-$SCRIPT_DIR/ssh/gated-form.sh}"
PLANNER="${CKA_SSH_PLANNER_SCRIPT:-$SCRIPT_DIR/planner.sh}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
RUNNER_ROOT="${CKA_SSH_RUNNER_STATE_ROOT:-$STATE_HOME/cka-practice/exam-ssh}"
SUPERVISOR_ROOT="${CKA_SSH_SUPERVISOR_STATE_ROOT:-$STATE_HOME/cka-practice/ssh-supervisor}"
SETUP_TIMEOUT_SEC="${CKA_SSH_SETUP_TIMEOUT_SEC:-180}"
GRADE_TIMEOUT_SEC="${CKA_SSH_GRADE_TIMEOUT_SEC:-60}"
DEFAULT_DURATION="${CKA_SSH_EXAM_DURATION_SECONDS:-7200}"
ANSWER_MANIFEST="$SCRIPT_DIR/ssh/answer-files.tsv"
ENGINE="${CKA_SSH_ENGINE:-docker}"
# Held-out exam bank forms (docs/exam-bank-design.md, track A). The ledger
# lives outside the repository so a checkout cannot reset exposure records.
EXAM_BANK_FORMS_DIR="${CKA_EXAM_BANK_FORMS_DIR:-$CKA_EXAM_BANK_DIR/forms}"
EXAM_BANK_LEDGER="${CKA_EXAM_BANK_LEDGER:-$STATE_HOME/cka-practice/exam-bank/ledger.tsv}"
READINESS_POLICY="${CKA_READINESS_POLICY:-$SCRIPT_DIR/readiness-policy.yaml}"

runner_die() { printf 'exam-ssh: %s\n' "$*" >&2; exit 2; }
# Progress goes to stderr so stdout stays a stable result channel.  Print
# question IDs only, never object names (exam bank blind rule).
runner_progress() { printf 'exam-ssh: %s\n' "$*" >&2; }
runner_transition_error() { runner_die "$1 (runner phase remains ${STATUS_PHASE:-unknown})"; }
runner_integrity_invalid() {
  local reason="${1:-invalid supervised run}"
  # If candidate access may still exist, stop exact supervisor IDs before the
  # outer state is changed to INVALID. Cleanup can then safely remove them.
  if [ "${STATUS_PHASE:-}" = RUNNING ] && [ -f "$SUPERVISOR_ROOT/runs/$RUN_ID/manifest.json" ]; then
    CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" seal \
      --run-id "$RUN_ID" --reason operator >> "$RUN_DIR/integrity-seal.log" 2>&1 \
      || CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" recover \
        --run-id "$RUN_ID" >> "$RUN_DIR/integrity-seal.log" 2>&1 || true
  fi
  runner_status_write INVALID "$reason"
  runner_die "$reason"
}

usage() {
  cat <<'EOF'
usage:
  cka exam-ssh begin --form NAME [--allow-seen]   prepare + start in one step
  cka exam-ssh question N                         show question N (1-17)
  cka exam-ssh enter                              open the base host, then: ssh cka-target
  cka exam-ssh finish                             seal + collect + grade + cleanup

Step-by-step commands:
  cka exam-ssh preflight [--install-linger]
  cka exam-ssh prepare [--run-id ID] [--seed SEED] [--duration-seconds N]
  cka exam-ssh prepare --form NAME [--allow-seen] [--run-id ID] [--duration-seconds N]
  cka exam-ssh start
  cka exam-ssh status
  cka exam-ssh question N
  cka exam-ssh enter
  cka exam-ssh seal
  cka exam-ssh collect
  cka exam-ssh grade
  cka exam-ssh cleanup

The supervised form is opt-in and admits only `environment: shared-kind`
questions from the SSH allowlist. There is no unsupervised timer fallback.

`--form NAME` runs a fixed held-out form from exam/bank/forms/NAME.tsv instead
of a seeded practice form. A started form is recorded as exposed; it counts as
blind only the first time unless --allow-seen is given, which marks it not blind.
EOF
}

require_native_runner_root() {
  [[ "$RUNNER_ROOT" = /* ]] || runner_die "runner state root must be an absolute Linux path"
  umask 077
  mkdir -p "$RUNNER_ROOT"
  chmod 0700 "$RUNNER_ROOT"
  local resolved fs_type
  resolved="$(realpath -e -- "$RUNNER_ROOT")" || runner_die "cannot resolve runner state root"
  [ "$resolved" = "$RUNNER_ROOT" ] || runner_die "runner state root must be canonical and contain no symlink components"
  fs_type="$(stat -f -c %T -- "$RUNNER_ROOT")" || runner_die "cannot inspect runner state filesystem"
  case "${fs_type,,}" in 9p|drvfs|cifs|nfs|nfs4|fuseblk|vfat) runner_die "runner state requires a native Linux filesystem (found $fs_type)" ;; esac
}

validate_run_id() {
  [[ "${1:-}" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] \
    || runner_die "run id must be 1-32 lowercase letters, digits, or internal hyphens"
}

validate_positive() { [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || runner_die "$1 must be a positive integer"; }

active_run_id() {
  local active="$RUNNER_ROOT/active"
  [ -f "$active" ] && [ ! -L "$active" ] || runner_die "there is no active supervised SSH run"
  [ "$(stat -c %a "$active")" = 600 ] || runner_die "active run record permissions changed"
  local value
  value="$(<"$active")"
  validate_run_id "$value"
  printf '%s\n' "$value"
}

RUN_ID="" RUN_DIR="" STATUS_PHASE="" STATUS_DETAIL=""
load_run() {
  RUN_ID="$(active_run_id)"
  RUN_DIR="$RUNNER_ROOT/runs/$RUN_ID"
  [ -d "$RUN_DIR" ] && [ ! -L "$RUN_DIR" ] || runner_die "active run directory is missing"
  runner_status_load
  if [ -f "$RUN_DIR/plan.json" ]; then
    runner_plan_verify
  elif [ "$STATUS_PHASE" != INVALID ] && [ "$STATUS_PHASE" != PREPARING ]; then
    runner_die "immutable runner plan is missing"
  fi
}

runner_status_load() {
  local file="$RUN_DIR/status"
  [ -f "$file" ] && [ ! -L "$file" ] || runner_die "runner status is missing"
  IFS='|' read -r STATUS_PHASE STATUS_DETAIL < "$file"
  case "$STATUS_PHASE" in PREPARING|PREPARED|RUNNING|SEALED|COLLECTED|GRADED|INVALID|CLEANED) ;; *) runner_die "runner status is corrupt" ;; esac
}

runner_status_write() {
  local phase="$1" detail="${2:-}" tmp
  case "$phase" in PREPARING|PREPARED|RUNNING|SEALED|COLLECTED|GRADED|INVALID|CLEANED) ;; *) runner_die "invalid runner phase: $phase" ;; esac
  [ -n "$RUN_DIR" ] || runner_die "cannot write status without a loaded run"
  case "$detail" in *'|'*|*$'\n'*|*$'\r'*) runner_die "invalid runner status detail" ;; esac
  tmp="$RUN_DIR/status.tmp.$$"
  printf '%s|%s\n' "$phase" "$detail" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$RUN_DIR/status"
  STATUS_PHASE="$phase"; STATUS_DETAIL="$detail"
}

# Setup-time grader evidence is host-trusted state.  It must never enter the
# candidate input bundle, but final graders must see the exact same bytes that
# setup and the preflight graders used.  The create-once manifest below binds
# those bytes to this run and form; the snapshot is revalidated before every
# runner transition and copied read-only into a fresh final-grader state root.
runner_trusted_state() {
  local action="$1" expected_digest="${2:-}"
  python3 - "$action" "$RUN_DIR" "$RUN_ID" "$RUN_DIR/questions" "$expected_digest" <<'PY' \
    || runner_die "trusted grader state ${action} failed"
import hashlib, json, os, re, stat, sys

action, run_dir, run_id, questions_path, expected_digest = sys.argv[1:]
source_parent = os.path.join(run_dir, "grader-state")
source_root = os.path.join(source_parent, "question-data")
snapshot_root = os.path.join(run_dir, "trusted-state")
snapshot_data = os.path.join(snapshot_root, "question-data")
manifest_path = os.path.join(run_dir, "trusted-state-manifest.json")
final_root = os.path.join(run_dir, "grader-final")
MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 32 * 1024 * 1024
MAX_FILES = 128
MAX_DIRS = 128
SAFE_COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")

def die(message):
    raise SystemExit(f"exam-ssh: trusted grader state: {message}")

def lst(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        die(f"missing path: {path}")

def require_dir(path, mode=None):
    value = lst(path)
    if stat.S_ISLNK(value.st_mode) or not stat.S_ISDIR(value.st_mode):
        die(f"directory is replaced or not a directory: {path}")
    if value.st_uid != os.geteuid():
        die(f"directory owner changed: {path}")
    if mode is not None and stat.S_IMODE(value.st_mode) != mode:
        die(f"directory mode changed: {path}")
    return value

def read_regular(path, *, mode=None, maximum=MAX_FILE):
    before = lst(path)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        die(f"non-regular file: {path}")
    if before.st_uid != os.geteuid() or before.st_nlink != 1:
        die(f"file owner/link count changed: {path}")
    if mode is not None and stat.S_IMODE(before.st_mode) != mode:
        die(f"file mode changed: {path}")
    if before.st_size > maximum:
        die(f"file exceeds size limit: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_nlink, opened.st_uid) != (
            before.st_dev, before.st_ino, before.st_mode, before.st_nlink, before.st_uid
        ):
            die(f"file changed while opening: {path}")
        chunks, total = [], 0
        while True:
            chunk = os.read(fd, min(1024 * 1024, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk); total += len(chunk)
            if total > maximum:
                die(f"file exceeds size limit: {path}")
        after = os.fstat(fd)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
            before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns
        ):
            die(f"file changed while reading: {path}")
        return b"".join(chunks)
    finally:
        os.close(fd)

def read_questions():
    payload = read_regular(questions_path, mode=None if action == "snapshot" else 0o400,
                           maximum=64 * 1024).decode("utf-8")
    result = [line.strip() for line in payload.splitlines() if line.strip()]
    if not result or len(result) != len(set(result)):
        die("question list is empty or duplicated")
    # Practice IDs and exam bank IDs (lib/common.sh CKA_*_ID_RE).
    if any(not re.fullmatch(r"(?:ex-)?(?:st|wl|sn|ca|ts)-[0-9]{2}", item) for item in result):
        die("question list contains an invalid ID")
    return result

def safe_relative(relative, questions):
    parts = relative.split("/")
    if not parts or parts[0] not in questions or any(not SAFE_COMPONENT.fullmatch(p) for p in parts):
        die(f"unsafe or cross-form evidence path: {relative}")

def scan_tree(root, questions, protected):
    require_dir(root, 0o500 if protected else None)
    directories, files, total = [], {}, 0
    stack = [(root, "")]
    while stack:
        current, prefix = stack.pop()
        try:
            entries = sorted(os.scandir(current), key=lambda item: item.name)
        except OSError as exc:
            die(f"cannot enumerate evidence tree: {exc}")
        for entry in entries:
            relative = f"{prefix}/{entry.name}" if prefix else entry.name
            safe_relative(relative, questions)
            value = entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(value.st_mode):
                die(f"symlink evidence path: {relative}")
            if value.st_uid != os.geteuid():
                die(f"evidence owner changed: {relative}")
            if stat.S_ISDIR(value.st_mode):
                if protected and stat.S_IMODE(value.st_mode) != 0o500:
                    die(f"evidence directory mode changed: {relative}")
                directories.append(relative)
                if len(directories) > MAX_DIRS:
                    die("too many evidence directories")
                stack.append((entry.path, relative))
            elif stat.S_ISREG(value.st_mode):
                data = read_regular(entry.path, mode=0o400 if protected else None)
                total += len(data)
                if total > MAX_TOTAL or len(files) >= MAX_FILES:
                    die("evidence tree exceeds limits")
                files[relative] = data
            else:
                die(f"special evidence file: {relative}")
    return sorted(directories), files

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()

def write_once(path, data, mode):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, mode)
    try:
        os.write(fd, data); os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(path, mode, follow_symlinks=False)
    value = lst(path)
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or stat.S_IMODE(value.st_mode) != mode:
        die(f"create-once file protection failed: {path}")

def create_tree(root, directories, files, root_mode):
    os.mkdir(root, 0o700)
    data_root = os.path.join(root, "question-data")
    os.mkdir(data_root, 0o700)
    for relative in sorted(directories, key=lambda item: (item.count("/"), item)):
        os.mkdir(os.path.join(data_root, *relative.split("/")), 0o700)
    for relative, data in sorted(files.items()):
        write_once(os.path.join(data_root, *relative.split("/")), data, 0o400)
    for relative in sorted(directories, key=lambda item: (-item.count("/"), item)):
        os.chmod(os.path.join(data_root, *relative.split("/")), 0o500)
    os.chmod(data_root, 0o500)
    os.chmod(root, root_mode)

def load_verified(questions):
    manifest_bytes = read_regular(manifest_path, mode=0o400, maximum=1024 * 1024)
    digest = hashlib.sha256(manifest_bytes).hexdigest()
    if not re.fullmatch(r"[0-9a-f]{64}", expected_digest) or digest != expected_digest:
        die("manifest digest differs from immutable plan")
    try:
        value = json.loads(manifest_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError):
        die("manifest is not canonical JSON")
    required = {"schema_version", "run_id", "questions", "directories", "files"}
    if not isinstance(value, dict) or set(value) != required or value.get("schema_version") != 1:
        die("manifest schema mismatch")
    if canonical(value) != manifest_bytes or value.get("run_id") != run_id or value.get("questions") != questions:
        die("manifest canonical/run/form binding mismatch")
    directories = value.get("directories")
    records = value.get("files")
    if (not isinstance(directories, list) or directories != sorted(set(directories)) or
            not isinstance(records, list)):
        die("manifest directory/file list is invalid")
    for relative in directories:
        if not isinstance(relative, str): die("manifest directory path is invalid")
        safe_relative(relative, questions)
    expected_files = {}
    for record in records:
        if not isinstance(record, dict) or set(record) != {"path", "size", "sha256"}:
            die("manifest file record is invalid")
        relative, size, sha = record.get("path"), record.get("size"), record.get("sha256")
        if not isinstance(relative, str): die("manifest file path is invalid")
        safe_relative(relative, questions)
        if relative in expected_files or not isinstance(size, int) or not 0 <= size <= MAX_FILE:
            die("manifest file size/path is invalid")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
            die("manifest file digest is invalid")
        expected_files[relative] = (size, sha)
    # Check the parent before opening any descendant so a replaced parent
    # symlink can never redirect verification to an attacker-controlled tree.
    require_dir(snapshot_root, 0o500)
    actual_dirs, actual_files = scan_tree(snapshot_data, questions, True)
    if directories != actual_dirs or set(expected_files) != set(actual_files):
        die("snapshot exact tree differs from manifest")
    for relative, data in actual_files.items():
        size, sha = expected_files[relative]
        if len(data) != size or hashlib.sha256(data).hexdigest() != sha:
            die(f"snapshot evidence digest mismatch: {relative}")
    return directories, actual_files

questions = read_questions()
require_dir(run_dir)
if action == "snapshot":
    require_dir(source_parent)
    if os.path.lexists(snapshot_root) or os.path.lexists(manifest_path):
        die("snapshot/manifest is create-once")
    if os.path.lexists(source_root):
        directories, files = scan_tree(source_root, questions, False)
    else:
        directories, files = [], {}
    create_tree(snapshot_root, directories, files, 0o500)
    records = [{"path": path, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
               for path, data in sorted(files.items())]
    manifest = {"schema_version": 1, "run_id": run_id, "questions": questions,
                "directories": directories, "files": records}
    write_once(manifest_path, canonical(manifest), 0o400)
elif action in {"verify", "materialize"}:
    directories, files = load_verified(questions)
    if action == "materialize":
        if os.path.lexists(final_root):
            die("final grader state is create-once")
        create_tree(final_root, directories, files, 0o700)
else:
    die("unknown operation")
PY
}

runner_trusted_state_snapshot() { runner_trusted_state snapshot; }
runner_trusted_state_verify() { runner_trusted_state verify "$1"; }
runner_trusted_state_materialize() { runner_trusted_state materialize "$1"; }

runner_plan_verify() {
  local plan="$RUN_DIR/plan.json" digest_file="$RUN_DIR/plan.sha256" expected actual
  [ -f "$plan" ] && [ ! -L "$plan" ] && [ "$(stat -c %a "$plan")" = 400 ] \
    || runner_die "immutable runner plan is missing or unprotected"
  [ -f "$digest_file" ] && [ ! -L "$digest_file" ] && [ "$(stat -c %a "$digest_file")" = 400 ] \
    || runner_die "immutable runner plan digest is missing or unprotected"
  expected="$(<"$digest_file")"; actual="$(sha256sum "$plan")"; actual="${actual%% *}"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$expected" = "$actual" ] \
    || runner_die "immutable runner plan digest mismatch"
  python3 - "$plan" "$RUN_ID" "$RUN_DIR/questions" "$RUN_DIR/input-manifest.json" <<'PY' || exit 2
import json, re, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
required = {"schema_version", "run_id", "seed", "duration_seconds", "questions", "external_network_id", "input_manifest_sha256", "trusted_state_manifest_sha256"}
if not isinstance(p, dict) or set(p) != required or p.get("schema_version") != 2 or p.get("run_id") != sys.argv[2]:
    raise SystemExit("exam-ssh: immutable plan schema/run mismatch")
if not isinstance(p.get("duration_seconds"), int) or not 1 <= p["duration_seconds"] <= 28800:
    raise SystemExit("exam-ssh: immutable plan duration is invalid")
if not re.fullmatch(r"[0-9a-f]{64}", str(p.get("external_network_id", ""))):
    raise SystemExit("exam-ssh: immutable plan network ID is invalid")
if not re.fullmatch(r"[0-9a-f]{64}", str(p.get("input_manifest_sha256", ""))):
    raise SystemExit("exam-ssh: immutable plan input digest is invalid")
if not re.fullmatch(r"[0-9a-f]{64}", str(p.get("trusted_state_manifest_sha256", ""))):
    raise SystemExit("exam-ssh: immutable plan trusted-state digest is invalid")
if not isinstance(p.get("questions"), list) or len(p["questions"]) != 17 or len(set(p["questions"])) != 17:
    raise SystemExit("exam-ssh: immutable plan question set is invalid")
questions=[line.strip() for line in open(sys.argv[3],encoding="utf-8") if line.strip()]
if questions != p["questions"]:
    raise SystemExit("exam-ssh: immutable question file differs from the plan")
inputs=json.load(open(sys.argv[4],encoding="utf-8"))
input_questions=[item.get("question_id") for item in inputs.get("questions",[]) if isinstance(item,dict)]
if input_questions != questions or inputs.get("active_question") != questions[0]:
    raise SystemExit("exam-ssh: immutable input question set differs from the plan")
PY
  local input_actual input_expected
  input_expected="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["input_manifest_sha256"])' "$plan")"
  input_actual="$(sha256sum "$RUN_DIR/input-manifest.json")"; input_actual="${input_actual%% *}"
  [ "$input_actual" = "$input_expected" ] || runner_die "immutable input manifest digest mismatch"
  local trusted_expected
  trusted_expected="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["trusted_state_manifest_sha256"])' "$plan")"
  runner_trusted_state_verify "$trusted_expected"
}

plan_value() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$RUN_DIR/plan.json" "$1"; }

question_dir() {
  local qid="$1" qdir
  if [[ "$qid" =~ $CKA_EXAM_BANK_ID_RE ]]; then
    qdir="$(exam_bank_qdir_of "$qid")" || runner_die "exam bank question directory missing: $qid"
  else
    qdir="$(qdir_of "$qid")" || runner_die "question directory missing: $qid"
  fi
  printf '%s\n' "$qdir"
}

# A fixed bank form is exam/bank/forms/<NAME>.tsv with lines
# id|setup_priority|mutex|breaks|requires. It must hold 17 distinct
# shared-kind bank questions split 5/4/3/3/2 by domain and use the same
# compatibility rules as exam/planner.sh.
bank_form_build() { # <form> <questions-out> <setup-order-out>
  local form="$1" manifest
  [[ "$form" =~ ^[A-Z]$ ]] || runner_die "form name must be one capital letter"
  manifest="$EXAM_BANK_FORMS_DIR/$form.tsv"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || runner_die "exam bank form not found: $form"
  python3 - "$manifest" "$CKA_EXAM_BANK_DIR" "$2" "$3" <<'PY'
import os, re, sys
manifest, bank, questions_out, order_out = sys.argv[1:5]
domains = {"st": "storage", "wl": "workloads-scheduling", "sn": "services-networking",
           "ca": "cluster-architecture", "ts": "troubleshooting"}
quota = {"troubleshooting": 5, "cluster-architecture": 4, "services-networking": 3,
         "workloads-scheduling": 3, "storage": 2}
rows = []
for number, raw in enumerate(open(manifest, encoding="utf-8"), 1):
    line = raw.rstrip("\r\n")
    if not line or line.startswith("#"):
        continue
    fields = line.split("|")
    if len(fields) != 5:
        raise SystemExit(f"exam-ssh: form line {number} needs 5 fields")
    qid, priority, mutex, breaks, requires = fields
    if not re.fullmatch(r"ex-(st|wl|sn|ca|ts)-[0-9]{2}", qid) or not re.fullmatch(r"[0-9]+", priority):
        raise SystemExit(f"exam-ssh: form line {number} is invalid")
    qdir = os.path.join(bank, domains[qid[3:5]], qid)
    meta_path = os.path.join(qdir, "meta.yaml")
    if os.path.islink(qdir) or not os.path.isfile(meta_path):
        raise SystemExit(f"exam-ssh: form question missing: {qid}")
    meta = {}
    for meta_line in open(meta_path, encoding="utf-8"):
        key, sep, value = meta_line.partition(":")
        if sep:
            meta[key.strip()] = value.strip()
    if meta.get("environment", "shared-kind") != "shared-kind":
        raise SystemExit(f"exam-ssh: form question is not shared-kind: {qid}")
    tokens = lambda value: {item for item in value.split(",") if item}
    rows.append((qid, int(priority), number, tokens(mutex), tokens(breaks), tokens(requires)))
ids = [row[0] for row in rows]
if len(ids) != 17 or len(set(ids)) != 17:
    raise SystemExit("exam-ssh: a form needs 17 distinct questions")
counts = {}
for qid in ids:
    counts[domains[qid[3:5]]] = counts.get(domains[qid[3:5]], 0) + 1
if counts != quota:
    raise SystemExit(f"exam-ssh: form domain split {counts} differs from {quota}")
for index, a in enumerate(rows):
    for b in rows[index + 1:]:
        if a[3] & b[3] or a[4] & b[4] or a[4] & b[5] or a[5] & b[4]:
            raise SystemExit(f"exam-ssh: incompatible form questions: {a[0]} {b[0]}")
with open(questions_out, "w", encoding="utf-8") as f:
    f.writelines(qid + "\n" for qid in ids)
with open(order_out, "w", encoding="utf-8") as f:
    f.writelines(row[0] + "\n" for row in sorted(rows, key=lambda r: (r[1], r[2])))
PY
}

bank_form_exposed() { # <form>
  [ -f "$EXAM_BANK_LEDGER" ] || return 1
  awk -F'\t' -v form="$1" '$1 == form && $4 == "EXPOSED" { found = 1 } END { exit found ? 0 : 1 }' \
    "$EXAM_BANK_LEDGER"
}

bank_form_mark_exposed() { # <form> <run-id>
  local dir="${EXAM_BANK_LEDGER%/*}"
  mkdir -p -- "$dir" && chmod 0700 -- "$dir" || return 1
  printf '%s\t%s\t%s\tEXPOSED\n' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$EXAM_BANK_LEDGER"
}

# Refuse a seen form unless the operator explicitly accepts a non-blind run.
bank_form_guard() { # <form> <allow-seen 0|1>
  if bank_form_exposed "$1"; then
    [ "$2" = 1 ] || runner_die "form $1 was already exposed; rerun with --allow-seen for a non-blind practice run"
    printf 'false\n'
  else
    printf 'true\n'
  fi
}

run_form_value() { # <key>; empty for seeded practice forms
  [ -f "$RUN_DIR/form.json" ] || return 0
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print(str(v).lower() if isinstance(v,bool) else v)' \
    "$RUN_DIR/form.json" "$1"
}

question_environment() {
  local qdir="$1" value
  value="$(meta_get "$qdir" environment)" || runner_die "cannot read question environment: $qdir"
  printf '%s\n' "${value:-shared-kind}"
}

# Drain questions require their target node to start without an ownerless Pod.
# Reuse the mock runner's fail-closed definition of a managed Pod: mirror Pods
# (static control-plane components) and Pods with a controller ownerReference
# are allowed; every other Pod is candidate/external state and blocks prepare.
ssh_node_has_only_managed_pods() { # ssh_node_has_only_managed_pods <node>
  kctx --request-timeout=20s get pods -A --field-selector "spec.nodeName=$1" -o json \
    2>/dev/null | python3 -c '
import json, sys

items = json.load(sys.stdin).get("items", [])
unmanaged = []
for pod in items:
    meta = pod.get("metadata", {})
    if meta.get("annotations", {}).get("kubernetes.io/config.mirror"):
        continue
    refs = meta.get("ownerReferences", [])
    if any(ref.get("controller") is True for ref in refs):
        continue
    namespace = meta.get("namespace") or "default"
    name = meta.get("name") or "unknown"
    unmanaged.append(namespace + "/" + name)
if unmanaged:
    print("unmanaged Pods: " + ", ".join(unmanaged), file=sys.stderr)
    raise SystemExit(1)
'
}

verify_ssh_form_runtime_requirements() { # verify_ssh_form_runtime_requirements <questions-file>
  local questions="$1"
  if grep -qx ca-05 "$questions"; then
    ssh_node_has_only_managed_pods "${CKA_CLUSTER_NAME}-worker" || return 1
  fi
  if grep -qx ca-06 "$questions"; then
    ssh_node_has_only_managed_pods "${CKA_CLUSTER_NAME}-worker2" || return 1
  fi
}

runner_require_safe_runtime_baseline() { # <questions-file> <before-setup|after-setup>
  local questions="$1" phase="$2" log="$RUN_DIR/logs/runtime-baseline-$2.log"
  if verify_ssh_form_runtime_requirements "$questions" > "$log" 2>&1; then
    return 0
  fi
  runner_status_write INVALID "unsafe shared cluster runtime baseline ($phase)"
  if [ "$phase" = after-setup ]; then
    # Setup has mutated the shared cluster, so restore selected questions while
    # retaining the INVALID run directory and runtime-baseline evidence.
    cleanup_selected_questions "$questions" >> "$RUN_DIR/logs/runtime-baseline-cleanup.log" 2>&1 || true
  fi
  runner_die "shared cluster runtime baseline is unsafe ($phase); session was not started"
}

# setup cleanup is allowed to remove a question's empty work directory.  The
# supervisor input contract, however, requires one canonical real directory
# for every selected question, including questions that do not submit files.
# Re-materialize only missing directories after setup and reject any linked or
# non-directory replacement before the immutable input manifest is written.
runner_materialize_work_roots() { # <questions-file>
  local questions="$1" requested root qid target resolved
  requested="${RUN_DIR%/}/work"
  [ -n "$requested" ] && [ "$requested" != / ] && [ ! -L "$requested" ] || return 1
  root="$(realpath -e -- "$requested")" || return 1
  [ "$root" = "$requested" ] && [ -d "$root" ] || return 1
  while IFS= read -r qid; do
    [ -n "$qid" ] || continue
    cka_question_id_valid "$qid" || return 1
    target="$root/$qid"
    [ ! -L "$target" ] || return 1
    if [ -e "$target" ]; then
      [ -d "$target" ] || return 1
    else
      mkdir -m 0700 -- "$target" || return 1
    fi
    resolved="$(realpath -e -- "$target")" || return 1
    [ "$resolved" = "$target" ] || return 1
    chmod 0700 -- "$target" || return 1
  done < "$questions"
}

cleanup_selected_questions() {
  local questions_file="$1" qid qdir failed=0 total index=0 started rc
  [ -r "$questions_file" ] || return 0
  total="$(grep -c . "$questions_file" || true)"
  while IFS= read -r qid; do
    [ -n "$qid" ] || continue
    index=$((index + 1)); started=$SECONDS; rc=0
    runner_progress "cleanup [$index/$total] $qid: removing question resources..."
    qdir="$(question_dir "$qid")" || {
      failed=1
      runner_progress "cleanup [$index/$total] $qid: FAILED (question directory not found)"
      continue
    }
    if [ -f "$qdir/teardown.sh" ] && [ ! -L "$qdir/teardown.sh" ]; then
      timeout --signal=TERM --kill-after=5s 120s env \
        CKA_WORK_DIR="$RUN_DIR/work" CKA_STATE_DIR="$RUN_DIR/grader-state" \
        bash "$qdir/teardown.sh" >> "$RUN_DIR/cleanup.log" 2>&1 || rc=1
    fi
    timeout --signal=TERM --kill-after=5s 120s env \
      CKA_WORK_DIR="$RUN_DIR/work" CKA_STATE_DIR="$RUN_DIR/grader-state" \
      bash -c \
      'set -uo pipefail; source "$1"; cleanup_question "$2"' _ \
      "$CKA_ROOT/lib/common.sh" "$qid" >> "$RUN_DIR/cleanup.log" 2>&1 || rc=1
    if [ "$rc" -eq 0 ]; then
      runner_progress "cleanup [$index/$total] $qid: done ($((SECONDS - started))s)"
    else
      failed=1
      runner_progress "cleanup [$index/$total] $qid: FAILED ($((SECONDS - started))s, see $RUN_DIR/cleanup.log)"
    fi
  done < "$questions_file"
  return "$failed"
}

resolve_kind_network_id() {
  local control_plane="${CKA_CLUSTER_NAME}-control-plane" result node actual
  result="$(docker container inspect "$control_plane" 2>/dev/null | python3 -c '
import json,re,sys
records=json.load(sys.stdin)
if len(records)!=1: raise SystemExit(1)
networks=(records[0].get("NetworkSettings") or {}).get("Networks") or {}
ids={v.get("NetworkID") for v in networks.values() if isinstance(v,dict)}
if len(ids)!=1: raise SystemExit(1)
value=next(iter(ids))
if not isinstance(value,str) or not re.fullmatch(r"[0-9a-f]{64}",value): raise SystemExit(1)
print(value)
')" || runner_die "cannot resolve the exact KIND cluster network ID"
  for node in "${CKA_CLUSTER_NAME}-worker" "${CKA_CLUSTER_NAME}-worker2"; do
    actual="$(docker container inspect "$node" 2>/dev/null | python3 -c '
import json,sys
r=json.load(sys.stdin); n=(r[0].get("NetworkSettings") or {}).get("Networks") or {}
ids={v.get("NetworkID") for v in n.values() if isinstance(v,dict)}
print(next(iter(ids)) if len(ids)==1 else "")
')" || runner_die "cannot verify KIND node network: $node"
    [ "$actual" = "$result" ] || runner_die "KIND nodes do not share one exact network ID"
  done
  printf '%s\n' "$result"
}

cmd_preflight() { CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" preflight "$@"; }

cmd_prepare() {
  local run_id="" seed="" duration="$DEFAULT_DURATION" catalog questions setup_order qid qdir rc
  local form="" allow_seen=0 blind=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-id) [ "$#" -ge 2 ] || runner_die '--run-id needs a value'; run_id="$2"; shift 2 ;;
      --seed) [ "$#" -ge 2 ] || runner_die '--seed needs a value'; seed="$2"; shift 2 ;;
      --form) [ "$#" -ge 2 ] || runner_die '--form needs a value'; form="$2"; shift 2 ;;
      --allow-seen) allow_seen=1; shift ;;
      --duration-seconds) [ "$#" -ge 2 ] || runner_die '--duration-seconds needs a value'; duration="$2"; shift 2 ;;
      *) runner_die "unknown prepare argument: $1" ;;
    esac
  done
  if [ -n "$form" ]; then
    [ -z "$seed" ] || runner_die '--form and --seed cannot be combined'
    [[ "$form" =~ ^[A-Z]$ ]] || runner_die "form name must be one capital letter"
    seed="form-$form"
    # Decide exposure before any run state or cluster mutation exists.
    blind="$(bank_form_guard "$form" "$allow_seen")" || exit 2
  else
    [ "$allow_seen" = 0 ] || runner_die '--allow-seen applies only to --form'
  fi
  [ -n "$run_id" ] || run_id="ssh-$(date -u +%Y%m%d%H%M%S)"
  [ -n "$seed" ] || seed="ssh-$(date -u +%Y%m%d%H%M%S)-$$"
  validate_run_id "$run_id"; validate_positive duration "$duration"
  [ "$duration" -le 28800 ] || runner_die "duration cannot exceed 28800 seconds"
  [[ "$seed" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || runner_die "seed contains unsupported characters"

  CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" preflight
  command -v timeout >/dev/null 2>&1 || runner_die "timeout is required"
  command -v python3 >/dev/null 2>&1 || runner_die "python3 is required"
  command -v docker >/dev/null 2>&1 || runner_die "docker is required"
  docker info >/dev/null 2>&1 || runner_die "Docker engine is not reachable"
  docker image inspect "${CKA_SSH_BASE_IMAGE:-cka-practice/ssh-base:v1}" \
    "${CKA_SSH_TARGET_IMAGE:-cka-practice/ssh-target:v1}" >/dev/null 2>&1 \
    || runner_die "build the designated-host images first: bash exam/ssh/build.sh"
  require_cluster

  if [ -e "$RUNNER_ROOT/active" ] || [ -e "$RUNNER_ROOT/runs/$run_id" ]; then
    runner_die "another supervised run exists or this run id was already used"
  fi
  RUN_ID="$run_id"; RUN_DIR="$RUNNER_ROOT/runs/$RUN_ID"
  mkdir -p "$RUN_DIR" "$RUN_DIR/logs" "$RUN_DIR/work" "$RUN_DIR/grader-state"
  chmod 0700 "$RUN_DIR" "$RUN_DIR/logs" "$RUN_DIR/work" "$RUN_DIR/grader-state"
  printf '%s\n' "$RUN_ID" > "$RUNNER_ROOT/active"; chmod 0600 "$RUNNER_ROOT/active"
  runner_status_write PREPARING "form and shared cluster setup"
  catalog="$RUN_DIR/catalog.tsv"; questions="$RUN_DIR/questions"; setup_order="$RUN_DIR/setup-order"

  if [ -n "$form" ]; then
    if ! (bank_form_build "$form" "$questions" "$setup_order") > "$RUN_DIR/logs/bank-form.log" 2>&1 \
       || ! cp -- "$EXAM_BANK_FORMS_DIR/$form.tsv" "$catalog"; then
      runner_status_write INVALID "exam bank form validation failed"
      runner_die "exam bank form $form is invalid; see $RUN_DIR/logs/bank-form.log"
    fi
    python3 - "$RUN_DIR/form.json" "$form" "$blind" "$catalog" <<'PY'
import hashlib, json, os, sys
path, form, blind, manifest = sys.argv[1:5]
value = {"form": form, "blind": blind == "true",
         "manifest_sha256": hashlib.sha256(open(manifest, "rb").read()).hexdigest()}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(value, f, sort_keys=True)
    f.write("\n")
PY
  elif ! bash "$GATED_FORM" --catalog-out "$catalog" > "$RUN_DIR/logs/gated-form.log" 2>&1 \
     || ! CKA_FORM_CATALOG="$catalog" bash "$PLANNER" --seed "$seed" \
       --questions-out "$questions" --setup-order-out "$setup_order" > "$RUN_DIR/logs/planner.log" 2>&1 \
     || ! bash "$GATED_FORM" --verify-form "$questions" >> "$RUN_DIR/logs/gated-form.log" 2>&1; then
    runner_status_write INVALID "form generation failed"
    runner_die "safe SSH form generation failed; see $RUN_DIR/logs"
  fi

  while IFS= read -r qid; do
    qdir="$(question_dir "$qid")"
    [ "$(question_environment "$qdir")" = shared-kind ] \
      || { runner_status_write INVALID "disposable question selected: $qid"; runner_die "SSH form selected non-shared question: $qid"; }
    mkdir -p "$RUN_DIR/work/$qid"
  done < "$questions"

  # Reject external/candidate-owned node state before any question setup is
  # attempted. This preserves the offending baseline as diagnostic evidence.
  runner_require_safe_runtime_baseline "$questions" before-setup

  while IFS= read -r qid; do
    qdir="$(question_dir "$qid")"
    if timeout --signal=TERM --kill-after=5s "${SETUP_TIMEOUT_SEC}s" env \
      CKA_WORK_DIR="$RUN_DIR/work" CKA_STATE_DIR="$RUN_DIR/grader-state" \
      bash "$qdir/setup.sh" > "$RUN_DIR/logs/$qid-setup.log" 2>&1; then rc=0; else rc=$?; fi
    if [ "$rc" -ne 0 ]; then
      runner_status_write INVALID "$qid setup failed ($rc)"
      cleanup_selected_questions "$questions" || true
      runner_die "$qid setup failed; supervised session was not started"
    fi
  done < "$setup_order"

  # Close the race with setup and reject any ownerless Pod introduced while
  # the form was prepared. Candidate access and the independent timer still
  # do not exist at this point.
  runner_require_safe_runtime_baseline "$questions" after-setup

  # A setup that cannot be observed by its grader is infrastructure-invalid.
  while IFS= read -r qid; do
    qdir="$(question_dir "$qid")"
    set +e
    timeout --signal=TERM --kill-after=5s "${GRADE_TIMEOUT_SEC}s" env \
      CKA_WORK_DIR="$RUN_DIR/work" CKA_STATE_DIR="$RUN_DIR/grader-state" \
      bash "$qdir/grade.sh" > "$RUN_DIR/logs/$qid-preflight-grade.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
      runner_status_write INVALID "$qid preflight grader failed ($rc)"
      cleanup_selected_questions "$questions" || true
      runner_die "$qid preflight grader is invalid; session was not started"
    fi
  done < "$questions"

  # Preserve only setup-created grading evidence.  It is deliberately outside
  # the target input manifest, and the plan binds its create-once manifest.
  if ! (runner_trusted_state_snapshot); then
    runner_status_write INVALID "trusted grader evidence snapshot failed"
    cleanup_selected_questions "$questions" || true
    runner_die "trusted grader evidence was not snapshotted; session was not started"
  fi

  if ! runner_materialize_work_roots "$questions"; then
    runner_status_write INVALID "question work-root materialization failed"
    cleanup_selected_questions "$questions" || true
    runner_die "question work roots are unsafe; session was not started"
  fi

  local kubeconfig="$RUN_DIR/kubeconfig-internal.yaml" endpoint network_id input_manifest
  kind get kubeconfig --internal --name "$CKA_CLUSTER_NAME" > "$kubeconfig"
  chmod 0600 "$kubeconfig"
  endpoint="$(kubectl --kubeconfig "$kubeconfig" config view --raw -o jsonpath='{.clusters[0].cluster.server}')"
  [ "$endpoint" = "https://${CKA_CLUSTER_NAME}-control-plane:6443" ] \
    || { runner_status_write INVALID "unexpected internal API endpoint"; runner_die "KIND internal kubeconfig endpoint is not exact: $endpoint"; }
  network_id="$(resolve_kind_network_id)"
  input_manifest="$RUN_DIR/input-manifest.json"
  python3 - "$questions" "$kubeconfig" "$RUN_DIR/work" "$input_manifest" <<'PY'
import json, os, sys
questions=[line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
value={"schema_version":1,"active_question":questions[0],"questions":[
    {"question_id":q,"kubeconfig":sys.argv[2],"work_root":os.path.join(sys.argv[3],q)}
    for q in questions]}
payload=(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode()
fd=os.open(sys.argv[4],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o400)
with os.fdopen(fd,"wb") as f: f.write(payload); f.flush(); os.fsync(f.fileno())
PY
  local input_digest trusted_digest plan="$RUN_DIR/plan.json"
  input_digest="$(sha256sum "$input_manifest")"; input_digest="${input_digest%% *}"
  trusted_digest="$(sha256sum "$RUN_DIR/trusted-state-manifest.json")"; trusted_digest="${trusted_digest%% *}"
  python3 - "$plan" "$RUN_ID" "$seed" "$duration" "$questions" "$network_id" "$input_digest" "$trusted_digest" <<'PY'
import json, os, sys
questions=[line.strip() for line in open(sys.argv[5], encoding="utf-8") if line.strip()]
value={"schema_version":2,"run_id":sys.argv[2],"seed":sys.argv[3],"duration_seconds":int(sys.argv[4]),
       "questions":questions,"external_network_id":sys.argv[6],"input_manifest_sha256":sys.argv[7],
       "trusted_state_manifest_sha256":sys.argv[8]}
payload=(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode()
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o400)
with os.fdopen(fd,"wb") as f: f.write(payload); f.flush(); os.fsync(f.fileno())
PY
  sha256sum "$plan" | awk '{print $1}' > "$RUN_DIR/plan.sha256"
  chmod 0400 "$plan" "$RUN_DIR/plan.sha256" "$input_manifest"
  chmod 0400 "$questions" "$setup_order" "$catalog" "$kubeconfig"
  runner_plan_verify
  runner_status_write PREPARED "immutable form ready"
  if [ -n "$form" ]; then
    printf 'Exam bank form %s prepared (blind: %s)\n' "$form" "$blind"
  fi
  printf 'SSH supervised form prepared: %s (17 shared API-safe questions)\n' "$RUN_ID"
  printf 'Start only when ready: cka exam-ssh start\n'
}

answer_arguments() {
  local qid answer_id relative extra
  declare -A selected=()
  while IFS= read -r qid; do selected[$qid]=1; done < "$RUN_DIR/questions"
  while IFS='|' read -r answer_id relative extra; do
    answer_id="${answer_id%$'\r'}"; relative="${relative%$'\r'}"
    case "$answer_id" in ''|'#'*) continue ;; esac
    [ -z "${extra:-}" ] || runner_die "answer manifest has extra fields"
    [ -n "${selected[$answer_id]+x}" ] || continue
    printf '%s:%s\n' "$answer_id" "$relative"
  done < "$ANSWER_MANIFEST"
  # Bank questions declare their submission files in meta.yaml answer_files.
  while IFS= read -r qid; do
    [[ "$qid" =~ $CKA_EXAM_BANK_ID_RE ]] || continue
    python3 - "$(question_dir "$qid")/meta.yaml" "$qid" <<'PY' || runner_die "invalid answer_files for $qid"
import json, re, sys
raw = ""
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("answer_files:"):
        raw = line.split(":", 1)[1].strip()
files = json.loads(raw) if raw else []
for relative in files:
    if not isinstance(relative, str) or not re.fullmatch(r"[A-Za-z0-9._/-]+", relative) \
            or ".." in relative.split("/") or relative.startswith("/"):
        raise SystemExit(1)
    print(f"{sys.argv[2]}:{relative}")
PY
  done < "$RUN_DIR/questions"
}

cmd_start() {
  load_run
  [ "$STATUS_PHASE" = PREPARED ] || runner_transition_error "start requires PREPARED, found $STATUS_PHASE"
  local duration network answer output rc
  duration="$(plan_value duration_seconds)"; network="$(plan_value external_network_id)"
  declare -a args=(start --run-id "$RUN_ID" --duration-seconds "$duration"
    --input-manifest "$RUN_DIR/input-manifest.json" --external-network-id "$network"
    --base-image "${CKA_SSH_BASE_IMAGE:-cka-practice/ssh-base:v1}"
    --target-image "${CKA_SSH_TARGET_IMAGE:-cka-practice/ssh-target:v1}")
  while IFS= read -r answer; do [ -n "$answer" ] && args+=(--answer "$answer"); done < <(answer_arguments)
  # A bank form is consumed once candidate access may begin, even if the run
  # later fails. Record it first so no exposure can go unrecorded.
  local form
  form="$(run_form_value form)"
  if [ -n "$form" ]; then
    bank_form_mark_exposed "$form" "$RUN_ID" \
      || runner_die "cannot record exposure of form $form; the run was not started"
  fi
  set +e; output="$(CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" "${args[@]}" 2>&1)"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then runner_status_write INVALID "supervisor activation failed ($rc)"; printf '%s\n' "$output" >&2; runner_die "supervisor refused activation"; fi
  runner_status_write RUNNING "deadline supervisor active"
  printf '%s\n' "$output"
  printf 'Enter the base host: cka exam-ssh enter\nThen run: ssh cka-target\n'
}

cmd_status() {
  load_run
  printf 'run: %s\nrunner phase: %s\n' "$RUN_ID" "$STATUS_PHASE"
  if [ "$STATUS_PHASE" != PREPARING ] && [ -d "$SUPERVISOR_ROOT/runs/$RUN_ID" ]; then
    CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" status --run-id "$RUN_ID"
  fi
}

cmd_question() {
  local number="${1:-}"
  load_run
  # Question text is exam content: reveal it only once the deadline supervisor
  # is running, and afterwards for review. Never before start.
  case "$STATUS_PHASE" in
    RUNNING|SEALED|COLLECTED|GRADED) ;;
    *) runner_transition_error "question text requires a started run, found $STATUS_PHASE" ;;
  esac
  [[ "$number" =~ ^([1-9]|1[0-7])$ ]] || runner_die "question number must be 1-17"
  local qid qdir
  qid="$(sed -n "${number}p" "$RUN_DIR/questions")"; qdir="$(question_dir "$qid")"
  printf '\nQuestion %s/17 — %s\n\n' "$number" "$qid"
  cat "$qdir/question.md"
  printf '\nOn cka-target, activate this question context with:\n  cka-use-context %s\n' "$qid"
}

cmd_enter() {
  load_run
  [ "$STATUS_PHASE" = RUNNING ] || runner_transition_error "candidate entry requires RUNNING, found $STATUS_PHASE"
  local entry base_id
  entry="$(CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" candidate-entry --run-id "$RUN_ID")" \
    || runner_integrity_invalid "supervisor denied candidate entry"
  base_id="$(printf '%s' "$entry" | python3 -c 'import json,re,sys; v=json.load(sys.stdin).get("base_container_id",""); print(v) if re.fullmatch(r"[0-9a-f]{64}",v) else sys.exit(1)')" \
    || runner_integrity_invalid "supervisor returned an invalid base identity"
  command -v "$ENGINE" >/dev/null 2>&1 || runner_transition_error "container engine is unavailable"
  exec "$ENGINE" container exec --interactive --tty --user candidate "$base_id" bash
}

cmd_seal() {
  load_run
  [ "$STATUS_PHASE" = RUNNING ] || runner_transition_error "seal requires RUNNING, found $STATUS_PHASE"
  if ! CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" seal --run-id "$RUN_ID" --reason manual; then
    runner_status_write INVALID "supervisor seal failed"; runner_die "run is INVALID because sealing was not proven"
  fi
  runner_status_write SEALED "candidate access stopped"
}

cmd_collect() {
  load_run
  [ "$STATUS_PHASE" = SEALED ] || runner_transition_error "collect requires SEALED, found $STATUS_PHASE"
  [ ! -e "$RUN_DIR/collected" ] || runner_transition_error "collection destination already exists"
  if ! CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" collect \
      --run-id "$RUN_ID" --destination "$RUN_DIR/collected"; then
    runner_status_write INVALID "answer collection failed"; runner_die "run is INVALID because answer collection failed"
  fi
  runner_status_write COLLECTED "allowlisted files collected"
}

parse_grade_state() {
  local value="$1"
  [[ "$value" =~ ^graded:([0-9]+)/([0-9]+)$ ]] || return 1
  G_EARNED="${BASH_REMATCH[1]}"; G_MAX="${BASH_REMATCH[2]}"
}

cmd_grade() {
  load_run
  [ "$STATUS_PHASE" = COLLECTED ] || runner_transition_error "grade requires COLLECTED, found $STATUS_PHASE"
  [ ! -e "$RUN_DIR/grade-authorization.json" ] || runner_transition_error "grade authorization is create-once"
  local authorization auth_tmp="$RUN_DIR/grade-authorization.tmp.$$"
  # This call is deliberately the first grading-side effect.  No question
  # grader path is reached unless the supervisor proves the seal gate now.
  if ! authorization="$(CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" authorize-grade --run-id "$RUN_ID")"; then
    runner_status_write INVALID "supervisor grade authorization failed"
    runner_die "no grader was called because authorize-grade failed"
  fi
  printf '%s\n' "$authorization" > "$auth_tmp"; chmod 0400 "$auth_tmp"; mv -- "$auth_tmp" "$RUN_DIR/grade-authorization.json"
  local timed_out
  timed_out="$(python3 - "$RUN_DIR/grade-authorization.json" "$RUN_ID" <<'PY'
import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8"))
required={"run_id","operation","seal_reason","sealed_at_epoch","deadline_epoch","deadline_enforced","manifest_sha256","seal_proof_sha256"}
if not required.issubset(v) or v.get("run_id") != sys.argv[2] or v.get("operation") != "grade": raise SystemExit(1)
reason=v.get("seal_reason")
if reason not in {"manual","operator","deadline"}: raise SystemExit(1)
if v.get("deadline_enforced") is not (reason == "deadline"): raise SystemExit(1)
if not isinstance(v.get("sealed_at_epoch"),int) or not isinstance(v.get("deadline_epoch"),int): raise SystemExit(1)
print("1" if reason == "deadline" else "0")
PY
)" || runner_integrity_invalid "grade authorization payload mismatch"

  if ! (runner_trusted_state_materialize "$(plan_value trusted_state_manifest_sha256)"); then
    runner_status_write INVALID "trusted grader evidence materialization failed"
    runner_die "supervised result is INVALID because trusted grader evidence was not materialized"
  fi
  local qid qdir rc state expected total_earned=0 total_max=0 invalid=0
  local scores="$RUN_DIR/question-scores.tsv"
  : > "$scores"
  while IFS= read -r qid; do
    qdir="$(question_dir "$qid")"; expected="$(meta_get "$qdir" points)"
    set +e
    timeout --signal=TERM --kill-after=5s "${GRADE_TIMEOUT_SEC}s" env \
      CKA_WORK_DIR="$RUN_DIR/collected" CKA_STATE_DIR="$RUN_DIR/grader-final" \
      bash "$qdir/grade.sh" > "$RUN_DIR/logs/$qid-final-grade.log" 2>&1
    rc=$?
    set -e
    state="$(cat "$RUN_DIR/grader-final/status/$qid" 2>/dev/null || true)"
    if [ "$rc" -gt 1 ] || ! parse_grade_state "$state" || [ "$G_MAX" != "$expected" ]; then
      invalid=1
      printf '%s: INVALID (grader=%s state=%s)\n' "$qid" "$rc" "$state"
    else
      total_earned=$((total_earned + G_EARNED)); total_max=$((total_max + G_MAX))
      printf '%s: %s/%s\n' "$qid" "$G_EARNED" "$G_MAX"
      printf '%s\t%s\t%s\t%s\n' "$qid" "$(domain_of "$qid")" "$G_EARNED" "$G_MAX" >> "$scores"
    fi
  done < "$RUN_DIR/questions"
  if [ "$invalid" -ne 0 ] || [ "$total_max" -le 0 ]; then
    runner_status_write INVALID "one or more host graders failed"
    runner_die "supervised result is INVALID; see $RUN_DIR/logs"
  fi
  local pct=$((total_earned * 100 / total_max)) verdict=FAIL
  if [ "$timed_out" = 1 ]; then
    verdict=TIMEOUT
  elif [ "$pct" -ge 66 ]; then
    verdict=PASS
  fi
  printf 'score: %s/%s (%s%%) — %s\n' "$total_earned" "$total_max" "$pct" "$verdict" | tee "$RUN_DIR/score.txt"
  # The exam verdict (66%) and the local readiness verdict are separate:
  # readiness also needs a blind bank form and the readiness-policy thresholds.
  python3 - "$scores" "$RUN_DIR/form.json" "$READINESS_POLICY" "$verdict" "$RUN_DIR/result.json" <<'PY'
import json, os, sys
scores_path, form_path, policy_path, verdict, out = sys.argv[1:6]
questions, domains = [], {}
for line in open(scores_path, encoding="utf-8"):
    qid, domain, earned, maximum = line.rstrip("\n").split("\t")
    questions.append({"id": qid, "domain": domain, "earned": int(earned), "max": int(maximum)})
    total = domains.setdefault(domain, {"earned": 0, "max": 0})
    total["earned"] += int(earned)
    total["max"] += int(maximum)
for total in domains.values():
    total["percent"] = total["earned"] * 100 // total["max"]
earned = sum(q["earned"] for q in questions)
maximum = sum(q["max"] for q in questions)
percent = earned * 100 // maximum
form = json.load(open(form_path, encoding="utf-8")) if os.path.isfile(form_path) else {}
policy = json.load(open(policy_path, encoding="utf-8"))["practiceReady"]
blind = form.get("blind") is True
readiness = (blind and verdict == "PASS"
             and percent >= policy["minimumOverallPercentEachRun"]
             and all(d["percent"] >= policy["minimumDomainPercentEachRun"] for d in domains.values()))
value = {"form": form.get("form"), "blind": blind, "verdict": verdict,
         "earned": earned, "max": maximum, "percent": percent,
         "domains": domains, "questions": questions, "readinessPass": readiness}
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(value, f, indent=2, sort_keys=True)
    f.write("\n")
for name in sorted(domains):
    d = domains[name]
    print(f"  {name}: {d['earned']}/{d['max']} ({d['percent']}%)")
print(f"form: {form.get('form') or 'seeded practice form'}, blind: {str(blind).lower()}, "
      f"readiness pass: {str(readiness).lower()}")
PY
  chmod 0400 "$RUN_DIR/score.txt" "$RUN_DIR/grade-authorization.json" "$scores"
  runner_status_write GRADED "$verdict $total_earned/$total_max"
}

cmd_cleanup() {
  load_run
  local failed=0
  runner_progress "cleanup run $RUN_ID (phase ${STATUS_PHASE:-unknown}); details go to $RUN_DIR/cleanup.log"
  if [ -f "$SUPERVISOR_ROOT/runs/$RUN_ID/manifest.json" ]; then
    # Seal is idempotent. Always attempt it before removal, including when an
    # earlier integrity failure changed only the runner phase to INVALID.
    runner_progress "cleanup: sealing the candidate session..."
    CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" seal --run-id "$RUN_ID" --reason operator \
      >> "$RUN_DIR/cleanup.log" 2>&1 || true
    runner_progress "cleanup: removing base/target containers and the supervisor network..."
    if CKA_SSH_SUPERVISOR_STATE_ROOT="$SUPERVISOR_ROOT" bash "$SESSION" cleanup --run-id "$RUN_ID" \
        >> "$RUN_DIR/cleanup.log" 2>&1; then
      runner_progress "cleanup: supervisor objects removed"
    else
      failed=1
      runner_progress "cleanup: supervisor cleanup FAILED (see cleanup.log)"
    fi
  elif [ -d "$SUPERVISOR_ROOT/runs/$RUN_ID" ]; then
    # A prepare failure can leave audit-only state after exact journal recovery.
    # Accept it only with the create-once recovery proof and no active record.
    python3 - "$SUPERVISOR_ROOT" "$RUN_ID" <<'PY' >> "$RUN_DIR/cleanup.log" 2>&1 || failed=1
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); run_id=sys.argv[2]; run=root/"runs"/run_id
proof=run/"allocation-recovery-proof.json"; active=root/"active.json"
if not proof.is_file() or proof.is_symlink() or active.exists(): raise SystemExit(1)
value=json.load(open(proof,encoding="utf-8"))
if value.get("run_id") != run_id or value.get("valid") is not False: raise SystemExit(1)
PY
  fi
  cleanup_selected_questions "$RUN_DIR/questions" || failed=1
  [ "$failed" -eq 0 ] || { runner_status_write INVALID "cleanup incomplete"; runner_die "cleanup was incomplete; audit state was preserved"; }
  runner_status_write CLEANED "supervisor objects and shared question resources removed"
  local active_value="$(<"$RUNNER_ROOT/active")"
  [ "$active_value" = "$RUN_ID" ] || runner_die "active run changed during cleanup"
  rm -- "$RUNNER_ROOT/active"
  printf 'supervised SSH run cleaned; audit retained at %s\n' "$RUN_DIR"
}

# One-step entry: prepare the form, then start the timer and containers.
cmd_begin() {
  cmd_prepare "$@"
  runner_progress "begin: form prepared; starting the timed session..."
  cmd_start
  printf 'Questions: cka exam-ssh question 1 .. 17 (this terminal)\n'
  printf 'Work:      cka exam-ssh enter, then ssh cka-target (another terminal)\n'
  printf 'Finish:    cka exam-ssh finish\n'
}

# One-step exit: run whichever of seal, collect and grade remain, then clean
# up.  A deadline-sealed run is still RUNNING for the runner, and the
# supervisor seal is idempotent, so the same path covers both endings.
cmd_finish() {
  load_run
  if [ "$STATUS_PHASE" = RUNNING ]; then
    runner_progress "finish: sealing the session (candidate access stops)..."
    cmd_seal; load_run
  fi
  if [ "$STATUS_PHASE" = SEALED ]; then
    runner_progress "finish: collecting answer files..."
    cmd_collect; load_run
  fi
  if [ "$STATUS_PHASE" = COLLECTED ]; then
    runner_progress "finish: grading 17 questions..."
    cmd_grade; load_run
  fi
  [ "$STATUS_PHASE" = GRADED ] \
    || runner_die "finish needs a gradable run, found $STATUS_PHASE; use 'cka exam-ssh cleanup' to discard it"
  cmd_cleanup
}

main() {
  require_native_runner_root
  local command="${1:-help}"; shift || true
  # All transitions, including prepare, are serialized independently of the
  # supervisor's own immutable-object lock.
  exec 9> "$RUNNER_ROOT/runner.lock"
  flock -x 9 || runner_die "cannot acquire runner transition lock"
  case "$command" in
    preflight) cmd_preflight "$@" ;;
    prepare) cmd_prepare "$@" ;;
    begin) cmd_begin "$@" ;;
    finish) [ "$#" -eq 0 ] || runner_die 'finish takes no arguments'; cmd_finish ;;
    start) [ "$#" -eq 0 ] || runner_die 'start takes no arguments'; cmd_start ;;
    status) [ "$#" -eq 0 ] || runner_die 'status takes no arguments'; cmd_status ;;
    question) [ "$#" -eq 1 ] || runner_die 'question requires N'; cmd_question "$1" ;;
    enter) [ "$#" -eq 0 ] || runner_die 'enter takes no arguments'; flock -u 9; cmd_enter ;;
    seal) [ "$#" -eq 0 ] || runner_die 'seal takes no arguments'; cmd_seal ;;
    collect) [ "$#" -eq 0 ] || runner_die 'collect takes no arguments'; cmd_collect ;;
    grade) [ "$#" -eq 0 ] || runner_die 'grade takes no arguments'; cmd_grade ;;
    cleanup) [ "$#" -eq 0 ] || runner_die 'cleanup takes no arguments'; cmd_cleanup ;;
    help|-h|--help) usage ;;
    *) usage >&2; runner_die "unknown command: $command" ;;
  esac
}

if [ "${CKA_SSH_RUNNER_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
fi
