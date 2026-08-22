#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/cell.sh"

cell_activate st-06 csi-cell

kubectl apply -f "$CKA_WORK_DIR/st-06/csi-hostpath-driver.yaml"
kubectl -n csi-hostpath rollout status statefulset/csi-hostpathplugin \
  --timeout=240s

kubectl apply -f - <<'EOF'
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
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: csi-lab
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: csi-hostpath-lab
  resources:
    requests:
      storage: 256Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: writer
  namespace: csi-lab
spec:
  nodeSelector:
    cka-practice/csi-node: "true"
  containers:
    - name: writer
      image: busybox:1.36
      command:
        - sh
        - -c
        - printf '%s\n' csi-extension-ready > /data/proof.txt; sync; sleep infinity
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data
EOF

kubectl -n csi-lab wait --for=condition=Ready pod/writer --timeout=240s
