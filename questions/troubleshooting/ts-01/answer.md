# ts-01 정답지 — Fix a Deployment stuck in ImagePullBackOff

## 진단 과정

```bash
kubectl -n app-track get pods
#   frontend-xxx   0/1   ImagePullBackOff

kubectl -n app-track describe pod <pod-name> | tail -15
#   Failed to pull image "nginx:1.92-fake": ... not found
```

## 모범 답안

```bash
kubectl -n app-track set image deploy/frontend nginx=nginx:1.29
kubectl -n app-track rollout status deploy/frontend    # 3/3 확인
```

## 해설 (한국어)

- **ImagePullBackOff / ErrImagePull 진단 루틴**: `get pods`로 상태 확인 →
  `describe pod`의 Events에서 정확한 실패 사유(오타, 존재하지 않는 태그,
  프라이빗 레지스트리 인증 실패 등)를 읽는다. Events가 진실이다.
- 수정은 3가지 중 편한 것으로: `kubectl set image deploy/<name> <container>=<image>`,
  `kubectl edit deploy`, 또는 `kubectl patch`. set image가 가장 빠르다.
- `set image`의 형식은 `<컨테이너이름>=<이미지>` — 컨테이너 이름을 먼저
  `kubectl get deploy -o jsonpath='{.spec.template.spec.containers[*].name}'`으로 확인.
- BackOff 상태의 Pod는 이미지 수정 후 롤링 업데이트로 자동 교체된다 —
  Pod를 직접 지울 필요 없다.

## 채점 기준 (5점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | 이미지 nginx:1.29 | jsonpath |
| 3 | 3/3 Ready | `.status.readyReplicas` |
