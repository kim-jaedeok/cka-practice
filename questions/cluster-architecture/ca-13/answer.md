# ca-13 answer — install cert-manager from a pinned offline manifest

```bash
kubectl apply --server-side --force-conflicts \
  -f ~/cka/ca-13/cert-manager-v1.21.1.yaml

kubectl -n cert-manager wait --for=condition=Available \
  deployment/cert-manager deployment/cert-manager-cainjector \
  deployment/cert-manager-webhook --timeout=180s

kubectl -n operator-verify wait --for=condition=Ready \
  certificate/install-proof --timeout=120s
kubectl -n operator-verify get certificate,certificaterequest,secret
```

The setup preloads digest-locked images into the disposable cell. Applying the
local manifest therefore exercises installation and reconciliation without a
runtime network fetch.

Official references:

- https://cert-manager.io/docs/installation/
- https://cert-manager.io/docs/releases/
- https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
