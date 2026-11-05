Solve this question on: `cka-use-context ex-wl-03`

In namespace `cache-tier` the Deployment `web` (Pod label `app=web`) runs one
Pod on each worker node. The Deployment `cache` (Pod label `app=cache`) runs
`2` replicas, but the scheduler places its Pods without any rule.

Change the Deployment `cache` so that:

1. A `cache` Pod may only be scheduled onto a node that already runs a Pod with
   label `app=web` (a hard requirement, node-level topology
   `kubernetes.io/hostname`).
2. Two `cache` Pods may never run on the same node (a hard requirement, same
   topology).
3. Use inter-Pod affinity and anti-affinity rules for both requirements.
4. `cache` finishes its rollout with `2` Ready replicas.

Do not modify the Deployment `web`, and do not change any node.
