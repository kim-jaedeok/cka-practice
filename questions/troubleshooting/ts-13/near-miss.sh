#!/usr/bin/env bash
# Deliberately incomplete: etcd is repaired, but kube-apiserver still targets 22379.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

docker exec cka-control-plane sed -i \
  's#--listen-client-urls=https://127.0.0.1:12379,#--listen-client-urls=https://127.0.0.1:2379,#' \
  /etc/kubernetes/manifests/etcd.yaml
