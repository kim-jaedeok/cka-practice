# ex-ts-02 정답지 — Pods stuck before the container starts

## 진단 과정

```bash
kubectl -n billing get pods -l app=invoice-api
#   STATUS: CreateContainerConfigError
kubectl -n billing describe pod -l app=invoice-api | grep -A3 Events
#   Error: couldn't find key password in Secret billing/invoice-db
kubectl -n billing get secret invoice-db -o jsonpath='{.data}'   # key 이름 확인
#   {"db-password":"...","username":"..."}
```

## 모범 답안

```bash
kubectl -n billing edit deploy invoice-api
#   env[DB_PASSWORD].valueFrom.secretKeyRef.key: password → db-password
kubectl -n billing rollout status deploy/invoice-api
```

- Secret에 `password` key를 추가하면 요구사항 4를 어긴다.
- `DB_PASSWORD`에 literal `value`를 넣으면 요구사항 3을 어긴다.
- `optional: true`를 붙이면 container는 시작하지만 `DB_PASSWORD`가 비어 있다.

## 해설

- **CreateContainerConfigError**: kubelet이 container 설정을 만들지 못할 때의 상태다.
  image pull은 끝났고 container는 아직 만들어지지 않았다. 원인은 `describe pod`의
  event에 나온다. 흔한 원인은 없는 ConfigMap·Secret이나 없는 key를 참조하는 경우다.
- **CrashLoopBackOff와의 차이**: CrashLoopBackOff는 container가 시작한 뒤 종료하는
  경우다. 이 문제는 container가 시작하기 전 단계에서 멈춘다. 그래서 `kubectl logs`에는
  아무것도 없다.

공식 문서:
[Secrets — Using Secrets as environment variables](https://kubernetes.io/docs/concepts/configuration/secret/#using-secrets-as-environment-variables) ·
[Distribute Credentials Securely Using Secrets](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/) ·
[Debug Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 2 | `DB_USER`·`DB_PASSWORD`가 `invoice-db`의 실제 key를 `secretKeyRef`로 참조 |
| 1 | Secret `invoice-db` 무변경 (setup 때 저장한 UID·data 지문 비교) |
| 2 | 2개 replica Ready로 rollout 완료 |
| 1 | 실행 중인 container의 환경 변수 값이 Secret 값과 같음 |
