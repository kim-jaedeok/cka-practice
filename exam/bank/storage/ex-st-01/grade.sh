#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-st-01

# The claim's selector matches archive-pv-c and neither of the other volumes.
exst01_selector() {
  local pvc pvs
  _python3_require || return $?
  pvc="$(_resource_json pvc vault-claim vault-archive)" || return 1
  pvs="$(kctx get pv archive-pv-a archive-pv-b archive-pv-c -o json 2>/dev/null)" || return 1
  python3 -c '
import json, sys
pvc = json.loads(sys.argv[1])
pvs = {p["metadata"]["name"]: p["metadata"].get("labels", {}) for p in json.loads(sys.argv[2])["items"]}
sel = pvc["spec"].get("selector")
def matches(sel, labels):
    if not sel or not (sel.get("matchLabels") or sel.get("matchExpressions")):
        return False
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for e in sel.get("matchExpressions") or []:
        key, op, vals = e.get("key"), e.get("operator"), e.get("values") or []
        if op == "In" and labels.get(key) not in vals: return False
        if op == "NotIn" and labels.get(key) in vals: return False
        if op == "Exists" and key not in labels: return False
        if op == "DoesNotExist" and key in labels: return False
    return True
ok = (len(pvs) == 3 and matches(sel, pvs["archive-pv-c"])
      and not matches(sel, pvs["archive-pv-a"]) and not matches(sel, pvs["archive-pv-b"]))
raise SystemExit(0 if ok else 1)
' "$pvc" "$pvs"
}

exst01_claim() {
  jp_eq pvc vault-claim vault-archive '{.status.phase}' Bound && \
  jp_eq pvc vault-claim vault-archive '{.spec.volumeName}' archive-pv-c && \
  jp_eq pvc vault-claim vault-archive '{.spec.storageClassName}' archive && \
  jp_array_has pvc vault-claim vault-archive '{.spec.accessModes[*]}' ReadWriteOnce
}

exst01_live() {
  [ "$(kctx -n vault-archive exec vault-writer -- cat /vault/state.txt 2>/dev/null | tr -d '\r\n ')" = sealed ]
}

_python3_require || true

criterion 2 "vault-claim (archive, RWO) is Bound to archive-pv-c" \
  "exst01_claim"

criterion 1 "vault-claim selects archive-pv-c by labels (tier=cold, media=ssd)" \
  "exst01_selector"

criterion 1 "archive-pv-c has reclaim policy Retain" \
  "jp_eq pv archive-pv-c - '{.spec.persistentVolumeReclaimPolicy}' Retain"

criterion 1 "Pod vault-writer is Running with vault-claim at /vault" \
  "pod_running vault-archive vault-writer && \
   claim_mounted_at pod vault-writer vault-archive vault-claim /vault"

criterion 1 "실측: /vault/state.txt contains sealed" \
  "exst01_live"

grade_finish
