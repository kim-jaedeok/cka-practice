Solve this question on: `kubectl config use-context kind-cka`

A Kustomize project is available at `~/cka/ca-08`:

```
~/cka/ca-08
├── base/                 (deployment kapp + service kapp)
└── overlays/prod/        (prod customizations)
```

1. Inspect what the `prod` overlay changes compared to the base
   (namespace, name prefix, replicas, image tag).

2. Apply the **prod overlay** to the cluster using kubectl's built-in
   Kustomize support.

3. Verify the result in namespace `kust-prod`: Deployment `prod-kapp`
   with 3 ready replicas running image `nginx:1.29`.
