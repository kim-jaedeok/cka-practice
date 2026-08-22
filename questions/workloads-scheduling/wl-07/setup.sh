#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=wl-07
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" affinity-spread

# 이전 시도나 수동 테스트가 남긴 라벨을 제거해 eligible set을 정확히
# 두 worker로 고정한다. 컨트롤 플레인에 이 라벨이 남아 있으면 affinity가
# 아무런 역할을 하지 않는 오답이나 분산 오탐이 발생할 수 있다.
mapfile -t nodes < <(kctx get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ "${#nodes[@]}" -gt 0 ] || die "노드 목록을 읽을 수 없습니다."
for node in "${nodes[@]}"; do
  case "$node" in
    cka-worker|cka-worker2)
      kctx label node "$node" cka-practice/wl07=eligible --overwrite >/dev/null
      ;;
    *)
      kctx label node "$node" cka-practice/wl07- >/dev/null 2>&1 || true
      ;;
  esac
done

worker_is_usable() {
  local node="$1" effects
  [ "$(kctx get node "$node" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null)" = True ] || return 1
  [ "$(kctx get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)" != true ] \
    || return 1
  effects="$(kctx get node "$node" \
      -o jsonpath='{range .spec.taints[*]}{.effect}{"\n"}{end}' 2>/dev/null)" \
    || return 1
  ! printf '%s\n' "$effects" | grep -Eq '^(NoSchedule|NoExecute)$'
}

worker_is_usable cka-worker \
  || die "cka-worker는 Ready이며 스케줄 가능해야 합니다."
worker_is_usable cka-worker2 \
  || die "cka-worker2는 Ready이며 스케줄 가능해야 합니다."

eligible_nodes="$(kctx get nodes -l cka-practice/wl07=eligible \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)"
[ "$eligible_nodes" = $'cka-worker\ncka-worker2' ] \
  || die "wl-07 eligible 노드는 cka-worker, cka-worker2 두 개여야 합니다."
