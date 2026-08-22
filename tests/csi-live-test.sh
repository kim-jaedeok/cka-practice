#!/usr/bin/env bash
# Opt-in live contract for the disposable CSI extension lab.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "${CKA_CSI_LIVE:-0}" = 1 ] || {
  printf '%s\n' 'SKIP: set CKA_CSI_LIVE=1 after caching CSI assets'
  # A required live gate must not be mistaken for a passing execution when
  # its explicit opt-in was omitted.
  exit 77
}

source "$ROOT/lib/common.sh"
source "$ROOT/lib/cell.sh"
source "$ROOT/lib/csi.sh"

QID=st-06
QDIR="$ROOT/questions/storage/$QID"
API_REQUEST_TIMEOUT=10s
ALTERNATIVE_DELETE_WAIT=90
ALTERNATIVE_READY_WAIT=240

read_live_timeout() {
  local key="$1" value
  value="$(meta_get "$QDIR" "$key")"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] \
    || die "$QID has an invalid $key: ${value:-missing}"
  printf '%s' "$value"
}

SETUP_TIMEOUT="$(read_live_timeout setup_timeout_seconds)"
GRADE_TIMEOUT="$(read_live_timeout grade_timeout_seconds)"
CLEANUP_TIMEOUT="$SETUP_TIMEOUT"

command -v timeout >/dev/null 2>&1 \
  || die "CSI live test requires GNU timeout"
command -v kubectl >/dev/null 2>&1 \
  || die "CSI live test requires kubectl"

cell_may_exist=0
cell_active=0
cleanup_attempted=0

csi_live_diagnostics() { # <failed-stage>
  local failed_stage="$1"
  err "CSI live diagnostics after stage: $failed_stage"
  printf '[diag] score state: %s\n' "$(state_get "$QID")" >&2

  # Never let diagnostics fall through to the shared cluster. cell_activate
  # has already bound both context and kubeconfig when this flag is set.
  if [ "$cell_active" -ne 1 ] || ! csi_disposable_context; then
    warn "disposable CSI context was not activated; cluster queries skipped"
    return 0
  fi

  printf '%s\n' '[diag] CSI controller and node-plugin Pods' >&2
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
    -n csi-hostpath get statefulset,pods -o wide >&2 || true
  printf '%s\n' '[diag] API-defaulted CSIDriver spec' >&2
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
    get csidriver hostpath.csi.k8s.io \
    -o 'custom-columns=NAME:.metadata.name,ATTACH:.spec.attachRequired,POD_INFO:.spec.podInfoOnMount,FS_GROUP:.spec.fsGroupPolicy,MODES:.spec.volumeLifecycleModes,CAPACITY:.spec.storageCapacity,REPUBLISH:.spec.requiresRepublish,SELINUX:.spec.seLinuxMount' \
    >&2 || true
  printf '%s\n' '[diag] CSINode driver registrations' >&2
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
    get csinodes \
    -o 'custom-columns=NODE:.metadata.name,DRIVERS:.spec.drivers[*].name,NODE_IDS:.spec.drivers[*].nodeID' \
    >&2 || true
  printf '%s\n' '[diag] writer and claim lifecycle' >&2
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
    -n csi-lab get pod writer -o wide >&2 || true
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
    -n csi-lab get pvc data -o wide >&2 || true
  printf '%s\n' '[diag] writer deletion and scheduling fields' >&2
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
    -n csi-lab get pod writer \
    -o 'custom-columns=NAME:.metadata.name,PHASE:.status.phase,DELETING:.metadata.deletionTimestamp,GRACE:.metadata.deletionGracePeriodSeconds,FINALIZERS:.metadata.finalizers,NODE:.spec.nodeName' \
    >&2 || true
  printf '%s\n' '[diag] provisioned volumes and attachments' >&2
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
    get pv -o wide >&2 || true
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
    get volumeattachments \
    -o 'custom-columns=NAME:.metadata.name,PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName,ATTACHED:.status.attached,DELETING:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers' \
    >&2 || true
  printf '%s\n' '[diag] recent writer events' >&2
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
    -n csi-lab get events --field-selector involvedObject.name=writer \
    --sort-by=.metadata.creationTimestamp >&2 || true
}

run_stage() { # <label> <seconds> <executable> [args...]
  local label="$1" seconds="$2" rc
  shift 2
  info "CSI live stage: $label (limit ${seconds}s)"
  if timeout --foreground "${seconds}s" "$@"; then
    ok "CSI live stage complete: $label"
    return 0
  else
    rc=$?
  fi

  if [ "$rc" -eq 124 ]; then
    err "CSI live stage timed out after ${seconds}s: $label"
  else
    err "CSI live stage failed with exit $rc: $label"
  fi
  csi_live_diagnostics "$label"
  return "$rc"
}

cleanup_on_exit() {
  local original_rc=$? cleanup_rc=0
  trap - EXIT INT TERM
  if [ "$cell_may_exist" -eq 1 ] && [ "$cleanup_attempted" -eq 0 ]; then
    cleanup_attempted=1
    info "CSI live stage: cleanup after exit (limit ${CLEANUP_TIMEOUT}s)"
    if timeout --foreground "${CLEANUP_TIMEOUT}s" \
      "$ROOT/cka" cleanup "$QID"; then
      ok "CSI live stage complete: cleanup after exit"
    else
      cleanup_rc=$?
      err "CSI cleanup failed with exit $cleanup_rc; cleanup output is preserved above"
    fi
  fi
  [ "$original_rc" -ne 0 ] || original_rc="$cleanup_rc"
  exit "$original_rc"
}
trap 'exit 130' INT TERM
trap cleanup_on_exit EXIT

info "CSI live stage: verify locked offline bundle"
csi_bundle_verify || die "cache CSI assets first: cluster/csi/cache-images.sh"
ok "CSI live stage complete: verify locked offline bundle"

cell_may_exist=1
run_stage "create disposable CSI cell" "$SETUP_TIMEOUT" \
  "$ROOT/cka" start "$QID"

info "CSI live stage: activate disposable CSI context"
cell_activate "$QID" csi-cell \
  || die "failed to activate the disposable CSI context"
cell_active=1
ok "CSI live stage complete: activate disposable CSI context"

run_stage "canonical solution" "$SETUP_TIMEOUT" \
  bash "$QDIR/solve.sh"
run_stage "canonical grade" "$GRADE_TIMEOUT" \
  bash "$QDIR/grade.sh"
[ "$(state_get "$QID")" = graded:10/10 ] \
  || die "canonical CSI solution did not receive 10/10: $(state_get "$QID")"

# A semantically correct Pod does not need the reference answer's optional
# nodeSelector. With one schedulable worker, CSI registration and the attached
# volume determine the actual node relationship checked by the grader. Issue
# deletion without waiting, then use the documented deletion-wait primitive as
# its own stage so a stuck unmount/finalizer is distinguishable from grading.
run_stage "alternative: request canonical writer deletion" 30 \
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
  -n csi-lab delete pod writer --wait=false
run_stage "alternative: wait for canonical writer deletion" \
  "$((ALTERNATIVE_DELETE_WAIT + 15))" \
  kubectl --context "$CKA_CONTEXT" -n csi-lab \
  wait --for=delete pod/writer --timeout="${ALTERNATIVE_DELETE_WAIT}s"

run_stage "alternative: apply writer without nodeSelector" 30 \
  kubectl --context "$CKA_CONTEXT" --request-timeout="$API_REQUEST_TIMEOUT" \
  apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: writer
  namespace: csi-lab
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: [sh, -c, "printf '%s\n' csi-extension-ready > /data/proof.txt; sync; sleep infinity"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data
EOF

run_stage "alternative: wait for writer Ready" \
  "$((ALTERNATIVE_READY_WAIT + 15))" \
  kubectl --context "$CKA_CONTEXT" -n csi-lab \
  wait --for=condition=Ready pod/writer --timeout="${ALTERNATIVE_READY_WAIT}s"
run_stage "alternative grade" "$GRADE_TIMEOUT" \
  bash "$QDIR/grade.sh"
[ "$(state_get "$QID")" = graded:10/10 ] \
  || die "valid CSI solution without nodeSelector was rejected: $(state_get "$QID")"

# Mark before the destructive command so the EXIT trap never retries a failed
# cleanup against a partially removed cell.
cleanup_attempted=1
run_stage "cleanup disposable CSI cell" "$CLEANUP_TIMEOUT" \
  "$ROOT/cka" cleanup "$QID"
trap - EXIT INT TERM
printf '%s\n' 'PASS: disposable CSI driver, dynamic volume, attachment, and data path'
