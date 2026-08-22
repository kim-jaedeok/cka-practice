#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"
source "$CKA_ROOT/lib/csi.sh"

grade_init st-06

if ! csi_disposable_context; then
  grade_invalid "st-06 is not running in its disposable CSI cell" || true
  grade_finish
  exit 0
fi

# A grader must never inherit kubectl's default unlimited request lifetime.
# Ordinary API reads use a per-request deadline; the streaming exec used for
# the real data-path proof also has a process deadline because it can remain
# open after the initial HTTP request has succeeded.
ST06_API_REQUEST_TIMEOUT="10s"
ST06_EXEC_TIMEOUT="15s"

st06_kctx() {
  kctx --request-timeout="$ST06_API_REQUEST_TIMEOUT" "$@"
}

st06_writer_marker_exact() {
  local marker rc=0
  if ! command -v timeout >/dev/null 2>&1; then
    grade_invalid "st-06 grading dependency unavailable: timeout" || true
    return 2
  fi

  marker="$(
    timeout --foreground "$ST06_EXEC_TIMEOUT" \
      kubectl --context "$CKA_CONTEXT" -n csi-lab \
      exec writer -- cat /data/proof.txt 2>/dev/null
  )" || rc=$?
  case "$rc" in
    0) [ "$marker" = csi-extension-ready ] ;;
    124|137)
      grade_invalid "st-06 writer data-path exec exceeded $ST06_EXEC_TIMEOUT" || true
      return 2
      ;;
    *) return 1 ;;
  esac
}

st06_plugin_contract() {
  local manifest expected
  manifest="$(st06_kctx -n csi-hostpath get statefulset csi-hostpathplugin -o json 2>/dev/null)" \
    || return 1
  expected="$(printf '%s\n' \
    "${CSI_HOSTPATH_IMAGE%:*}@${CSI_HOSTPATH_DIGEST}" \
    "${CSI_REGISTRAR_IMAGE%:*}@${CSI_REGISTRAR_DIGEST}" \
    "${CSI_LIVENESS_IMAGE%:*}@${CSI_LIVENESS_DIGEST}" \
    "${CSI_PROVISIONER_IMAGE%:*}@${CSI_PROVISIONER_DIGEST}" \
    "${CSI_ATTACHER_IMAGE%:*}@${CSI_ATTACHER_DIGEST}" | sort)"
  EXPECTED_IMAGES="$expected" python3 -c '
import json, os, sys

obj = json.load(sys.stdin)
meta = obj.get("metadata", {})
status = obj.get("status", {})
spec = obj.get("spec", {})
template = spec.get("template", {}).get("spec", {})
containers = template.get("containers", [])
images = sorted(c.get("image", "") for c in containers)
expected = os.environ["EXPECTED_IMAGES"].splitlines()
names = {c.get("name") for c in containers}
ready = (
    spec.get("replicas") == 1
    and status.get("observedGeneration") == meta.get("generation")
    and status.get("readyReplicas") == 1
    and status.get("currentReplicas") == 1
    and status.get("updatedReplicas") == 1
)
node_selector = template.get("nodeSelector", {}) == {"cka-practice/csi-node": "true"}
required = {"hostpath", "node-driver-registrar", "liveness-probe", "csi-provisioner", "csi-attacher"}
raise SystemExit(0 if ready and node_selector and names == required and images == expected else 1)
' <<< "$manifest"
}

st06_csidriver_and_node_registered() {
  local driver nodes
  driver="$(st06_kctx get csidriver hostpath.csi.k8s.io -o json 2>/dev/null)" || return 1
  nodes="$(st06_kctx get csinodes -o json 2>/dev/null)" || return 1
  python3 -c '
import json, sys

decoder = json.JSONDecoder(); text = sys.stdin.read(); pos = 0; values = []
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    value, pos = decoder.raw_decode(text, pos); values.append(value)
if len(values) != 2: raise SystemExit(1)
driver, nodes = values
spec = driver.get("spec", {})
# The API defaults an omitted/empty lifecycle list to Persistent and allows a
# driver to advertise additional modes. podInfoOnMount and fsGroupPolicy are
# orthogonal to the PVC-backed data path in this task, so neither is a fair scoring
# requirement. An explicit attachRequired=false remains incompatible with the
# required VolumeAttachment path.
modes = spec.get("volumeLifecycleModes") or ["Persistent"]
driver_ok = (
    spec.get("attachRequired", True) is True
    and "Persistent" in modes
)
registered = [
    item.get("metadata", {}).get("name", "")
    for item in nodes.get("items", [])
    if any(d.get("name") == "hostpath.csi.k8s.io"
           for d in (item.get("spec", {}).get("drivers") or []))
]
# Registration is per node. More than one valid registration is not an error;
# the writer criterion separately proves registration on the consuming node.
raise SystemExit(0 if driver_ok and bool(registered) else 1)
' <<< "$driver"$'\n'"$nodes"
}

st06_storageclass_exact() {
  local obj
  obj="$(st06_kctx get storageclass csi-hostpath-lab -o json 2>/dev/null)" || return 1
  python3 -c '
import json, sys
s = json.load(sys.stdin)
ok = (
    s.get("provisioner") == "hostpath.csi.k8s.io"
    and s.get("reclaimPolicy") == "Delete"
    and s.get("volumeBindingMode") == "Immediate"
    and s.get("allowVolumeExpansion") is True
    and not s.get("parameters")
)
raise SystemExit(0 if ok else 1)
' <<< "$obj"
}

st06_dynamic_volume_contract() {
  local claim pv_name pv
  claim="$(st06_kctx -n csi-lab get pvc data -o json 2>/dev/null)" || return 1
  pv_name="$(printf '%s' "$claim" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("spec",{}).get("volumeName",""))')"
  [ -n "$pv_name" ] || return 1
  pv="$(st06_kctx get pv "$pv_name" -o json 2>/dev/null)" || return 1
  python3 -c '
import json, sys
decoder = json.JSONDecoder(); text = sys.stdin.read(); pos = 0; values = []
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    value, pos = decoder.raw_decode(text, pos); values.append(value)
if len(values) != 2: raise SystemExit(1)
claim, pv = values
cs = claim.get("spec", {})
ps = pv.get("spec", {})
ref = ps.get("claimRef", {})
csi = ps.get("csi", {})
annotations = pv.get("metadata", {}).get("annotations", {})
ok = (
    pv.get("metadata", {}).get("name") == "pvc-" + claim.get("metadata", {}).get("uid", "")
    and pv.get("metadata", {}).get("creationTimestamp", "") >= claim.get("metadata", {}).get("creationTimestamp", "")
    and claim.get("status", {}).get("phase") == "Bound"
    and cs.get("storageClassName") == "csi-hostpath-lab"
    and cs.get("accessModes") == ["ReadWriteOnce"]
    and cs.get("resources", {}).get("requests", {}).get("storage") == "256Mi"
    and ps.get("storageClassName") == "csi-hostpath-lab"
    and ps.get("persistentVolumeReclaimPolicy") == "Delete"
    and csi.get("driver") == "hostpath.csi.k8s.io"
    and bool(csi.get("volumeHandle"))
    and "hostPath" not in ps and "local" not in ps
    and ref.get("namespace") == "csi-lab" and ref.get("name") == "data"
    and ref.get("uid") == claim.get("metadata", {}).get("uid")
    and annotations.get("pv.kubernetes.io/provisioned-by") == "hostpath.csi.k8s.io"
    and csi.get("volumeAttributes", {}).get("storage.kubernetes.io/csiProvisionerIdentity", "").endswith("-hostpath.csi.k8s.io")
)
raise SystemExit(0 if ok else 1)
' <<< "$claim"$'\n'"$pv"
}

st06_writer_contract() {
  local pod claim pv_name nodes attachments
  pod="$(st06_kctx -n csi-lab get pod writer -o json 2>/dev/null)" || return 1
  claim="$(st06_kctx -n csi-lab get pvc data -o json 2>/dev/null)" || return 1
  pv_name="$(printf '%s' "$claim" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("spec",{}).get("volumeName",""))')"
  [ -n "$pv_name" ] || return 1
  nodes="$(st06_kctx get csinodes -o json 2>/dev/null)" || return 1
  attachments="$(st06_kctx get volumeattachments -o json 2>/dev/null)" || return 1
  PV_NAME="$pv_name" python3 -c '
import json, os, sys

decoder = json.JSONDecoder(); text = sys.stdin.read(); pos = 0; values = []
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    value, pos = decoder.raw_decode(text, pos); values.append(value)
if len(values) != 3: raise SystemExit(1)
p, nodes, attachments = values
s = p.get("spec", {})
containers = s.get("containers", [])
volumes = s.get("volumes", [])
if len(containers) != 1 or containers[0].get("name") != "writer" or containers[0].get("image") != "busybox:1.36":
    raise SystemExit(1)
claim_volumes = [v for v in volumes if v.get("persistentVolumeClaim", {}).get("claimName") == "data"]
if len(claim_volumes) != 1:
    raise SystemExit(1)
mounts = [m for m in containers[0].get("volumeMounts", []) if m.get("mountPath") == "/data"]
ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in p.get("status", {}).get("conditions", []))
node_name = s.get("nodeName", "")
registered = any(
    item.get("metadata", {}).get("name") == node_name
    and any(d.get("name") == "hostpath.csi.k8s.io"
            for d in (item.get("spec", {}).get("drivers") or []))
    for item in nodes.get("items", [])
)
attached = [
    item for item in attachments.get("items", [])
    if item.get("spec", {}).get("attacher") == "hostpath.csi.k8s.io"
    and item.get("spec", {}).get("nodeName") == node_name
    and item.get("spec", {}).get("source", {}).get("persistentVolumeName") == os.environ["PV_NAME"]
    and item.get("status", {}).get("attached") is True
]
ok = (
    len(mounts) == 1 and mounts[0].get("name") == claim_volumes[0].get("name")
    and bool(node_name) and registered and len(attached) == 1 and ready
)
raise SystemExit(0 if ok else 1)
' <<< "$pod"$'\n'"$nodes"$'\n'"$attachments"
}

criterion 2 "실제 CSI plugin과 고정 이미지 5개가 worker에서 Ready" \
  "st06_plugin_contract"
criterion 2 "CSIDriver가 persistent attach를 선언하고 CSINode에 driver가 등록됨" \
  "st06_csidriver_and_node_registered"
criterion 2 "StorageClass가 요청된 CSI provisioner와 lifecycle을 사용" \
  "st06_storageclass_exact"
criterion 2 "PVC UID 기반 CSI PV가 외부 provisioner에 의해 동적으로 생성됨" \
  "st06_dynamic_volume_contract"
criterion 2 "writer node의 CSINode·VolumeAttachment를 거쳐 /data marker를 읽음" \
  "st06_writer_contract && st06_writer_marker_exact"

grade_finish
