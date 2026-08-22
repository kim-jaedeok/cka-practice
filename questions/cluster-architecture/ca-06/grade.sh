#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"
source "$CKA_ROOT/lib/cell-grader.sh"
source "$CKA_ROOT/cluster/cells/kubeadm/package-cache.sh"

cell_grader_bind ca-06
grade_init ca-06
cell_grade_validate kubeadm-upgrade

NODE="$CKA_CELL_NODE_WORKER2"
TARGET="$KUBEADM_PACKAGE_TO_VERSION"

ca06_node_out() { cell_node_out worker2 "$1"; }

ca06_package_version() {
  [ "$(ca06_node_out "dpkg-query -W -f='\${Version}' '$1' 2>/dev/null")" = "$TARGET" ]
}

ca06_packages_held() {
  local held package
  held="$(ca06_node_out 'apt-mark showhold | sort')" || return 1
  for package in kubeadm kubectl kubelet; do
    printf '%s\n' "$held" | grep -Fxq "$package" || return 1
  done
}

ca06_upgrade_ran() {
  ca06_node_out 'find /etc/kubernetes/tmp -maxdepth 1 -type d \
    -name "kubeadm-kubelet-config-*" -print -quit' | grep -q .
}

ca06_kubelet_restarted_after_install() {
  local installed_at active_at expected_defaults actual_defaults
  expected_defaults="$(cell_evidence_get ca-06 kubelet_defaults_sha256)" || return 2
  [[ "$expected_defaults" =~ ^[0-9a-f]{64}$ ]] || return 2
  actual_defaults="$(ca06_node_out \
    'test -f /etc/default/kubelet && test ! -L /etc/default/kubelet && sha256sum /etc/default/kubelet' \
    | awk '{print $1}')" || return 1
  installed_at="$(ca06_node_out 'stat -c %Y /var/lib/dpkg/info/kubelet.list')" || return 1
  active_at="$(ca06_node_out \
    'date -d "$(systemctl show -p ActiveEnterTimestamp --value kubelet)" +%s')" || return 1
  [ "$actual_defaults" = "$expected_defaults" ] \
    && [[ "$installed_at" =~ ^[0-9]+$ ]] && [[ "$active_at" =~ ^[0-9]+$ ]] \
    && [ "$active_at" -ge "$installed_at" ] \
    && [ "$(ca06_node_out 'systemctl is-active kubelet')" = active ]
}

ca06_identities_preserved() {
  local node_uid deploy_uid
  node_uid="$(cell_evidence_get ca-06 worker2_node_uid)" || return 2
  deploy_uid="$(cell_evidence_get ca-06 payments_deployment_uid)" || return 2
  [ "$(kctx get node "$NODE" -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$node_uid" ] \
    && [ "$(kctx -n node-upgrade get deployment payments-api \
      -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$deploy_uid" ]
}

criterion 1 "setup 당시 payments-api Pod UID가 남지 않음" \
  "res_absent_sel pods node-upgrade drain-probe=original"
criterion 1 "worker2의 실제 kubeadm package와 binary가 $TARGET" \
  "ca06_package_version kubeadm && [ \"\$(ca06_node_out 'kubeadm version -o short')\" = v1.35.0 ]"
criterion 1 "kubeadm이 생성하는 kubelet config backup이 존재" \
  "ca06_upgrade_ran"
criterion 1 "실제 kubelet·kubectl package와 binaries가 $TARGET" \
  "ca06_package_version kubelet && ca06_package_version kubectl && \
   [ \"\$(ca06_node_out 'kubelet --version')\" = 'Kubernetes v1.35.0' ] && \
   ca06_node_out 'kubectl version --client -o json' | grep -Fq '\"gitVersion\": \"v1.35.0\"'"
criterion 1 "kubeadm·kubelet·kubectl이 다시 hold 상태" \
  "ca06_packages_held"
criterion 1 "KIND kubelet 설정을 보존하고 package 설치 후 kubelet이 재시작되어 active" \
  "ca06_kubelet_restarted_after_install"
criterion 1 "원본 Node·Deployment UID를 보존하고 worker2가 v1.35.0 Ready/schedulable" \
  "ca06_identities_preserved && node_ready '$NODE' && node_schedulable '$NODE' && \
   [ \"\$(kctx get node '$NODE' -o jsonpath='{.status.nodeInfo.kubeletVersion}')\" = v1.35.0 ]"
criterion 1 "payments-api가 원본 Deployment에서 2/2 Ready로 복귀" \
  "deploy_ready node-upgrade payments-api 2"

grade_finish
