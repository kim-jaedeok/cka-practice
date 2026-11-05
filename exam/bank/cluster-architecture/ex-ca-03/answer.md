# ex-ca-03 정답지 — Repair and apply a Kustomize overlay

## 진단 과정

```bash
cd ~/cka/ex-ca-03
kubectl kustomize overlays/staging
#   error: accumulating resources from '../base': ... overlays/base: no such file or directory
```

경로를 고친 뒤 다시 build하면 오류는 없다. 그러나 결과의 image가 `nginx:1.28`이다.
`images[].name`은 바꿀 image의 이름과 정확히 같아야 한다. `ngnix`는 아무 image와도
일치하지 않으므로 Kustomize는 아무 오류 없이 무시한다.

## 모범 답안

```yaml
# overlays/staging/kustomization.yaml 에서 두 곳을 고친다
resources:
  - ../../base          # overlays/staging 기준 상대 경로
images:
  - name: nginx         # ngnix → nginx
    newTag: "1.29"
```

```bash
kubectl kustomize overlays/staging | grep -E 'image:|stg-catalog-settings'
kubectl apply -k overlays/staging
kubectl -n kz-staging rollout status deploy/stg-catalog
kubectl -n kz-staging exec deploy/stg-catalog -- printenv MODE     # staging
```

## 해설

- **`resources`의 상대 경로**는 그 `kustomization.yaml`이 있는 디렉터리 기준이다.
- **조용한 실패**: `images`, `replicas`, `patches`의 대상 이름이 틀리면 build는 성공하고
  결과만 다르다. apply 전에 `kubectl kustomize`로 결과를 확인한다.
- **configMapGenerator**: 내용 hash를 이름 뒤에 붙인다. 같은 kustomization 안에서 그
  ConfigMap을 이름으로 참조하는 곳(`configMapKeyRef`)도 hash가 붙은 이름으로 바뀐다. 내용이
  바뀌면 이름이 바뀌므로 Deployment가 새로 rollout된다.
- **`labels`(includeSelectors: false)**: metadata label만 추가하고 selector는 바꾸지
  않는다.

공식 문서:
[Declarative Management of Kubernetes Objects Using Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) ·
[kubectl apply](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_apply/)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 1 | Deployment·Service `stg-catalog`가 `part-of=catalog` label 보유 |
| 1 | image `nginx:1.29` |
| 1 | 2개 replica Ready |
| 2 | `MODE`가 hash 붙은 생성 ConfigMap(`MODE=staging`, label 보유)에서 옴 |
| 1 | 실행 중인 container의 `MODE=staging` |
| 1 | Service `stg-catalog`의 ready endpoint |
