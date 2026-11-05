Solve this question on: `cka-use-context ex-wl-01`

In namespace `orders` the Deployment `order-api` runs `4` replicas of
`nginx:1.28`.

1. Change its update strategy so that a rollout never has fewer than `4`
   available Pods and creates at most `1` extra Pod at a time
   (`RollingUpdate` with `maxSurge: 1` and `maxUnavailable: 0`).
2. Keep at most `5` old ReplicaSets for rollback (`revisionHistoryLimit`).
3. Update the container image to `nginx:1.29`.
4. `kubectl rollout history deploy/order-api -n orders` must show the change
   cause `upgrade nginx to 1.29` for the revision that runs `nginx:1.29`.
5. The rollout must finish with `4` Ready replicas.
