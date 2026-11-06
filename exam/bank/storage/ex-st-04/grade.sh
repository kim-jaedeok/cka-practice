#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-st-04

EXST04_NODE="${CKA_CLUSTER_NAME}-worker2"

exst04_sc() { # <mode>
  kctx get storageclass -o json 2>/dev/null | python3 -c '
import json, sys
mode, node = sys.argv[1:3]
items = {s["metadata"]["name"]: s for s in json.load(sys.stdin)["items"]}
sc = items.get("edge-local", {})
default_key = "storageclass.kubernetes.io/is-default-class"
if mode == "basic":
    ok = (sc.get("provisioner") == "rancher.io/local-path"
          and sc.get("volumeBindingMode") == "WaitForFirstConsumer")
elif mode == "topology":
    terms = sc.get("allowedTopologies", [])
    ok = (len(terms) == 1 and terms[0].get("matchLabelExpressions") == [
        {"key": "kubernetes.io/hostname", "values": [node]}])
elif mode == "default":
    ok = (bool(sc)
          and sc.get("metadata", {}).get("annotations", {}).get(default_key) != "true"
          and items.get("standard", {}).get("metadata", {}).get("annotations", {}).get(default_key) == "true")
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1" "$EXST04_NODE"
}

exst04_claim() {
  kctx -n edge-data get pvc sensor-cache -o json 2>/dev/null | python3 -c '
import json, sys
pvc = json.load(sys.stdin)
spec = pvc["spec"]
ok = (pvc.get("status", {}).get("phase") == "Bound"
      and spec.get("storageClassName") == "edge-local"
      and spec.get("accessModes") == ["ReadWriteOnce"]
      and spec.get("resources", {}).get("requests", {}).get("storage") == "128Mi")
raise SystemExit(0 if ok else 1)
'
}

# The Pod was placed by the scheduler only, the claim is mounted at /cache and
# the volume really lives on cka-worker2.
exst04_pod() {
  local json pv
  json="$(kctx -n edge-data get pod sensor-writer -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
node = sys.argv[1]
pod = json.load(sys.stdin)
spec = pod["spec"]
vols = {v["name"]: v.get("persistentVolumeClaim", {}).get("claimName")
        for v in spec.get("volumes", [])}
mounted = any(vols.get(m.get("name")) == "sensor-cache" and m.get("mountPath") == "/cache"
              for c in spec.get("containers", []) for m in c.get("volumeMounts", []))
ok = (mounted and spec.get("nodeName") == node
      and not spec.get("nodeSelector") and not spec.get("affinity")
      and pod.get("status", {}).get("phase") == "Running")
raise SystemExit(0 if ok else 1)
' "$EXST04_NODE" || return 1
  pv="$(kctx -n edge-data get pvc sensor-cache -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
  [ -n "$pv" ] && kctx get pv "$pv" -o json 2>/dev/null | python3 -c '
import json, sys
node = sys.argv[1]
pv = json.load(sys.stdin)
terms = pv["spec"].get("nodeAffinity", {}).get("required", {}).get("nodeSelectorTerms", [])
ok = any(node in e.get("values", []) for t in terms for e in t.get("matchExpressions", []))
raise SystemExit(0 if ok else 1)
' "$EXST04_NODE"
}

_python3_require || true

criterion 1 "StorageClass edge-local uses rancher.io/local-path with WaitForFirstConsumer" \
  "exst04_sc basic"

criterion 2 "StorageClass edge-local allows volumes only on cka-worker2" \
  "exst04_sc topology"

criterion 1 "edge-local is not the default class and standard still is" \
  "exst04_sc default"

criterion 1 "PVC sensor-cache is Bound with edge-local, ReadWriteOnce, 128Mi" \
  "exst04_claim"

criterion 1 "실측: sensor-writer runs on cka-worker2 without node rules, volume on that node" \
  "exst04_pod"

grade_finish
