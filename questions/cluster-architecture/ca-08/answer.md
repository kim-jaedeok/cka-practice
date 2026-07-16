# ca-08 정답지 — Deploy with Kustomize overlays

## 모범 답안

```bash
# 1. overlay가 무엇을 바꾸는지 확인 (dry-run 렌더링)
kubectl kustomize ~/cka/ca-08/overlays/prod | less
#   → namespace: kust-prod, 이름 prefix prod-, replicas 3, nginx:1.29

# 2. 적용 (-k 플래그)
kubectl apply -k ~/cka/ca-08/overlays/prod

# 3. 확인
kubectl -n kust-prod get deploy,svc
kubectl -n kust-prod get deploy prod-kapp -o wide   # 3/3, nginx:1.29
```

## 해설 (한국어)

- **Kustomize는 kubectl에 내장**되어 있다: 렌더링만 하려면 `kubectl kustomize <dir>`,
  적용은 `kubectl apply -k <dir>`. 별도 바이너리 설치가 필요 없다.
- **base/overlay 패턴**: base에 공통 매니페스트를 두고, overlay의
  `kustomization.yaml`이 환경별 차이(namespace, namePrefix, replicas, images 등)를
  선언적으로 덮어쓴다. 템플릿 변수 없이 순수 YAML 패치라는 점이 Helm과의 차이.
- overlay가 리소스 이름에 `namePrefix: prod-`를 붙이므로 결과물은 `prod-kapp`이다 —
  적용 후 원래 이름(kapp)으로 찾으면 없다고 당황하지 말 것.
- 적용 전에 `kubectl kustomize`(또는 `kubectl apply -k --dry-run=client -o yaml`)로
  렌더링 결과를 확인하는 습관이 실수를 줄인다.
- 공식 문서 참조 경로: **Tasks → Manage Kubernetes Objects →
  Declarative Management using Kustomize**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | prod-kapp Deployment 존재 (kust-prod) | 리소스 조회 |
| 1 | prod-kapp Service 존재 | 리소스 조회 |
| 1 | 이미지 nginx:1.29 | jsonpath |
| 2 | 3/3 Ready | `.status.readyReplicas` |
