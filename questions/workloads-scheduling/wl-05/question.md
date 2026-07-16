Solve this question on: `kubectl config use-context kind-cka`

The cluster has two worker nodes:

- `cka-worker` is labeled `disktype=ssd`
- `cka-worker2` is tainted `env=prod:NoSchedule`

In namespace `scheduling` complete the following tasks:

1. Create a Deployment `ssd-app` with `2` replicas, image `nginx:1.29`,
   whose Pods are scheduled **only on the node with the `disktype=ssd` label**
   (use a nodeSelector).

2. Create a single Pod `prod-pod`, image `nginx:1.29`, that runs
   **on the tainted node `cka-worker2`**. Add the required toleration
   (key `env`, value `prod`, effect `NoSchedule`) and pin it to that node
   with a nodeSelector on `kubernetes.io/hostname`.

All Pods must be Running.
