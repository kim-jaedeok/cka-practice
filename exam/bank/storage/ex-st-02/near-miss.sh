#!/usr/bin/env bash
# Near-miss fixture: the ephemeral volume works, but the claim template asks
# for 1Gi instead of 256Mi.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n render-farm patch deploy renderer --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/volumes/0","value":{
    "name":"scratch",
    "ephemeral":{"volumeClaimTemplate":{"spec":{
      "storageClassName":"standard",
      "accessModes":["ReadWriteOnce"],
      "resources":{"requests":{"storage":"1Gi"}}}}}}}
]' >/dev/null
wait_deploy render-farm renderer 240s
for _ in $(seq 1 30); do
  [ "$(kctx -n render-farm get pvc -o name | wc -l)" -eq 2 ] && break
  sleep 2
done
