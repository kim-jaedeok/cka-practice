# st-02 정답지 — StorageClass and dynamic provisioning

## 모범 답안

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-storage
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-fast
  namespace: project-beta
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-storage
  resources:
    requests:
      storage: 500Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: web-fast
  namespace: project-beta
spec:
  containers:
    - name: nginx
      image: nginx:1.29
      volumeMounts:
        - name: data
          mountPath: /usr/share/nginx/html
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-fast
```

## 해설 (한국어)

- **동적 프로비저닝**: StorageClass가 지정된 PVC가 생기면 provisioner가 PV를 자동 생성한다.
  정적 바인딩(st-01)과 달리 PV를 직접 만들 필요가 없다.
- **`WaitForFirstConsumer`의 의미**: PVC를 만들어도 즉시 Bound가 되지 않고, 그 PVC를
  사용하는 **Pod가 스케줄링될 때** 볼륨이 생성·바인딩된다. Pod를 만들기 전까지
  `Pending`인 것은 정상이다 — 시험에서 이걸 오류로 착각하지 말 것.
- StorageClass는 cluster-scoped이며 `provisioner` 필드는 변경 불가(immutable)이므로
  잘못 만들었다면 삭제 후 재생성해야 한다.
- 공식 문서 참조 경로: **Concepts → Storage → Storage Classes**, 예시 YAML 복사 후 수정.

## 채점 기준 (7점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | SC 스펙 (provisioner/WaitForFirstConsumer/Delete) | jsonpath 필드 비교 |
| 1 | PVC 스펙 (500Mi/RWO/fast-storage) | jsonpath 필드 비교 |
| 2 | Pod가 nginx:1.29 + PVC 마운트 경로 일치 | jsonpath 필드 비교 |
| 1 | PVC Bound (동적 프로비저닝 성공) | `.status.phase` |
| 1 | Pod Ready | Ready condition |
