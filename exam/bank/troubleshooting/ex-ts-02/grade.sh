#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-02

exts02_secret_unchanged() {
  local path="$CKA_STATE_DIR/question-data/ex-ts-02/secret-fingerprint" expected current
  [ -s "$path" ] \
    || { grade_invalid "ex-ts-02 baseline Secret fingerprint missing" || true; return 2; }
  expected="$(tr -d '\r\n' < "$path")"
  current="$(kctx -n billing get secret invoice-db -o json 2>/dev/null | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
print(obj["metadata"]["uid"] + "|" + hashlib.sha256(
    json.dumps(obj.get("data", {}), sort_keys=True).encode()).hexdigest())
')" || return 1
  [ -n "$expected" ] && [ "$current" = "$expected" ]
}

# Both variables must be secretKeyRef entries that point at existing keys of
# invoice-db. A literal value or an optional reference to a missing key fails.
exts02_env_from_secret() {
  local json
  _python3_require || return $?
  json="$(_resource_json deployment invoice-api billing)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
containers = obj["spec"]["template"]["spec"].get("containers", [])
want = {"DB_USER": "username", "DB_PASSWORD": "db-password"}
found = {}
for c in containers:
    for e in c.get("env", []):
        ref = (e.get("valueFrom") or {}).get("secretKeyRef") or {}
        if e.get("name") in want and "value" not in e:
            found[e["name"]] = (ref.get("name"), ref.get("key"))
ok = all(found.get(k) == ("invoice-db", v) for k, v in want.items())
raise SystemExit(0 if ok else 1)
'
}

# The running container must see the real Secret values.
exts02_live_env() {
  local pod user pass
  pod="$(kctx -n billing get pods -l app=invoice-api --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || return 1
  [ -n "$pod" ] || return 1
  user="$(kctx -n billing exec "$pod" -- printenv DB_USER 2>/dev/null)" || return 1
  pass="$(kctx -n billing exec "$pod" -- printenv DB_PASSWORD 2>/dev/null)" || return 1
  [ "$user" = invoice_svc ] && [ "$pass" = Tr4nsact10n-Ledger ]
}

_python3_require || true

criterion 2 "DB_USER and DB_PASSWORD come from existing keys of Secret invoice-db" \
  "exts02_env_from_secret"

criterion 1 "Secret invoice-db is unchanged" \
  "exts02_secret_unchanged"

criterion 2 "invoice-api has 2 Ready replicas" \
  "deploy_ready billing invoice-api 2"

criterion 1 "실측: a running container sees the Secret values" \
  "exts02_live_env"

grade_finish
