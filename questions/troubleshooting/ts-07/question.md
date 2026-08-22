Solve this question on: `kubectl config use-context kind-cka`

In namespace `logging`, Pod `api-gateway` contains the containers `gateway`,
`worker`, and `metrics`. The `worker` container has restarted once.

1. Read the **current** log of container `gateway`, extract every line that
   contains the exact string `ERROR`, and save only those lines to
   `~/cka/ts-07/gateway-errors.log`.
2. Read the complete log from the **previous instance** of container `worker`
   and save it unchanged to `~/cka/ts-07/worker-previous.log`.

Do not include log output from another container or from the current `worker`
instance.
