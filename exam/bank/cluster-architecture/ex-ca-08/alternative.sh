#!/usr/bin/env bash
# Alternative fixture: create the bootstrap token Secret by hand with kubectl
# and build the join command from the CA public key hash computed with openssl.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
CP="$(cka_cp_node)"

id="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
secret="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
expiration="$(date -u -d '+3 hours' +%Y-%m-%dT%H:%M:%SZ)"

kctx apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-$id
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  description: "rack-b expansion"
  token-id: "$id"
  token-secret: "$secret"
  expiration: "$expiration"
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: "system:bootstrappers:kubeadm:default-node-token"
EOF

hash="$(docker exec "$CP" sh -c \
  'openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt | openssl pkey -pubin -outform der | sha256sum' \
  | cut -d' ' -f1)"
mkdir -p "$CKA_WORK_DIR/ex-ca-08"
printf 'kubeadm join cka-control-plane:6443 --discovery-token-ca-cert-hash sha256:%s --token %s.%s\n' \
  "$hash" "$id" "$secret" > "$CKA_WORK_DIR/ex-ca-08/join-worker.sh"
