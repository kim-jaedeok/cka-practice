# ts-09 정답지 — PVC stuck in Pending

## 진단 과정

```bash
kubectl -n data-layer get pvc,pv
#   report-pvc   Pending   ...   report    ← PVC의 storageClassName
#   report-pv    Available ...   reports   ← PV의 storageClassName (불일치!)

kubectl -n data-layer describe pvc report-pvc | tail -5
#   waiting for first consumer / no persistent volumes available ... class "report"
```

원인: PVC가 `report`(오타), PV는 `reports` — storageClassName 불일치로 바인딩 불가.

## 모범 답안

`spec.storageClassName`은 **불변(immutable)** 필드이므로 PVC를 재생성한다.
PVC를 Pod가 물고 있으므로 Pod → PVC 순서로 삭제:

```bash
kubectl -n data-layer delete pod report-app
kubectl -n data-layer delete pvc report-pvc
```

수정된 PVC + Pod 재생성 (storageClassName만 `reports`로 변경, 나머지 동일):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: report-pvc
  namespace: data-layer
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: reports        # 수정
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: report-app
  namespace: data-layer
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: reports
          mountPath: /reports
  volumes:
    - name: reports
      persistentVolumeClaim:
        claimName: report-pvc
```

## 해설 (한국어)

- **PVC Pending의 3대 원인**: (1) storageClassName 불일치/부재, (2) accessModes
  비호환, (3) 용량 부족(PV < PVC 요청). `describe pvc`의 Events가 원인을 알려준다.
- PVC의 `storageClassName`·`accessModes`·`volumeName` 등은 생성 후 변경 불가 —
  `kubectl edit`으로 고치려 하면 거부된다. **삭제 후 재생성**이 정석이다.
- 삭제 순서 주의: PVC를 사용하는 Pod가 있으면 PVC 삭제가 finalizer 때문에
  멈춘다(Terminating 유지) — Pod 먼저 삭제.
- 재생성 전에 원본 매니페스트를 백업해두면(`kubectl get pvc ... -o yaml > pvc.yaml`)
  실수를 줄일 수 있다.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 3 | PVC Bound + volumeName == report-pv | jsonpath |
| 2 | report-app Running | Ready condition |
| 1 | PV 무변경 (금지사항 준수) | jsonpath |
