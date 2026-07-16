# wl-02 정답지 — Add a native sidecar logging container

## 모범 답안

```bash
kubectl -n mercury edit deploy cleaner
```

`spec.template.spec`에 `initContainers` 블록을 추가한다:

```yaml
spec:
  template:
    spec:
      initContainers:                      # 추가
        - name: logger-con
          image: busybox:1.36
          restartPolicy: Always            # ★ 이 한 줄이 native sidecar의 핵심
          command: ["sh", "-c", "tail -n+1 -F /var/log/cleaner/cleaner.log"]
          volumeMounts:
            - name: logs
              mountPath: /var/log/cleaner
      containers:
        - name: cleaner-con
          # ... 기존 그대로 ...
```

확인:

```bash
kubectl -n mercury rollout status deploy/cleaner
kubectl -n mercury logs deployment/cleaner -c logger-con --tail=10
```

## 해설 (한국어)

- **Native sidecar (K8s 1.29+ GA)**: `initContainers` 항목에 `restartPolicy: Always`를
  주면 일반 init 컨테이너와 달리 **종료를 기다리지 않고 계속 실행**되며, 메인 컨테이너보다
  먼저 시작하고 늦게 종료된다. 최신 CKA에서 사이드카는 이 방식으로 내는 것이 표준이다.
- `restartPolicy: Always`를 빼먹으면 init 컨테이너가 끝나기를 기다리느라 Pod가
  `Init:0/1` 상태에 영원히 머문다 — 대표적인 함정.
- 두 컨테이너가 **같은 볼륨(`logs`)을 공유**해야 파일이 보인다. 볼륨 이름은 문제에서
  주어진 기존 이름을 그대로 참조한다.
- `tail -n+1 -F`: 파일 처음부터 출력하고(-n+1) 파일이 재생성되어도 계속 follow(-F)한다.
- 공식 문서 참조 경로: **Concepts → Workloads → Pods → Sidecar Containers**.

## 채점 기준 (8점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 3 | initContainer `logger-con` + `restartPolicy: Always` + 이미지 | jsonpath 비교 |
| 2 | `logs` 볼륨을 `/var/log/cleaner`에 마운트 | jsonpath 비교 |
| 1 | 롤아웃 성공 (1/1) | `.status.readyReplicas` |
| 2 | `kubectl logs -c logger-con` 출력에 로그 존재 | 실제 로그 grep |
