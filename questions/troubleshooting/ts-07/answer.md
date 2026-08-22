# ts-07 정답지 — Inspect current and previous multi-container logs

## 모범 답안

```bash
mkdir -p ~/cka/ts-07
kubectl -n logging logs api-gateway -c gateway \
  | grep ERROR > ~/cka/ts-07/gateway-errors.log
kubectl -n logging logs api-gateway -c worker --previous \
  > ~/cka/ts-07/worker-previous.log

# 확인
cat ~/cka/ts-07/gateway-errors.log
cat ~/cka/ts-07/worker-previous.log
```

## 해설 (한국어)

- `kubectl logs`는 컨테이너의 stdout/stderr 스트림을 보여준다.
- 멀티 컨테이너 Pod에서는 `-c <container>`로 대상을 명시해야 한다.
- `--previous`는 재시작 전 container instance의 로그를 읽는다. 현재 로그와
  직전 로그는 서로 다른 스트림이므로 파일을 만든 뒤 내용을 비교한다.
- 리다이렉션(`>`)은 **호스트 셸**에서 일어나므로 파일은 조작 머신에 생성된다 —
  "save to file" 문제의 표준 패턴.
- 함정 주의: `grep ERROR`는 대소문자를 구분한다. 문제에서 요구한 문자열을
  정확히 사용할 것 (`grep -i`를 함부로 쓰면 의도치 않은 라인이 섞일 수 있다).

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 3 | gateway 현재 로그의 ERROR 라인만 완전·정확하게 저장 | 실제 명령 출력과 비교 |
| 3 | worker 직전 instance 로그 전체를 변경 없이 저장 | `--previous` 출력과 비교 |
