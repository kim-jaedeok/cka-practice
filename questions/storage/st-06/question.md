Connect with `ssh st06-admin`. That shell is connected to the disposable
Kubernetes cluster for this task.

Install and prove a working CSI storage extension:

1. Apply the locked offline driver manifest at
   `~/cka/st-06/csi-hostpath-driver.yaml`.
2. Create a `StorageClass` named `csi-hostpath-lab` with:
   - provisioner `hostpath.csi.k8s.io`
   - reclaim policy `Delete`
   - volume binding mode `Immediate`
   - volume expansion enabled
3. In namespace `csi-lab`, create a PVC named `data` requesting `256Mi`,
   `ReadWriteOnce`, from that StorageClass.
4. Create a Pod named `writer` using image `busybox:1.36`. Mount the claim at
   `/data`, write exactly `csi-extension-ready` to `/data/proof.txt`, and keep
   the container running.

The PVC must be dynamically provisioned through CSI. A static PV, `hostPath`,
or `local` volume does not satisfy the task.
