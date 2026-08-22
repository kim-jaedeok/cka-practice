#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/cell-grader.sh"

cell_grader_bind ca-11
grade_init ca-11
cell_grade_validate kubeadm-ha

criterion 2 "3 control planes와 3 workers가 정확히 존재하고 모두 Ready" \
  "cell_exact_ready_nodes cp1 cp2 cp3 worker1 worker2 worker3"

criterion 1 "cp1/cp2/cp3가 control-plane label과 NoSchedule taint 보유" \
  "cell_control_planes_joined"

criterion 2 "각 control plane의 API server, scheduler, controller, etcd가 Ready" \
  "cell_control_plane_static_pods_ready"

criterion 2 "stacked etcd가 정확히 3개 voting member이며 모두 healthy" \
  "cell_etcd_three_healthy_members"

criterion 1 "모든 admin.conf와 kubeadm-config가 고정 load balancer endpoint 사용" \
  "cell_control_plane_endpoint_exact"

criterion 1 "host kubeconfig가 기록된 TCP load balancer를 통해 readyz에 도달" \
  "cell_lb_path_ready"

criterion 1 "기존 cp1 Node UID와 cluster CA가 보존됨" \
  "cell_ha_baseline_preserved"

criterion 1 "기존 survival-web UID와 실제 Service data path가 보존됨" \
  "cell_ha_survival_preserved"

criterion 1 "완료 증거 ConfigMap ha-proof가 정확함" \
  "jp_eq configmap ha-proof ha-survival '{.data.completed}' true"

grade_finish
