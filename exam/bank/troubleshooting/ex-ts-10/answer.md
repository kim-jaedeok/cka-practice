# ex-ts-10 정답지 — A namespace never finishes deleting

## 진단 과정

```bash
kubectl get namespace tenant-old -o yaml
#   status.conditions:
#     NamespaceContentRemaining:  Some resources are remaining: configmaps has 1 resource instances,
#                                 workqueues.queue.example.io has 1 resource instances
#     NamespaceFinalizersRemaining: Some content in the namespace has finalizers remaining:
#                                 queue.example.io/drain in 2 resource instances
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n 1 kubectl get --show-kind --ignore-not-found -n tenant-old
#   workqueue.queue.example.io/orders-q, configmap/drain-state
kubectl -n tenant-old get workqueue orders-q -o jsonpath='{.metadata.finalizers}'
kubectl -n tenant-old get configmap drain-state -o jsonpath='{.metadata.finalizers}'
#   ["queue.example.io/drain"]
```

두 object에 `queue.example.io/drain` finalizer가 있다. 이 finalizer를 지우던 controller는 이미
없다. 그래서 두 object의 삭제가 끝나지 않고, namespace도 `Terminating`에 머문다.

## 모범 답안

```bash
kubectl -n tenant-old patch workqueue orders-q --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl -n tenant-old patch configmap drain-state --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl get namespace tenant-old              # 잠시 뒤 NotFound
kubectl -n tenant-old get workqueues          # No resources found
kubectl -n tenant-live get workqueue billing-q   # 그대로 있다
```

## 해설

- **finalizer**는 object 삭제 전에 처리해야 할 일이 남았다는 표시다. 삭제 요청을 받은 object는
  `deletionTimestamp`가 붙은 채 남고, finalizer 목록이 비어야 실제로 지워진다.
- **namespace 삭제**는 namespace controller가 안의 object를 모두 지운 뒤 끝난다. 안의 object가
  finalizer 때문에 남으면 namespace도 `Terminating`에 머문다. 원인은 namespace의
  `status.conditions`에 나온다.
- **`/finalize`로 namespace의 `kubernetes` finalizer를 강제로 지우면 안 된다.** namespace는
  사라지지만 안의 object는 저장소에 남는다. 같은 이름의 namespace를 다시 만들면 그 object가 다시
  보인다. 채점은 이 잔여 object를 확인한다.
- CRD를 지우면 모든 namespace의 WorkQueue가 함께 지워진다. 다른 tenant가 쓰므로 지우면 안 된다.

공식 문서:
[Finalizers](https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/) ·
[Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/) ·
[Use Custom Resources](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 2 | namespace `tenant-old`가 없다 |
| 2 | `tenant-old` 이름으로 남은 WorkQueue와 `drain-state` ConfigMap이 없다 |
| 1 | CRD가 setup 때와 같은 object로 남아 있다 |
| 1 | `tenant-live`의 `billing-q`가 finalizer와 함께 그대로 있다 |
