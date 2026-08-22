#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/cell-grader.sh"

cell_grader_bind ca-12
grade_init ca-12
cell_grade_validate kubeadm-bootstrap 1

ca12_control_plane_ready() {
  cell_api_ready \
    && cell_node_out cp1 'test -s /etc/kubernetes/admin.conf \
      && test -s /etc/kubernetes/manifests/kube-apiserver.yaml \
      && test -s /etc/kubernetes/manifests/etcd.yaml'
}

criterion 2 "cp1이 실제 kubeadm control plane으로 bootstrap됨" \
  "ca12_control_plane_ready"

criterion 2 "cp1, worker1, worker2만 존재하고 모두 Ready" \
  "cell_exact_ready_nodes cp1 worker1 worker2"

criterion 1 "두 worker가 kubelet TLS bootstrap을 완료" \
  "cell_worker_tls_bootstrapped worker1 && cell_worker_tls_bootstrapped worker2"

criterion 2 "kindnet과 CoreDNS가 모든 노드에서 정상 수렴" \
  "cell_kube_system_ready"

criterion 1 "bootstrap-web 두 Pod가 서로 다른 worker에서 Ready" \
  "cell_bootstrap_workload_exact"

criterion 2 "worker의 network-client에서 Service HTTP data path 성공" \
  "cell_bootstrap_service_works"

grade_finish
