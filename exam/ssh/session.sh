#!/usr/bin/env bash
set -Eeuo pipefail

# Stable host-side entry point for the supervised SSH lifecycle.  This script
# deliberately has no nohup/sleep fallback: automatic mode is unavailable when
# the Linux systemd service manager cannot provide both an independent timer
# and a restartable guard service.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR="$SCRIPT_DIR/supervisor/supervisor.py"
PYTHON="${CKA_SSH_SUPERVISOR_PYTHON:-python3}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_ROOT="${CKA_SSH_SUPERVISOR_STATE_ROOT:-$STATE_HOME/cka-practice/ssh-supervisor}"
ENGINE="${CKA_SSH_ENGINE:-docker}"
SYSTEMD_SCOPE="${CKA_SSH_SYSTEMD_SCOPE:-user}"

die() { printf 'ssh-session: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
usage:
  session.sh preflight [--install-linger]
  session.sh start --run-id ID --duration-seconds N [--answer QUESTION:FILE ...]
                   [--input-manifest ABSOLUTE_PATH --external-network-id FULL_ID]
                   [--base-image IMAGE] [--target-image IMAGE]
  session.sh seal --run-id ID [--reason manual|operator]
  session.sh status --run-id ID
  session.sh recover --run-id ID
  session.sh collect --run-id ID --destination NEW_ABSOLUTE_PATH
  session.sh authorize-grade --run-id ID
  session.sh candidate-entry --run-id ID
  session.sh cleanup --run-id ID

Environment:
  CKA_SSH_SUPERVISOR_STATE_ROOT  protected native-Linux state directory
  CKA_SSH_ENGINE                 container-engine CLI (default: docker)
  CKA_SSH_SUPERVISOR_PYTHON     Python 3 executable

`start` requires a persistent per-user systemd manager. There is intentionally
no unsupervised fallback. `preflight --install-linger` is the explicit, one-time
privileged step when login lingering has not already been enabled.
EOF
}

[ -f "$SUPERVISOR" ] && [ ! -L "$SUPERVISOR" ] || die "supervisor is missing"
command -v "$PYTHON" >/dev/null 2>&1 || die "Python 3 is required"
PYTHON="$(command -v "$PYTHON")"

require_systemd() {
  local probe_unit user_name
  command -v systemctl >/dev/null 2>&1 || die "automatic mode requires systemctl"
  command -v systemd-run >/dev/null 2>&1 || die "automatic mode requires systemd-run"
  [ "$(cat /proc/1/comm 2>/dev/null || true)" = systemd ] \
    || die "automatic mode is disabled because PID 1 is not systemd"
  [ "$SYSTEMD_SCOPE" = user ] \
    || die "automatic mode requires the persistent per-user systemd scope"
  user_name="$(id -un)"
  [ -n "$user_name" ] || die "cannot determine the supervisor user"
  command -v loginctl >/dev/null 2>&1 || die "automatic mode requires loginctl"
  [ "$(loginctl show-user "$user_name" --property=Linger --value 2>/dev/null || true)" = yes ] \
    || die "user lingering is disabled; run: $0 preflight --install-linger"
  systemctl --user show --property=Version --value >/dev/null 2>&1 \
    || die "automatic mode is disabled because the per-user systemd manager is not reachable"
  probe_unit="cka-ssh-supervisor-probe-$(id -u)-$$"
  systemd-run --user --quiet --wait --collect --unit "$probe_unit" /usr/bin/true >/dev/null 2>&1 \
    || die "automatic mode is disabled because this host user cannot create systemd units"
}

preflight() {
  local install_linger="${1:-0}" user_name
  command -v systemctl >/dev/null 2>&1 || die "automatic mode requires systemctl"
  command -v systemd-run >/dev/null 2>&1 || die "automatic mode requires systemd-run"
  command -v loginctl >/dev/null 2>&1 || die "automatic mode requires loginctl"
  [ "$(cat /proc/1/comm 2>/dev/null || true)" = systemd ] \
    || die "automatic mode is disabled because PID 1 is not systemd"
  user_name="$(id -un)"
  if [ "$(loginctl show-user "$user_name" --property=Linger --value 2>/dev/null || true)" != yes ]; then
    [ "$install_linger" = 1 ] \
      || die "one-time setup required: $0 preflight --install-linger"
    command -v sudo >/dev/null 2>&1 || die "sudo is required only for the one-time linger setup"
    printf 'Enabling persistent user services for %s (one-time privileged step).\n' "$user_name" >&2
    sudo loginctl enable-linger "$user_name" \
      || die "could not enable persistent per-user systemd services"
  fi
  umask 077
  mkdir -p "$STATE_ROOT" || die "cannot create protected supervisor state: $STATE_ROOT"
  chmod 0700 "$STATE_ROOT" || die "cannot protect supervisor state: $STATE_ROOT"
  require_systemd
  run_supervisor preflight --state-root "$STATE_ROOT" >/dev/null \
    || die "supervisor rejected the protected state directory"
  printf 'supervised SSH preflight passed (persistent user systemd, protected native state)\n'
}

json_field() {
  local field="$1"
  "$PYTHON" -c 'import json,sys; value=json.load(sys.stdin); print(value[sys.argv[1]])' "$field"
}

run_supervisor() {
  "$PYTHON" "$SUPERVISOR" "$@"
}

command="${1:-}"
[ -n "$command" ] || { usage >&2; exit 2; }
shift

case "$command" in
  preflight)
    install_linger=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --install-linger) install_linger=1; shift ;;
        *) die "unknown preflight argument: $1" ;;
      esac
    done
    preflight "$install_linger"
    ;;

  start)
    require_systemd
    command -v "$ENGINE" >/dev/null 2>&1 || die "container engine command is unavailable: $ENGINE"
    ENGINE="$(command -v "$ENGINE")"
    run_id=""; duration=""; base_image="cka-practice/ssh-base:v1"; target_image="cka-practice/ssh-target:v1"
    input_manifest=""; external_network_id=""
    declare -a answers=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --run-id) [ "$#" -ge 2 ] || die '--run-id needs a value'; run_id="$2"; shift 2 ;;
        --duration-seconds) [ "$#" -ge 2 ] || die '--duration-seconds needs a value'; duration="$2"; shift 2 ;;
        --answer) [ "$#" -ge 2 ] || die '--answer needs a value'; answers+=("$2"); shift 2 ;;
        --base-image) [ "$#" -ge 2 ] || die '--base-image needs a value'; base_image="$2"; shift 2 ;;
        --target-image) [ "$#" -ge 2 ] || die '--target-image needs a value'; target_image="$2"; shift 2 ;;
        --input-manifest) [ "$#" -ge 2 ] || die '--input-manifest needs a value'; input_manifest="$2"; shift 2 ;;
        --external-network-id) [ "$#" -ge 2 ] || die '--external-network-id needs a value'; external_network_id="$2"; shift 2 ;;
        *) die "unknown start argument: $1" ;;
      esac
    done
    [ -n "$run_id" ] && [ -n "$duration" ] || die 'start requires --run-id and --duration-seconds'
    declare -a prepare_args=(prepare --state-root "$STATE_ROOT" --run-id "$run_id" --engine "$ENGINE"
      --duration-seconds "$duration" --base-image "$base_image" --target-image "$target_image")
    if [ -n "$input_manifest" ] || [ -n "$external_network_id" ]; then
      [ -n "$input_manifest" ] && [ -n "$external_network_id" ] \
        || die '--input-manifest and --external-network-id must be used together'
      prepare_args+=(--input-manifest "$input_manifest" --external-network-id "$external_network_id")
    fi
    for answer in "${answers[@]}"; do prepare_args+=(--answer "$answer"); done
    set +e
    prepared="$(run_supervisor "${prepare_args[@]}")"
    prepare_rc=$?
    set -e
    if [ "$prepare_rc" -ne 0 ]; then
      # Allocation may have failed after fsyncing one or more exact IDs. The
      # recovery path consumes only that protected journal and never deletes
      # the external KIND network. Never recover merely because a create-once
      # run ID already existed: that could seal another valid session.
      if "$PYTHON" - "$STATE_ROOT" "$run_id" <<'PY' >/dev/null 2>&1
import json,pathlib,sys
run=pathlib.Path(sys.argv[1])/"runs"/sys.argv[2]
status=run/"status.json"; journal=run/"allocation.jsonl"
if not status.is_file() or status.is_symlink() or not journal.is_file() or journal.is_symlink(): raise SystemExit(1)
value=json.load(open(status,encoding="utf-8"))
if value.get("run_id") != sys.argv[2] or value.get("phase") != "INVALID": raise SystemExit(1)
if (value.get("details") or {}).get("reason") != "allocation-failed": raise SystemExit(1)
PY
      then
        run_supervisor recover --state-root "$STATE_ROOT" --run-id "$run_id" --engine "$ENGINE" \
          >/dev/null 2>&1 || true
      fi
      exit "$prepare_rc"
    fi
    deadline="$(printf '%s' "$prepared" | json_field deadline_epoch)" || die 'cannot read prepared deadline'
    timer_unit="$(printf '%s' "$prepared" | json_field timer_unit)" || die 'cannot read prepared timer unit'
    timer_base="${timer_unit%.timer}"
    nonce_short="${timer_base##*-}"
    guard_unit="cka-ssh-guard-${run_id}-${nonce_short}"

    fail_start() {
      local incoming_rc=$? rc
      rc="${1:-$incoming_rc}"
      [ "$rc" -ne 0 ] || rc=2
      trap - ERR INT TERM
      run_supervisor seal --state-root "$STATE_ROOT" --run-id "$run_id" --engine "$ENGINE" \
        --reason activation-failure >/dev/null 2>&1 || true
      systemctl --user stop "$guard_unit.service" "$timer_unit" >/dev/null 2>&1 || true
      exit "$rc"
    }
    trap fail_start ERR INT TERM

    # systemd-run creates both ${timer_base}.timer and ${timer_base}.service.
    # The timer invokes the immutable-ID seal path independently of the guard.
    systemd-run --user --quiet --collect --unit "$timer_base" \
      --on-calendar="@${deadline}" \
      --timer-property=AccuracySec=1us \
      --property=Type=oneshot \
      "$PYTHON" "$SUPERVISOR" seal --state-root "$STATE_ROOT" \
      --run-id "$run_id" --engine "$ENGINE" --reason deadline
    systemctl --user is-active --quiet "$timer_unit"
    run_supervisor timer-ready --state-root "$STATE_ROOT" --run-id "$run_id" \
      --unit "$timer_unit" --systemctl-scope user >/dev/null

    # The restartable guard is a second deadline path.  If it is killed or the
    # Python process crashes, systemd starts it again; watch seals immediately
    # when it observes an overdue deadline or a host boot mismatch.
    systemd-run --user --quiet --collect --unit "$guard_unit" \
      --property=Type=simple \
      --property=Restart=on-failure \
      --property=RestartPreventExitStatus=2 \
      --property=RestartSec=1s \
      --property=NoNewPrivileges=yes \
      "$PYTHON" "$SUPERVISOR" watch --state-root "$STATE_ROOT" \
      --run-id "$run_id" --engine "$ENGINE" --unit "$guard_unit.service"
    systemctl --user is-active --quiet "$guard_unit.service"
    guard_ready=0
    for _attempt in $(seq 1 50); do
      if run_supervisor guard-ready --state-root "$STATE_ROOT" --run-id "$run_id" \
          --unit "$guard_unit.service" >/dev/null 2>&1; then
        guard_ready=1
        break
      fi
      sleep 0.1
    done
    if [ "$guard_ready" -ne 1 ]; then
      printf 'ssh-session: restartable guard did not publish readiness\n' >&2
      fail_start 2
    fi

    run_supervisor activate --state-root "$STATE_ROOT" --run-id "$run_id" --engine "$ENGINE"
    trap - ERR INT TERM
    printf 'supervised SSH run %s is active; deadline=%s\n' "$run_id" "$deadline"
    ;;

  seal)
    run_id=""; reason="operator"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --run-id) [ "$#" -ge 2 ] || die '--run-id needs a value'; run_id="$2"; shift 2 ;;
        --reason) [ "$#" -ge 2 ] || die '--reason needs a value'; reason="$2"; shift 2 ;;
        *) die "unknown seal argument: $1" ;;
      esac
    done
    [ -n "$run_id" ] || die 'seal requires --run-id'
    case "$reason" in manual|operator) ;; *) die 'manual seal reason must be manual or operator' ;; esac
    run_supervisor seal --state-root "$STATE_ROOT" --run-id "$run_id" --engine "$ENGINE" --reason "$reason"
    ;;

  status)
    [ "${1:-}" = --run-id ] && [ "$#" -eq 2 ] || die 'status requires --run-id ID'
    run_supervisor status --state-root "$STATE_ROOT" --run-id "$2"
    ;;

  recover)
    [ "${1:-}" = --run-id ] && [ "$#" -eq 2 ] || die 'recover requires --run-id ID'
    run_supervisor recover --state-root "$STATE_ROOT" --run-id "$2" --engine "$ENGINE"
    ;;

  collect)
    run_id=""; destination=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --run-id) [ "$#" -ge 2 ] || die '--run-id needs a value'; run_id="$2"; shift 2 ;;
        --destination) [ "$#" -ge 2 ] || die '--destination needs a value'; destination="$2"; shift 2 ;;
        *) die "unknown collect argument: $1" ;;
      esac
    done
    [ -n "$run_id" ] && [ -n "$destination" ] || die 'collect requires --run-id and --destination'
    run_supervisor collect --state-root "$STATE_ROOT" --run-id "$run_id" --engine "$ENGINE" --destination "$destination"
    ;;

  authorize-grade)
    [ "${1:-}" = --run-id ] && [ "$#" -eq 2 ] || die 'authorize-grade requires --run-id ID'
    run_supervisor authorize-grade --state-root "$STATE_ROOT" --run-id "$2" --engine "$ENGINE"
    ;;

  candidate-entry)
    [ "${1:-}" = --run-id ] && [ "$#" -eq 2 ] || die 'candidate-entry requires --run-id ID'
    run_supervisor candidate-entry --state-root "$STATE_ROOT" --run-id "$2" --engine "$ENGINE"
    ;;

  cleanup)
    [ "${1:-}" = --run-id ] && [ "$#" -eq 2 ] || die 'cleanup requires --run-id ID'
    run_id="$2"
    status_json="$(run_supervisor status --state-root "$STATE_ROOT" --run-id "$run_id")"
    manifest="$STATE_ROOT/runs/$run_id/manifest.json"
    nonce_short="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_nonce"][:12])' "$manifest")"
    run_supervisor cleanup --state-root "$STATE_ROOT" --run-id "$run_id" --engine "$ENGINE"
    systemctl --user stop "cka-ssh-guard-${run_id}-${nonce_short}.service" \
      "cka-ssh-deadline-${run_id}-${nonce_short}.timer" >/dev/null 2>&1 || true
    ;;

  -h|--help|help) usage ;;
  *) usage >&2; die "unknown command: $command" ;;
esac
