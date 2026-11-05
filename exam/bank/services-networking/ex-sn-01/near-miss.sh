#!/usr/bin/env bash
# Near-miss fixture: the EndpointSlice port has no name. kube-proxy matches
# slice ports to Service ports by name, so the named Service port "http" gets
# no backend and traffic fails.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

ip="$(kctx -n legacy-host get pod legacy-app -o jsonpath='{.status.podIP}')"
kctx apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: legacy-api
  namespace: bridge
spec:
  ports:
    - name: http
      port: 8080
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: legacy-api-1
  namespace: bridge
  labels:
    kubernetes.io/service-name: legacy-api
addressType: IPv4
ports:
  - port: 80
    protocol: TCP
endpoints:
  - addresses: ["$ip"]
EOF
sleep 3
