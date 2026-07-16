#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-06

criterion 2 "Corefile의 잘못된 플러그인(forwardx)이 수정됨" \
  "_jp_get cm coredns kube-system '{.data.Corefile}' | grep -q 'forward ' && \
   ! _jp_get cm coredns kube-system '{.data.Corefile}' | grep -q 'forwardx'"

criterion 3 "CoreDNS 2/2 Ready (CrashLoop 해소)" \
  "deploy_ready kube-system coredns 2"

criterion 2 "실측: Pod에서 DNS 조회 성공" \
  "dns_resolves kubernetes.default.svc.cluster.local"

grade_finish
