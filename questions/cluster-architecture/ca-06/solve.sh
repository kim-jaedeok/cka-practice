#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx drain cka-worker2 --ignore-daemonsets --delete-emptydir-data --timeout=180s

mkdir -p "$CKA_WORK_DIR/ca-06"
cat > "$CKA_WORK_DIR/ca-06/upgrade-commands.txt" <<'EOF'
apt-get update
apt-mark unhold kubeadm
apt-get install -y kubeadm=1.36.1-1.1
apt-mark hold kubeadm
kubeadm upgrade node
apt-mark unhold kubelet kubectl
apt-get install -y kubelet=1.36.1-1.1 kubectl=1.36.1-1.1
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
kubectl uncordon cka-worker2
EOF
