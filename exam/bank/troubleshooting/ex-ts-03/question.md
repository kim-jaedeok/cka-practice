Solve this question on: `cka-use-context ex-ts-03`

In namespace `reports` the Job `nightly-report` has failed. It reads its
settings from the ConfigMap `report-config`.

1. Find the error message that the failed container printed. Save that log
   line, and only that line, to `~/cka/ex-ts-03/job-error.log`.
2. Fix the problem so that a Job named `nightly-report` in namespace `reports`
   completes successfully.
3. Keep the Job's container image and command unchanged. Do NOT modify the
   ConfigMap `report-config`.
