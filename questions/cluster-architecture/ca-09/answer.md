# ca-09 answer — configure an operator-backed certificate

```bash
kubectl -n operators apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: operator-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: db-api-tls
spec:
  secretName: db-api-tls
  commonName: db.operators.svc
  dnsNames: [db.operators.svc]
  duration: 24h
  renewBefore: 8h
  privateKey:
    algorithm: RSA
    size: 2048
  usages: [digital signature, key encipherment, server auth]
  issuerRef:
    name: operator-selfsigned
    kind: Issuer
EOF

kubectl -n operators wait --for=condition=Ready \
  issuer/operator-selfsigned certificate/db-api-tls --timeout=120s
kubectl -n operators get certificate,certificaterequest,secret
```

The important result is the reconcile chain, not just the two submitted custom
resources: Certificate → CertificateRequest → `kubernetes.io/tls` Secret.

Official references:

- https://cert-manager.io/docs/usage/certificate/
- https://cert-manager.io/docs/configuration/selfsigned/
- https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
