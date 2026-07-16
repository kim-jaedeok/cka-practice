# ca-02 정답지 — Grant cluster-wide access with ClusterRole

## 모범 답안

```bash
kubectl create clusterrole node-viewer --verb=get --verb=list --resource=nodes

kubectl create clusterrolebinding node-viewer-binding \
  --clusterrole=node-viewer --serviceaccount=dev-team:node-inspector
```

검증:

```bash
kubectl auth can-i list nodes \
  --as system:serviceaccount:dev-team:node-inspector     # yes
kubectl auth can-i delete nodes \
  --as system:serviceaccount:dev-team:node-inspector     # no
```

## 해설 (한국어)

- **nodes는 cluster-scoped 리소스**다 — Role(네임스페이스 한정)로는 권한을 줄 수 없고
  반드시 ClusterRole + ClusterRoleBinding 조합이 필요하다. "어떤 리소스가
  cluster-scoped인가"는 `kubectl api-resources --namespaced=false`로 확인.
- ClusterRole을 **RoleBinding**으로 바인딩하면 특정 네임스페이스 안의 권한만 부여된다
  (공용 권한 템플릿 패턴). cluster-scoped 리소스 접근에는 도움이 안 되므로 구분할 것 —
  시험 단골 함정.
- subject의 SA는 네임스페이스 소속이므로 바인딩에 `dev-team:node-inspector`처럼
  네임스페이스를 명시한다.
- 최소 권한 원칙: 요구된 verbs(get, list)만 부여한다. `--verb=*` 같은 광범위 권한은
  요구사항 위반으로 감점될 수 있다.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | ClusterRole 규칙 (nodes, get/list) | jsonpath 비교 |
| 1 | ClusterRoleBinding 연결 | jsonpath 비교 |
| 1 | 실측 nodes list = yes | `kubectl auth can-i` |
| 1 | 실측 nodes delete = no | `kubectl auth can-i` |
| 1 | 실측 secrets list = no | `kubectl auth can-i` |
