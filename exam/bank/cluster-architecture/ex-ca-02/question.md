Solve this question on: `cka-use-context ex-ca-02`

In namespace `rollouts` an autoscaling bot runs as the ServiceAccount
`scaler-bot`. The namespace contains the Deployments `frontend` and `backend`.

1. Create a Role `frontend-scaler` and a RoleBinding `scaler-bot-frontend-scaler`
   in namespace `rollouts` so that the ServiceAccount `scaler-bot`:
   - can `get`, `list` and `watch` Deployments in `rollouts`
   - can `get`, `update` and `patch` the **scale** subresource of the
     Deployment `frontend` only
2. `scaler-bot` must NOT be able to `update` or `patch` the Deployments
   themselves, and must NOT be able to change the scale of `backend`.
3. Acting as `scaler-bot` (for example with `kubectl --as`), scale `frontend` to
   `3` replicas. Leave `backend` at `1` replica.
