Solve this question on: `cka-use-context ex-sn-04`

In namespace `node-agents` the DaemonSet `stats-agent` (Pod label
`app=stats-agent`) runs one agent on each worker node. Each agent serves HTTP
on container port `8080` and metrics on container port `9100`. The Deployment
`reporter` runs one Pod on each worker node.

Each `reporter` Pod must always talk to the agent on its **own** node.

1. In namespace `node-agents`, create a Service `stats-agent` of type
   `ClusterIP` that selects the agent Pods and has two ports:
   - name `http`, port `80`, to container port `8080`
   - name `metrics`, port `9100`, to container port `9100`
2. Configure the Service so that traffic sent from a Pod inside the cluster is
   delivered only to an agent on the same node as the sending Pod.
3. Requests from each `reporter` Pod to
   `http://stats-agent.node-agents.svc.cluster.local/` must always be answered
   by the agent on that Pod's node.

Do not change the DaemonSet or the Deployment.
