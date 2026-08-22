#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/controllers.sh"

QID=sn-05
STATE_DIR="$CKA_STATE_DIR/question-data/$QID"
SN05_BACKEND_IMAGE="$(controller_pinned_image_ref "$GATEWAY_BACKEND_IMAGE")"
SN05_PROBE_IMAGE="$(controller_pinned_image_ref "$GATEWAY_PROBE_IMAGE")"

sn05_infra_fingerprint() {
  {
    kctx -n envoy-gateway-system get deployment,service,serviceaccount,configmap -o json
    kctx get gatewayclass envoy-cka -o json
    kctx -n envoy-gateway-system get envoyproxy cka-clusterip -o json
    kctx -n traffic get configmap/store-page deployment/store service/store-svc -o json
    kctx -n cka-controller-system get deployment/sn05-probe -o json
    kctx get clusterrole,clusterrolebinding -o json
  } | python3 -c '
import hashlib,json,sys
decoder=json.JSONDecoder(); text=sys.stdin.read(); pos=0; values=[]
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    obj,pos=decoder.raw_decode(text,pos)
    for item in obj.get("items",[obj]):
        meta=item.get("metadata",{}); name=meta.get("name",""); ns=meta.get("namespace","")
        owned=((ns=="envoy-gateway-system" and name in {"envoy-gateway","envoy-gateway-config","cka-clusterip"})
               or ns in {"traffic","cka-controller-system"}
               or name=="envoy-cka" or (not ns and name.startswith("envoy-gateway")))
        if owned:
            values.append({"apiVersion":item.get("apiVersion"),"kind":item.get("kind"),
              "name":name,"namespace":ns,"uid":meta.get("uid"),"spec":item.get("spec"),
              "data":item.get("data"),"rules":item.get("rules"),
              "roleRef":item.get("roleRef"),"subjects":item.get("subjects")})
payload=json.dumps(sorted(values,key=lambda x:(x["kind"] or "",x["namespace"],x["name"])),sort_keys=True,separators=(",",":"))
print(hashlib.sha256(payload.encode()).hexdigest())
'
}

controller_require_disposable_cell "$QID" gateway-cell
require_cluster_readonly
if ! controller_cell_status "$QID" gateway-cell >/dev/null 2>&1; then
  controller_cell_prepare "$QID" gateway-cell
  controller_cell_activate "$QID" gateway-cell
fi
cleanup_question "$QID"
recreate_ns "$QID" traffic
kctx create namespace cka-controller-system --dry-run=client -o yaml | kctx apply -f - >/dev/null

kctx apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: store-page
  namespace: traffic
data:
  index.html: |
    cka-sn05-envoy-dataplane
  store: |
    cka-sn05-envoy-dataplane
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: store
  namespace: traffic
spec:
  replicas: 2
  selector:
    matchLabels:
      app: store
  template:
    metadata:
      labels:
        app: store
    spec:
      containers:
        - name: nginx
          image: $SN05_BACKEND_IMAGE
          imagePullPolicy: Never
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: http
          volumeMounts:
            - name: page
              mountPath: /usr/share/nginx/html
      volumes:
        - name: page
          configMap:
            name: store-page
---
apiVersion: v1
kind: Service
metadata:
  name: store-svc
  namespace: traffic
spec:
  selector:
    app: store
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sn05-probe
  namespace: cka-controller-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sn05-probe
  template:
    metadata:
      labels:
        app: sn05-probe
    spec:
      containers:
        - name: probe
          image: $SN05_PROBE_IMAGE
          imagePullPolicy: Never
          command: [sh, -c, "sleep 86400"]
EOF

wait_deploy traffic store
wait_deploy cka-controller-system sn05-probe
for _ in $(seq 1 60); do
  [ "$(kctx get gatewayclass envoy-cka -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" = True ] && break
  sleep 1
done
[ "$(kctx get gatewayclass envoy-cka -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" = True ] \
  || die "Envoy GatewayClass was not accepted"

umask 077
mkdir -p "$STATE_DIR"
sn05_infra_fingerprint > "$STATE_DIR/infra.sha256"
grep -Eq '^[0-9a-f]{64}$' "$STATE_DIR/infra.sha256" \
  || die "sn-05 trusted infrastructure fingerprint failed"
