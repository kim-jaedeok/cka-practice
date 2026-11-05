Solve this question on: `cka-use-context ex-wl-02`

In namespace `inference` the Deployment `predictor` (container `server`) needs
its model settings and its registry token in one directory. The ConfigMap
`model-config` and the Secret `model-registry` already exist.

Change the Deployment `predictor` so that:

1. It has exactly one new volume named `bundle`, mounted **read-only** at
   `/etc/predictor` in container `server`.
2. The directory contains only these two files:
   - `/etc/predictor/config/model.yaml` — key `model.yaml` of ConfigMap
     `model-config`
   - `/etc/predictor/auth/token` — key `token` of Secret `model-registry`
   No other key of the ConfigMap or the Secret may appear.
3. Both files have the permission mode `0440`.
4. The Deployment finishes its rollout with `1` Ready replica.

Do not modify the ConfigMap or the Secret.
