# ts-07 정답지 — Extract error lines from container logs

## 모범 답안

```bash
mkdir -p ~/cka/ts-07
kubectl -n logging logs api-gateway | grep ERROR > ~/cka/ts-07/errors.log

# 확인
cat ~/cka/ts-07/errors.log      # ERROR 라인 6줄만
```

## 해설 (한국어)

- `kubectl logs`는 컨테이너의 **stdout/stderr 스트림**을 보여준다
  (공식 역량: "Manage and evaluate container output streams").
- 자주 쓰는 옵션: `-f`(팔로우), `--previous`(직전 컨테이너), `--tail=N`,
  `--since=1h`, `-c <container>`(멀티 컨테이너), `--timestamps`,
  `-l app=x`(라벨 셀렉터로 여러 Pod).
- 리다이렉션(`>`)은 **호스트 셸**에서 일어나므로 파일은 조작 머신에 생성된다 —
  "save to file" 문제의 표준 패턴.
- 함정 주의: `grep ERROR`는 대소문자를 구분한다. 문제에서 요구한 문자열을
  정확히 사용할 것 (`grep -i`를 함부로 쓰면 의도치 않은 라인이 섞일 수 있다).

## 채점 기준 (4점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | ERROR 라인 포함 (첫/마지막 라인 확인) | 파일 grep |
| 1 | INFO 라인 미포함 | 파일 grep |
| 1 | ERROR 라인 수 = 6 | grep -c |
