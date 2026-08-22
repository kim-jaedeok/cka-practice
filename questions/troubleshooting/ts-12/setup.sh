#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-12
require_cluster
cleanup_question "$QID"

# 원본 kube-scheduler 매니페스트 백업 (최초 1회)
mkdir -p "$CKA_STATE_DIR/backup"
if [ ! -f "$CKA_STATE_DIR/backup/kube-scheduler.yaml" ]; then
  docker exec cka-control-plane cat /etc/kubernetes/manifests/kube-scheduler.yaml \
    > "$CKA_STATE_DIR/backup/kube-scheduler.yaml"
fi

# Start from the known-good manifest so repeated/interrupted setup is deterministic.
docker exec -i cka-control-plane sh -c \
  'cat > /etc/kubernetes/manifests/kube-scheduler.yaml' \
  < "$CKA_STATE_DIR/backup/kube-scheduler.yaml"
for _ in $(seq 1 60); do
  scheduler_command="$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
    -o jsonpath='{.spec.containers[?(@.name=="kube-scheduler")].command[0]}' \
    2>/dev/null || true)"
  scheduler_ready="$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || true)"
  [ "$scheduler_command" = kube-scheduler ] && [ "$scheduler_ready" = True ] && break
  sleep 2
done
[ "${scheduler_command:-}" = kube-scheduler ] && [ "${scheduler_ready:-}" = True ] \
  || die "kube-scheduler의 정상 출발 상태를 복원하지 못했습니다."
old_pod_uid="$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
  -o jsonpath='{.metadata.uid}')"

# 스케줄러 커맨드를 오타로 망가뜨린다
docker exec cka-control-plane sed -i 's|- kube-scheduler|- kube-schedulerx|' \
  /etc/kubernetes/manifests/kube-scheduler.yaml

# kubelet이 static Pod manifest 변경을 실제로 관측한 뒤에만 문제 workload를 만든다.
# 이전 Ready mirror Pod를 장애 상태로 오인하지 않도록 command, UID, Ready를 함께 본다.
scheduler_broken=0
for _ in $(seq 1 60); do
  new_pod_uid="$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
    -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  scheduler_command="$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
    -o jsonpath='{.spec.containers[?(@.name=="kube-scheduler")].command[0]}' \
    2>/dev/null || true)"
  scheduler_ready="$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || true)"
  if [ "$scheduler_command" = kube-schedulerx ] \
      && [ -n "$new_pod_uid" ] && [ "$new_pod_uid" != "$old_pod_uid" ] \
      && [ "$scheduler_ready" != True ]; then
    scheduler_broken=1
    break
  fi
  sleep 2
done
[ "$scheduler_broken" -eq 1 ] \
  || die "kubelet이 잘못된 kube-scheduler manifest를 반영하지 않았습니다."

# 스케줄러가 내려간 뒤 테스트 Deployment 생성 → 두 Pod가 미할당 Pending 상태가 된다.
recreate_ns "$QID" sched-check
kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sched-test
  namespace: sched-check
spec:
  replicas: 2
  selector:
    matchLabels: {app: sched-test}
  template:
    metadata:
      labels: {app: sched-test}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
EOF
pending_baseline=0
for _ in $(seq 1 30); do
  if kctx -n sched-check get pods -l app=sched-test -o json 2>/dev/null \
      | python3 -c '
import json, sys
pods = json.load(sys.stdin).get("items", [])
ok = len(pods) == 2 and all(
    not pod.get("spec", {}).get("nodeName")
    and pod.get("status", {}).get("phase") == "Pending"
    for pod in pods
)
raise SystemExit(0 if ok else 1)
'; then
    pending_baseline=1
    break
  fi
  sleep 1
done
[ "$pending_baseline" -eq 1 ] \
  || die "sched-test Pod 두 개가 미할당 Pending 상태가 되지 않았습니다."
info "kube-scheduler가 중단된 상태입니다. sched-test Pod는 Pending으로 남습니다."
