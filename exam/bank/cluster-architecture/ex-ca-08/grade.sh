#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ca-08

EXCA08_DATA="$CKA_STATE_DIR/question-data/ex-ca-08"
EXCA08_FILE="$CKA_WORK_DIR/ex-ca-08/join-worker.sh"
EXCA08_CP="$(cka_cp_node)"

exca08_baseline_file() { # <name>
  [ -f "$EXCA08_DATA/$1" ] \
    || { grade_invalid "ex-ca-08 baseline $1 missing" || true; return 2; }
  printf '%s\n' "$EXCA08_DATA/$1"
}

exca08_tokens_json() {
  kctx -n kube-system get secrets --field-selector type=bootstrap.kubernetes.io/token \
    -o json 2>/dev/null
}

exca08_ca_hash() {
  node_exec_out "$EXCA08_CP" \
    'openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt | openssl pkey -pubin -outform der | sha256sum' \
    | cut -d' ' -f1
}

# One Python check over the tokens and the join file. Mode picks the item.
exca08_check() { # <mode>
  local tokens existing hash="-" cp_ip
  tokens="$(exca08_tokens_json)" || return 1
  existing="$(exca08_baseline_file existing-token-uids)" || return $?
  if [ "$1" = hash ]; then
    hash="$(exca08_ca_hash)"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] \
      || { grade_invalid "cannot compute the cluster CA hash" || true; return 2; }
  fi
  cp_ip="$(kctx get node "$EXCA08_CP" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
  printf '%s' "$tokens" | python3 -c '
import base64, datetime, json, os, re, sys
mode, existing_path, join_path, ca_hash, cp_ip = sys.argv[1:6]
items = json.load(sys.stdin)["items"]
now = datetime.datetime.now(datetime.timezone.utc)

def ts(value):
    return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc)

def field(secret, key):
    return base64.b64decode(secret.get("data", {}).get(key, "")).decode(errors="replace")

ours = [s for s in items if field(s, "description") == "rack-b expansion"]
token = ours[0] if len(ours) == 1 else None
token_value = (field(token, "token-id") + "." + field(token, "token-secret")) if token else None

def join_parts():
    if not os.path.isfile(join_path):
        return None
    lines = [l.strip() for l in open(join_path, encoding="utf-8", errors="replace") if l.strip()]
    if len(lines) != 1:
        return None
    words = lines[0].split()
    if words[:2] != ["kubeadm", "join"] or len(words) < 3:
        return None
    opts, i = {}, 3
    while i < len(words):
        if words[i].startswith("--") and i + 1 < len(words):
            opts[words[i]] = words[i + 1]
            i += 2
        else:
            return None
    return words[2], opts

if mode == "token":
    ok = token is not None
    if ok:
        exp = field(token, "expiration")
        ok = bool(exp) and ts(exp) > now and bool(re.fullmatch(r"[a-z0-9]{6}\.[a-z0-9]{16}", token_value))
elif mode == "ttl":
    ok = False
    if token is not None and field(token, "expiration"):
        ttl = (ts(field(token, "expiration")) - ts(token["metadata"]["creationTimestamp"])).total_seconds()
        ok = 3 * 3600 - 300 <= ttl <= 3 * 3600 + 300
elif mode == "usage":
    ok = (token is not None
          and field(token, "usage-bootstrap-authentication") == "true"
          and field(token, "usage-bootstrap-signing") == "true"
          and "system:bootstrappers:kubeadm:default-node-token"
              in field(token, "auth-extra-groups").split(","))
elif mode == "join":
    parts = join_parts()
    ok = (parts is not None and token is not None
          and parts[0] in ("cka-control-plane:6443", cp_ip + ":6443")
          and parts[1].get("--token") == token_value)
elif mode == "hash":
    parts = join_parts()
    ok = parts is not None and parts[1].get("--discovery-token-ca-cert-hash") == "sha256:" + ca_hash
elif mode == "existing":
    uids = {s["metadata"]["uid"] for s in items}
    wanted = [l.strip() for l in open(existing_path) if l.strip()]
    ok = all(u in uids for u in wanted)
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1" "$existing" "$EXCA08_FILE" "$hash" "${cp_ip:-none}"
}

_python3_require || true

criterion 1 "one valid bootstrap token has the description 'rack-b expansion'" \
  "exca08_check token"

criterion 2 "the token lives for 3 hours" \
  "exca08_check ttl"

criterion 1 "the token can authenticate and sign for joining nodes" \
  "exca08_check usage"

criterion 2 "join-worker.sh is one kubeadm join command with that token" \
  "exca08_check join"

criterion 1 "join-worker.sh pins the cluster CA public key hash" \
  "exca08_check hash"

criterion 1 "the bootstrap tokens that existed before were not removed" \
  "exca08_check existing"

grade_finish
