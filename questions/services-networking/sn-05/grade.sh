#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"
source "$CKA_ROOT/lib/controllers.sh"

SN05_STATE_DIR="$CKA_STATE_DIR/question-data/sn-05"
SN05_TAMPERED=0

sn05_infra_fingerprint() {
  {
    kctx -n envoy-gateway-system get deployment,service,serviceaccount,configmap -o json 2>/dev/null || return 1
    kctx get gatewayclass envoy-cka -o json 2>/dev/null || return 1
    kctx -n envoy-gateway-system get envoyproxy cka-clusterip -o json 2>/dev/null || return 1
    kctx -n traffic get configmap/store-page deployment/store service/store-svc -o json 2>/dev/null || return 1
    kctx -n cka-controller-system get deployment/sn05-probe -o json 2>/dev/null || return 1
    kctx get clusterrole,clusterrolebinding -o json 2>/dev/null || return 1
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

sn05_infra_matches() {
  local expected current
  expected="$(tr -d '\r\n' < "$SN05_STATE_DIR/infra.sha256" 2>/dev/null)" || return 2
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 2
  current="$(sn05_infra_fingerprint)" || return 1
  [ "$current" = "$expected" ]
}

sn05_guard() { [ "$SN05_TAMPERED" -eq 0 ]; }

sn05_candidate_network_policy_present() {
  local namespace
  for namespace in traffic cka-controller-system envoy-gateway-system; do
    if kctx -n "$namespace" get networkpolicy -o name 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

sn05_gateway_spec_exact() {
  local json
  json="$(_resource_json gateway main-gw traffic)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
spec=json.load(sys.stdin).get("spec",{}); listeners=spec.get("listeners",[])
ok=(spec.get("gatewayClassName")=="envoy-cka" and len(listeners)==1)
if ok:
    listener=listeners[0]
    ok=(listener.get("name")=="http" and listener.get("protocol")=="HTTP"
        and listener.get("port")==80 and listener.get("hostname")=="shop.example.com")
raise SystemExit(0 if ok else 1)
'
}

sn05_route_spec_exact() {
  gateway_parent_ref_has store-route traffic main-gw http 80 \
    && jp_array_has httproute store-route traffic '{.spec.hostnames[*]}' shop.example.com \
    && jp_array_count httproute store-route traffic '{.spec.hostnames[*]}' 1 \
    && httproute_rule_has store-route traffic /store store-svc 80 \
    && gateway_listener_allows_httproute main-gw traffic http traffic
}

sn05_gateway_status_current() {
  local json
  json="$(_resource_json gateway main-gw traffic)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
obj=json.load(sys.stdin); generation=obj.get("metadata",{}).get("generation"); status=obj.get("status",{})
conditions=status.get("conditions",[])
def current_true(items, kind):
    return any(c.get("type")==kind and c.get("status")=="True" and c.get("observedGeneration")==generation for c in items)
listeners=[x for x in status.get("listeners",[]) if x.get("name")=="http"]
ok=(current_true(conditions,"Accepted") and current_true(conditions,"Programmed") and len(listeners)==1
    and listeners[0].get("attachedRoutes")==1
    and current_true(listeners[0].get("conditions",[]),"Accepted")
    and current_true(listeners[0].get("conditions",[]),"ResolvedRefs"))
raise SystemExit(0 if ok else 1)
'
}

sn05_route_status_current() {
  local json
  json="$(_resource_json httproute store-route traffic)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
obj=json.load(sys.stdin); generation=obj.get("metadata",{}).get("generation"); parents=obj.get("status",{}).get("parents",[])
valid=[]
for parent in parents:
    ref=parent.get("parentRef",{})
    if (ref.get("name")=="main-gw" and ref.get("namespace","traffic")=="traffic"
        and ref.get("group","gateway.networking.k8s.io")=="gateway.networking.k8s.io"
        and ref.get("kind","Gateway")=="Gateway" and ref.get("sectionName","http")=="http"
        and parent.get("controllerName")=="gateway.envoyproxy.io/gatewayclass-controller"):
        conditions=parent.get("conditions",[])
        accepted=any(c.get("type")=="Accepted" and c.get("status")=="True" and c.get("observedGeneration")==generation for c in conditions)
        resolved=any(c.get("type")=="ResolvedRefs" and c.get("status")=="True" and c.get("observedGeneration")==generation for c in conditions)
        if accepted and resolved: valid.append(parent)
raise SystemExit(0 if len(valid)==1 else 1)
'
}

sn05_data_service_ref() {
  local address services
  address="$(_jp_get gateway main-gw traffic '{.status.addresses[0].value}')" || return 1
  [ -n "$address" ] || return 1
  services="$(kctx get services -A -o json 2>/dev/null)" || return 1
  printf '%s' "$services" | python3 -c '
import json,sys
address=sys.argv[1]; found=[]
for item in json.load(sys.stdin).get("items",[]):
    spec=item.get("spec",{}); ports=spec.get("ports",[])
    if (spec.get("clusterIP")==address and spec.get("type","ClusterIP")=="ClusterIP"
        and any(p.get("port")==80 and p.get("protocol","TCP")=="TCP" for p in ports)):
        meta=item.get("metadata",{}); found.append((meta.get("namespace"),meta.get("name"),address))
if len(found)==1: print("|".join(found[0]))
else: raise SystemExit(1)
' "$address"
}

sn05_data_service_ready() {
  local ref ns name address
  ref="$(sn05_data_service_ref)" || return 1
  IFS='|' read -r ns name address <<< "$ref"
  svc_has_endpoints "$ns" "$name"
}

sn05_workload_runtime_locked() {
  controller_deployment_runtime_locked traffic store nginx \
    "$GATEWAY_BACKEND_IMAGE" \
    && controller_deployment_runtime_locked cka-controller-system sn05-probe \
      probe "$GATEWAY_PROBE_IMAGE"
}

sn05_data_deployment_ref() {
  local ref ns service address
  ref="$(sn05_data_service_ref)" || return 1
  IFS='|' read -r ns service address <<<"$ref"
  {
    kctx -n "$ns" get service "$service" -o json 2>/dev/null || return 1
    kctx -n "$ns" get deployments -o json 2>/dev/null || return 1
  } | python3 -c '
import json,sys
decoder=json.JSONDecoder(); text=sys.stdin.read(); pos=0; values=[]
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    value,pos=decoder.raw_decode(text,pos); values.append(value)
if len(values)!=2: raise SystemExit(1)
service,deployments=values
selector=service.get("spec",{}).get("selector",{})
if not isinstance(selector,dict) or not selector: raise SystemExit(1)
found=[]
for item in deployments.get("items",[]):
    labels=item.get("spec",{}).get("template",{}).get("metadata",{}).get("labels",{})
    if isinstance(labels,dict) and all(labels.get(k)==v for k,v in selector.items()):
        found.append(item.get("metadata",{}).get("name"))
if len(found)==1 and isinstance(found[0],str) and found[0]: print(found[0])
else: raise SystemExit(1)
'
}

sn05_data_plane_runtime_locked() {
  local ref ns service address deployment
  ref="$(sn05_data_service_ref)" || return 1
  IFS='|' read -r ns service address <<<"$ref"
  deployment="$(sn05_data_deployment_ref)" || return 1
  controller_deployment_runtime_locked "$ns" "$deployment" envoy \
    "$ENVOY_PROXY_IMAGE"
}

sn05_http_contains() { # host path expected [attempts]
  local host="$1" path="$2" expected="$3" attempts="${4:-1}" ref ns name address out
  ref="$(sn05_data_service_ref)" || return 1
  IFS='|' read -r ns name address <<< "$ref"
  for _ in $(seq 1 "$attempts"); do
    out="$(kctx -n cka-controller-system exec deploy/sn05-probe -- \
      wget -qO- --timeout=5 --header "Host: $host" "http://$address$path" 2>/dev/null || true)"
    printf '%s' "$out" | grep -Fq -- "$expected" && return 0
    sleep 1
  done
  return 1
}

sn05_http_404() { # host path
  local ref ns name address out
  ref="$(sn05_data_service_ref)" || return 1
  IFS='|' read -r ns name address <<< "$ref"
  out="$(kctx -n cka-controller-system exec deploy/sn05-probe -- \
    wget -S -O /dev/null --timeout=5 --header "Host: $1" "http://$address$2" 2>&1 || true)"
  printf '%s\n' "$out" | grep -Eq 'HTTP/1\.[01][[:space:]]+404'
}

[ "${CKA_QUESTION_SOURCE_ONLY:-0}" = 1 ] && return 0

grade_init sn-05

if [ ! -r "$SN05_STATE_DIR/infra.sha256" ]; then
  grade_invalid "sn-05 trusted Gateway infrastructure baseline missing" || true
elif ! sn05_infra_matches; then
  SN05_TAMPERED=1
elif sn05_candidate_network_policy_present; then
  # A candidate-created policy can deliberately break the backend, probe, or
  # generated Envoy path. That is an ordinary wrong answer, never an
  # infrastructure INVALID result.
  SN05_TAMPERED=1
elif ! deploy_ready envoy-gateway-system envoy-gateway 1 \
    || ! deploy_ready cka-controller-system sn05-probe 1 \
    || ! svc_has_endpoints traffic store-svc \
    || ! controller_envoy_gateway_runtime_locked \
    || ! controller_envoy_profile_is_locked \
    || ! sn05_workload_runtime_locked; then
  grade_invalid "unchanged Envoy Gateway or probe infrastructure unavailable" || true
fi

criterion 2 "Gateway class/listener/hostname가 정확하고 route attachment를 허용" \
  "sn05_guard && sn05_gateway_spec_exact && gateway_listener_allows_httproute main-gw traffic http traffic"

criterion 2 "HTTPRoute parent/hostname/PathPrefix/backend 관계가 정확" \
  "sn05_guard && sn05_route_spec_exact"

criterion 2 "현재 generation의 Gateway/HTTPRoute status와 파생 ClusterIP data plane이 정상" \
  "sn05_guard && sn05_gateway_status_current && sn05_route_status_current && \
   sn05_data_service_ready && sn05_data_plane_runtime_locked"

criterion 2 "실측: Host=shop.example.com, /store가 store backend marker 반환" \
  "sn05_guard && sn05_data_plane_runtime_locked && \
   sn05_http_contains shop.example.com /store cka-sn05-envoy-dataplane 2"

criterion 1 "실측: 잘못된 Host는 Envoy에서 HTTP 404" \
  "sn05_guard && sn05_data_plane_runtime_locked && \
   sn05_http_404 wrong.example.com /store"

criterion 1 "실측: 일치하지 않는 path는 Envoy에서 HTTP 404" \
  "sn05_guard && sn05_data_plane_runtime_locked && \
   sn05_http_404 shop.example.com /not-store"

grade_finish
