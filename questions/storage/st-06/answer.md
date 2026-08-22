# Solution

Apply the provided, checksum-locked CSI driver first:

```bash
kubectl apply -f ~/cka/st-06/csi-hostpath-driver.yaml
kubectl -n csi-hostpath rollout status statefulset/csi-hostpathplugin --timeout=240s
```

Then create the requested StorageClass, PVC, and Pod. The complete reference
commands are in `solve.sh`.

Useful verification commands:

```bash
kubectl get csidriver hostpath.csi.k8s.io
kubectl get csinode -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.drivers[*].name}{"\n"}{end}'
kubectl -n csi-lab get pvc data
kubectl get pv -o custom-columns=NAME:.metadata.name,DRIVER:.spec.csi.driver,HANDLE:.spec.csi.volumeHandle
kubectl -n csi-lab exec writer -- cat /data/proof.txt
```

This is a real CSI data path: the external provisioner creates a PV whose
source is `.spec.csi`, kubelet discovers the node plugin through the registrar,
and the driver publishes the volume into the Pod.

Official references:

- https://kubernetes-csi.github.io/docs/deploying.html
- https://kubernetes.io/docs/concepts/storage/storage-classes/
- https://github.com/kubernetes-csi/csi-driver-host-path/tree/v1.18.0
