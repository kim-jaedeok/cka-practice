#!/usr/bin/env bash
# Near-miss fixture: the certificate is issued and saved, but the Role only
# covers Pods, so dana cannot read Pod logs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

work="$CKA_WORK_DIR/ex-ca-04"
request="$(base64 -w0 < "$work/dana.csr")"
kctx apply -f - >/dev/null <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: dana-csr
spec:
  request: $request
  signerName: kubernetes.io/kube-apiserver-client
  usages: ["client auth"]
  expirationSeconds: 86400
EOF
kctx certificate approve dana-csr >/dev/null
for _ in $(seq 1 30); do
  cert="$(kctx get csr dana-csr -o jsonpath='{.status.certificate}')"
  [ -n "$cert" ] && break
  sleep 1
done
printf '%s' "$cert" | base64 -d > "$work/dana.crt"

kctx -n audit-zone create role log-reader --verb=get,list --resource=pods >/dev/null
kctx -n audit-zone create rolebinding dana-log-reader --role=log-reader --user=dana >/dev/null
