Solve this question on: `kubectl config use-context kind-cka`

A Helm chart is available on this machine at `~/cka/ca-07/chart/webapp`.

1. Install the chart as a release named `webapp-rel` into namespace
   `helm-apps`, overriding `replicaCount` to `2`.

2. The team then decides to update nginx. **Upgrade** the release
   (do not uninstall) so that the image tag is `1.29`, keeping
   `replicaCount=2`.

3. The release must be in `deployed` status with revision `2` or higher,
   and the Deployment `webapp-rel` must have 2 ready replicas running
   image `nginx:1.29`.
