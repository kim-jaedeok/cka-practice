# ts-02 정답지 — Diagnose a CrashLoopBackOff

## 진단 과정

```bash
kubectl -n batch-jobs get pods
#   worker-xxx   0/1   CrashLoopBackOff   4 (30s ago)

# 컨테이너가 왜 죽는지: 로그와 종료코드
kubectl -n batch-jobs logs deploy/worker --previous     # "worker booting..." 후 종료
kubectl -n batch-jobs describe pod <pod> | grep -A5 "Last State"
#   Exit Code: 1

# 원인: command가 'echo ...; exit 1' 로 되어 있음
kubectl -n batch-jobs get deploy worker \
  -o jsonpath='{.spec.template.spec.containers[0].command}'
```

## 모범 답안

```bash
kubectl -n batch-jobs edit deploy worker
```

```yaml
      containers:
        - name: worker
          image: busybox:1.36
          command: ["sleep", "infinity"]      # 수정
```

```bash
kubectl -n batch-jobs rollout status deploy/worker   # 2/2
```

## 해설 (한국어)

- **CrashLoopBackOff 진단 루틴**: (1) `logs --previous`로 죽기 직전 로그 확인
  (현재 컨테이너는 재시작 직후라 로그가 없을 수 있다), (2) `describe pod`의
  `Last State`/`Exit Code` 확인, (3) command/args, 설정, 의존 서비스 순으로 원인 추적.
- Exit Code 해석: `1`(앱 오류), `137`(OOMKill = 128+9), `126/127`(명령 실행 불가/없음) —
  코드만으로 원인 계열을 좁힐 수 있다.
- CrashLoopBackOff은 "재시작 대기 중" 상태다. 원인을 고치면 백오프 타이머 후
  자동 복구되며, 급하면 `rollout restart`로 즉시 새 Pod를 만들 수 있다.
- 공식 문서 참조 경로: **Tasks → Monitoring, Logging, and Debugging →
  Debug Pods**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | command 수정 (sleep, exit 1 제거) | jsonpath |
| 3 | 2/2 Ready | `.status.readyReplicas` |
| 1 | CrashLoopBackOff 상태 없음 | containerStatuses 검사 |
