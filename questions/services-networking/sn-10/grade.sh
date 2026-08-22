#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

netpol_semantics() { # netpol_semantics <policy> <mode>
  local json
  _python3_require || return $?
  json="$(_resource_json networkpolicy "$1" sn10-checkout)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys

obj = json.load(sys.stdin)
mode = sys.argv[1]
spec = obj.get("spec", {})

def selector(labels):
    return {"matchLabels": labels}

def selected_checkout():
    return spec.get("podSelector") == selector({"app": "checkout"})

def peer_is(peer, namespace_labels, pod_labels):
    return (
        set(peer) == {"namespaceSelector", "podSelector"}
        and peer.get("namespaceSelector") == selector(namespace_labels)
        and peer.get("podSelector") == selector(pod_labels)
    )

def port_set(items):
    return {
        (item.get("protocol", "TCP"), item.get("port"))
        for item in items
        if set(item).issubset({"protocol", "port", "endPort"})
        and "endPort" not in item
    }

ok = selected_checkout()
if mode == "isolate":
    ok = ok and set(spec.get("policyTypes", [])) == {"Ingress", "Egress"}
    ok = ok and spec.get("ingress", []) == [] and spec.get("egress", []) == []
elif mode == "monitoring":
    rules = spec.get("ingress", [])
    ok = ok and spec.get("policyTypes") == ["Ingress"] and len(rules) == 1
    if ok:
        rule = rules[0]
        peers = rule.get("from", [])
        ok = (
            set(rule) == {"from", "ports"}
            and len(peers) == 1
            and peer_is(
                peers[0],
                {"cka-practice/sn-10-role": "monitoring"},
                {"access": "monitor"},
            )
            and port_set(rule.get("ports", [])) == {("TCP", 8080)}
            and len(rule.get("ports", [])) == 1
        )
elif mode == "dns":
    rules = spec.get("egress", [])
    ok = ok and spec.get("policyTypes") == ["Egress"] and len(rules) == 1
    if ok:
        rule = rules[0]
        peers = rule.get("to", [])
        ok = (
            set(rule) == {"to", "ports"}
            and len(peers) == 1
            and peer_is(
                peers[0],
                {"kubernetes.io/metadata.name": "kube-system"},
                {"k8s-app": "kube-dns"},
            )
            and port_set(rule.get("ports", [])) == {("UDP", 53), ("TCP", 53)}
            and len(rule.get("ports", [])) == 2
        )
elif mode == "catalog":
    rules = spec.get("egress", [])
    ok = ok and spec.get("policyTypes") == ["Egress"] and len(rules) == 1
    if ok:
        rule = rules[0]
        peers = rule.get("to", [])
        ok = (
            set(rule) == {"to", "ports"}
            and len(peers) == 1
            and peer_is(
                peers[0],
                {"cka-practice/sn-10-role": "catalog"},
                {"app": "catalog"},
            )
            and port_set(rule.get("ports", [])) == {("TCP", 8080)}
            and len(rule.get("ports", [])) == 1
        )
else:
    ok = False

raise SystemExit(0 if ok else 1)
' "$2"
}

grade_init sn-10

criterion 1 "isolate-checkout: checkout ingress·egress 기본 차단" \
  "netpol_semantics isolate-checkout isolate"

criterion 1 "monitoring namespace와 access=monitor Pod의 교집합만 TCP 8080 ingress" \
  "netpol_semantics allow-monitoring-ingress monitoring"

criterion 1 "CoreDNS에 UDP/TCP 53 egress 허용" \
  "netpol_semantics allow-dns-egress dns"

criterion 1 "catalog namespace와 app=catalog Pod의 교집합만 TCP 8080 egress" \
  "netpol_semantics allow-catalog-egress catalog"

criterion 2 "실측 ingress: monitoring/probe만 허용" \
  "http_ok_from sn10-monitoring probe http://checkout.sn10-checkout.svc.cluster.local:8080 && \
   http_denied_from sn10-monitoring other http://checkout.sn10-checkout.svc.cluster.local:8080 && \
   http_denied_from sn10-untrusted probe http://checkout.sn10-checkout.svc.cluster.local:8080"

criterion 2 "실측 egress: DNS+catalog 허용, 같은 namespace의 admin 차단" \
  "http_ok_from sn10-checkout checkout http://catalog-svc.sn10-catalog.svc.cluster.local:8080 && \
   http_denied_from sn10-checkout checkout http://admin-svc.sn10-catalog.svc.cluster.local:8080"

grade_finish
