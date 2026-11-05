# ex-ca-02 정답지 — Allow a ServiceAccount to scale one Deployment only

## 모범 답안

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: frontend-scaler, namespace: rollouts}
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale"]      # subresource는 "<resource>/<subresource>"
    resourceNames: ["frontend"]
    verbs: ["get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: scaler-bot-frontend-scaler, namespace: rollouts}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: frontend-scaler}
subjects:
  - {kind: ServiceAccount, name: scaler-bot, namespace: rollouts}
```

```bash
kubectl apply -f rbac.yaml
SA=system:serviceaccount:rollouts:scaler-bot
kubectl -n rollouts auth can-i patch deployments/frontend --subresource=scale --as $SA  # yes
kubectl -n rollouts auth can-i patch deployments/backend  --subresource=scale --as $SA  # no
kubectl -n rollouts auth can-i patch deployments/frontend --as $SA                      # no
kubectl -n rollouts scale deploy frontend --replicas=3 --as $SA
```

## 해설

- **subresource 권한은 따로 준다.** `deployments` 권한은 `deployments/scale`을 포함하지
  않는다. 반대로 `deployments/scale`만 주면 Deployment 본문은 바꿀 수 없다.
- **resourceNames**: 특정 이름의 객체로 권한을 좁힌다. `list`·`watch`·`create`처럼 이름이
  정해지지 않은 요청에는 적용되지 않으므로 그 규칙은 따로 둔다.
- `kubectl scale`은 scale subresource로 요청한다. 그래서 `--as`로 실행해도 위 Role로
  충분하다.

공식 문서:
[Using RBAC Authorization — Referring to resources](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#referring-to-resources) ·
[kubectl auth can-i](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/) ·
[User impersonation](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#user-impersonation)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 1 | RoleBinding이 Role `frontend-scaler`를 ServiceAccount `scaler-bot`에 연결 |
| 1 | Deployment get·list·watch 허용 |
| 2 | `frontend`의 `deployments/scale` get·update·patch 허용 |
| 2 | `backend` scale, Deployment update·patch·delete 거부 |
| 1 | `frontend` 3개, `backend` 1개 replica Ready |
