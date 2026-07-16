# st-03 정답지 — Expand a PersistentVolumeClaim

## 모범 답안

```bash
kubectl -n project-gamma edit pvc cache-pvc
# spec.resources.requests.storage: 1Gi → 3Gi 로 수정 후 저장
```

또는 patch 한 줄로:

```bash
kubectl -n project-gamma patch pvc cache-pvc --type=merge \
  -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}'
```

## 해설 (한국어)

- **PVC 확장 조건**: PVC가 사용하는 StorageClass에 `allowVolumeExpansion: true`가
  설정되어 있어야 API 서버가 `spec.resources.requests.storage` 증가를 허용한다.
  (이 조건이 없으면 edit 시 거부된다)
- PVC는 **축소 불가**, 확장만 가능하다.
- 실무/실전에서는 CSI 드라이버가 실제 볼륨을 리사이즈한 뒤 `status.capacity`가
  갱신되며, 파일시스템 확장은 Pod 재시작이 필요한 경우도 있다
  (`FileSystemResizePending` condition 확인). 이 연습 환경의 local-path
  프로비저너는 실제 리사이즈를 수행하지 않으므로 요청값(spec)만 채점한다.
- **PVC를 지웠다 다시 만들면 안 된다** — 실제 시험에서도 "do not delete" 제약이
  자주 붙고, 삭제 시 데이터 유실로 0점 처리될 수 있다.

## 채점 기준 (4점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 3 | `spec.resources.requests.storage` == 3Gi | jsonpath 비교 |
| 1 | Pod `cache-pod` 가 Running 유지 | Ready condition |
