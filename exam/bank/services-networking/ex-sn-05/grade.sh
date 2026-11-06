#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-sn-05

EXSN05_DATA="$CKA_STATE_DIR/question-data/ex-sn-05"

exsn05_cert_sha() {
  [ -s "$EXSN05_DATA/cert-sha256" ] \
    || { grade_invalid "ex-sn-05 baseline cert-sha256 missing" || true; return 2; }
  tr -d '\r\n' < "$EXSN05_DATA/cert-sha256"
}

exsn05_secret() {
  local expected
  expected="$(exsn05_cert_sha)" || return $?
  kctx -n secure-vault get secret vault-tls -o json 2>/dev/null | python3 -c '
import base64, hashlib, json, ssl, sys
expected = sys.argv[1]
s = json.load(sys.stdin)
data = s.get("data", {})
ok = s.get("type") == "kubernetes.io/tls" and bool(data.get("tls.key"))
if ok:
    pem = base64.b64decode(data.get("tls.crt", "")).decode(errors="replace")
    start = pem.find("-----BEGIN CERTIFICATE-----")
    end = pem.find("-----END CERTIFICATE-----")
    ok = start >= 0 and end > start
    if ok:
        der = ssl.PEM_cert_to_DER_cert(pem[start:end + len("-----END CERTIFICATE-----")] + "\n")
        ok = hashlib.sha256(der).hexdigest() == expected
raise SystemExit(0 if ok else 1)
' "$expected"
}

exsn05_ingress() { # <mode>
  kctx -n secure-vault get ingress vault -o json 2>/dev/null | python3 -c '
import json, sys
mode = sys.argv[1]
spec = json.load(sys.stdin)["spec"]
if mode == "route":
    ok = spec.get("ingressClassName") == "nginx" and any(
        rule.get("host") == "vault.secure.test" and any(
            p.get("path", "/") == "/" and p.get("pathType") == "Prefix"
            and p.get("backend", {}).get("service", {}).get("name") == "vault-ui"
            and p.get("backend", {}).get("service", {}).get("port", {}).get("number") == 80
            for p in rule.get("http", {}).get("paths", []))
        for rule in spec.get("rules", []))
elif mode == "tls":
    ok = any(t.get("secretName") == "vault-tls" and "vault.secure.test" in t.get("hosts", [])
             for t in spec.get("tls", []))
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1"
}

# HTTPS through the ingress controller on the lab host port 8443 with SNI:
# the controller must present the provided certificate and reach vault-ui.
exsn05_https() {
  local expected
  expected="$(exsn05_cert_sha)" || return $?
  python3 - "$expected" <<'PY'
import hashlib, socket, ssl, sys
expected = sys.argv[1]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    with socket.create_connection(("127.0.0.1", 8443), timeout=5) as raw:
        with ctx.wrap_socket(raw, server_hostname="vault.secure.test") as tls:
            der = tls.getpeercert(binary_form=True)
            tls.sendall(b"GET / HTTP/1.1\r\nHost: vault.secure.test\r\nConnection: close\r\n\r\n")
            body = b""
            while True:
                chunk = tls.recv(4096)
                if not chunk:
                    break
                body += chunk
except OSError:
    raise SystemExit(1)
ok = hashlib.sha256(der).hexdigest() == expected and b"vault-ui-ok" in body
raise SystemExit(0 if ok else 1)
PY
}

_python3_require || true

criterion 2 "Secret vault-tls is a TLS Secret with the provided certificate" \
  "exsn05_secret"

criterion 1 "Ingress vault (class nginx) routes vault.secure.test / to vault-ui:80" \
  "exsn05_ingress route"

criterion 1 "Ingress vault terminates TLS for vault.secure.test with vault-tls" \
  "exsn05_ingress tls"

criterion 2 "실측: HTTPS to vault.secure.test shows the provided certificate and reaches vault-ui" \
  "exsn05_https"

grade_finish
