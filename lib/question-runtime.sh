#!/usr/bin/env bash
# Question execution adapter.
#
# The long-lived kind-cka cluster and disposable cells are intentionally
# separate execution paths.  A disposable question must never fall back to the
# shared context when its cell cannot be prepared or reactivated.

if [ -z "${CKA_ROOT:-}" ]; then
  CKA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Legacy shared-kind questions predate per-question setup deadlines. Keep their
# setup/teardown bounded without requiring a metadata migration; disposable
# questions use their explicit, longer setup_timeout_seconds value.
QUESTION_RUNTIME_DEFAULT_SCRIPT_TIMEOUT_SECONDS=300

question_runtime_environment() { # <question-dir>
  local qdir="$1" environment
  environment="$(meta_get "$qdir" environment)" || return 1
  [ -n "$environment" ] || environment=shared-kind
  case "$environment" in
    shared-kind|kubeadm-bootstrap|kubeadm-ha|kubeadm-upgrade|operator-cell|gateway-cell|csi-cell)
      printf '%s\n' "$environment"
      ;;
    *)
      err "지원하지 않는 문제 실행 환경입니다: $environment"
      return 1
      ;;
  esac
}

question_runtime_is_disposable() { # <environment>
  case "$1" in
    kubeadm-bootstrap|kubeadm-ha|kubeadm-upgrade|operator-cell|gateway-cell|csi-cell) return 0 ;;
    shared-kind) return 1 ;;
    *) return 2 ;;
  esac
}

_question_runtime_load_cell_library() {
  declare -F cell_prepare >/dev/null \
    && declare -F cell_activate >/dev/null \
    && declare -F cell_cleanup >/dev/null \
    && declare -F cell_status >/dev/null \
    && declare -F cell_select >/dev/null \
    && declare -F cell_selection_clear >/dev/null \
    && declare -F cell_selection_clear_current >/dev/null \
    && declare -F _cell_cleanup_all_managed_locked >/dev/null \
    && declare -F cell_cleanup_all_managed >/dev/null \
    && return 0
  # shellcheck source=cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  declare -F cell_prepare >/dev/null \
    && declare -F cell_activate >/dev/null \
    && declare -F cell_cleanup >/dev/null \
    && declare -F cell_status >/dev/null \
    && declare -F cell_select >/dev/null \
    && declare -F cell_selection_clear >/dev/null \
    && declare -F cell_selection_clear_current >/dev/null \
    && declare -F _cell_cleanup_all_managed_locked >/dev/null \
    && declare -F cell_cleanup_all_managed >/dev/null
}

_question_runtime_load_controller_library() {
  declare -F controller_cell_cleanup >/dev/null \
    && declare -F controller_cell_status >/dev/null \
    && return 0
  # shellcheck source=controllers.sh
  source "$CKA_ROOT/lib/controllers.sh"
  declare -F controller_cell_cleanup >/dev/null \
    && declare -F controller_cell_status >/dev/null
}

_question_runtime_load_csi_library() {
  declare -F csi_cell_prepare >/dev/null \
    && declare -F csi_cell_activate >/dev/null \
    && declare -F csi_cell_cleanup >/dev/null \
    && declare -F csi_cell_status >/dev/null \
    && return 0
  # shellcheck source=csi.sh
  source "$CKA_ROOT/lib/csi.sh"
  declare -F csi_cell_prepare >/dev/null \
    && declare -F csi_cell_activate >/dev/null \
    && declare -F csi_cell_cleanup >/dev/null \
    && declare -F csi_cell_status >/dev/null
}

_question_runtime_run_script() { # <question-dir> <script-name>
  local qdir="$1" name="$2" script="$1/$2" timeout_seconds
  [ -f "$script" ] && [ ! -L "$script" ] \
    || { err "문제 실행 파일을 안전하게 읽을 수 없습니다: $script"; return 1; }
  case "$name" in
    setup.sh|teardown.sh)
      timeout_seconds="$(meta_get "$qdir" setup_timeout_seconds)"
      timeout_seconds="${timeout_seconds:-$QUESTION_RUNTIME_DEFAULT_SCRIPT_TIMEOUT_SECONDS}"
      [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
        || { err "$name deadline metadata가 유효하지 않습니다."; return 1; }
      command -v timeout >/dev/null 2>&1 || return 1
      timeout --foreground --kill-after=5s "${timeout_seconds}s" bash "$script"
      ;;
    *) bash "$script" ;;
  esac
}

_question_runtime_run_kubeadm_setup() { # <question-dir>
  # The destructive opt-in is scoped to the disposable setup subprocess.  It
  # is never exported globally or reused by the shared KIND path.
  CKA_ENABLE_DISPOSABLE_CELLS=1 CKA_ENABLE_KUBEADM_CELLS=1 \
    _question_runtime_run_script "$1" setup.sh
}

_question_runtime_profile_prepare() { # <qid> <environment>
  case "$2" in
    operator-cell|gateway-cell)
      # Controller profiles are part of setup.sh so those scripts remain
      # independently runnable.  The runtime only guarantees an active base
      # cell before handing control to setup.
      return 0
      ;;
    csi-cell)
      _question_runtime_load_csi_library || return 1
      # CSI image preload must happen before the candidate setup is published.
      # Run it in a subshell because profile helpers use die() on validation
      # failures; the caller must remain alive to perform safe cell cleanup.
      (csi_cell_prepare "$1" "$2" && csi_cell_activate "$1" "$2")
      ;;
    kubeadm-bootstrap|kubeadm-ha|kubeadm-upgrade) return 0 ;;
    *) return 1 ;;
  esac
}

_question_runtime_profile_reactivate() { # <qid> <environment>
  case "$2" in
    operator-cell|gateway-cell)
      # The base cell activation above is sufficient. A profile status check
      # here would confuse a candidate's intended changes with infrastructure
      # damage (an operator-install exercise starts absent and ends running).
      # The grader owns that distinction and must remain observational.
      return 0
      ;;
    csi-cell)
      _question_runtime_load_csi_library || return 1
      (csi_cell_activate "$1" "$2")
      ;;
    kubeadm-bootstrap|kubeadm-ha|kubeadm-upgrade) return 0 ;;
    *) return 1 ;;
  esac
}

_question_runtime_profile_cleanup() { # <qid> <environment>
  case "$2" in
    operator-cell|gateway-cell)
      _question_runtime_load_controller_library || return 1
      (controller_cell_cleanup "$1" "$2")
      ;;
    csi-cell)
      _question_runtime_load_csi_library || return 1
      (csi_cell_cleanup "$1" "$2")
      ;;
    kubeadm-bootstrap|kubeadm-ha|kubeadm-upgrade) return 0 ;;
    *) return 1 ;;
  esac
}

_question_runtime_cleanup_disposable() { # <qid> <question-dir> <environment>
  local qid="$1" qdir="$2" environment="$3" failed=0 active=0 cleanup_rc=0

  _question_runtime_load_cell_library || return 1

  # Do not run a teardown script against the inherited/shared context.  Only a
  # cell whose immutable manifest and topology reactivate successfully may be
  # mutated by profile or question cleanup.
  if cell_status "$qid" "$environment" >/dev/null 2>&1; then
    if cell_activate "$qid" "$environment" \
        && cell_select "$qid" "$environment"; then
      active=1
    fi
  fi

  if [ "$active" -eq 1 ]; then
    _question_runtime_profile_cleanup "$qid" "$environment" || failed=$((failed+1))
    if [ -f "$qdir/teardown.sh" ] && [ ! -L "$qdir/teardown.sh" ]; then
      _question_runtime_run_script "$qdir" teardown.sh || failed=$((failed+1))
    fi
  fi

  # cell_cleanup is the sole authority that removes immutable Docker IDs.  It
  # is also called after a PREPARING failure, where cell_status is expected to
  # fail but a partially written manifest may still be safely recoverable. The
  # active selection is cleared only after exact cleanup succeeds. On lock
  # timeout or any cleanup failure, both journal and selection are preserved so
  # a retry stays fail-closed instead of falling back to the shared cluster.
  if (cell_cleanup "$qid" "$environment"); then
    cell_selection_clear "$qid" || failed=$((failed+1))
  else
    cleanup_rc=$?
    failed=$((failed+1))
    err "$qid exact cell cleanup failed (exit $cleanup_rc); immutable state and active selection were preserved"
  fi
  [ "$cleanup_rc" -eq 0 ] || return "$cleanup_rc"
  [ "$failed" -eq 0 ] || return 1
  return 0
}

_question_runtime_cleanup_after_failure() { # <qid> <question-dir> <environment>
  local cleanup_rc=0
  _question_runtime_cleanup_disposable "$1" "$2" "$3" || cleanup_rc=$?
  if [ "$cleanup_rc" -ne 0 ]; then
    warn "실패한 $1 환경을 자동으로 안전하게 정리하지 못했습니다 (exit $cleanup_rc). 상태와 active-cell 선택을 보존했습니다. 'cka cleanup $1'로 다시 검증하세요."
  fi
  return 0
}

question_runtime_start() { # <qid> <question-dir>
  local qid="$1" qdir="$2" environment mode
  environment="$(question_runtime_environment "$qdir")" || return 1
  mode="$(meta_get "$qdir" mode)" || return 1

  case "$environment" in
    shared-kind)
      # Individual recovery drills must be able to repair the exact broken
      # API/node baseline before a generic cluster probe can succeed. Their
      # setup scripts own that bounded recovery and call require_cluster only
      # after restoring the prerequisite they deliberately broke.
      [ "$mode" = individual-only ] || require_cluster || return 1
      _question_runtime_run_script "$qdir" setup.sh || return 1
      # A previous disposable lab may still exist, but shared practice must
      # never let its ssh aliases continue targeting that cell.
      _question_runtime_load_cell_library || return 1
      cell_selection_clear_current
      ;;
    kubeadm-bootstrap|kubeadm-ha|kubeadm-upgrade)
      _question_runtime_load_cell_library || return 1
      # kubeadm labs intentionally construct their topology from setup.sh.
      if ! _question_runtime_run_kubeadm_setup "$qdir"; then
        _question_runtime_cleanup_after_failure "$qid" "$qdir" "$environment"
        return 1
      fi
      if ! cell_activate "$qid" "$environment"; then
        _question_runtime_cleanup_after_failure "$qid" "$qdir" "$environment"
        return 1
      fi
      if ! cell_select "$qid" "$environment"; then
        _question_runtime_cleanup_after_failure "$qid" "$qdir" "$environment"
        return 1
      fi
      ;;
    operator-cell|gateway-cell|csi-cell)
      _question_runtime_load_cell_library || return 1
      if ! (cell_prepare "$qid" "$environment"); then
        _question_runtime_cleanup_after_failure "$qid" "$qdir" "$environment"
        return 1
      fi
      if ! cell_activate "$qid" "$environment"; then
        _question_runtime_cleanup_after_failure "$qid" "$qdir" "$environment"
        return 1
      fi
      # Select before any profile or question mutation. Their guards require
      # the native active-cell pointer plus the sealed manifest identity.
      if ! cell_select "$qid" "$environment"; then
        _question_runtime_cleanup_after_failure "$qid" "$qdir" "$environment"
        return 1
      fi
      if ! _question_runtime_profile_prepare "$qid" "$environment"; then
        _question_runtime_cleanup_after_failure "$qid" "$qdir" "$environment"
        return 1
      fi
      if ! _question_runtime_run_script "$qdir" setup.sh; then
        _question_runtime_cleanup_after_failure "$qid" "$qdir" "$environment"
        return 1
      fi
      ;;
  esac
}

question_runtime_grade() { # <qid> <question-dir>
  local qid="$1" qdir="$2" environment
  environment="$(question_runtime_environment "$qdir")" || return 1
  if question_runtime_is_disposable "$environment"; then
    _question_runtime_load_cell_library || return 1
    cell_activate "$qid" "$environment" || return 1
    cell_select "$qid" "$environment" || return 1
    _question_runtime_profile_reactivate "$qid" "$environment" || return 1
  elif [ "$environment" != shared-kind ]; then
    return 1
  fi
  _question_runtime_run_script "$qdir" grade.sh
}

question_runtime_cleanup() { # <qid> <question-dir>
  local qid="$1" qdir="$2" environment mode
  environment="$(question_runtime_environment "$qdir")" || return 1
  mode="$(meta_get "$qdir" mode)" || return 1
  if question_runtime_is_disposable "$environment"; then
    _question_runtime_cleanup_disposable "$qid" "$qdir" "$environment"
    return
  fi
  [ "$environment" = shared-kind ] || return 1
  # A recovery drill's teardown is itself the mechanism that restores an
  # unavailable API, kubelet, CRI, CNI, or service path. Do not block it on
  # the health condition it is responsible for repairing.
  if [ "$mode" = individual-only ] \
      && [ -f "$qdir/teardown.sh" ] && [ ! -L "$qdir/teardown.sh" ]; then
    _question_runtime_run_script "$qdir" teardown.sh
    return
  fi
  require_cluster_readonly || return 1
  if [ -f "$qdir/teardown.sh" ] && [ ! -L "$qdir/teardown.sh" ]; then
    _question_runtime_run_script "$qdir" teardown.sh
  else
    cleanup_question "$qid"
  fi
}

question_runtime_reset() { # <qid> <question-dir>
  local qid="$1" qdir="$2" environment
  environment="$(question_runtime_environment "$qdir")" || return 1
  if question_runtime_is_disposable "$environment"; then
    question_runtime_cleanup "$qid" "$qdir" || return 1
  elif [ "$environment" != shared-kind ]; then
    return 1
  fi
  question_runtime_start "$qid" "$qdir"
}
