# ts-10 정답지 — Application gets RBAC Forbidden errors

## 진단 과정

```bash
# 에러 메시지 해부:
#   User "system:serviceaccount:ci-cd:deployer"   ← 누가
#   cannot list resource "deployments"            ← 무엇을
#   in API group "apps"                           ← 어느 그룹
#   in the namespace "ci-cd"                      ← 어디서

# 현재 권한 확인
kubectl -n ci-cd get role deployer-role -o yaml
#   rules: apiGroups [""], resources [pods]   ← deployments가 아니라 pods!

kubectl auth can-i list deployments -n ci-cd \
  --as system:serviceaccount:ci-cd:deployer      # no
```

## 모범 답안

```bash
kubectl -n ci-cd edit role deployer-role
```

```yaml
rules:
  - apiGroups: ["apps"]          # deployments는 apps 그룹
    resources: ["deployments"]
    verbs: ["get", "list", "update"]
```

검증:

```bash
kubectl auth can-i list deployments -n ci-cd \
  --as system:serviceaccount:ci-cd:deployer      # yes
kubectl auth can-i delete deployments -n ci-cd \
  --as system:serviceaccount:ci-cd:deployer      # no
```

## 해설 (한국어)

- **Forbidden 에러 메시지는 답을 다 알려준다**: 주체(SA), 동사(list), 리소스
  (deployments), API 그룹(apps), 네임스페이스까지 — 그대로 Role 규칙으로 옮기면 된다.
- **apiGroups 함정**: pods/services/configmaps는 core 그룹(`""`),
  deployments/replicasets/statefulsets는 `apps`, ingress는 `networking.k8s.io`.
  리소스의 그룹은 `kubectl api-resources | grep <resource>`로 확인.
- Role은 RoleBinding과 달리 **수정 가능**하다 (roleRef만 불변). edit/apply로 고친다.
- 요구사항에 없는 delete를 추가하면 "must NOT be able to delete" 조건 위반으로
  감점 — 최소 권한 원칙.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | Role 규칙 수정 | jsonpath |
| 2 | 실측 list/update = yes | `kubectl auth can-i` |
| 2 | 실측 delete = no | `kubectl auth can-i` |
