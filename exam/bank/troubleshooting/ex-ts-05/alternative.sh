#!/usr/bin/env bash
# Alternative fixture: keep dnsPolicy None, but point dnsConfig at the kube-dns
# Service and list the cluster search domains. This also uses cluster DNS.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

dns="$(kctx -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')"
kctx -n mapping patch deploy geo-resolver --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/dnsConfig\",\"value\":{
    \"nameservers\":[\"$dns\"],
    \"searches\":[\"mapping.svc.cluster.local\",\"svc.cluster.local\",\"cluster.local\"],
    \"options\":[{\"name\":\"ndots\",\"value\":\"5\"}]}}
]" >/dev/null
wait_deploy mapping geo-resolver 180s
