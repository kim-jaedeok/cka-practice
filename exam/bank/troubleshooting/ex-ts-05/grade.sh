#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-05

EXTS05_DATA="$CKA_STATE_DIR/question-data/ex-ts-05"

exts05_baseline() { # <name>
  [ -s "$EXTS05_DATA/$1" ] \
    || { grade_invalid "ex-ts-05 baseline $1 missing" || true; return 2; }
  tr -d '\r\n' < "$EXTS05_DATA/$1"
}

exts05_probe_unchanged() {
  local expected current
  expected="$(exts05_baseline probe-fingerprint)" || return $?
  current="$(kctx -n mapping get deploy geo-resolver -o json 2>/dev/null | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
c = obj["spec"]["template"]["spec"]["containers"][0]
print(hashlib.sha256(json.dumps(c.get("readinessProbe"), sort_keys=True).encode()).hexdigest())
')" || return 1
  [ "$current" = "$expected" ]
}

exts05_backend_unchanged() {
  local expected current
  expected="$(exts05_baseline backend-fingerprint)" || return $?
  current="$(python3 - "$CKA_CONTEXT" 2>/dev/null <<'PY'
import hashlib, json, subprocess, sys
ctx = sys.argv[1]
def get(kind, name):
    return json.loads(subprocess.check_output(
        ["kubectl", "--context", ctx, "-n", "mapping", "get", kind, name, "-o", "json"]))
svc = get("service", "tiles-api")
dep = get("deployment", "tiles")
print(svc["metadata"]["uid"] + "|" + dep["metadata"]["uid"] + "|" + hashlib.sha256(json.dumps(
    [svc["spec"]["selector"], svc["spec"]["ports"], dep["spec"]["template"]],
    sort_keys=True).encode()).hexdigest())
PY
)" || return 1
  [ "$current" = "$expected" ]
}

# Every Running geo-resolver Pod uses the kube-dns Service as nameserver and
# reaches tiles-api by its short name and its FQDN.
exts05_live_dns() {
  local dns pods pod
  dns="$(kctx -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)" \
    || { grade_invalid "kube-dns Service unavailable" || true; return 2; }
  [ -n "$dns" ] || { grade_invalid "kube-dns Service has no ClusterIP" || true; return 2; }
  # Old Pods that are still terminating after a rollout are not graded.
  pods="$(kctx -n mapping get pods -l app=geo-resolver --field-selector=status.phase=Running \
    -o json 2>/dev/null | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    if not p["metadata"].get("deletionTimestamp"):
        print(p["metadata"]["name"])
')" || return 1
  [ -n "$pods" ] || return 1
  for pod in $pods; do
    kctx -n mapping exec "$pod" -- sh -c '
      grep -Eq "^nameserver[[:space:]]+$1([[:space:]]|\$)" /etc/resolv.conf &&
      nslookup tiles-api.mapping.svc.cluster.local >/dev/null 2>&1 &&
      wget -q -O /dev/null -T 4 http://tiles-api/
    ' _ "$dns" >/dev/null 2>&1 || return 1
  done
}

_python3_require || true

criterion 1 "geo-resolver keeps its original readiness probe" \
  "exts05_probe_unchanged"

criterion 1 "Service tiles-api and Deployment tiles are unchanged" \
  "exts05_backend_unchanged"

criterion 2 "geo-resolver has 2 Ready replicas" \
  "deploy_ready mapping geo-resolver 2"

criterion 2 "실측: geo-resolver Pods use cluster DNS and reach tiles-api by short name and FQDN" \
  "exts05_live_dns"

grade_finish
