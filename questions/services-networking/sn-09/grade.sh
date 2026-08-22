#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

SN09_STATE_DIR="$CKA_STATE_DIR/question-data/sn-09"
SN09_SENTINEL_BASELINE="$SN09_STATE_DIR/sentinel.sha256"
SN09_STORE_BASELINE="$SN09_STATE_DIR/store-deployment.sha256"
SN09_SENTINEL_TAMPERED=0
SN09_STORE_TAMPERED=0

lb_address() { # lb_address <namespace> <service>
  local ip hostname
  ip="$(_jp_get service "$2" "$1" '{.status.loadBalancer.ingress[0].ip}')" || return 1
  hostname="$(_jp_get service "$2" "$1" '{.status.loadBalancer.ingress[0].hostname}')" || return 1
  printf '%s\n' "${ip:-$hostname}"
}

lb_url() { # lb_url <address> <port>
  case "$1" in
    *:*) printf 'http://[%s]:%s\n' "$1" "$2" ;;
    *)   printf 'http://%s:%s\n' "$1" "$2" ;;
  esac
}

lb_http_contains() { # lb_http_contains <namespace> <service> <port> <text>
  local address url
  command -v curl >/dev/null 2>&1 || {
    grade_invalid "grading dependency unavailable: curl" || true
    return 2
  }
  address="$(lb_address "$1" "$2")" || return 1
  [ -n "$address" ] || return 1
  url="$(lb_url "$address" "$3")"
  curl -fsS --noproxy '*' --connect-timeout 2 --max-time 5 "$url" \
    2>/dev/null | grep -Fq -- "$4"
}

lb_address_wait() { # <namespace> <service> [attempts]
  local address i attempts="${3:-20}"
  for i in $(seq 1 "$attempts"); do
    address="$(lb_address "$1" "$2" 2>/dev/null || true)"
    if [ -n "$address" ]; then
      printf '%s\n' "$address"
      return 0
    fi
    sleep 1
  done
  return 1
}

lb_http_contains_retry() { # <namespace> <service> <port> <text> [attempts]
  local i attempts="${5:-10}"
  for i in $(seq 1 "$attempts"); do
    lb_http_contains "$1" "$2" "$3" "$4" && return 0
    sleep 1
  done
  return 1
}

lb_service_spec_is() { # lb_service_spec_is <namespace> <service> <selector> <port> <targetPort>
  local json
  _python3_require || return $?
  json="$(_resource_json service "$2" "$1")" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
selector, port_text, target_text = sys.argv[1:4]
key, value = selector.split("=", 1)
spec = obj.get("spec", {})
ports = spec.get("ports", [])
ok = (
    spec.get("type") == "LoadBalancer"
    and spec.get("selector") == {key: value}
    and spec.get("loadBalancerClass") in (None, "")
    and len(ports) == 1
)
if ok:
    item = ports[0]
    ok = (
        item.get("protocol", "TCP") == "TCP"
        and item.get("port") == int(port_text)
        and item.get("targetPort", item.get("port")) == int(target_text)
    )
raise SystemExit(0 if ok else 1)
' "$3" "$4" "$5"
}

sn09_port80_proxy_inventory_json() {
  local ids candidate
  command -v docker >/dev/null 2>&1 || return 1
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

sn09_typed_resource_list_json() { # <expected item kind>
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

sn09_resource_fingerprint() { # store | sentinel
  local proxy_inventory
  _python3_require || return $?
  case "$1" in
    store)
      proxy_inventory="$(sn09_port80_proxy_inventory_json)" || return 1
      {
        for ref in configmap/store-page deployment/store; do
          kctx -n lb-shop get "$ref" -o json 2>/dev/null || return 1
        done
        kctx -n lb-shop get networkpolicy -o json 2>/dev/null \
          | sn09_typed_resource_list_json NetworkPolicy || return 1
        kctx get service -A -o json 2>/dev/null \
          | sn09_typed_resource_list_json Service || return 1
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
          kctx -n cka-system get "$ref" -o json 2>/dev/null || return 1
        done
        kctx -n cka-system get networkpolicy -o json 2>/dev/null \
          | sn09_typed_resource_list_json NetworkPolicy || return 1
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

sn09_fingerprint_matches() { # <store|sentinel> <baseline-file>
  local expected current
  [ -r "$2" ] || return 2
  expected="$(tr -d '\r\n' < "$2")" || return 2
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 2
  current="$(sn09_resource_fingerprint "$1" 2>/dev/null)" || return 1
  [ "$current" = "$expected" ]
}

sn09_candidate_guard() {
  [ "$SN09_SENTINEL_TAMPERED" -eq 0 ] && [ "$SN09_STORE_TAMPERED" -eq 0 ]
}

sn09_check_trusted_baselines() {
  # Missing trusted baselines are infrastructure failures.  In contrast,
  # candidate-visible resources that were deleted or altered force a FAIL.
  if [ ! -r "$SN09_SENTINEL_BASELINE" ] || [ ! -r "$SN09_STORE_BASELINE" ]; then
    grade_invalid "sn-09 trusted baseline fingerprint missing" || true
  elif ! sn09_fingerprint_matches sentinel "$SN09_SENTINEL_BASELINE"; then
    SN09_SENTINEL_TAMPERED=1
  elif ! sn09_fingerprint_matches store "$SN09_STORE_BASELINE"; then
    # This includes candidate-created NetworkPolicies and supplied workload
    # changes.  They are answer failures, not provider outages.
    SN09_STORE_TAMPERED=1
  elif ! svc_has_endpoints cka-system sn09-lb-sentinel \
      || ! lb_http_contains_retry cka-system sn09-lb-sentinel 18080 \
        cka-sn09-provider-ready 5; then
    grade_invalid "unchanged LoadBalancer sentinel data plane unavailable" || true
  fi
}

[ "${CKA_QUESTION_SOURCE_ONLY:-0}" = 1 ] && return 0

grade_init sn-09
sn09_check_trusted_baselines

# Setup already proved TCP 80 specifically.  If an exact candidate Service with
# ready endpoints cannot get an address or serve the unchanged workload after a
# bounded settle period, classify that as provider/host infrastructure failure.
if sn09_candidate_guard \
    && lb_service_spec_is lb-shop store-lb app=store 80 80 \
    && svc_has_endpoints lb-shop store-lb; then
  if ! lb_address_wait lb-shop store-lb 20 >/dev/null; then
    grade_invalid "exact store-lb received no address after the port-80 preflight" || true
  elif ! lb_http_contains_retry lb-shop store-lb 80 cka-sn09-loadbalancer 10; then
    grade_invalid "exact store-lb address cannot reach the unchanged workload" || true
  fi
fi

criterion 2 "store-lb: LoadBalancer, selector app=store, TCP 80 → 80" \
  "sn09_candidate_guard && \
   lb_service_spec_is lb-shop store-lb app=store 80 80"

criterion 1 "store-lb에 Ready EndpointSlice 주소가 존재" \
  "sn09_candidate_guard && svc_has_endpoints lb-shop store-lb"

criterion 2 "LoadBalancer 구현체가 외부 주소를 할당" \
  "sn09_candidate_guard && [ -n \"\$(lb_address lb-shop store-lb)\" ]"

criterion 3 "실측: 외부 주소의 HTTP 응답이 store 워크로드에 도달" \
  "sn09_candidate_guard && \
   lb_http_contains_retry lb-shop store-lb 80 cka-sn09-loadbalancer 3"

grade_finish
