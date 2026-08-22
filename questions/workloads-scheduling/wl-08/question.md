Solve this question on: `kubectl config use-context kind-cka`

Namespace `admission-guard` contains:

- LimitRange `guardrails`, which constrains and defaults per-container CPU and
  memory requests/limits;
- ResourceQuota `team-budget`, which permits at most `3` Pods and an aggregate
  `600m` of requested CPU;
- Deployment `quota-web`, desired replicas `3`. Its current template requests
  too much CPU, so admission cannot create all replicas.

Do **not** delete or weaken `guardrails` or `team-budget`.

Update `quota-web` so that it has `3` replicas and its `nginx` container uses:

- requests: `cpu: 200m`, `memory: 128Mi`
- limits: `cpu: 400m`, `memory: 256Mi`

All three replicas must become Ready while remaining within the existing quota.
