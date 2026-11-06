# ex-st-04 정답지 — Restrict dynamically provisioned volumes to one node

## 모범 답안

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: edge-local
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
  - matchLabelExpressions:
      - key: kubernetes.io/hostname
        values:
          - cka-worker2
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sensor-cache
  namespace: edge-data
spec:
  storageClassName: edge-local
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 128Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: sensor-writer
  namespace: edge-data
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "date > /cache/started && exec sleep 3600000"]
      volumeMounts:
        - name: cache
          mountPath: /cache
  volumes:
    - name: cache
      persistentVolumeClaim:
        claimName: sensor-cache
```

```bash
kubectl apply -f edge.yaml
kubectl -n edge-data get pvc sensor-cache            # Pod가 뜨기 전에는 Pending (정상)
kubectl -n edge-data get pod sensor-writer -o wide   # NODE cka-worker2
kubectl get pv -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values
kubectl get storageclass                             # standard만 (default)
```

## 해설

- **`volumeBindingMode: WaitForFirstConsumer`**이면 PVC는 Pod가 schedule될 때까지 `Pending`이다.
  scheduler가 Pod의 node를 고를 때 StorageClass의 `allowedTopologies`를 함께 본다. 그래서 Pod에
  node 규칙이 없어도 `cka-worker2`로 간다.
- **`allowedTopologies`**는 동적으로 만드는 volume이 놓일 수 있는 topology를 제한한다. 만들어진 PV는
  그 node의 nodeAffinity를 가진다.
- `nodeName`을 직접 쓰면 scheduler를 건너뛴다. 그러면 WaitForFirstConsumer claim에 node가 정해지지
  않아 volume이 만들어지지 않는다.
- default StorageClass는 annotation `storageclass.kubernetes.io/is-default-class: "true"`로 정한다.
  새 class에 이 annotation을 넣지 않는다.

공식 문서:
[Storage Classes: Volume binding mode](https://kubernetes.io/docs/concepts/storage/storage-classes/#volume-binding-mode) ·
[Storage Classes: Allowed topologies](https://kubernetes.io/docs/concepts/storage/storage-classes/#allowed-topologies) ·
[Change the default StorageClass](https://kubernetes.io/docs/tasks/administer-cluster/change-default-storage-class/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 1 | `edge-local`이 `rancher.io/local-path`와 `WaitForFirstConsumer`를 쓴다 |
| 2 | `allowedTopologies`가 `kubernetes.io/hostname: cka-worker2` 하나다 |
| 1 | `edge-local`은 default가 아니고 `standard`가 default다 |
| 1 | `sensor-cache`가 Bound이고 edge-local, ReadWriteOnce, 128Mi다 |
| 1 | 실측: `sensor-writer`가 node 규칙 없이 cka-worker2에서 Running이고, PV가 그 node에 있다 |
