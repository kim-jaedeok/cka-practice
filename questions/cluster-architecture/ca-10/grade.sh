#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-10

criterion 2 "cka-worker의 /etc/kubernetes/manifests/에 매니페스트 존재" \
  "node_exec cka-worker 'grep -l static-web /etc/kubernetes/manifests/*.yaml'"

criterion 2 "mirror Pod static-web-cka-worker가 Running" \
  "pod_running default static-web-cka-worker"

criterion 1 "이미지가 nginx:1.29" \
  "jp_eq pod static-web-cka-worker default '{.spec.containers[0].image}' nginx:1.29"

criterion 1 "static Pod임 (kubelet이 소유한 mirror Pod)" \
  "jp_eq pod static-web-cka-worker default '{.metadata.ownerReferences[0].kind}' Node"

grade_finish
