#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

QID=sn-09
SENTINEL=sn09-lb-sentinel
PREFLIGHT=sn09-port80-preflight
STATE_DIR="$CKA_STATE_DIR/question-data/$QID"

cleanup_reserved() {
  kctx -n cka-system delete service "$PREFLIGHT" "$SENTINEL" \
    --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
  kctx -n cka-system delete deployment,configmap "$SENTINEL" \
    --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
}

cleanup_state() {
  question_state_clear "$QID"
}

cleanup_on_error() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    cleanup_reserved
    cleanup_question "$QID" || true
    cleanup_state || true
  fi
  exit "$rc"
}
trap cleanup_on_error EXIT

lb_address() {
  local ip hostname
  ip="$(kctx -n "$1" get service "$2" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  hostname="$(kctx -n "$1" get service "$2" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  printf '%s\n' "${ip:-$hostname}"
}

lb_url() {
  case "$1" in
    *:*) printf 'http://[%s]:%s\n' "$1" "$2" ;;
    *)   printf 'http://%s:%s\n' "$1" "$2" ;;
  esac
}

wait_lb_http() { # <service> <port>
  local service="$1" port="$2" address url
  for _ in $(seq 1 90); do
    address="$(lb_address cka-system "$service")"
    if [ -n "$address" ]; then
      url="$(lb_url "$address" "$port")"
      if curl -fsS --noproxy '*' --connect-timeout 2 --max-time 5 "$url" \
          2>/dev/null | grep -Fq 'cka-sn09-provider-ready'; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

wait_lb_container_gone() { # <namespace/service>
  local owner="${CKA_CLUSTER_NAME}/$1" i
  for i in $(seq 1 90); do
    if [ -z "$(docker ps -aq --filter \
        "label=io.x-k8s.cloud-provider-kind.loadbalancer.name=$owner")" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

port80_proxy_inventory_json() {
  local ids candidate
  ids="$(docker ps -aq --no-trunc --filter \
    "label=io.x-k8s.cloud-provider-kind.cluster=$CKA_CLUSTER_NAME")" || return 1
  {
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      [[ "$candidate" =~ ^[0-9a-f]{64}$ ]] || return 1
      docker container inspect --format '{{json .}}' "$candidate" 2>/dev/null || return 1
    done <<< "$ids"
  } | python3 -c '
import json, re, sys
decoder = json.JSONDecoder()
text = sys.stdin.read()
pos = 0
items = []
cluster = sys.argv[1]
expected = f"{cluster}/lb-shop/store-lb"
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    obj, pos = decoder.raw_decode(text, pos)
    labels = (obj.get("Config") or {}).get("Labels") or {}
    if labels.get("io.x-k8s.cloud-provider-kind.cluster") != cluster:
        continue
    bindings = (obj.get("HostConfig") or {}).get("PortBindings") or {}
    if "80/tcp" not in bindings:
        continue
    lb_name = labels.get("io.x-k8s.cloud-provider-kind.loadbalancer.name", "")
    if lb_name == expected:
        continue
    object_id = obj.get("Id", "")
    if not re.fullmatch(r"[0-9a-f]{64}", object_id):
        raise SystemExit(1)
    items.append({"id": object_id, "name": obj.get("Name", ""), "loadbalancer": lb_name})
print(json.dumps(sorted(items, key=lambda item: (item["loadbalancer"], item["id"])),
                 sort_keys=True, separators=(",", ":")))
' "$CKA_CLUSTER_NAME"
}

typed_resource_list_json() { # <expected item kind>
  python3 -c '
import json, sys
expected = sys.argv[1]
obj = json.load(sys.stdin)
if not isinstance(obj, dict):
    raise SystemExit(1)
if obj.get("kind") not in ("List", expected + "List"):
    raise SystemExit(1)
items = obj.get("items")
if not isinstance(items, list):
    raise SystemExit(1)
for item in items:
    if not isinstance(item, dict) or item.get("kind") != expected:
        raise SystemExit(1)
print(json.dumps({"kind": expected + "Inventory", "items": items},
                 sort_keys=True, separators=(",", ":")))
' "$1"
}

resource_fingerprint() { # deployment <name> <ns> | sentinel
  local proxy_inventory
  case "$1" in
    store)
      proxy_inventory="$(port80_proxy_inventory_json)" || return 1
      {
        for ref in configmap/store-page deployment/store; do
          kctx -n lb-shop get "$ref" -o json 2>/dev/null
        done
        kctx -n lb-shop get networkpolicy -o json 2>/dev/null \
          | typed_resource_list_json NetworkPolicy || return 1
        kctx get service -A -o json 2>/dev/null \
          | typed_resource_list_json Service || return 1
        printf '{"kind":"DockerPort80ProxyList","items":%s}\n' "$proxy_inventory"
      } | python3 -c '
import hashlib, json, sys
decoder = json.JSONDecoder()
text = sys.stdin.read()
pos = 0
items = []
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    obj, pos = decoder.raw_decode(text, pos)
    kind = obj.get("kind")
    if kind == "NetworkPolicyInventory":
        policies = []
        for item in obj.get("items", []):
            metadata = item.get("metadata")
            spec = item.get("spec")
            if not isinstance(metadata, dict) or not isinstance(spec, dict):
                raise SystemExit(1)
            name = metadata.get("name")
            uid = metadata.get("uid")
            if not isinstance(name, str) or not name or not isinstance(uid, str) or not uid:
                raise SystemExit(1)
            policies.append({
                "name": name,
                "uid": uid,
                "spec": spec,
            })
        items.append({"kind": kind, "items": sorted(policies, key=lambda item: item["name"])})
    elif kind == "ServiceInventory":
        services = []
        for item in obj.get("items", []):
            metadata = item.get("metadata")
            spec = item.get("spec")
            if not isinstance(metadata, dict) or not isinstance(spec, dict):
                raise SystemExit(1)
            namespace = metadata.get("namespace")
            name = metadata.get("name")
            uid = metadata.get("uid")
            ports = spec.get("ports", [])
            if (not isinstance(namespace, str) or not namespace
                    or not isinstance(name, str) or not name
                    or not isinstance(uid, str) or not uid
                    or not isinstance(ports, list)
                    or any(not isinstance(port, dict) for port in ports)):
                raise SystemExit(1)
            if spec.get("type") != "LoadBalancer":
                continue
            if not any(port.get("port") == 80 for port in ports):
                continue
            if namespace == "lb-shop" and name == "store-lb":
                continue
            services.append({
                "namespace": namespace,
                "name": name,
                "uid": uid,
                "spec": spec,
            })
        items.append({
            "kind": kind,
            "items": sorted(services, key=lambda item: (item["namespace"], item["name"])),
        })
    elif kind == "DockerPort80ProxyList":
        items.append({"kind": kind, "items": obj.get("items", [])})
    else:
        body = {"kind": kind, "uid": obj["metadata"]["uid"]}
        if kind == "ConfigMap": body["data"] = obj.get("data", {})
        else: body["spec"] = obj.get("spec", {})
        items.append(body)
print(hashlib.sha256(json.dumps(items, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
'
      ;;
    sentinel)
      {
        for ref in configmap/sn09-lb-sentinel deployment/sn09-lb-sentinel service/sn09-lb-sentinel; do
          kctx -n cka-system get "$ref" -o json 2>/dev/null
        done
        kctx -n cka-system get networkpolicy -o json 2>/dev/null \
          | typed_resource_list_json NetworkPolicy || return 1
      } | python3 -c '
import hashlib, json, sys
decoder = json.JSONDecoder()
text = sys.stdin.read()
pos = 0
items = []
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    obj, pos = decoder.raw_decode(text, pos)
    kind = obj.get("kind")
    if kind == "NetworkPolicyInventory":
        policies = []
        for item in obj.get("items", []):
            metadata = item.get("metadata")
            spec = item.get("spec")
            if not isinstance(metadata, dict) or not isinstance(spec, dict):
                raise SystemExit(1)
            name = metadata.get("name")
            uid = metadata.get("uid")
            if not isinstance(name, str) or not name or not isinstance(uid, str) or not uid:
                raise SystemExit(1)
            policies.append({
                "name": name,
                "uid": uid,
                "spec": spec,
            })
        body = {"kind": kind, "items": sorted(policies, key=lambda item: item["name"])}
    else:
        body = {"kind": kind, "uid": obj["metadata"]["uid"]}
        if kind == "ConfigMap": body["data"] = obj.get("data", {})
        else: body["spec"] = obj.get("spec", {})
    items.append(body)
print(hashlib.sha256(json.dumps(items, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
'
      ;;
    *) return 1 ;;
  esac
}

require_cluster
for command_name in curl docker python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "sn-09 setup requires $command_name"
done
cleanup_question "$QID"
cleanup_reserved
cleanup_state || die "sn-09 trusted state를 안전하게 초기화하지 못했습니다."
recreate_ns "$QID" lb-shop

kctx apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: store-page
  namespace: lb-shop
data:
  index.html: |
    cka-sn09-loadbalancer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: store
  namespace: lb-shop
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
          image: nginx:1.29
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: http
          volumeMounts:
            - name: page
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
      volumes:
        - name: page
          configMap:
            name: store-page
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: sn09-lb-sentinel
  namespace: cka-system
data:
  index.html: |
    cka-sn09-provider-ready
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sn09-lb-sentinel
  namespace: cka-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sn09-lb-sentinel
  template:
    metadata:
      labels:
        app: sn09-lb-sentinel
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: http
          volumeMounts:
            - name: page
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
      volumes:
        - name: page
          configMap:
            name: sn09-lb-sentinel
EOF

wait_deploy lb-shop store
wait_deploy cka-system "$SENTINEL"

# Prove the exact candidate port before the task starts.  On WSL/macOS the
# provider may publish Service ports on the host, so a high-port probe alone
# cannot detect a collision or privileged-port failure on TCP 80.
kctx apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $PREFLIGHT
  namespace: cka-system
spec:
  type: LoadBalancer
  selector:
    app: $SENTINEL
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
EOF
wait_lb_http "$PREFLIGHT" 80 \
  || die "LoadBalancer provider cannot serve the candidate's required TCP port 80"
kctx -n cka-system delete service "$PREFLIGHT" --wait=true --timeout=120s >/dev/null \
  || die "port-80 LoadBalancer preflight Service cleanup failed"
wait_lb_container_gone "cka-system/$PREFLIGHT" \
  || die "port-80 LoadBalancer preflight container cleanup failed"

# Keep an independent high-port sentinel for grading-time infrastructure checks.
kctx apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $SENTINEL
  namespace: cka-system
spec:
  type: LoadBalancer
  selector:
    app: $SENTINEL
  ports:
    - name: http
      protocol: TCP
      port: 18080
      targetPort: 80
EOF
wait_lb_http "$SENTINEL" 18080 \
  || die "LoadBalancer provider assigned no working grading sentinel"

umask 077
mkdir -p "$STATE_DIR"
[ ! -L "$STATE_DIR" ] || die "sn-09 trusted state directory must not be a symlink"
resource_fingerprint store > "$STATE_DIR/store-deployment.sha256"
resource_fingerprint sentinel > "$STATE_DIR/sentinel.sha256"
grep -Eq '^[0-9a-f]{64}$' "$STATE_DIR/store-deployment.sha256" \
  && grep -Eq '^[0-9a-f]{64}$' "$STATE_DIR/sentinel.sha256" \
  || die "sn-09 baseline fingerprints could not be recorded"

trap - EXIT
