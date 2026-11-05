Solve this question on: `cka-use-context ex-ca-03`

A Kustomize project is available at `~/cka/ex-ca-03`:

```text
~/cka/ex-ca-03
├── base/                (Deployment and Service "catalog")
└── overlays/staging/    (staging customizations)
```

The `staging` overlay does not produce the intended result.

1. Fix the files in `overlays/staging/` only. Do not edit `base/`.
2. Apply the overlay with kubectl's built-in Kustomize support.
3. The result in namespace `kz-staging` must be:
   - Deployment `stg-catalog` with `2` Ready replicas running image `nginx:1.29`
   - its container gets the environment variable `MODE=staging` from the
     ConfigMap that the overlay generates (`stg-catalog-settings-<hash>`)
   - Service `stg-catalog` with ready endpoints
   - the Deployment, the Service and the generated ConfigMap carry the label
     `app.kubernetes.io/part-of=catalog`
