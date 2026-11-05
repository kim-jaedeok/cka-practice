#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ca-01

EXCA01_CRD=backuppolicies.dataprotection.example.org

exca01_crd_check() { # <names|versions|printer>
  local json
  _python3_require || return $?
  json="$(_resource_json crd "$EXCA01_CRD" -)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
crd = json.load(sys.stdin)
mode = sys.argv[1]
spec = crd.get("spec", {})
names = spec.get("names", {})
versions = spec.get("versions", [])
established = any(c.get("type") == "Established" and c.get("status") == "True"
                  for c in crd.get("status", {}).get("conditions", []))
if mode == "names":
    ok = (established and spec.get("group") == "dataprotection.example.org"
          and spec.get("scope") == "Namespaced"
          and names.get("kind") == "BackupPolicy"
          and names.get("plural") == "backuppolicies"
          and names.get("singular") == "backuppolicy"
          and "bkp" in names.get("shortNames", []))
elif mode == "versions":
    ok = (len(versions) == 1 and versions[0].get("name") == "v1"
          and versions[0].get("served") is True and versions[0].get("storage") is True)
else:
    cols = [c for v in versions if v.get("name") == "v1"
            for c in v.get("additionalPrinterColumns", [])]
    ok = any(c.get("name") == "Schedule" and c.get("jsonPath") == ".spec.schedule"
             and c.get("type") == "string" for c in cols)
raise SystemExit(0 if ok else 1)
' "$1"
}

exca01_dry_run() { # <spec-json|-> ; succeeds when the API server accepts the object
  local spec="$1" body
  if [ "$spec" = "-" ]; then
    body='{"apiVersion":"dataprotection.example.org/v1","kind":"BackupPolicy","metadata":{"name":"grade-probe","namespace":"backup-ops"}}'
  else
    body='{"apiVersion":"dataprotection.example.org/v1","kind":"BackupPolicy","metadata":{"name":"grade-probe","namespace":"backup-ops"},"spec":'"$spec"'}'
  fi
  printf '%s' "$body" | kctx create --dry-run=server -f - >/dev/null 2>&1
}

# A valid object is accepted. Objects without spec, without schedule, or with
# retentionDays outside 1..90 are rejected.
exca01_validation() {
  exca01_dry_run '{"schedule":"0 3 * * *","retentionDays":30,"target":"x"}' || return 1
  ! exca01_dry_run '-' || return 1
  ! exca01_dry_run '{"retentionDays":30,"target":"x"}' || return 1
  ! exca01_dry_run '{"schedule":"0 3 * * *","retentionDays":120}' || return 1
  ! exca01_dry_run '{"schedule":"0 3 * * *","retentionDays":0}' || return 1
  ! exca01_dry_run '{"schedule":"0 3 * * *","retentionDays":"14"}'
}

exca01_instance() {
  local json
  json="$(kctx -n backup-ops get backuppolicies.dataprotection.example.org nightly-db \
    -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
spec = json.load(sys.stdin).get("spec", {})
ok = spec == {"schedule": "0 2 * * *", "retentionDays": 14, "target": "orders-db"}
raise SystemExit(0 if ok else 1)
'
}

_python3_require || true

criterion 2 "CRD is established with the requested group, names, short name and scope" \
  "exca01_crd_check names"

criterion 1 "CRD serves only v1 and stores v1" \
  "exca01_crd_check versions"

criterion 2 "API server enforces the schema (required spec/schedule, retentionDays 1..90 integer)" \
  "exca01_validation"

criterion 1 "Printer column Schedule shows .spec.schedule" \
  "exca01_crd_check printer"

criterion 2 "BackupPolicy nightly-db exists in backup-ops with the requested spec" \
  "exca01_instance"

grade_finish
