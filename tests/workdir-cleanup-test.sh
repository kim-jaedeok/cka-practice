#!/usr/bin/env bash
# Real filesystem checks with cluster operations stubbed out.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/cka-workdir-cleanup.XXXXXX)"
[[ "$TEST_ROOT" = /tmp/cka-workdir-cleanup.* ]] || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export CKA_WORK_DIR="$TEST_ROOT/work"
export CKA_STATE_DIR="$TEST_ROOT/state"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/question-runtime.sh"
practice_files() { :; }

expect_failure() {
  if "$@"; then
    printf 'unexpected success: %s\n' "$*" >&2
    exit 1
  fi
}

mkdir -p "$CKA_WORK_DIR/ca-09/nested" "$CKA_WORK_DIR/ts-01" "$TEST_ROOT/outside"
printf keep > "$TEST_ROOT/outside/evidence"
printf answer > "$CKA_WORK_DIR/ca-09/nested/issuer.yaml"
printf hidden > "$CKA_WORK_DIR/ca-09/.draft"
printf keep > "$CKA_WORK_DIR/ts-01/answer.txt"
printf keep > "$CKA_WORK_DIR/notes.txt"
ln -s "$TEST_ROOT/outside" "$CKA_WORK_DIR/ca-09/link"
workdir_clear ca-09
[ ! -e "$CKA_WORK_DIR/ca-09" ]
[ "$(cat "$TEST_ROOT/outside/evidence")" = keep ]
[ -f "$CKA_WORK_DIR/ts-01/answer.txt" ]
workdir_clear ca-09
ln -s "$TEST_ROOT/outside" "$CKA_WORK_DIR/ca-09"
expect_failure workdir_clear_all 2>/dev/null
[ -L "$CKA_WORK_DIR/ca-09" ]
[ ! -e "$CKA_WORK_DIR/ts-01" ]
[ "$(cat "$TEST_ROOT/outside/evidence")" = keep ]
expect_failure workdir_prepare ca-09
rm -- "$CKA_WORK_DIR/ca-09"
expect_failure workdir_clear ../outside
CKA_WORK_DIR=/ expect_failure workdir_clear_all
ln -s "$CKA_WORK_DIR" "$TEST_ROOT/work-link"
CKA_WORK_DIR="$TEST_ROOT/work-link" expect_failure workdir_clear_all

# Runtime cleanup must cover disposable cells and teardown-only shared drills.
meta_get() { if [ "$2" = mode ]; then printf '%s' individual-only; fi; }
question_runtime_environment() { printf '%s' "$TEST_ENVIRONMENT"; }
require_cluster() { :; }
require_cluster_readonly() { :; }
_question_runtime_load_cell_library() { :; }
cell_selection_clear_current() { :; }
_question_runtime_cleanup_disposable() { return "${CLEANUP_RC:-0}"; }
_question_runtime_run_script() {
  if [ "$2" = setup.sh ]; then
    [ ! -e "$CKA_WORK_DIR/ca-09/issuer.yaml" ] || return 1
    workdir_prepare ca-09
    printf fixture > "$CKA_WORK_DIR/ca-09/fixture.yaml"
  fi
  return "${SCRIPT_RC:-0}"
}
mkdir -p "$TEST_ROOT/question"
touch "$TEST_ROOT/question/teardown.sh"
for TEST_ENVIRONMENT in shared-kind operator-cell; do
  workdir_prepare ca-09
  printf answer > "$CKA_WORK_DIR/ca-09/issuer.yaml"
  question_runtime_cleanup ca-09 "$TEST_ROOT/question"
  [ ! -e "$CKA_WORK_DIR/ca-09" ]
done
TEST_ENVIRONMENT=operator-cell
workdir_prepare ca-09
printf answer > "$CKA_WORK_DIR/ca-09/issuer.yaml"
CLEANUP_RC=1
expect_failure question_runtime_cleanup ca-09 "$TEST_ROOT/question"
[ -f "$CKA_WORK_DIR/ca-09/issuer.yaml" ]
unset CLEANUP_RC
TEST_ENVIRONMENT=shared-kind
question_runtime_reset ca-09 "$TEST_ROOT/question"
[ ! -e "$CKA_WORK_DIR/ca-09/issuer.yaml" ]
[ "$(cat "$CKA_WORK_DIR/ca-09/fixture.yaml")" = fixture ]
question_runtime_cleanup ca-09 "$TEST_ROOT/question"
TEST_ENVIRONMENT=operator-cell
cell_prepare() { :; }
cell_activate() { :; }
cell_select() { :; }
_question_runtime_profile_prepare() { :; }
workdir_prepare ca-09
printf answer > "$CKA_WORK_DIR/ca-09/issuer.yaml"
question_runtime_reset ca-09 "$TEST_ROOT/question"
[ ! -e "$CKA_WORK_DIR/ca-09/issuer.yaml" ]
[ "$(cat "$CKA_WORK_DIR/ca-09/fixture.yaml")" = fixture ]
question_runtime_cleanup ca-09 "$TEST_ROOT/question"
TEST_ENVIRONMENT=shared-kind
SCRIPT_RC=1
expect_failure question_runtime_start ca-09 "$TEST_ROOT/question"
unset SCRIPT_RC

# Run the actual cluster-down body without touching Docker or kind.
eval "$(sed -n '/^cmd_cluster_down() (/,/^)/p' "$ROOT/cka")"
deny_if_exam_locked() { :; }
_cloud_provider_kind_validate_cluster_name() { :; }
cell_feature_enabled() { :; }
_cell_lock() { :; }
_cell_cleanup_all_managed_locked() { :; }
cloud_provider_kind_cleanup_cluster_loadbalancers() { :; }
cloud_provider_kind_stop_if_no_clusters() { :; }
kind() { return "${KIND_RC:-0}"; }
workdir_prepare ca-09
printf answer > "$CKA_WORK_DIR/ca-09/issuer.yaml"
KIND_RC=1
expect_failure cmd_cluster_down >/dev/null 2>&1
[ -f "$CKA_WORK_DIR/ca-09/issuer.yaml" ]
unset KIND_RC
cmd_cluster_down
[ ! -e "$CKA_WORK_DIR/ca-09" ]
[ "$(cat "$CKA_WORK_DIR/notes.txt")" = keep ]

# Run the real reset script with a fixture common/setup to isolate the host.
mkdir -p "$TEST_ROOT/reset/cluster" "$TEST_ROOT/reset/lib"
cp "$ROOT/cluster/reset-cluster.sh" "$TEST_ROOT/reset/cluster/"
printf 'cell_cleanup_all_managed() { return "${CELL_CLEANUP_RC:-0}"; }\n' > "$TEST_ROOT/reset/lib/cell.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/reset/cluster/setup-cluster.sh"
warn() { :; }
err() { printf '%s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
declare -f workdir_clear_all workdir_clear workdir_root_resolve \
  state_subdir_clear warn die err kind practice_files \
  cloud_provider_kind_cleanup_cluster_loadbalancers > "$TEST_ROOT/reset/lib/common.sh"
export CKA_CLUSTER_NAME=cka
workdir_prepare ca-09
printf answer > "$CKA_WORK_DIR/ca-09/issuer.yaml"
CELL_CLEANUP_RC=1 expect_failure bash "$TEST_ROOT/reset/cluster/reset-cluster.sh" >/dev/null 2>&1
[ -f "$CKA_WORK_DIR/ca-09/issuer.yaml" ]
bash "$TEST_ROOT/reset/cluster/reset-cluster.sh" >/dev/null
[ ! -e "$CKA_WORK_DIR/ca-09" ]
[ "$(cat "$CKA_WORK_DIR/notes.txt")" = keep ]
printf 'PASS: practice file cleanup, path boundaries, and lifecycle integration\n'
