Solve this question on: `kubectl config use-context kind-cka`

In namespace `fabric`, Pod `trainer-a` runs on node `cka-worker` and Pod
`trainer-b` runs on node `cka-worker2`.

You can open a shell on a node with `ssh <node-name>`.

1. On node `cka-worker`, find the network interface that the node uses to send
   packets to the IP address of Pod `trainer-b`.
2. Save only the interface name (for example `eth1`) to the file
   `~/cka/sn-11/egress-interface.txt`.

Do not modify the Pods.
