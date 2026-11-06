# ex-st-03 정답지 — Move an application's data to a larger volume

## 모범 답안

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: reports-v2
  namespace: reports-store
spec:
  storageClassName: standard
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 512Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: copier
  namespace: reports-store
spec:
  restartPolicy: Never
  containers:
    - name: copy
      image: busybox:1.36
      command: ["sh", "-c", "cp -a /old/. /new/ && ls -R /new"]
      volumeMounts:
        - { name: old, mountPath: /old, readOnly: true }
        - { name: new, mountPath: /new }
  volumes:
    - name: old
      persistentVolumeClaim: { claimName: reports-old }
    - name: new
      persistentVolumeClaim: { claimName: reports-v2 }
```

```bash
kubectl apply -f migrate.yaml
kubectl -n reports-store get pvc                 # reports-v2는 copier가 뜰 때 Bound가 된다
kubectl -n reports-store logs copier             # q1.csv q2.csv archive/2025.csv
kubectl -n reports-store delete pod copier

kubectl -n reports-store edit deploy report-server
#   volumes[name=data].persistentVolumeClaim.claimName: reports-old → reports-v2
kubectl -n reports-store rollout status deploy/report-server
kubectl -n reports-store exec deploy/report-server -- ls -R /data
```

다른 정답: 새 claim만 mount한 임시 Pod를 띄우고 `tar`로 흘려 보낸다.

```bash
kubectl -n reports-store exec deploy/report-server -- tar cf - -C /data . \
  | kubectl -n reports-store exec -i receiver -- tar xf - -C /new
```

## 해설

- `standard`(local-path)는 **WaitForFirstConsumer**다. 새 PVC는 그 claim을 쓰는 Pod가 schedule될
  때 그 node에 PV를 만든다. 두 claim을 함께 mount한 copier는 기존 PV가 있는 node로 가고, 새 PV도
  같은 node에 생긴다.
- `cp -a /old/. /new/`는 숨김 파일과 하위 디렉터리를 포함해 권한과 시간을 유지하며 복사한다.
- **ReadWriteOnce**는 한 node에서만 mount할 수 있다는 뜻이다. 같은 node의 여러 Pod는 함께
  mount할 수 있다.
- PVC 크기를 늘리려면 StorageClass에 `allowVolumeExpansion: true`와 확장을 지원하는 provisioner가
  필요하다. 그래서 이 문제는 새 claim으로 옮긴다.

공식 문서:
[Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/) ·
[Storage Classes: Volume binding mode](https://kubernetes.io/docs/concepts/storage/storage-classes/#volume-binding-mode)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 1 | `reports-v2`가 Bound이고 standard, ReadWriteOnce, 512Mi다 |
| 1 | `report-server`의 volume `data`가 `reports-v2`를 `/data`에 mount한다 |
| 1 | `report-server`가 Ready 1개다 |
| 2 | 실측: `reports-v2`를 mount한 실행 중인 서버의 `/data` 파일 3개가 원래 파일과 checksum이 같다 |
| 1 | `reports-old`가 남아 있고 Bound다 |
