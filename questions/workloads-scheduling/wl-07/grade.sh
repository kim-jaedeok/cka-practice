#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-07

# JSONPath로 특정 tuple만 검색하면 추가 OR term이나 자기 Pod를 제외하는
# selector를 놓칠 수 있다. 전체 매니페스트를 파싱해 필요한 구조를
# 정확히 검증한다. 이 로컬 연습 환경은 다른 문제 setup에서도 python3를 사용한다.
wl07_manifest_check() { # wl07_manifest_check <identity|affinity|spread>
  local mode="$1" manifest
  command -v python3 >/dev/null 2>&1 || {
    grade_invalid "grading dependency unavailable: python3" || true
    return 2
  }
  manifest="$(kctx -n affinity-spread get deploy spread-web -o json 2>/dev/null)" \
    || return 1
  python3 -c '
import json
import sys

d = json.load(sys.stdin)
mode = sys.argv[1]
spec = d.get("spec", {})
pod = spec.get("template", {})
pod_spec = pod.get("spec", {})

if mode == "identity":
    selector = spec.get("selector", {})
    selector_labels = selector.get("matchLabels", {})
    selector_expressions = selector.get("matchExpressions", [])
    deployment_selector_is_exact = (
        selector_labels == {"app": "spread-web"}
        and not selector_expressions
    ) or (
        not selector_labels
        and selector_expressions == [{
            "key": "app",
            "operator": "In",
            "values": ["spread-web"],
        }]
    )
    labels = pod.get("metadata", {}).get("labels", {})
    containers = pod_spec.get("containers", [])
    ok = (
        deployment_selector_is_exact
        and labels.get("app") == "spread-web"
        and len(containers) == 1
        and containers[0].get("image") == "nginx:1.29"
    )
elif mode == "affinity":
    required = (
        pod_spec.get("affinity", {})
        .get("nodeAffinity", {})
        .get("requiredDuringSchedulingIgnoredDuringExecution")
    )
    terms = required.get("nodeSelectorTerms", []) if isinstance(required, dict) else []
    if len(terms) != 1:
        ok = False
    else:
        term = terms[0]
        expressions = term.get("matchExpressions", [])
        ok = (
            len(expressions) == 1
            and expressions[0] == {
                "key": "cka-practice/wl07",
                "operator": "In",
                "values": ["eligible"],
            }
            and not term.get("matchFields")
        )
elif mode == "spread":
    constraints = pod_spec.get("topologySpreadConstraints", [])
    if len(constraints) != 1:
        ok = False
    else:
        c = constraints[0]
        label_selector = c.get("labelSelector", {})
        match_labels = label_selector.get("matchLabels", {})
        match_expressions = label_selector.get("matchExpressions", [])
        selector_is_exact = (
            match_labels == {"app": "spread-web"}
            and not match_expressions
        ) or (
            not match_labels
            and match_expressions == [{
                "key": "app",
                "operator": "In",
                "values": ["spread-web"],
            }]
        )
        ok = (
            c.get("maxSkew") == 1
            and c.get("topologyKey") == "kubernetes.io/hostname"
            and c.get("whenUnsatisfiable") == "DoNotSchedule"
            and selector_is_exact
            and not c.get("matchLabelKeys")
        )
else:
    ok = False

raise SystemExit(0 if ok else 1)
' "$mode" <<< "$manifest"
}

# Deployment의 UID로 ReplicaSet을 찾고, 그 ReplicaSet UID를 owner로 가진 Pod만
# 세어 같은 label을 붙인 위장 Pod가 2:2 판정에 섞이지 않게 한다.
wl07_owned_distribution() {
  local deploy_uid rs_rows pod_rows rs_uid owner_uid pod_name node deleting ready
  local total=0 worker1=0 worker2=0 rs_count=0
  declare -A owned_rs=()

  deploy_uid="$(kctx -n affinity-spread get deploy spread-web \
    -o jsonpath='{.metadata.uid}' 2>/dev/null)" || return 1
  [ -n "$deploy_uid" ] || return 1
  rs_rows="$(kctx -n affinity-spread get replicasets \
    -o jsonpath='{range .items[*]}{.metadata.uid}{"|"}{.metadata.ownerReferences[?(@.kind=="Deployment")].uid}{"\n"}{end}' \
    2>/dev/null)" || return 1
  while IFS='|' read -r rs_uid owner_uid; do
    [ -n "$rs_uid" ] || continue
    if [ "$owner_uid" = "$deploy_uid" ]; then
      owned_rs["$rs_uid"]=1
      rs_count=$((rs_count + 1))
    fi
  done <<< "$rs_rows"
  [ "$rs_count" -gt 0 ] || return 1

  pod_rows="$(kctx -n affinity-spread get pods \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[?(@.kind=="ReplicaSet")].uid}{"|"}{.spec.nodeName}{"|"}{.metadata.deletionTimestamp}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null)" || return 1
  while IFS='|' read -r pod_name owner_uid node deleting ready; do
    [ -n "$pod_name" ] || continue
    [ -n "$owner_uid" ] || continue
    [ -n "${owned_rs[$owner_uid]:-}" ] || continue
    [ -z "$deleting" ] || continue
    total=$((total + 1))
    [ "$ready" = True ] || return 1
    case "$node" in
      cka-worker) worker1=$((worker1 + 1)) ;;
      cka-worker2) worker2=$((worker2 + 1)) ;;
      *) return 1 ;;
    esac
  done <<< "$pod_rows"

  [ "$total" -eq 4 ] && [ "$worker1" -eq 2 ] && [ "$worker2" -eq 2 ]
}

criterion 1 "Deployment selector/template label과 nginx image가 정확" \
  "wl07_manifest_check identity"

criterion 2 "required nodeAffinity가 단일 safe term으로 eligible만 허용" \
  "wl07_manifest_check affinity"

criterion 2 "hostname 분산 제약과 자기 Pod를 포함하는 selector가 정확" \
  "wl07_manifest_check spread"

criterion 1 "spread-web 네 replica가 모두 Ready" \
  "jp_eq deploy spread-web affinity-spread '{.spec.replicas}' 4 && \
   deploy_ready affinity-spread spread-web 4"

criterion 2 "실제 Pod가 두 worker에 2개씩 분산" \
  "wl07_owned_distribution"

grade_finish
