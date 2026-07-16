#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-08

criterion 2 "Corefile에 log 플러그인 활성화" \
  "_jp_get cm coredns kube-system '{.data.Corefile}' | grep -qE '^[[:space:]]*log[[:space:]]*$'"

criterion 1 "CoreDNS 2개 Pod 정상 롤아웃" \
  "deploy_ready kube-system coredns 2"

criterion 1 "클러스터 DNS 조회 정상 동작 (실측)" \
  "dns_resolves kubernetes.default.svc.cluster.local"

criterion 2 "dns-ip.txt에 kube-dns ClusterIP 저장" \
  "file_contains \"\$CKA_WORK_DIR/sn-08/dns-ip.txt\" \"\$(_jp_get svc kube-dns kube-system '{.spec.clusterIP}')\""

grade_finish
