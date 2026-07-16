# ca-01 정답지 — Grant namespaced access with Role and RoleBinding

## 모범 답안

명령형(imperative) 커맨드가 가장 빠르다:

```bash
kubectl -n dev-team create role pod-reader \
  --verb=get --verb=list --verb=watch --resource=pods

kubectl -n dev-team create rolebinding app-reader-binding \
  --role=pod-reader --serviceaccount=dev-team:app-reader
```

검증:

```bash
kubectl auth can-i list pods -n dev-team \
  --as system:serviceaccount:dev-team:app-reader        # yes
kubectl auth can-i delete pods -n dev-team \
  --as system:serviceaccount:dev-team:app-reader        # no
```

## 해설 (한국어)

- **RBAC 4형제**: Role(네임스페이스 권한 정의) / ClusterRole(클러스터 권한 정의) /
  RoleBinding(네임스페이스에서 부여) / ClusterRoleBinding(클러스터 전체 부여).
  Role+RoleBinding은 해당 네임스페이스 안에서만 유효하다 — 그래서 다른 ns의
  pods는 볼 수 없다는 요구사항이 자동으로 충족된다.
- ServiceAccount를 subject로 쓸 때 형식은 `--serviceaccount=<namespace>:<name>`.
  YAML에서는 `subjects[].kind: ServiceAccount`, `namespace` 필드 필수.
- **`kubectl auth can-i` + `--as system:serviceaccount:<ns>:<sa>`** 는 RBAC 검증의
  표준 도구다. 시험에서도 이것으로 스스로 확인하는 습관을 들일 것.
- RBAC는 **허용만 정의**한다(deny 규칙 없음). 바인딩이 없으면 기본 거부.
- 공식 문서 참조 경로: **Reference → Access Authn/Authz → RBAC Authorization**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | Role 규칙 (pods, get/list/watch) | jsonpath 비교 |
| 1 | RoleBinding roleRef/subjects | jsonpath 비교 |
| 1 | 실측 can-i list = yes | `kubectl auth can-i` |
| 1 | 실측 can-i delete = no | `kubectl auth can-i` |
| 1 | 실측 타 ns list = no | `kubectl auth can-i` |
