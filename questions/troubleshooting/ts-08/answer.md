# ts-08 정답지 — Find the top CPU-consuming Pod

## 모범 답안

```bash
# CPU 기준 정렬
kubectl -n monitor top pods --sort-by=cpu
#   NAME             CPU(cores)   MEMORY(bytes)
#   metrics-crunch   250m         2Mi            ← 최다
#   idle-api         0m           0Mi
#   idle-worker      0m           0Mi

mkdir -p ~/cka/ts-08
echo "metrics-crunch" > ~/cka/ts-08/top-pod.txt

# 한 줄로 처리하려면:
kubectl -n monitor top pods --no-headers --sort-by=cpu | head -1 | awk '{print $1}' \
  > ~/cka/ts-08/top-pod.txt
```

## 해설 (한국어)

- `kubectl top pods/nodes`는 **metrics-server**가 설치되어 있어야 동작한다
  (공식 역량: "Monitor cluster and application resource usage").
  "error: Metrics API not available"이 나오면 metrics-server 부재/장애다.
- `--sort-by=cpu|memory` 옵션으로 정렬, `-A`로 전체 네임스페이스,
  `--containers`로 컨테이너 단위 사용량을 볼 수 있다.
- 메트릭은 수집 주기(기본 15초~1분) 때문에 Pod 시작 직후엔 비어 있을 수 있다 —
  "no metrics available yet"이면 잠시 기다렸다 다시 실행.
- 시험에서는 이 유형이 "가장 CPU를 많이 쓰는 Pod 이름을 파일에 기록"으로
  출제된다 — Pod 이름만 깔끔하게 기록할 것 (헤더/수치 포함 금지).

## 채점 기준 (5점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | 파일 존재 | 파일 확인 |
| 3 | 실제 top Pod와 일치 | 채점기가 kubectl top 재실행 비교 |
