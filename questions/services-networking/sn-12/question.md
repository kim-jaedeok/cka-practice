Solve this question on: `kubectl config use-context kind-cka`

The container runtime on each node reads its network plugin configuration from
the standard CNI configuration directory.

You can open a shell on a node with `ssh <node-name>`.

1. On node `cka-worker`, find the CNI configuration file that the container
   runtime uses.
2. In that configuration, find the type of the IPAM plugin that assigns Pod IP
   addresses.
3. Save only the IPAM plugin type to the file `~/cka/sn-12/ipam.txt`.

Do not modify any file on the node.
