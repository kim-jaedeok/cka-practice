#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-13

sn13_headless_service() {
  jp_eq svc workers training '{.spec.clusterIP}' None \
    && jp_eq svc workers training '{.spec.selector.app}' worker \
    && jp_relation_has svc workers training \
      '{range .spec.ports[*]}{.port}{"\n"}{end}' 80
}

sn13_statefulset_ready() {
  local status
  status="$(_jp_get statefulset worker training \
    '{.spec.serviceName}{"|"}{.spec.replicas}{"|"}{.status.readyReplicas}{"|"}{.spec.template.metadata.labels.app}{"|"}{.spec.template.spec.containers[0].image}')" \
    || return 1
  [ "$status" = "workers|2|2|worker|nginx:1.29" ]
}

FQDN=worker-1.workers.training.svc.cluster.local

criterion 2 "headless Service workers selects app=worker on port 80" \
  "sn13_headless_service"

criterion 2 "StatefulSet worker uses workers and has 2 Ready replicas" \
  "sn13_statefulset_ready"

criterion 1 "실측: worker-1의 Pod DNS 이름이 풀림" \
  "dns_resolves $FQDN"

criterion 1 "worker-1-fqdn.txt에 worker-1의 FQDN 저장" \
  "file_contains \"\$CKA_WORK_DIR/sn-13/worker-1-fqdn.txt\" '^[[:space:]]*worker-1\\.workers\\.training\\.svc\\.cluster\\.local\\.?[[:space:]]*$'"

grade_finish
