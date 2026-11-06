#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ca-05
CP="$(cka_cp_node)"
require_cluster

# etcdctl and etcdutl must exist on the control plane node. The helper returns
# 1 when they are already installed.
install_node_etcdctl >/dev/null 2>&1 || true
node_etcdctl_ok || die "ex-ca-05: control plane node에 etcdctl·etcdutl이 없습니다."

docker exec "$CP" rm -rf /var/lib/etcd-backup
cleanup_question "$QID"
question_state_clear "$QID"
workdir_reset "$QID"
recreate_ns "$QID" upgrade-prep

# A value that exists only after this setup ran. A snapshot that contains it
# was taken after the setup.
marker="cutover-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
kctx -n upgrade-prep create configmap cutover-plan \
  --from-literal=window=sat-0200 --from-literal=token="$marker" >/dev/null

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
printf '%s\n' "$marker" > "$CKA_STATE_DIR/question-data/$QID/marker"
docker exec "$CP" sha256sum /etc/kubernetes/manifests/etcd.yaml | cut -d' ' -f1 \
  > "$CKA_STATE_DIR/question-data/$QID/etcd-manifest-sha256"
