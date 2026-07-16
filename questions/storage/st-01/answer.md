# st-01 정답지 — PersistentVolume and PersistentVolumeClaim

## 모범 답안

```bash
kubectl config use-context kind-cka
```

아래 매니페스트를 작성해 적용한다 (`vim pv.yaml` → `kubectl apply -f pv.yaml`):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-alpha
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /data/pv-alpha
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-alpha
  namespace: project-alpha
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: manual
  resources:
    requests:
      storage: 1Gi
```

바인딩 확인:

```bash
kubectl -n project-alpha get pvc pvc-alpha   # STATUS: Bound, VOLUME: pv-alpha
```

## 해설 (한국어)

- **PV와 PVC의 바인딩 조건**: `storageClassName`이 서로 일치하고, PV의 capacity(2Gi)가
  PVC의 요청(1Gi) 이상이며, accessModes가 호환되면 컨트롤러가 자동으로 바인딩한다.
- `storageClassName: manual`은 실제 StorageClass 오브젝트가 없어도 된다 — 문자열 매칭으로
  정적 바인딩(static provisioning)에 사용되는 관례적 이름이다.
- `persistentVolumeReclaimPolicy: Retain`은 PVC 삭제 후에도 볼륨과 데이터를 보존한다.
  (hostPath PV의 기본값도 Retain이지만, 시험에서는 요구사항대로 **명시**하는 습관이 안전하다)
- PV는 cluster-scoped, PVC는 namespaced 리소스라는 점에 주의한다.
- 공식 문서 참조 경로: **Concepts → Storage → Persistent Volumes** 페이지의 예시 YAML을
  복사해 수정하는 것이 가장 빠르다.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | PV `pv-alpha` 존재 | `kubectl get pv pv-alpha` |
| 2 | PV 스펙 일치 (2Gi/RWO/hostPath/manual/Retain) | jsonpath 필드 비교 |
| 1 | PVC `pvc-alpha` 존재 (project-alpha) | `kubectl get pvc -n project-alpha` |
| 1 | PVC 스펙 일치 (1Gi/RWO/manual) | jsonpath 필드 비교 |
| 1 | PVC가 `pv-alpha`에 Bound | `.status.phase` + `.spec.volumeName` |
