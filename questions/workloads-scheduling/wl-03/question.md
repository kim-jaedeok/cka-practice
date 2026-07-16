Solve this question on: `kubectl config use-context kind-cka`

In namespace `autoscale` there is a Deployment named `web-cache` with CPU
resource requests already configured.

Create a HorizontalPodAutoscaler (`autoscaling/v2`) named `web-cache-hpa`
in namespace `autoscale`:

- Target: Deployment `web-cache`
- Minimum replicas: `2`
- Maximum replicas: `5`
- Scale on CPU utilization with an average target of `60%`

After creation the HPA should scale the Deployment up to the minimum of 2 replicas.
