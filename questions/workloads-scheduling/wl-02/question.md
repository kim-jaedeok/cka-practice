Solve this question on: `kubectl config use-context kind-cka`

In namespace `mercury` the Deployment `cleaner` writes log output to the file
`/var/log/cleaner/cleaner.log` inside an `emptyDir` volume named `logs`.
The log is currently not accessible via `kubectl logs`.

Extend the Deployment `cleaner` with a **sidecar container** implemented as a
native sidecar (an init container that keeps running):

- Name: `logger-con`
- Image: `busybox:1.36`
- Command: `sh -c 'tail -n+1 -F /var/log/cleaner/cleaner.log'`
- It must be defined under `initContainers` with `restartPolicy: Always`
- Mount the existing volume `logs` at `/var/log/cleaner`

Afterwards `kubectl logs deployment/cleaner -c logger-con` must show the
application log output.
