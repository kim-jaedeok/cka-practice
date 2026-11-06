#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ca-06

# Read the Helm release history from its storage Secrets, so that grading does
# not depend on a Helm binary on the grading host.
exca06_history() { # <mode>
  local json
  json="$(kctx -n ops-dash get secrets -l owner=helm,name=board -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import base64, gzip, json, sys
mode = sys.argv[1]
releases = []
for item in json.load(sys.stdin).get("items", []):
    if item.get("type") != "helm.sh/release.v1":
        continue
    raw = base64.b64decode(base64.b64decode(item["data"]["release"]))
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    releases.append(json.loads(raw))
releases.sort(key=lambda r: r.get("version", 0))
by_version = {r.get("version"): r for r in releases}
rollbacks = [r["version"] for r in releases
             if r.get("info", {}).get("description", "").startswith("Rollback to 1")]
if mode == "rollback":
    ok = bool(rollbacks)
elif mode == "history":
    first = by_version.get(1, {})
    ok = first.get("chart", {}).get("metadata", {}).get("version") == "0.1.0"
elif mode == "latest":
    last = releases[-1] if releases else {}
    ok = (bool(rollbacks)
          and last.get("version", 0) > max(rollbacks)
          and last.get("info", {}).get("status") == "deployed"
          and last.get("chart", {}).get("metadata", {}).get("name") == "status-board"
          and last.get("chart", {}).get("metadata", {}).get("version") == "0.2.0")
elif mode == "latest-chart":
    last = releases[-1] if releases else {}
    ok = (last.get("info", {}).get("status") == "deployed"
          and last.get("chart", {}).get("metadata", {}).get("version") == "0.2.0")
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1"
}

exca06_workload() {
  deploy_ready ops-dash board 2 \
    && jp_eq deploy board ops-dash '{.spec.template.spec.containers[0].image}' nginx:1.29
}

_python3_require || true

criterion 2 "release board was rolled back to revision 1 with Helm" \
  "exca06_history rollback"

criterion 1 "release history was kept (no uninstall and reinstall)" \
  "exca06_history history"

criterion 2 "after the rollback, board was upgraded to chart status-board 0.2.0 (deployed)" \
  "exca06_history latest"

criterion 2 "Deployment board has 2 Ready replicas running nginx:1.29" \
  "exca06_workload"

criterion 1 "ConfigMap board-banner holds the banner from prod-values.yaml" \
  "jp_eq configmap board-banner ops-dash '{.data.banner}' 'Ops Board'"

grade_finish
