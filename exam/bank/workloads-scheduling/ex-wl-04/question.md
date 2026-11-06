Solve this question on: `cka-use-context ex-wl-04`

In namespace `api-scale` the Deployment `quote-api` (container `api`) must
scale automatically with its CPU load. The cluster runs metrics-server.

1. Create a HorizontalPodAutoscaler named `quote-api` (API `autoscaling/v2`)
   for the Deployment `quote-api` with:
   - at least `2` and at most `6` replicas
   - one metric: average CPU utilization of `60` percent
2. When the load drops, the HPA must scale down slowly:
   - a scale-down stabilization window of `120` seconds
   - remove at most `1` Pod per `60` seconds
3. The HPA must be able to compute the current CPU utilization of the Pods
   (`kubectl get hpa` must not show `<unknown>` as the current value). Change
   the Deployment only as far as this needs. Do not set a CPU limit, and do not
   change the image.
