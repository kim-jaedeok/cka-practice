# ex-ca-06 정답지 — Recover a Helm release and move it to a new chart version

## 진단 과정

```bash
helm -n ops-dash history board
#   REVISION  STATUS      CHART               DESCRIPTION
#   1         superseded  status-board-0.1.0  Install complete
#   2         deployed    status-board-0.1.0  Upgrade complete
helm -n ops-dash get values board --revision 2      # image.tag: 1.99-hotfix
kubectl -n ops-dash get pods                        # 새 Pod가 ErrImagePull/ImagePullBackOff
```

마지막으로 동작한 revision은 1이다.

## 모범 답안

```bash
helm -n ops-dash rollback board 1
helm -n ops-dash history board                      # 3  deployed  Rollback to 1

cd ~/cka/ex-ca-06
helm -n ops-dash upgrade board ./status-board-0.2.0 -f prod-values.yaml --set image.tag=1.29
helm -n ops-dash history board                      # 4  deployed  status-board-0.2.0
kubectl -n ops-dash rollout status deploy/board
kubectl -n ops-dash get deploy board -o wide         # 2/2, nginx:1.29
kubectl -n ops-dash get configmap board-banner -o jsonpath='{.data.banner}'   # Ops Board
```

## 해설

- **`helm rollback <release> <revision>`**은 그 revision의 manifest와 values로 새 revision을 만든다.
  history에는 `Rollback to 1`이라는 설명이 남는다. 이전 revision을 지우지 않는다.
- **uninstall 뒤 다시 install하면 안 된다.** release history가 사라지고 revision 1부터 다시
  시작한다. 채점은 history의 revision 1이 남아 있는지 본다.
- **values 우선순위**: chart의 `values.yaml` < `-f` 파일 < `--set`. 그래서 `image.tag`는
  `--set` 값 `1.29`가 된다. `replicaCount`와 `banner`는 `prod-values.yaml` 값이다.
- `helm upgrade`는 기본으로 이전 revision의 사용자 values를 이어받지 않는다(`--reuse-values` 없음).
  그래서 revision 2의 잘못된 tag가 다시 들어오지 않는다.

공식 문서:
[helm rollback](https://helm.sh/docs/helm/helm_rollback/) ·
[helm upgrade](https://helm.sh/docs/helm/helm_upgrade/) ·
[helm history](https://helm.sh/docs/helm/helm_history/) ·
[Values Files](https://helm.sh/docs/chart_template_guide/values_files/)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---|---|
| 2 | release history에 `Rollback to 1` revision이 있다 |
| 1 | revision 1(chart 0.1.0)이 history에 남아 있다 (uninstall 없음) |
| 2 | rollback 뒤 마지막 revision이 chart `status-board` 0.2.0이고 `deployed`다 |
| 2 | Deployment `board`가 `nginx:1.29`로 Ready 2개다 |
| 1 | ConfigMap `board-banner`의 `banner`가 `Ops Board`다 |
