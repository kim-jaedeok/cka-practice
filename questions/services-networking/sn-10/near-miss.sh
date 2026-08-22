#!/usr/bin/env bash
# Near miss: split peers turn the intended namespace+pod AND into broader OR rules.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

bash "$(dirname "${BASH_SOURCE[0]}")/solve.sh"
kctx -n sn10-checkout patch networkpolicy allow-monitoring-ingress \
  --type=merge -p '{"spec":{"ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"cka-practice/sn-10-role":"monitoring"}}},{"podSelector":{"matchLabels":{"access":"monitor"}}}],"ports":[{"protocol":"TCP","port":8080}]}]}}'
kctx -n sn10-checkout patch networkpolicy allow-catalog-egress \
  --type=merge -p '{"spec":{"egress":[{"to":[{"namespaceSelector":{"matchLabels":{"cka-practice/sn-10-role":"catalog"}}},{"podSelector":{"matchLabels":{"app":"catalog"}}}],"ports":[{"protocol":"TCP","port":8080}]}]}}'
sleep 5
