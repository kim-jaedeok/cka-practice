# ex-st-01 정답지 — Bind a claim to a chosen PersistentVolume by labels

## 진단

```bash
kubectl get pv -l 'tier' -L tier,media
#   archive-pv-a 1Gi cold hdd Retain
#   archive-pv-b 2Gi hot  ssd Retain
#   archive-pv-c 3Gi cold ssd Delete   ← 대상. reclaim policy가 Delete다
```

selector 없이 1Gi를 요청하면 binder는 조건을 만족하는 가장 작은 volume(`archive-pv-a`)을
고른다. `tier=cold`만 쓰면 역시 `archive-pv-a`가 된다. 두 label을 모두 써야 한다.

## 모범 답안

```bash
kubectl patch pv archive-pv-c -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: vault-claim, namespace: vault-archive}
spec:
  storageClassName: archive
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 1Gi}}
  selector:
    matchLabels: {tier: cold, media: ssd}
---
apiVersion: v1
kind: Pod
metadata: {name: vault-writer, namespace: vault-archive}
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo sealed > /vault/state.txt && sleep infinity"]
      volumeMounts: [{name: vault, mountPath: /vault}]
  volumes:
    - name: vault
      persistentVolumeClaim: {claimName: vault-claim}
```

```bash
kubectl -n vault-archive get pvc vault-claim     # Bound  archive-pv-c  3Gi
kubectl -n vault-archive exec vault-writer -- cat /vault/state.txt
```

## 해설

- **static binding 조건**: storageClassName, access mode, 용량(요청 이상), selector가 모두
  맞아야 한다. 여러 PV가 맞으면 가장 작은 용량을 고른다. 묶인 PVC의 용량은 PV 용량(3Gi)으로
  보인다.
- **selector와 volumeName**: selector는 label 조건으로 후보를 좁힌다. volumeName은 PV
  하나를 직접 지정한다. 묶인 뒤에는 control plane이 `spec.volumeName`을 채운다.
- **reclaim policy**는 PV의 속성이다. `Delete`면 PVC를 지울 때 volume도 지운다.
  `Retain`이면 PV가 `Released`로 남고 데이터도 남는다. 이미 있는 PV는 `kubectl patch`로
  바꾼다.

공식 문서:
[Persistent Volumes — Binding](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#binding) ·
[Persistent Volumes — Selector](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#selector) ·
[Change the Reclaim Policy of a PersistentVolume](https://kubernetes.io/docs/tasks/administer-cluster/change-pv-reclaim-policy/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 2 | `vault-claim`(archive, RWO)이 `archive-pv-c`에 Bound |
| 1 | PVC selector가 `archive-pv-c`만 선택 (a·b는 제외) |
| 1 | `archive-pv-c` reclaim policy `Retain` |
| 1 | `vault-writer` Running, `/vault`에 `vault-claim` mount |
| 1 | `/vault/state.txt` 내용 `sealed` |
