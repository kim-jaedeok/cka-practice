# st-05 정답지 — Retain a volume and rebind preserved data

## 모범 답안

먼저 PVC 삭제가 PV와 데이터를 제거하지 않도록 reclaim policy를 바꾼다.

```bash
kubectl patch pv archive-pv --type=merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

kubectl -n storage-lifecycle delete pod archive-writer
kubectl -n storage-lifecycle delete pvc archive-old
kubectl wait --for=jsonpath='{.status.phase}'=Released pv/archive-pv --timeout=90s
```

Retain PV는 이전 `claimRef`를 유지하므로 이를 제거한 뒤 원래 PV를 명시하는 새
PVC를 만든다.

```bash
kubectl patch pv archive-pv --type=json \
  -p='[{"op":"remove","path":"/spec/claimRef"}]'
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: archive-restored
  namespace: storage-lifecycle
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: archive-lifecycle
  volumeName: archive-pv
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: archive-reader
  namespace: storage-lifecycle
spec:
  nodeSelector:
    kubernetes.io/hostname: cka-worker
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: archive
          mountPath: /archive
  volumes:
    - name: archive
      persistentVolumeClaim:
        claimName: archive-restored
```

검증:

```bash
kubectl -n storage-lifecycle wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/archive-restored --timeout=90s
kubectl -n storage-lifecycle wait --for=condition=Ready pod/archive-reader --timeout=180s
kubectl -n storage-lifecycle exec archive-reader -- cat /archive/marker.txt
```

## 해설

- `ReadWriteOnce`는 volume을 한 노드에서 read-write로 마운트할 수 있음을 뜻한다.
  hostPath 데이터가 node-local이므로 writer와 reader를 같은 worker에 둔다.
- `Retain`은 claim 삭제 뒤 PV와 저장 자산을 자동 재사용하지 않고 관리자가 직접
  복구하도록 남긴다. 따라서 `Released` PV의 이전 claimRef를 정리한 뒤 명시적으로
  다시 바인딩한다.
- 채점은 실행한 명령이 아니라 PV/PVC 관계, Ready 상태, marker 내용으로 판단한다.

공식 문서:

- [Persistent Volumes — Access modes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes)
- [Persistent Volumes — Reclaiming](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#reclaiming)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---:|---|
| 2 | 원래 PV가 Retain + 단일 RWO |
| 1 | 이전 Pod/PVC 제거 |
| 2 | replacement PVC가 원래 PV에 Bound |
| 1 | reader Pod의 node/claim/mount 관계와 Ready |
| 2 | marker 데이터 보존 |
