#!/usr/bin/env bash
# Disposable practice-cell lifecycle.
#
# A cell is deliberately separate from the long-lived kind-cka cluster.  Every
# Containers and networks are recorded by immutable full ID. Anonymous volume
# names are sealed with their mount destination and an inspect fingerprint.
# Cleanup proves those identities and relationships and never falls back to a
# name/glob/prune based delete.

if [ -z "${CKA_ROOT:-}" ]; then
  CKA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "$CKA_ROOT/lib/common.sh"

# Cell identity must survive separate WSL invocations. XDG_RUNTIME_DIR is
# session-scoped and may be removed when the last session exits, so trusted
# lifecycle journals live under the persistent XDG state home by default.
CKA_CELL_RUNTIME_DIR="${CKA_CELL_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cka-practice/cells}"
CKA_CELL_OWNER_LABEL="cka-practice.cell-owner"
CKA_CELL_QUESTION_LABEL="cka-practice.question"
CKA_CELL_SCHEMA=2
# Project safety floor for the workspace's host filesystem. Disposable HA
# cells can fan out several node volumes, so creation is refused below 10 GiB.
# The threshold is intentionally not environment-configurable; the only
# bypass is the explicit, noisy CKA_CELL_ALLOW_LOW_HOST_SPACE=1 opt-in.
CKA_CELL_MIN_HOST_FREE_KIB=10485760
# Fixed process and readiness ceilings. Question-level setup metadata supplies
# the outer prepare deadline; these inner bounds ensure a wedged child cannot
# retain the lifecycle flock or a PREPARING journal indefinitely.
CKA_CELL_KIND_WAIT_SECONDS=300
CKA_CELL_KIND_CREATE_TIMEOUT_SECONDS=420
CKA_CELL_API_READY_ATTEMPTS=30
# A competing lifecycle operation must never turn prepare-failure cleanup into
# an unbounded wait. The wait is configurable for slower hosts but deliberately
# capped; exit 75 (EX_TEMPFAIL) uniquely identifies lock contention/timeout.
CKA_CELL_LOCK_WAIT_SECONDS="${CKA_CELL_LOCK_WAIT_SECONDS:-15}"
CKA_CELL_LOCK_WAIT_MAX_SECONDS=120
CKA_CELL_LOCK_TIMEOUT_RC=75

cell_qid_valid() {
  [[ "$1" =~ ^(st|wl|sn|ca|ts)-[0-9]{2}$ ]]
}

cell_profile_valid() {
  case "$1" in
    kubeadm-bootstrap|kubeadm-ha|kubeadm-upgrade|operator-cell|gateway-cell|csi-cell) return 0 ;;
    *) return 1 ;;
  esac
}

cell_state_dir() {
  cell_qid_valid "$1" || return 1
  printf '%s/%s\n' "$CKA_CELL_RUNTIME_DIR" "$1"
}

cell_manifest_path() {
  printf '%s/manifest\n' "$(cell_state_dir "$1")"
}

cell_kubeconfig_path() {
  printf '%s/kubeconfig\n' "$(cell_state_dir "$1")"
}

cell_evidence_path() {
  printf '%s/evidence\n' "$(cell_state_dir "$1")"
}

cell_selection_path() {
  printf '%s/active-cell\n' "$CKA_STATE_DIR"
}

_cell_selection_root_preflight() {
  local root resolved
  root="${CKA_STATE_DIR%/}"
  [[ "$root" = /* ]] && [ -n "$root" ] && [ "$root" != / ] || return 1
  # realpath -m also resolves existing parent symlinks when the leaf does not
  # exist yet. This rejects accidental use of a linked state-directory path;
  # the lifecycle lock remains the serialization contract for cooperating
  # writers.
  resolved="$(realpath -m -- "$root" 2>/dev/null)" || return 1
  [ "$resolved" = "$root" ] || return 1
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
  fi
}

# Persist only the selected question id in the repository state. All trusted
# object identity remains in the native-Linux cell manifest and is rechecked
# before a shell or command is allowed to reach a container.
_cell_select_locked() { # <qid> <environment>; caller holds lifecycle lock
  local qid="$1" environment="$2" target tmp
  _cell_lock_is_owned || return 1
  cell_status "$qid" "$environment" >/dev/null || return 1
  _cell_selection_root_preflight || return 1
  [ -d "$CKA_STATE_DIR" ] || mkdir -p -- "$CKA_STATE_DIR" || return 1
  _cell_selection_root_preflight || return 1
  target="$(cell_selection_path)"
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || return 1
  fi
  tmp="$(mktemp "$CKA_STATE_DIR/.active-cell.XXXXXX")" || return 1
  chmod 0600 "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$qid" > "$tmp" || ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

cell_select() ( # <qid> <environment>
  set -uo pipefail
  _cell_lock || return $?
  _cell_select_locked "$@"
)

cell_selected_qid() {
  local target qid extra
  _cell_selection_root_preflight || return 1
  target="$(cell_selection_path)"
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  IFS= read -r qid < "$target" || return 1
  extra="$(sed -n '2,$p' "$target")" || return 1
  [ -z "$extra" ] && cell_qid_valid "$qid" || return 1
  cell_manifest_load "$qid" || return 1
  [ "$CELL_STATUS" = READY ] || return 1
  printf '%s\n' "$qid"
}

_cell_selection_clear_locked() { # <qid>; caller holds lifecycle lock
  local qid="$1" target selected extra
  _cell_lock_is_owned || return 1
  cell_qid_valid "$qid" || return 1
  _cell_selection_root_preflight || return 1
  target="$(cell_selection_path)"
  [ -e "$target" ] || [ -L "$target" ] || return 0
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  IFS= read -r selected < "$target" || return 1
  extra="$(sed -n '2,$p' "$target")" || return 1
  [ -z "$extra" ] && cell_qid_valid "$selected" || return 1
  [ "$selected" = "$qid" ] || return 0
  rm -f -- "$target"
}

cell_selection_clear() ( # <qid>
  set -uo pipefail
  _cell_lock || return $?
  _cell_selection_clear_locked "$@"
)

_cell_selection_clear_current_locked() { # caller holds lifecycle lock
  local target selected extra
  _cell_lock_is_owned || return 1
  _cell_selection_root_preflight || return 1
  target="$(cell_selection_path)"
  [ -e "$target" ] || [ -L "$target" ] || return 0
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  IFS= read -r selected < "$target" || return 1
  extra="$(sed -n '2,$p' "$target")" || return 1
  [ -z "$extra" ] && cell_qid_valid "$selected" || return 1
  rm -f -- "$target"
}

cell_selection_clear_current() (
  set -uo pipefail
  _cell_lock || return $?
  _cell_selection_clear_current_locked
)

cell_active_identity_matches() { # <qid> <environment>
  local qid="$1" environment="$2" selected kubeconfig
  cell_qid_valid "$qid" && cell_profile_valid "$environment" || return 1
  cell_runtime_readonly_ok || return 1
  selected="$(cell_selected_qid)" || return 1
  [ "$selected" = "$qid" ] || return 1
  cell_manifest_load "$qid" || return 1
  kubeconfig="$(cell_kubeconfig_path "$qid")" || return 1
  [ "$CELL_QID" = "$qid" ] \
    && [ "$CELL_PROFILE" = "$environment" ] \
    && [ "$CELL_STATUS" = READY ] \
    && [ "${CKA_CELL_QID:-}" = "$qid" ] \
    && [ "${CKA_CELL_ENVIRONMENT:-}" = "$environment" ] \
    && [ "${CKA_CELL_RUN_ID:-}" = "$CELL_RUN_ID" ] \
    && [ "${CKA_CELL_CLUSTER_NAME:-}" = "$CELL_CLUSTER_NAME" ] \
    && [ "${CKA_CONTEXT:-}" = "kind-$CELL_CLUSTER_NAME" ] \
    && [ "${KUBECONFIG:-}" = "$kubeconfig" ] \
    && [ -f "$kubeconfig" ] && [ ! -L "$kubeconfig" ] \
    && cell_verify_topology "$qid"
}

cell_run_id_valid() { [[ "$1" =~ ^[0-9a-f]{32}$ ]]; }
cell_docker_id_valid() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
cell_name_valid() { [[ "$1" =~ ^cka-cell-(st|wl|sn|ca|ts)-[0-9]{2}-[0-9a-f]{12}$ ]]; }
cell_container_name_valid() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; }
cell_volume_name_valid() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
cell_volume_destination_valid() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    && [[ "$1" != *'//'* ]] && [[ "$1" != *'/../'* ]] \
    && [[ "$1" != '/..' ]] && [[ "$1" != *'/./'* ]] && [[ "$1" != '/.' ]]
}

_cell_volume_arrays_init() {
  declare -gA CELL_VOLUME_COUNTS=()
  declare -gA CELL_VOLUME_NAMES=()
  declare -gA CELL_VOLUME_DESTINATIONS=()
  declare -gA CELL_VOLUME_FINGERPRINTS=()
}

_cell_volume_arrays_ensure() {
  declare -p CELL_VOLUME_COUNTS >/dev/null 2>&1 || declare -gA CELL_VOLUME_COUNTS=()
  declare -p CELL_VOLUME_NAMES >/dev/null 2>&1 || declare -gA CELL_VOLUME_NAMES=()
  declare -p CELL_VOLUME_DESTINATIONS >/dev/null 2>&1 \
    || declare -gA CELL_VOLUME_DESTINATIONS=()
  declare -p CELL_VOLUME_FINGERPRINTS >/dev/null 2>&1 \
    || declare -gA CELL_VOLUME_FINGERPRINTS=()
}

_cell_native_fs_ok() {
  local fs
  [ "${CKA_CELL_ALLOW_NON_NATIVE_STATE:-0}" = 1 ] && return 0
  fs="$(stat -f -c %T "$1" 2>/dev/null)" || return 1
  case "$fs" in
    9p|drvfs|fuseblk|vfat|exfat|ntfs) return 1 ;;
    *) return 0 ;;
  esac
}

cell_runtime_init() {
  local owner mode
  [[ "$CKA_CELL_RUNTIME_DIR" = /* ]] \
    || { err "cell runtime 경로는 절대 경로여야 합니다: $CKA_CELL_RUNTIME_DIR"; return 1; }
  umask 077
  mkdir -p -m 0700 -- "$CKA_CELL_RUNTIME_DIR" || return 1
  [ -d "$CKA_CELL_RUNTIME_DIR" ] && [ ! -L "$CKA_CELL_RUNTIME_DIR" ] || return 1
  owner="$(stat -c %u "$CKA_CELL_RUNTIME_DIR" 2>/dev/null)" || return 1
  mode="$(stat -c %a "$CKA_CELL_RUNTIME_DIR" 2>/dev/null)" || return 1
  [ "$owner" = "$(id -u)" ] || { err "cell runtime 소유자가 현재 사용자와 다릅니다."; return 1; }
  [ "$mode" = 700 ] || { err "cell runtime 권한은 0700이어야 합니다: $mode"; return 1; }
  _cell_native_fs_ok "$CKA_CELL_RUNTIME_DIR" || {
    err "cell 상태는 WSL native Linux filesystem에 두어야 합니다: $CKA_CELL_RUNTIME_DIR"
    return 1
  }
}

cell_runtime_readonly_ok() {
  local owner mode
  [ -d "$CKA_CELL_RUNTIME_DIR" ] && [ ! -L "$CKA_CELL_RUNTIME_DIR" ] || return 1
  owner="$(stat -c %u "$CKA_CELL_RUNTIME_DIR" 2>/dev/null)" || return 1
  mode="$(stat -c %a "$CKA_CELL_RUNTIME_DIR" 2>/dev/null)" || return 1
  [ "$owner" = "$(id -u)" ] && [ "$mode" = 700 ] \
    && _cell_native_fs_ok "$CKA_CELL_RUNTIME_DIR"
}

_cell_lock_fd_safe() { # <fd> <expected-path>
  local fd="$1" lock_path="$2" owner links mode
  [[ "$fd" =~ ^[0-9]+$ ]] \
    && [ -f "$lock_path" ] && [ ! -L "$lock_path" ] \
    && [ -f "/proc/self/fd/$fd" ] \
    && [ "/proc/self/fd/$fd" -ef "$lock_path" ] || return 1
  owner="$(stat -L -c %u -- "/proc/self/fd/$fd" 2>/dev/null)" || return 1
  links="$(stat -L -c %h -- "/proc/self/fd/$fd" 2>/dev/null)" || return 1
  mode="$(stat -L -c %a -- "/proc/self/fd/$fd" 2>/dev/null)" || return 1
  [ "$owner" = "$(id -u)" ] && [ "$links" = 1 ] && [ "$mode" = 600 ]
}

_cell_lock() {
  local lock_path rc reuse_fd=0
  cell_runtime_init || return 1
  lock_path="$CKA_CELL_RUNTIME_DIR/lifecycle.lock"
  if [ -e "$lock_path" ] || [ -L "$lock_path" ]; then
    [ -f "$lock_path" ] && [ ! -L "$lock_path" ] || return 1
  fi

  [[ "$CKA_CELL_LOCK_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
    && [ "$CKA_CELL_LOCK_WAIT_SECONDS" -le "$CKA_CELL_LOCK_WAIT_MAX_SECONDS" ] || {
      err "cell lifecycle lock wait must be 1-${CKA_CELL_LOCK_WAIT_MAX_SECONDS}s"
      return 2
    }

  # Production lifecycle entry points execute in subshells, so their lock FD
  # closes automatically on return. A synchronous nested helper in the same
  # Bash process may safely reuse that exact FD; a stale or inherited marker is
  # closed before attempting a separately bounded acquisition.
  if [[ "${CELL_LOCK_FD:-}" =~ ^[0-9]+$ ]] \
      && [ -e "/proc/self/fd/$CELL_LOCK_FD" ]; then
    if _cell_lock_fd_safe "$CELL_LOCK_FD" "$lock_path"; then
      if [ "${CELL_LOCK_OWNER_BASHPID:-}" = "$BASHPID" ]; then
        reuse_fd=1
      else
        # A child Bash process inherited our exact lock FD. Close only that
        # verified descriptor before a separately bounded acquisition.
        exec {CELL_LOCK_FD}>&-
      fi
    fi
  fi
  if [ "$reuse_fd" -eq 0 ]; then
    # Never close an unrelated descriptor supplied through environment state.
    # Merely discard the untrusted marker and allocate our own descriptor.
    unset CELL_LOCK_FD CELL_LOCK_OWNER_BASHPID
    exec {CELL_LOCK_FD}<> "$lock_path" || return 1
  fi

  _cell_lock_fd_safe "$CELL_LOCK_FD" "$lock_path" || {
    exec {CELL_LOCK_FD}>&-
    unset CELL_LOCK_FD CELL_LOCK_OWNER_BASHPID
    return 1
  }
  if flock --exclusive --wait "$CKA_CELL_LOCK_WAIT_SECONDS" \
      --conflict-exit-code "$CKA_CELL_LOCK_TIMEOUT_RC" "$CELL_LOCK_FD"; then
    CELL_LOCK_OWNER_BASHPID="$BASHPID"
    if _cell_lock_fd_safe "$CELL_LOCK_FD" "$lock_path"; then
      return 0
    fi
    flock --unlock "$CELL_LOCK_FD" >/dev/null 2>&1 || true
    rc=1
  else
    # Capture inside the `else`: an `if` compound with no selected branch may
    # itself report success and would otherwise erase flock's conflict code.
    rc=$?
  fi
  exec {CELL_LOCK_FD}>&-
  unset CELL_LOCK_FD CELL_LOCK_OWNER_BASHPID
  if [ "$rc" -eq "$CKA_CELL_LOCK_TIMEOUT_RC" ]; then
    err "cell lifecycle lock wait exceeded ${CKA_CELL_LOCK_WAIT_SECONDS}s (exit $rc)"
  else
    err "cell lifecycle lock acquisition failed (exit $rc)"
  fi
  return "$rc"
}

_cell_lock_is_owned() {
  local lock_path="$CKA_CELL_RUNTIME_DIR/lifecycle.lock"
  [[ "${CELL_LOCK_FD:-}" =~ ^[0-9]+$ ]] \
    && [ "${CELL_LOCK_OWNER_BASHPID:-}" = "$BASHPID" ] \
    && _cell_lock_fd_safe "$CELL_LOCK_FD" "$lock_path" \
    && flock --exclusive --nonblock "$CELL_LOCK_FD"
}

_cell_df() { df "$@"; }

cell_host_storage_preflight() {
  local available
  case "${CKA_CELL_ALLOW_LOW_HOST_SPACE:-0}" in 0|1) ;; *) return 1 ;; esac
  [ -d "$CKA_ROOT" ] && [ ! -L "$CKA_ROOT" ] || return 1
  available="$(_cell_df -Pk -- "$CKA_ROOT" 2>/dev/null \
    | awk 'NR == 2 { print $4 }')" || return 1
  [[ "$available" =~ ^[0-9]+$ ]] || {
    err "workspace host filesystem의 가용 공간을 확인하지 못했습니다."
    return 1
  }
  if [ "$available" -lt "$CKA_CELL_MIN_HOST_FREE_KIB" ]; then
    if [ "${CKA_CELL_ALLOW_LOW_HOST_SPACE:-0}" = 1 ]; then
      warn "낮은 host 여유 공간을 명시적으로 허용했습니다: ${available} KiB"
      return 0
    fi
    err "일회용 cell 생성에는 workspace host filesystem에 최소 10 GiB가 필요합니다. 현재 ${available} KiB"
    err "공간을 확보하거나 위험을 이해한 경우에만 CKA_CELL_ALLOW_LOW_HOST_SPACE=1을 명시하세요."
    return 1
  fi
}

cell_expected_roles() {
  case "$1" in
    kubeadm-bootstrap|kubeadm-upgrade) printf '%s\n' cp1 worker1 worker2 ;;
    kubeadm-ha) printf '%s\n' cp1 cp2 cp3 worker1 worker2 worker3 lb ;;
    operator-cell|gateway-cell|csi-cell) printf '%s\n' cp1 worker1 ;;
    *) return 1 ;;
  esac
}

cell_role_container_name() {
  local cluster="$1" role="$2"
  case "$role" in
    cp1) printf '%s-control-plane\n' "$cluster" ;;
    cp2) printf '%s-control-plane2\n' "$cluster" ;;
    cp3) printf '%s-control-plane3\n' "$cluster" ;;
    worker1) printf '%s-worker\n' "$cluster" ;;
    worker2) printf '%s-worker2\n' "$cluster" ;;
    worker3) printf '%s-worker3\n' "$cluster" ;;
    lb) printf '%s-external-load-balancer\n' "$cluster" ;;
    *) return 1 ;;
  esac
}

cell_role_node_name() {
  [ "$2" != lb ] || return 1
  cell_role_container_name "$1" "$2"
}

_cell_manifest_value() { # <manifest> <key>
  local manifest="$1" key="$2"
  awk -F= -v key="$key" '
    $1 == key { count++; value=substr($0, length(key)+2) }
    END { if (count != 1) exit 1; print value }
  ' "$manifest"
}

_cell_manifest_syntax_ok() {
  local manifest="$1"
  [ -s "$manifest" ] && [ ! -L "$manifest" ] || return 1
  ! grep -qEv '^[a-z][a-z0-9_]*=[A-Za-z0-9._:/@+-]+$' "$manifest" \
    && awk -F= '{ if (++seen[$1] != 1) exit 1 }' "$manifest"
}

# Loads a manifest into CELL_* and CELL_CONTAINER_IDS[role]. Values are never
# eval'd. A PREPARING manifest may use a PENDING network ID or omit container
# IDs so an interrupted create can be recovered and safely cleaned up later.
cell_manifest_load() {
  local qid="$1" manifest role id key value count index name destination fingerprint allowed
  local -A seen_volume_names=()
  cell_qid_valid "$qid" || return 1
  manifest="$(cell_manifest_path "$qid")" || return 1
  _cell_manifest_syntax_ok "$manifest" || return 1

  CELL_SCHEMA="$(_cell_manifest_value "$manifest" schema)" || return 1
  CELL_RUN_ID="$(_cell_manifest_value "$manifest" run_id)" || return 1
  CELL_QID="$(_cell_manifest_value "$manifest" question_id)" || return 1
  CELL_PROFILE="$(_cell_manifest_value "$manifest" profile)" || return 1
  CELL_CLUSTER_NAME="$(_cell_manifest_value "$manifest" cluster_name)" || return 1
  CELL_NETWORK_NAME="$(_cell_manifest_value "$manifest" network_name)" || return 1
  CELL_NETWORK_ID="$(_cell_manifest_value "$manifest" network_id)" || return 1
  CELL_STATUS="$(_cell_manifest_value "$manifest" status)" || return 1

  [ "$CELL_SCHEMA" = "$CKA_CELL_SCHEMA" ] && [ "$CELL_QID" = "$qid" ] \
    && cell_run_id_valid "$CELL_RUN_ID" && cell_profile_valid "$CELL_PROFILE" \
    && cell_name_valid "$CELL_CLUSTER_NAME" && [ "$CELL_NETWORK_NAME" = "$CELL_CLUSTER_NAME" ] \
    && { cell_docker_id_valid "$CELL_NETWORK_ID" \
      || { [ "$CELL_STATUS" = PREPARING ] && [ "$CELL_NETWORK_ID" = PENDING ]; }; } \
    || return 1
  case "$CELL_STATUS" in PREPARING|READY|DELETING) ;; *) return 1 ;; esac

  declare -gA CELL_CONTAINER_IDS=()
  _cell_volume_arrays_init
  while IFS= read -r role; do
    key="container_$role"
    if id="$(_cell_manifest_value "$manifest" "$key" 2>/dev/null)"; then
      cell_docker_id_valid "$id" || return 1
      CELL_CONTAINER_IDS[$role]="$id"
    elif [ "$CELL_STATUS" = READY ]; then
      return 1
    fi

    count="$(_cell_manifest_value "$manifest" "volume_count_$role")" || return 1
    [[ "$count" =~ ^(0|[1-9][0-9]?)$ ]] && [ "$count" -le 32 ] || return 1
    CELL_VOLUME_COUNTS[$role]="$count"
    for ((index = 0; index < count; index++)); do
      name="$(_cell_manifest_value "$manifest" "volume_${role}_${index}_name")" || return 1
      destination="$(_cell_manifest_value "$manifest" \
        "volume_${role}_${index}_destination")" || return 1
      fingerprint="$(_cell_manifest_value "$manifest" \
        "volume_${role}_${index}_fingerprint")" || return 1
      cell_volume_name_valid "$name" && cell_volume_destination_valid "$destination" \
        && cell_docker_id_valid "$fingerprint" || return 1
      [ -z "${seen_volume_names[$name]+present}" ] || return 1
      seen_volume_names[$name]=1
      CELL_VOLUME_NAMES["$role:$index"]="$name"
      CELL_VOLUME_DESTINATIONS["$role:$index"]="$destination"
      CELL_VOLUME_FINGERPRINTS["$role:$index"]="$fingerprint"
    done
  done < <(cell_expected_roles "$CELL_PROFILE")

  # A trusted manifest is an allowlist, not a bag of partially interpreted
  # fields. Reject extra roles, out-of-range indexes and future fields until a
  # new schema explicitly defines them.
  while IFS='=' read -r key value; do
    allowed=0
    case "$key" in
      schema|run_id|question_id|profile|cluster_name|network_name|network_id|status)
        allowed=1
        ;;
    esac
    if [ "$allowed" -eq 0 ]; then
      while IFS= read -r role; do
        if [ "$key" = "container_$role" ] || [ "$key" = "volume_count_$role" ]; then
          allowed=1
          break
        fi
        count="${CELL_VOLUME_COUNTS[$role]}"
        for ((index = 0; index < count; index++)); do
          case "$key" in
            "volume_${role}_${index}_name"|"volume_${role}_${index}_destination"|\
              "volume_${role}_${index}_fingerprint")
              allowed=1
              break 2
              ;;
          esac
        done
      done < <(cell_expected_roles "$CELL_PROFILE")
    fi
    [ "$allowed" -eq 1 ] || return 1
  done < "$manifest"
}

_cell_manifest_write() {
  local qid="$1" state_dir tmp role id count index key name destination fingerprint
  state_dir="$(cell_state_dir "$qid")" || return 1
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  tmp="$(mktemp "$state_dir/.manifest.XXXXXX")" || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  _cell_volume_arrays_ensure
  {
    printf 'schema=%s\n' "$CKA_CELL_SCHEMA"
    printf 'run_id=%s\n' "$CELL_RUN_ID"
    printf 'question_id=%s\n' "$qid"
    printf 'profile=%s\n' "$CELL_PROFILE"
    printf 'cluster_name=%s\n' "$CELL_CLUSTER_NAME"
    printf 'network_name=%s\n' "$CELL_NETWORK_NAME"
    printf 'network_id=%s\n' "$CELL_NETWORK_ID"
    printf 'status=%s\n' "$CELL_STATUS"
    while IFS= read -r role; do
      id="${CELL_CONTAINER_IDS[$role]:-}"
      if [ -n "$id" ]; then
        printf 'container_%s=%s\n' "$role" "$id"
      fi
      count="${CELL_VOLUME_COUNTS[$role]:-0}"
      [[ "$count" =~ ^(0|[1-9][0-9]?)$ ]] && [ "$count" -le 32 ] || return 1
      printf 'volume_count_%s=%s\n' "$role" "$count"
      for ((index = 0; index < count; index++)); do
        key="$role:$index"
        name="${CELL_VOLUME_NAMES[$key]:-}"
        destination="${CELL_VOLUME_DESTINATIONS[$key]:-}"
        fingerprint="${CELL_VOLUME_FINGERPRINTS[$key]:-}"
        cell_volume_name_valid "$name" && cell_volume_destination_valid "$destination" \
          && cell_docker_id_valid "$fingerprint" || return 1
        printf 'volume_%s_%s_name=%s\n' "$role" "$index" "$name"
        printf 'volume_%s_%s_destination=%s\n' "$role" "$index" "$destination"
        printf 'volume_%s_%s_fingerprint=%s\n' "$role" "$index" "$fingerprint"
      done
    done < <(cell_expected_roles "$CELL_PROFILE")
    : # PREPARING manifests intentionally contain no container IDs yet.
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$state_dir/manifest"
}

_cell_external_timeout() { timeout --foreground --kill-after=5s "$@"; }
_cell_docker() { _cell_external_timeout "${CKA_CELL_DOCKER_TIMEOUT:-45}s" docker "$@"; }

cell_question_setup_timeout_seconds() { # <qid>
  local qdir value
  qdir="$(qdir_of "$1")" || return 1
  value="$(meta_get "$qdir" setup_timeout_seconds)"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$value"
}

cell_wait_api_ready() { # <qid>, accepts PREPARING or READY manifest
  local qid="$1" kubeconfig response attempt
  cell_manifest_load "$qid" || return 1
  kubeconfig="$(cell_kubeconfig_path "$qid")" || return 1
  [ -f "$kubeconfig" ] && [ ! -L "$kubeconfig" ] || return 1
  for ((attempt=1; attempt<=CKA_CELL_API_READY_ATTEMPTS; attempt++)); do
    response="$(_cell_external_timeout 5s kubectl --kubeconfig "$kubeconfig" \
      --request-timeout=3s get --raw=/readyz 2>/dev/null)" || response=""
    [ "$response" = ok ] && return 0
    sleep 1
  done
  return 1
}

_cell_volume_fingerprint() { # <anonymous-volume-name>
  local name="$1" record actual driver scope mountpoint created labels options extra fingerprint
  cell_volume_name_valid "$name" || return 1
  record="$(_cell_docker volume inspect --format \
    '{{.Name}}|{{.Driver}}|{{.Scope}}|{{.Mountpoint}}|{{.CreatedAt}}|{{json .Labels}}|{{json .Options}}' \
    "$name" 2>/dev/null)" || return 1
  [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
  IFS='|' read -r actual driver scope mountpoint created labels options extra <<< "$record"
  [ -z "${extra:-}" ] && [ "$actual" = "$name" ] && [ "$driver" = local ] \
    && [ "$scope" = local ] && [[ "$mountpoint" = /* ]] || return 1
  fingerprint="$(printf '%s' "$record" | sha256sum)" || return 1
  fingerprint="${fingerprint%% *}"
  cell_docker_id_valid "$fingerprint" || return 1
  printf '%s\n' "$fingerprint"
}

_cell_container_volume_mounts() { # <verified-container-id>
  local id="$1" raw name destination extra
  local -a mounts=()
  cell_docker_id_valid "$id" || return 1
  raw="$(_cell_docker container inspect --format \
    '{{range .Mounts}}{{if eq .Type "volume"}}{{printf "%s|%s\n" .Name .Destination}}{{end}}{{end}}' \
    "$id" 2>/dev/null)" || return 1
  [ -z "$raw" ] || [[ "$raw" != *$'\r'* ]] || return 1
  if [ -n "$raw" ]; then
    while IFS='|' read -r name destination extra; do
      [ -z "${extra:-}" ] && cell_volume_name_valid "$name" \
        && cell_volume_destination_valid "$destination" || return 1
      mounts+=("$name|$destination")
    done <<< "$raw"
  fi
  [ "${#mounts[@]}" -le 32 ] || return 1
  if [ "${#mounts[@]}" -gt 0 ]; then
    printf '%s\n' "${mounts[@]}" | LC_ALL=C sort
  fi
}

_cell_capture_container_volumes() { # <role> <verified-container-id>
  local role="$1" id="$2" mounts name destination extra fingerprint index=0 key
  local existing_count existing_index
  local -A seen=()
  local -a staged_names=() staged_destinations=() staged_fingerprints=()
  mounts="$(_cell_container_volume_mounts "$id")" || return 1
  if [ -n "$mounts" ]; then
    while IFS='|' read -r name destination extra; do
      [ -z "${extra:-}" ] && [ -z "${seen[$name]+present}" ] || return 1
      fingerprint="$(_cell_volume_fingerprint "$name")" || return 1
      staged_names[$index]="$name"
      staged_destinations[$index]="$destination"
      staged_fingerprints[$index]="$fingerprint"
      seen[$name]=1
      index=$((index + 1))
    done <<< "$mounts"
  fi

  # Never reseal an already journaled volume generation. During PREPARING a
  # role with count zero is not yet sealed and may be completed while its
  # immutable container is still present.
  existing_count="${CELL_VOLUME_COUNTS[$role]:-0}"
  [[ "$existing_count" =~ ^(0|[1-9][0-9]?)$ ]] || return 1
  if [ "$existing_count" -gt 0 ]; then
    [ "$existing_count" -eq "$index" ] || return 1
    for ((existing_index = 0; existing_index < existing_count; existing_index++)); do
      key="$role:$existing_index"
      [ "${CELL_VOLUME_NAMES[$key]:-}" = "${staged_names[$existing_index]}" ] \
        && [ "${CELL_VOLUME_DESTINATIONS[$key]:-}" = "${staged_destinations[$existing_index]}" ] \
        && [ "${CELL_VOLUME_FINGERPRINTS[$key]:-}" = "${staged_fingerprints[$existing_index]}" ] \
        || return 1
    done
    return 0
  fi

  for ((existing_index = 0; existing_index < index; existing_index++)); do
    key="$role:$existing_index"
    CELL_VOLUME_NAMES[$key]="${staged_names[$existing_index]}"
    CELL_VOLUME_DESTINATIONS[$key]="${staged_destinations[$existing_index]}"
    CELL_VOLUME_FINGERPRINTS[$key]="${staged_fingerprints[$existing_index]}"
  done
  CELL_VOLUME_COUNTS[$role]="$index"
}

_cell_volume_attachment_ids() { # <anonymous-volume-name>
  local name="$1" current id
  local -a ids=()
  cell_volume_name_valid "$name" || return 1
  current="$(_cell_docker ps --all --quiet --no-trunc \
    --filter "volume=$name" 2>/dev/null)" || return 1
  if [ -n "$current" ]; then
    while IFS= read -r id; do
      cell_docker_id_valid "$id" || return 1
      ids+=("$id")
    done <<< "$current"
  fi
  if [ "${#ids[@]}" -gt 0 ]; then
    printf '%s\n' "${ids[@]}" | LC_ALL=C sort -u
  fi
}

_cell_network_attachment_ids() { # <verified-network-id>
  local network_id="$1" current name record id actual_name extra
  local -a ids=()
  cell_docker_id_valid "$network_id" || return 1
  current="$(_cell_docker network inspect --format \
    '{{range .Containers}}{{printf "%s\n" .Name}}{{end}}' \
    "$network_id" 2>/dev/null)" || return 1
  if [ -n "$current" ]; then
    while IFS= read -r name; do
      cell_container_name_valid "$name" || return 1
      record="$(_cell_docker container inspect --format '{{.Id}}|{{.Name}}' \
        "$name" 2>/dev/null)" || return 1
      [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
      IFS='|' read -r id actual_name extra <<< "$record"
      [ -z "${extra:-}" ] && cell_docker_id_valid "$id" \
        && [ "$actual_name" = "/$name" ] || return 1
      ids+=("$id")
    done <<< "$current"
  fi
  [ "${#ids[@]}" -le 32 ] || return 1
  if [ "${#ids[@]}" -gt 0 ]; then
    printf '%s\n' "${ids[@]}" | LC_ALL=C sort -u
  fi
}

cell_verify_role_volumes() { # <qid> <role> <expected-attached-id-or-empty> [allow-missing]
  local qid="$1" role="$2" expected_attached="${3:-}" allow_missing="${4:-0}"
  local id count index key name destination fingerprint actual_fp actual_mounts="" expected_mounts=""
  local attached
  cell_manifest_load "$qid" || return 1
  id="${CELL_CONTAINER_IDS[$role]:-}"
  count="${CELL_VOLUME_COUNTS[$role]:-}"
  [[ "$count" =~ ^(0|[1-9][0-9]?)$ ]] || return 1
  [ -z "$expected_attached" ] || { cell_docker_id_valid "$expected_attached" \
    && [ "$expected_attached" = "$id" ]; } || return 1

  if [ -n "$expected_attached" ]; then
    actual_mounts="$(_cell_container_volume_mounts "$id")" || return 1
  fi
  for ((index = 0; index < count; index++)); do
    key="$role:$index"
    name="${CELL_VOLUME_NAMES[$key]}"
    destination="${CELL_VOLUME_DESTINATIONS[$key]}"
    fingerprint="${CELL_VOLUME_FINGERPRINTS[$key]}"
    expected_mounts+="$name|$destination"$'\n'
    if actual_fp="$(_cell_volume_fingerprint "$name")"; then
      [ "$actual_fp" = "$fingerprint" ] || {
        err "cell volume generation drift를 감지했습니다: $name"
        return 1
      }
    elif _cell_docker info >/dev/null 2>&1; then
      [ "$allow_missing" = 1 ] && [ -z "$expected_attached" ] || return 1
      continue
    else
      return 1
    fi
    attached="$(_cell_volume_attachment_ids "$name")" || return 1
    [ "$attached" = "$expected_attached" ] || {
      err "cell volume에 예상하지 않은 container attachment가 있습니다: $name"
      return 1
    }
  done
  if [ -n "$expected_attached" ]; then
    expected_mounts="${expected_mounts%$'\n'}"
    [ "$actual_mounts" = "$expected_mounts" ] || {
      err "cell container의 volume mount set이 manifest와 다릅니다: $role"
      return 1
    }
  fi
}

cell_verify_container_id() { # <qid> <role> [allow-stopped]
  local qid="$1" role="$2" allow_stopped="${3:-0}" id record running networks
  cell_manifest_load "$qid" || return 1
  id="${CELL_CONTAINER_IDS[$role]:-}"
  cell_docker_id_valid "$id" || return 1
  record="$(_cell_docker container inspect --format \
    '{{.Id}}|{{index .Config.Labels "io.x-k8s.kind.cluster"}}|{{.State.Running}}|{{json .NetworkSettings.Networks}}' \
    "$id" 2>/dev/null)" || return 1
  IFS='|' read -r actual cluster running networks <<< "$record"
  [ "$actual" = "$id" ] && [ "$cluster" = "$CELL_CLUSTER_NAME" ] \
    && printf '%s' "$networks" | grep -Fq "\"$CELL_NETWORK_NAME\"" || return 1
  [ "$allow_stopped" = 1 ] || [ "$running" = true ]
}

cell_verify_network_id() {
  local qid="$1" record actual owner question
  cell_manifest_load "$qid" || return 1
  record="$(_cell_docker network inspect --format \
    "{{.Id}}|{{index .Labels \"$CKA_CELL_OWNER_LABEL\"}}|{{index .Labels \"$CKA_CELL_QUESTION_LABEL\"}}" \
    "$CELL_NETWORK_ID" 2>/dev/null)" || return 1
  IFS='|' read -r actual owner question <<< "$record"
  [ "$actual" = "$CELL_NETWORK_ID" ] && [ "$owner" = "$CELL_RUN_ID" ] \
    && [ "$question" = "$qid" ]
}

cell_verify_topology() {
  local qid="$1" role id current recorded="" extras=""
  cell_manifest_load "$qid" || return 1
  [ "$CELL_STATUS" = READY ] || return 1
  cell_verify_network_id "$qid" || return 1
  while IFS= read -r role; do
    id="${CELL_CONTAINER_IDS[$role]:-}"
    cell_verify_container_id "$qid" "$role" || return 1
    cell_verify_role_volumes "$qid" "$role" "$id" || return 1
    recorded+="$id"$'\n'
  done < <(cell_expected_roles "$CELL_PROFILE")
  current="$(_cell_docker ps --all --quiet --no-trunc --filter \
    "label=io.x-k8s.kind.cluster=$CELL_CLUSTER_NAME" 2>/dev/null)" || return 1
  extras="$(comm -13 \
    <(printf '%s' "$recorded" | sed '/^$/d' | sort) \
    <(printf '%s\n' "$current" | sed '/^$/d' | sort))"
  [ -z "$extras" ]
}

_cell_capture_expected_ids() { # [qid], incrementally seals verified roles when supplied
  local qid="${1:-}" role name target record id actual_name cluster networks extra existing
  local current recorded="" extras=""
  while IFS= read -r role; do
    name="$(cell_role_container_name "$CELL_CLUSTER_NAME" "$role")" || return 1
    existing="${CELL_CONTAINER_IDS[$role]:-}"
    target="${existing:-$name}"
    record="$(_cell_docker container inspect --format \
      '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.x-k8s.kind.cluster"}}|{{json .NetworkSettings.Networks}}' \
      "$target" 2>/dev/null)" || {
        # A role already sealed by immutable ID may have been removed by an
        # interrupted cleanup. Preserve its journal entry; missing unsealed
        # roles are valid after a partial kind failure.
        [ -n "$existing" ] && recorded+="$existing"$'\n'
        continue
      }
    [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
    IFS='|' read -r id actual_name cluster networks extra <<< "$record"
    [ -z "${extra:-}" ] && cell_docker_id_valid "$id" \
      && [ "$cluster" = "$CELL_CLUSTER_NAME" ] \
      && printf '%s' "$networks" | grep -Fq "\"$CELL_NETWORK_NAME\"" || return 1
    if [ -n "$existing" ]; then
      [ "$id" = "$existing" ] || return 1
    else
      # Name lookup is only trusted before an immutable ID is sealed. Require
      # Docker's canonical exact name as well as the kind label and membership
      # of the run-owned network.
      [ "$actual_name" = "/$name" ] || return 1
    fi
    _cell_capture_container_volumes "$role" "$id" || return 1
    CELL_CONTAINER_IDS[$role]="$id"
    recorded+="$id"$'\n'
    [ -z "$qid" ] || _cell_manifest_write "$qid" || return 1
  done < <(cell_expected_roles "$CELL_PROFILE")

  current="$(_cell_docker ps --all --quiet --no-trunc --filter \
    "label=io.x-k8s.kind.cluster=$CELL_CLUSTER_NAME" 2>/dev/null)" || return 1
  extras="$(comm -13 \
    <(printf '%s' "$recorded" | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "$current" | sed '/^$/d' | sort -u))"
  [ -z "$extras" ] || {
    err "journal에 봉인할 수 없는 동일-cluster 컨테이너가 있습니다: ${extras//$'\n'/,}"
    return 1
  }
}

_cell_recover_preparing_network() { # <qid>, seals a run-labelled network
  local qid="$1" record id actual_name owner question extra current owned
  [ "$CELL_STATUS" = PREPARING ] || return 1
  [ "$CELL_NETWORK_ID" = PENDING ] || return 0
  if ! record="$(_cell_docker network inspect --format \
      "{{.Id}}|{{.Name}}|{{index .Labels \"$CKA_CELL_OWNER_LABEL\"}}|{{index .Labels \"$CKA_CELL_QUESTION_LABEL\"}}" \
      "$CELL_NETWORK_NAME" 2>/dev/null)"; then
    _cell_docker info >/dev/null 2>&1 || return 1
    # Distinguish a missing network from a formatting/transient failure and
    # prove that no renamed network still carries this run's owner label.
    ! _cell_docker network inspect "$CELL_NETWORK_NAME" >/dev/null 2>&1 || return 1
    owned="$(_cell_docker network ls --quiet --no-trunc \
      --filter "label=$CKA_CELL_OWNER_LABEL=$CELL_RUN_ID" 2>/dev/null)" || return 1
    [ -z "$owned" ] || return 1
    current="$(_cell_docker ps --all --quiet --no-trunc --filter \
      "label=io.x-k8s.kind.cluster=$CELL_CLUSTER_NAME" 2>/dev/null)" || return 1
    [ -z "$current" ] || return 1
    return 0
  fi
  [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
  IFS='|' read -r id actual_name owner question extra <<< "$record"
  [ -z "${extra:-}" ] && cell_docker_id_valid "$id" \
    && [ "$actual_name" = "$CELL_NETWORK_NAME" ] \
    && [ "$owner" = "$CELL_RUN_ID" ] && [ "$question" = "$qid" ] || return 1
  CELL_NETWORK_ID="$id"
  _cell_manifest_write "$qid"
}

_cell_recover_preparing_manifest() { # <qid>
  local qid="$1"
  cell_manifest_load "$qid" || return 1
  [ "$CELL_STATUS" = PREPARING ] || return 0
  _cell_recover_preparing_network "$qid" || return 1
  [ "$CELL_NETWORK_ID" != PENDING ] || return 0
  cell_verify_network_id "$qid" || return 1
  # cell_verify_network_id reloads the journal. Seal each verified role and
  # its complete anonymous-volume set in a separate atomic manifest replace.
  _cell_capture_expected_ids "$qid"
}

# Explicit administrator recovery for a PREPARING kind cell whose local
# journal was lost. It never scans broadly or deletes anything: the caller
# supplies the exact question, profile and random cluster name; the network's
# full owner label reconstructs the run ID; and every expected deterministic
# container, cluster label, network endpoint and anonymous-volume generation
# must agree before a new PREPARING journal is committed.
cell_recover_preparing() ( # <qid> <profile> <exact-cluster-name>
  set -uo pipefail
  local qid="$1" profile="$2" cluster_name="$3" state_dir suffix record
  local network_id actual_name run_id question extra role id recorded="" attached
  cell_feature_enabled \
    || { err "cell journal 복구에는 CKA_ENABLE_DISPOSABLE_CELLS=1 이 필요합니다."; return 1; }
  cell_qid_valid "$qid" && cell_profile_valid "$profile" \
    && cell_name_valid "$cluster_name" || return 1
  suffix="${cluster_name##*-}"
  [ "$cluster_name" = "cka-cell-$qid-$suffix" ] && [[ "$suffix" =~ ^[0-9a-f]{12}$ ]] \
    || return 1
  for command in docker flock timeout stat sha256sum sed sort comm; do
    command -v "$command" >/dev/null || return 1
  done
  _cell_docker info >/dev/null 2>&1 || return 1
  _cell_lock || return $?
  state_dir="$(cell_state_dir "$qid")" || return 1
  [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ] \
    || { err "$qid cell journal이 이미 있어 복구로 덮어쓰지 않습니다."; return 1; }

  record="$(_cell_docker network inspect --format \
    "{{.Id}}|{{.Name}}|{{index .Labels \"$CKA_CELL_OWNER_LABEL\"}}|{{index .Labels \"$CKA_CELL_QUESTION_LABEL\"}}" \
    "$cluster_name" 2>/dev/null)" || return 1
  [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
  IFS='|' read -r network_id actual_name run_id question extra <<< "$record"
  [ -z "${extra:-}" ] && cell_docker_id_valid "$network_id" \
    && [ "$actual_name" = "$cluster_name" ] && cell_run_id_valid "$run_id" \
    && [ "${run_id:0:12}" = "$suffix" ] && [ "$question" = "$qid" ] || return 1

  CELL_RUN_ID="$run_id"
  CELL_QID="$qid"
  CELL_PROFILE="$profile"
  CELL_CLUSTER_NAME="$cluster_name"
  CELL_NETWORK_NAME="$cluster_name"
  CELL_NETWORK_ID="$network_id"
  CELL_STATUS=PREPARING
  declare -gA CELL_CONTAINER_IDS=()
  _cell_volume_arrays_init
  while IFS= read -r role; do
    CELL_VOLUME_COUNTS[$role]=0
  done < <(cell_expected_roles "$CELL_PROFILE")

  _cell_capture_expected_ids "" || return 1
  while IFS= read -r role; do
    id="${CELL_CONTAINER_IDS[$role]:-}"
    cell_docker_id_valid "$id" || {
      err "복구 대상에 필수 cell 컨테이너가 없습니다: $role"
      return 1
    }
    recorded+="$id"$'\n'
  done < <(cell_expected_roles "$CELL_PROFILE")
  attached="$(_cell_network_attachment_ids "$CELL_NETWORK_ID")" || return 1
  extra="$(comm -13 \
    <(printf '%s' "$recorded" | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "$attached" | sed '/^$/d' | sort -u))"
  [ -z "$extra" ] || {
    err "복구 대상 network에 봉인되지 않은 endpoint가 있습니다: ${extra//$'\n'/,}"
    return 1
  }

  mkdir -m 0700 -- "$state_dir" || return 1
  _cell_manifest_write "$qid" || return 1
  # Re-read and revalidate the committed allowlist before reporting success.
  _cell_preflight_destroy "$qid" || {
    err "복구 journal은 보존했지만 최종 재검증에 실패했습니다. 삭제하지 않습니다."
    return 1
  }
  ok "$qid PREPARING cell journal 복구 완료: $cluster_name"
)

cell_feature_enabled() {
  [ "${CKA_ENABLE_DISPOSABLE_CELLS:-${CKA_ENABLE_KUBEADM_CELLS:-0}}" = 1 ]
}

cell_create() ( # <qid> <profile> <kind-config>
  set -uo pipefail
  local qid="$1" profile="$2" config="$3" state_dir network_id kind_rc=0 role
  cell_feature_enabled \
    || { err "일회용 셀은 CKA_ENABLE_DISPOSABLE_CELLS=1 일 때만 생성합니다."; return 1; }
  cell_qid_valid "$qid" && cell_profile_valid "$profile" && [ -r "$config" ] || return 1
  for command in docker kind kubectl flock timeout stat sha256sum df awk; do
    command -v "$command" >/dev/null || { err "$command 이 필요합니다."; return 1; }
  done
  cell_host_storage_preflight || return 1
  _cell_docker info >/dev/null 2>&1 || { err "Docker daemon에 연결할 수 없습니다."; return 1; }
  _cell_lock || return $?
  state_dir="$(cell_state_dir "$qid")" || return 1
  [ ! -e "$state_dir" ] || { err "$qid cell이 이미 존재합니다. 검증된 down을 먼저 실행하세요."; return 1; }
  mkdir -m 0700 -- "$state_dir" || return 1

  CELL_RUN_ID="$(tr -d '-' < /proc/sys/kernel/random/uuid)"
  cell_run_id_valid "$CELL_RUN_ID" || return 1
  CELL_QID="$qid"
  CELL_PROFILE="$profile"
  CELL_CLUSTER_NAME="cka-cell-${qid}-${CELL_RUN_ID:0:12}"
  CELL_NETWORK_NAME="$CELL_CLUSTER_NAME"
  CELL_STATUS=PREPARING
  declare -gA CELL_CONTAINER_IDS=()
  _cell_volume_arrays_init
  while IFS= read -r role; do
    CELL_VOLUME_COUNTS[$role]=0
  done < <(cell_expected_roles "$CELL_PROFILE")

  # Persist the random run identity before allocating the first Docker object.
  # If network creation succeeds but this process exits before capturing its
  # output, cleanup can recover only the exact run-labelled network by name.
  CELL_NETWORK_ID=PENDING
  _cell_manifest_write "$qid" || {
    err "cell PREPARING intent manifest를 기록하지 못했습니다."
    return 1
  }
  network_id="$(_cell_docker network create --driver bridge \
    --label "$CKA_CELL_OWNER_LABEL=$CELL_RUN_ID" \
    --label "$CKA_CELL_QUESTION_LABEL=$qid" "$CELL_NETWORK_NAME")" || return 1
  CELL_NETWORK_ID="${network_id#sha256:}"
  cell_docker_id_valid "$CELL_NETWORK_ID" || {
    err "Docker가 유효한 full network ID를 반환하지 않았습니다."
    return 1
  }
  _cell_manifest_write "$qid" || {
    err "cell PREPARING network manifest를 기록하지 못했습니다."
    return 1
  }

  _cell_external_timeout "${CKA_CELL_KIND_CREATE_TIMEOUT_SECONDS}s" \
    env KIND_EXPERIMENTAL_DOCKER_NETWORK="$CELL_NETWORK_NAME" \
    kind create cluster --name "$CELL_CLUSTER_NAME" --image "$KIND_NODE_IMAGE" \
      --config "$config" --kubeconfig "$state_dir/kubeconfig" \
      --wait "${CKA_CELL_KIND_WAIT_SECONDS}s" || kind_rc=$?
  _cell_capture_expected_ids "$qid" || {
    err "cell object journal 기록에 실패했습니다. 다음 cleanup은 PREPARING journal을 먼저 복구합니다."
    return 1
  }
  _cell_manifest_write "$qid" || return 1
  [ "$kind_rc" -eq 0 ] || {
    err "kind cell 생성 실패 또는 ${CKA_CELL_KIND_CREATE_TIMEOUT_SECONDS}s deadline 초과. 기록된 immutable ID는 'cell.sh down $qid'으로만 정리하세요."
    return "$kind_rc"
  }
  while IFS= read -r role; do
    cell_docker_id_valid "${CELL_CONTAINER_IDS[$role]:-}" \
      || { err "필수 cell 컨테이너를 기록하지 못했습니다: $role"; return 1; }
  done < <(cell_expected_roles "$CELL_PROFILE")
  chmod 0600 "$state_dir/kubeconfig" || return 1
  ok "$qid disposable cell 생성 완료: $CELL_CLUSTER_NAME"
)

cell_mark_ready() (
  set -uo pipefail
  local qid="$1"
  _cell_lock || return $?
  cell_manifest_load "$qid" || return 1
  [ "$CELL_STATUS" = PREPARING ] || return 1
  # PREPARING is intentionally accepted here; every expected object must be
  # present/running before the state can become READY.
  local role
  while IFS= read -r role; do
    cell_verify_container_id "$qid" "$role" || return 1
    cell_verify_role_volumes "$qid" "$role" "${CELL_CONTAINER_IDS[$role]}" || return 1
  done < <(cell_expected_roles "$CELL_PROFILE")
  case "$CELL_PROFILE" in
    # This exercise intentionally finishes with blank kubeadm hosts and no API.
    kubeadm-bootstrap) ;;
    *)
      cell_wait_api_ready "$qid" || {
        err "$qid API /readyz가 bounded readiness window 안에 준비되지 않았습니다."
        return 1
      }
      ;;
  esac
  CELL_STATUS=READY
  _cell_manifest_write "$qid"
)

_cell_preflight_destroy() {
  local qid="$1" role id current recorded="" attached_expected="" attached_current extra=""
  cell_manifest_load "$qid" || return 1
  cell_verify_network_id "$qid" || return 1
  while IFS= read -r role; do
    id="${CELL_CONTAINER_IDS[$role]:-}"
    [ -n "$id" ] || continue
    recorded+="$id"$'\n'
    if _cell_docker container inspect "$id" >/dev/null 2>&1; then
      cell_verify_container_id "$qid" "$role" 1 || return 1
      cell_verify_role_volumes "$qid" "$role" "$id" || return 1
      attached_expected+="$id"$'\n'
    elif _cell_docker info >/dev/null 2>&1; then
      # An interrupted cleanup may already have removed the container. Only
      # the sealed volume generation may remain, and it must be unattached.
      cell_verify_role_volumes "$qid" "$role" "" 1 || return 1
    else
      return 1
    fi
  done < <(cell_expected_roles "$CELL_PROFILE")
  current="$(_cell_docker ps --all --quiet --no-trunc --filter \
    "label=io.x-k8s.kind.cluster=$CELL_CLUSTER_NAME" 2>/dev/null)" || return 1
  extra="$(comm -13 \
    <(printf '%s' "$recorded" | sed '/^$/d' | sort) \
    <(printf '%s\n' "$current" | sed '/^$/d' | sort))"
  [ -z "$extra" ] || {
    err "manifest에 없는 동일-cluster 컨테이너가 있어 삭제를 거부합니다: ${extra//$'\n'/,}"
    return 1
  }
  attached_current="$(_cell_network_attachment_ids "$CELL_NETWORK_ID")" || return 1
  extra="$(comm -13 \
    <(printf '%s' "$attached_expected" | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "$attached_current" | sed '/^$/d' | sort -u))"
  [ -z "$extra" ] || {
    # Docker removes a stopped container from network inspect's live endpoint
    # map even though the immutable container and its configured network are
    # still inspectable. Missing sealed IDs are therefore safe; only current
    # endpoints outside the sealed-and-existing ID allowlist block deletion.
    err "cell network에 manifest container가 아닌 endpoint가 있어 삭제를 거부합니다: ${extra//$'\n'/,}"
    return 1
  }
}

_cell_state_files_preflight() { # <qid>; caller holds lifecycle lock
  local qid="$1" state_dir entry name rc=0 dotglob_set=0 nullglob_set=0
  local -a entries=()
  _cell_lock_is_owned || return 1
  state_dir="$(cell_state_dir "$qid")" || return 1
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  shopt -q dotglob && dotglob_set=1
  shopt -q nullglob && nullglob_set=1
  shopt -s dotglob nullglob
  entries=("$state_dir"/*)
  for entry in "${entries[@]}"; do
    name="${entry##*/}"
    case "$name" in
      manifest|kubeconfig|evidence)
        [ -f "$entry" ] && [ ! -L "$entry" ] || {
          err "안전한 일반 파일이 아닌 cell 상태 항목이 있습니다: $entry"
          rc=1
          break
        }
        ;;
      *)
        err "알 수 없는 cell 상태 파일을 보존하고 삭제를 중단합니다: $entry"
        rc=1
        break
        ;;
    esac
  done
  [ "$dotglob_set" -eq 1 ] || shopt -u dotglob
  [ "$nullglob_set" -eq 1 ] || shopt -u nullglob
  return "$rc"
}

_cell_prepare_destroy_locked() { # <qid> [require-present]; caller holds the lifecycle lock
  local qid="$1" require_present="${2:-0}" state_dir
  _cell_lock_is_owned || return 1
  state_dir="$(cell_state_dir "$qid")" || return 1
  if [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ]; then
    [ "$require_present" = 0 ]
    return $?
  fi
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  _cell_state_files_preflight "$qid" || return 1
  cell_manifest_load "$qid" || return 1
  if [ "$CELL_STATUS" = PREPARING ]; then
    _cell_recover_preparing_manifest "$qid" || {
      err "PREPARING cell journal을 안전하게 복구할 수 없어 삭제를 거부합니다."
      return 1
    }
    _cell_state_files_preflight "$qid" || return 1
    cell_manifest_load "$qid" || return 1
  fi
  [ "$CELL_NETWORK_ID" = PENDING ] && return 0
  _cell_preflight_destroy "$qid" || return 1
}

_cell_remove_local_state_locked() { # <qid>; caller holds lifecycle lock and loaded manifest
  local qid="$1" state_dir unknown rc
  _cell_lock_is_owned || return 1
  state_dir="$(cell_state_dir "$qid")" || return 1
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  _cell_state_files_preflight "$qid" || return 1
  rm -f -- "$state_dir/kubeconfig" "$state_dir/evidence" || return 1
  rm -f -- "$state_dir/manifest" || return 1
  unknown="$(find "$state_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || {
    _cell_manifest_write "$qid" >/dev/null 2>&1 || true
    return 1
  }
  if [ -n "$unknown" ]; then
    _cell_manifest_write "$qid" >/dev/null 2>&1 \
      || err "cell ownership manifest 복원에도 실패했습니다: $qid"
    err "알 수 없는 cell 상태 파일을 보존하고 삭제를 중단합니다: $unknown"
    return 1
  fi
  if rmdir -- "$state_dir"; then
    return 0
  else
    rc=$?
  fi
  # A transient rmdir failure must not strand an empty qid directory without
  # the immutable ownership evidence needed by a later exact cleanup retry.
  if [ -d "$state_dir" ] && [ ! -L "$state_dir" ]; then
    _cell_manifest_write "$qid" >/dev/null 2>&1 \
      || err "cell ownership manifest 복원에도 실패했습니다: $qid"
  fi
  return "$rc"
}

_cell_destroy_locked() { # <qid> [require-present]; caller holds the lifecycle lock
  local qid="$1" require_present="${2:-0}" state_dir role id remaining count index key name fingerprint actual_fp attached
  local removed_network_id
  _cell_lock_is_owned || return 1
  state_dir="$(cell_state_dir "$qid")" || return 1
  if [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ]; then
    [ "$require_present" = 0 ]
    return $?
  fi
  _cell_prepare_destroy_locked "$qid" "$require_present" || return 1
  [ "$require_present" = 0 ] || { [ -d "$state_dir" ] && [ ! -L "$state_dir" ]; } \
    || return 1
  if [ "$CELL_NETWORK_ID" = PENDING ]; then
    # The intent was persisted before network allocation. Recovery proved that
    # neither the exact network nor any same-cluster container exists, so only
    # the local journal may be removed.
    _cell_remove_local_state_locked "$qid" || return 1
    ok "$qid unallocated disposable cell journal 삭제 완료"
    return 0
  fi
  CELL_STATUS=DELETING
  _cell_manifest_write "$qid" || return 1

  while IFS= read -r role; do
    id="${CELL_CONTAINER_IDS[$role]:-}"
    [ -n "$id" ] || continue
    if _cell_docker container inspect "$id" >/dev/null 2>&1; then
      cell_verify_container_id "$qid" "$role" 1 || return 1
      _cell_docker container rm --force "$id" >/dev/null || return 1
    fi
  done < <(cell_expected_roles "$CELL_PROFILE" | tac)

  remaining="$(_cell_docker ps --all --quiet --no-trunc --filter \
    "label=io.x-k8s.kind.cluster=$CELL_CLUSTER_NAME" 2>/dev/null)" || return 1
  [ -z "$remaining" ] || { err "cell 컨테이너가 남아 network 삭제를 중단합니다."; return 1; }

  # Docker's default container removal leaves image-declared anonymous
  # volumes behind. Remove only the exact anonymous generations sealed in the
  # manifest. A foreign attachment or a same-name recreated volume fails
  # closed before any volume delete is attempted.
  while IFS= read -r role; do
    count="${CELL_VOLUME_COUNTS[$role]}"
    for ((index = 0; index < count; index++)); do
      key="$role:$index"
      name="${CELL_VOLUME_NAMES[$key]}"
      fingerprint="${CELL_VOLUME_FINGERPRINTS[$key]}"
      if actual_fp="$(_cell_volume_fingerprint "$name")"; then
        [ "$actual_fp" = "$fingerprint" ] \
          || { err "cell volume generation drift로 삭제를 거부합니다: $name"; return 1; }
        attached="$(_cell_volume_attachment_ids "$name")" || return 1
        [ -z "$attached" ] \
          || { err "사용 중인 cell volume 삭제를 거부합니다: $name"; return 1; }
        _cell_docker volume rm "$name" >/dev/null || return 1
      elif _cell_docker info >/dev/null 2>&1; then
        : # already absent after an interrupted cleanup
      else
        return 1
      fi
    done
  done < <(cell_expected_roles "$CELL_PROFILE" | tac)

  cell_verify_network_id "$qid" || return 1
  [ "$(_cell_docker network inspect --format '{{len .Containers}}' "$CELL_NETWORK_ID")" = 0 ] \
    || { err "cell network에 연결된 endpoint가 남았습니다."; return 1; }
  removed_network_id="$CELL_NETWORK_ID"
  # Publish a recoverable no-container/no-volume intent before the final
  # network removal. If the process stops afterwards, PREPARING recovery can
  # prove whether this exact run-labelled network still exists and retry.
  CELL_STATUS=PREPARING
  CELL_NETWORK_ID=PENDING
  declare -gA CELL_CONTAINER_IDS=()
  _cell_volume_arrays_init
  while IFS= read -r role; do
    CELL_VOLUME_COUNTS[$role]=0
  done < <(cell_expected_roles "$CELL_PROFILE")
  _cell_manifest_write "$qid" || return 1
  _cell_docker network rm "$removed_network_id" >/dev/null || return 1
  _cell_remove_local_state_locked "$qid" || return 1
  ok "$qid disposable cell 삭제 완료"
}

cell_destroy() ( # <qid>
  set -uo pipefail
  local qid="$1"
  cell_feature_enabled \
    || { err "일회용 셀 삭제에는 CKA_ENABLE_DISPOSABLE_CELLS=1 이 필요합니다."; return 1; }
  _cell_lock || return $?
  _cell_destroy_locked "$qid"
)

_cell_selection_clear_preflight() {
  local target qid extra
  _cell_lock_is_owned || return 1
  _cell_selection_root_preflight || return 1
  target="$(cell_selection_path)"
  [ -e "$target" ] || [ -L "$target" ] || return 0
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  IFS= read -r qid < "$target" || return 1
  extra="$(sed -n '2,$p' "$target")" || return 1
  [ -z "$extra" ] && cell_qid_valid "$qid"
}

_cell_managed_inventory_preflight_locked() { # <qid...>; detection only, never deletion authority
  local qid role id current record actual cluster marker extra
  local -A expected_networks=() expected_containers=() seen_networks=() seen_containers=()
  _cell_lock_is_owned || return 1

  for qid in "$@"; do
    cell_manifest_load "$qid" || return 1
    if [ "$CELL_NETWORK_ID" != PENDING ]; then
      expected_networks[$CELL_NETWORK_ID]=1
    fi
    while IFS= read -r role; do
      id="${CELL_CONTAINER_IDS[$role]:-}"
      [ -z "$id" ] || expected_containers[$id]=1
    done < <(cell_expected_roles "$CELL_PROFILE")
  done

  current="$(_cell_docker network ls --quiet --no-trunc \
    --filter "label=$CKA_CELL_OWNER_LABEL" 2>/dev/null)" || return 1
  if [ -n "$current" ]; then
    while IFS= read -r id; do
      cell_docker_id_valid "$id" && [ -z "${seen_networks[$id]+present}" ] || return 1
      seen_networks[$id]=1
      [ -n "${expected_networks[$id]+present}" ] || {
        err "journal에 없는 cka-practice cell network를 감지해 전체 정리를 중단합니다: $id"
        return 1
      }
    done <<< "$current"
  fi
  for id in "${!expected_networks[@]}"; do
    [ -n "${seen_networks[$id]+present}" ] || return 1
  done

  current="$(_cell_docker ps --all --quiet --no-trunc \
    --filter 'label=io.x-k8s.kind.cluster' 2>/dev/null)" || return 1
  if [ -n "$current" ]; then
    while IFS= read -r id; do
      cell_docker_id_valid "$id" || return 1
      record="$(_cell_docker container inspect --format \
        '{{.Id}}|{{index .Config.Labels "io.x-k8s.kind.cluster"}}|END' \
        "$id" 2>/dev/null)" || return 1
      [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
      IFS='|' read -r actual cluster marker extra <<< "$record"
      [ "$actual" = "$id" ] && [ "$marker" = END ] && [ -z "${extra:-}" ] || return 1
      [[ "$cluster" =~ ^cka-cell-(st|wl|sn|ca|ts)-[0-9]{2}-[0-9a-f]{12}$ ]] || continue
      [ -z "${seen_containers[$id]+present}" ] || return 1
      seen_containers[$id]=1
      [ -n "${expected_containers[$id]+present}" ] || {
        err "journal에 없는 cka-practice cell container를 감지해 전체 정리를 중단합니다: $id"
        return 1
      }
    done <<< "$current"
  fi
  # Missing sealed containers are valid after an interrupted cleanup. The
  # destructive per-cell preflight separately verifies any surviving sealed
  # container and its remaining volume generation. Inventory is only used to
  # reject cka-cell containers that no journal authorizes.
}

# Delete only cells whose immutable journals live in the protected runtime
# root.  Names, KIND inventory and Docker labels are never deletion authority.
# All journals and Docker relationships are preflighted under one lifecycle
# lock before the first exact-ID removal.
_cell_cleanup_all_managed_locked() { # caller holds lifecycle lock
  local runtime entry qid index identity unknown
  local -a entries=() confirmed_entries=() qids=() journal_identities=() remaining=()
  local -a tombstones=() tombstone_identities=()

  _cell_lock_is_owned || return 1
  CKA_ENABLE_DISPOSABLE_CELLS="${CKA_ENABLE_DISPOSABLE_CELLS:-1}"
  cell_feature_enabled \
    || { err "일회용 셀 전체 정리에는 CKA_ENABLE_DISPOSABLE_CELLS=1 이 필요합니다."; return 1; }
  runtime="${CKA_CELL_RUNTIME_DIR%/}"
  [ -n "$runtime" ] && [ "$runtime" != / ] || return 1
  _cell_selection_clear_preflight || {
    err "active-cell 선택 상태가 손상되어 전체 정리를 중단합니다."
    return 1
  }

  shopt -s dotglob nullglob
  entries=("$runtime"/*)
  for entry in "${entries[@]}"; do
    if [ "$entry" = "$runtime/lifecycle.lock" ]; then
      [ -f "$entry" ] && [ ! -L "$entry" ] \
        && [ "$(stat -c %u -- "$entry" 2>/dev/null)" = "$(id -u)" ] \
        && [ "$(stat -c %h -- "$entry" 2>/dev/null)" = 1 ] \
        && [ "$(stat -c %a -- "$entry" 2>/dev/null)" = 600 ] || {
        err "일회용 셀 lifecycle lock이 안전한 일반 파일이 아닙니다."
        return 1
      }
      continue
    fi
    qid="${entry##*/}"
    [ -d "$entry" ] && [ ! -L "$entry" ] && cell_qid_valid "$qid" || {
      err "알 수 없거나 안전하지 않은 일회용 셀 상태 항목이 있습니다: $entry"
      return 1
    }
    identity="$(stat -c '%d:%i' -- "$entry" 2>/dev/null)" || return 1
    if [ ! -e "$entry/manifest" ] && [ ! -L "$entry/manifest" ]; then
      unknown="$(find "$entry" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" \
        || return 1
      [ -z "$unknown" ] || {
        err "manifest가 없는 일회용 셀 상태를 보존하고 전체 정리를 중단합니다: $qid"
        return 1
      }
      # A process can stop after unlinking the final manifest but before the
      # qid directory rmdir. Treat only a completely empty, identity-pinned
      # directory as local post-cleanup debris. Docker inventory below must
      # still prove that no unjournaled cell object exists.
      tombstones+=("$qid")
      tombstone_identities+=("$identity")
    else
      cell_manifest_load "$qid" || {
        err "일회용 셀 manifest를 사전 검증하지 못했습니다: $qid"
        return 1
      }
      qids+=("$qid")
      journal_identities+=("$identity")
    fi
  done

  for qid in "${qids[@]}"; do
    _cell_prepare_destroy_locked "$qid" 1 || {
      err "일회용 셀 삭제 전 전체 사전 검증에 실패했습니다: $qid"
      return 1
    }
  done
  _cell_managed_inventory_preflight_locked "${qids[@]}" || {
    err "Docker inventory와 cell journal이 일치하지 않아 전체 정리를 중단합니다."
    return 1
  }

  # Cooperative creators share this lock. Reconfirm the direct-child snapshot
  # anyway so an out-of-contract writer cannot be hidden by the batch cleanup.
  confirmed_entries=("$runtime"/*)
  [ "${#confirmed_entries[@]}" -eq "${#entries[@]}" ] || {
    err "일회용 셀 inventory가 사전 검증 중 변경되었습니다."
    return 1
  }
  for ((index=0; index < ${#entries[@]}; index++)); do
    [ "${confirmed_entries[$index]}" = "${entries[$index]}" ] || {
      err "일회용 셀 inventory가 사전 검증 중 변경되었습니다."
      return 1
    }
  done

  for ((index=0; index < ${#tombstones[@]}; index++)); do
    qid="${tombstones[$index]}"
    entry="$runtime/$qid"
    [ -d "$entry" ] && [ ! -L "$entry" ] \
      && [ "$(stat -c '%d:%i' -- "$entry" 2>/dev/null)" = "${tombstone_identities[$index]}" ] \
      && [ -z "$(find "$entry" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] || {
        err "사전 검증한 빈 cell 상태 디렉터리가 삭제 전에 변경되었습니다: $qid"
        return 1
      }
    rmdir -- "$entry" || return 1
    _cell_selection_clear_locked "$qid" || {
      err "정리한 빈 일회용 셀의 active-cell 선택 상태를 해제하지 못했습니다: $qid"
      return 1
    }
  done

  for ((index=0; index < ${#qids[@]}; index++)); do
    qid="${qids[$index]}"
    entry="$runtime/$qid"
    [ -d "$entry" ] && [ ! -L "$entry" ] \
      && [ "$(stat -c '%d:%i' -- "$entry" 2>/dev/null)" = "${journal_identities[$index]}" ] || {
        err "사전 검증한 cell journal identity가 삭제 전에 변경되었습니다: $qid"
        return 1
      }
    info "관리 중인 일회용 셀 정리 중: $qid"
    _cell_destroy_locked "$qid" 1 || {
      err "일회용 셀 정리에 실패해 공유 클러스터 삭제를 중단합니다: $qid"
      return 1
    }
    _cell_selection_clear_locked "$qid" || {
      err "삭제한 일회용 셀의 active-cell 선택 상태를 해제하지 못했습니다: $qid"
      return 1
    }
  done

  remaining=("$runtime"/*)
  for entry in "${remaining[@]}"; do
    [ "$entry" = "$runtime/lifecycle.lock" ] \
      && [ -f "$entry" ] && [ ! -L "$entry" ] && continue
    err "일회용 셀 상태가 정리 후에도 남았습니다: $entry"
    return 1
  done
  _cell_selection_clear_current_locked || {
    err "active-cell 선택 상태를 안전하게 해제하지 못했습니다."
    return 1
  }
}

cell_cleanup_all_managed() (
  set -uo pipefail
  CKA_ENABLE_DISPOSABLE_CELLS="${CKA_ENABLE_DISPOSABLE_CELLS:-1}"
  cell_feature_enabled \
    || { err "일회용 셀 전체 정리에는 CKA_ENABLE_DISPOSABLE_CELLS=1 이 필요합니다."; return 1; }
  _cell_lock || return $?
  _cell_cleanup_all_managed_locked
)

cell_exec() { # <qid> <role> <command...>
  local qid="$1" role="$2" id
  shift 2
  cell_verify_container_id "$qid" "$role" || return 1
  id="${CELL_CONTAINER_IDS[$role]}"
  _cell_docker exec "$id" "$@"
}

cell_exec_stdin() { # <qid> <role> <command...>, forwards caller stdin
  local qid="$1" role="$2" id
  shift 2
  cell_verify_container_id "$qid" "$role" || return 1
  id="${CELL_CONTAINER_IDS[$role]}"
  _cell_docker exec --interactive "$id" "$@"
}

cell_exec_script() { # <qid> <role> <script> [script args...]
  local qid="$1" role="$2" script="$3" id
  shift 3
  [ -r "$script" ] || return 1
  cell_verify_container_id "$qid" "$role" || return 1
  id="${CELL_CONTAINER_IDS[$role]}"
  _cell_docker exec -i "$id" bash -s -- "$@" < "$script"
}

cell_kubectl() { # <qid> <kubectl args...>
  local qid="$1" kubeconfig
  shift
  cell_manifest_load "$qid" || return 1
  kubeconfig="$(cell_kubeconfig_path "$qid")" || return 1
  [ -r "$kubeconfig" ] && [ ! -L "$kubeconfig" ] || return 1
  kubectl --kubeconfig "$kubeconfig" "$@"
}

cell_evidence_get() { # <qid> <key>
  local path
  path="$(cell_evidence_path "$1")" || return 1
  _cell_manifest_value "$path" "$2"
}

cell_status() {
  local qid="$1" expected_profile="${2:-}"
  cell_runtime_readonly_ok && cell_manifest_load "$qid" || return 1
  [ -z "$expected_profile" ] || [ "$CELL_PROFILE" = "$expected_profile" ] || return 1
  printf '%s\t%s\t%s\t%s\n' "$CELL_QID" "$CELL_PROFILE" "$CELL_STATUS" "$CELL_CLUSTER_NAME"
}

# Stable runner-facing API.  These functions keep topology-specific dispatch
# behind one contract so the shared-cluster runner never needs to discover or
# delete Docker resources itself.
cell_prepare() { # <qid> <environment>
  local qid="$1" environment="$2" timeout_seconds rc=0
  cell_qid_valid "$qid" && cell_profile_valid "$environment" || return 1
  timeout_seconds="$(cell_question_setup_timeout_seconds "$qid")" || return 1
  case "$qid:$environment" in
    ca-11:kubeadm-ha|ca-12:kubeadm-bootstrap|ca-06:kubeadm-upgrade)
      if _cell_external_timeout "${timeout_seconds}s" \
          env CKA_ENABLE_DISPOSABLE_CELLS="${CKA_ENABLE_DISPOSABLE_CELLS:-1}" \
          CKA_ENABLE_KUBEADM_CELLS="${CKA_ENABLE_KUBEADM_CELLS:-1}" \
          bash "$CKA_ROOT/cluster/cells/kubeadm/cell.sh" up "$qid" >&2; then
        cell_status "$qid" "$environment"
      else
        rc=$?
        err "$qid cell prepare 실패 또는 ${timeout_seconds}s deadline 초과 (exit $rc)"
        return 1
      fi
      ;;
    ca-09:operator-cell|ca-13:operator-cell|sn-05:gateway-cell|st-06:csi-cell)
      if _cell_external_timeout "${timeout_seconds}s" \
          env CKA_ENABLE_DISPOSABLE_CELLS="${CKA_ENABLE_DISPOSABLE_CELLS:-1}" \
          bash "$CKA_ROOT/cluster/cells/generic/cell.sh" up "$qid" "$environment" >&2; then
        cell_status "$qid" "$environment"
      else
        rc=$?
        err "$qid cell prepare 실패 또는 ${timeout_seconds}s deadline 초과 (exit $rc)"
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

cell_activate() { # <qid> <environment>
  local qid="$1" environment="$2" role context
  cell_runtime_readonly_ok && cell_manifest_load "$qid" || return 1
  [ "$CELL_PROFILE" = "$environment" ] && [ "$CELL_STATUS" = READY ] || return 1
  cell_verify_topology "$qid" || return 1
  context="kind-$CELL_CLUSTER_NAME"
  export CKA_CELL_QID="$qid"
  export CKA_CELL_ENVIRONMENT="$environment"
  export CKA_CELL_RUN_ID="$CELL_RUN_ID"
  export CKA_CELL_CLUSTER_NAME="$CELL_CLUSTER_NAME"
  export CKA_CONTEXT="$context"
  export KUBECONFIG="$(cell_kubeconfig_path "$qid")"
  while IFS= read -r role; do
    [ "$role" = lb ] && continue
    printf -v "CKA_CELL_NODE_${role^^}" '%s' "$(cell_role_node_name "$CELL_CLUSTER_NAME" "$role")"
    export "CKA_CELL_NODE_${role^^}"
  done < <(cell_expected_roles "$CELL_PROFILE")
}

cell_cleanup() { # <qid> <environment>
  local qid="$1" environment="$2"
  cell_qid_valid "$qid" && cell_profile_valid "$environment" || return 1
  if [ -e "$(cell_state_dir "$qid")" ]; then
    cell_manifest_load "$qid" && [ "$CELL_PROFILE" = "$environment" ] || return 1
  fi
  CKA_ENABLE_DISPOSABLE_CELLS="${CKA_ENABLE_DISPOSABLE_CELLS:-1}" \
    CKA_ENABLE_KUBEADM_CELLS="${CKA_ENABLE_KUBEADM_CELLS:-1}" \
    cell_destroy "$qid" >&2
}
