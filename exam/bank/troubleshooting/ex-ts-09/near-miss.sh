#!/usr/bin/env bash
# Near-miss fixture: the DNS rule is fixed, but the pricing rule still allows
# the Service port 80 instead of the Pod port 8080.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n checkout patch networkpolicy cart-egress --type=json -p '[
  {"op":"replace","path":"/spec/egress/0/to/0/namespaceSelector/matchLabels",
   "value":{"kubernetes.io/metadata.name":"kube-system"}}]' >/dev/null
sleep 5
