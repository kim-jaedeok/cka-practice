#!/usr/bin/env bash
# A fake CSIDriver plus a static hostPath PV must not pass the dynamic CSI criteria.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/cell.sh"

cell_activate st-06 csi-cell

kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: hostpath.csi.k8s.io
spec:
  attachRequired: true
  podInfoOnMount: true
  fsGroupPolicy: File
  volumeLifecycleModes: [Persistent]
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: csi-hostpath-lab
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: fake-csi-pv
spec:
  capacity:
    storage: 256Mi
  accessModes: [ReadWriteOnce]
  storageClassName: csi-hostpath-lab
  persistentVolumeReclaimPolicy: Delete
  hostPath:
    path: /tmp/fake-csi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: csi-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: csi-hostpath-lab
  volumeName: fake-csi-pv
  resources:
    requests:
      storage: 256Mi
EOF
