Solve this question on: `kubectl config use-context kind-cka`

In namespace `project-delta` there is a Deployment named `web-store` and an existing
PersistentVolumeClaim named `store-data` (already Bound).

Modify the Deployment `web-store` so that:

1. The PVC `store-data` is mounted at `/var/www/data` in the `nginx` container.
2. An additional `emptyDir` volume named `tmp-cache` is mounted at `/tmp/cache`
   in the `nginx` container.
3. The Deployment rolls out successfully (1/1 replicas ready).

Do not delete the Deployment; modify it in place.
