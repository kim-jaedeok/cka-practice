Solve this question on: `cka-use-context ex-ts-01`

In namespace `ledger` the Deployment `audit-writer` should run `2` replicas, but
`kubectl -n ledger get deploy audit-writer` shows `0/2` and no Pods exist.

1. Find out why the Deployment does not create any Pods.
2. Fix the problem so that both replicas of `audit-writer` are `Ready`.
3. The Pods must keep running under the identity that the Deployment already
   specifies. Do not change the Deployment's `serviceAccountName`, image, or
   replica count.
