Solve this question on: `kubectl config use-context kind-cka`

Both worker nodes have the label `cka-practice/wl07=eligible`.

In namespace `affinity-spread`, create a Deployment named `spread-web` with:

- `4` replicas using image `nginx:1.29` and Pod label `app=spread-web`;
- **required** node affinity
  (`requiredDuringSchedulingIgnoredDuringExecution`) that permits only nodes where
  `cka-practice/wl07 In [eligible]`;
- a topology spread constraint with `maxSkew: 1`, topology key
  `kubernetes.io/hostname`, and `whenUnsatisfiable: DoNotSchedule`;
- a topology spread label selector that targets `app=spread-web`.

All four replicas must be Ready and distributed evenly across the two eligible
worker nodes.
