Solve this question on: `cka-use-context ex-ts-08`

In namespace `nightly-ops` the CronJob `db-vacuum` is scheduled to run every
minute. The database team reports that no new run of it has finished for a
long time.

1. Find out why the CronJob does not start new runs.
2. Fix it so that a new Job created from the CronJob `db-vacuum` completes
   successfully.
3. Make sure that a hanging run can never block the CronJob for long again:
   Kubernetes must stop every Job that the CronJob creates after at most
   `120` seconds.
4. Do not change the CronJob's schedule, its concurrency policy, or its
   container. Do not suspend the CronJob.
