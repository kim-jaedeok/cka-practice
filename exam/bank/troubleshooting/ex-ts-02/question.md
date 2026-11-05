Solve this question on: `cka-use-context ex-ts-02`

In namespace `billing` the Deployment `invoice-api` (2 replicas) was just
deployed. Its Pods exist, but their containers never start.

1. Find the root cause.
2. Fix it so that both replicas of `invoice-api` are `Ready`.
3. The container must still receive the environment variables `DB_USER` and
   `DB_PASSWORD`, and both values must still come from the Secret
   `invoice-db`. Do not put literal values in the Deployment.
4. Do NOT modify the Secret `invoice-db`.
