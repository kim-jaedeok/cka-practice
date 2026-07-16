# ca-07 정답지 — Install and upgrade a Helm release

## 모범 답안

```bash
# 1. 설치 (values 오버라이드)
helm install webapp-rel ~/cka/ca-07/chart/webapp \
  -n helm-apps --set replicaCount=2

# 2. 업그레이드 (기존 오버라이드 유지 + 이미지 태그 변경)
helm upgrade webapp-rel ~/cka/ca-07/chart/webapp \
  -n helm-apps --set replicaCount=2 --set image.tag=1.29

# 3. 확인
helm -n helm-apps list                    # STATUS deployed, REVISION 2
kubectl -n helm-apps get deploy webapp-rel -o wide   # 2/2, nginx:1.29
```

## 해설 (한국어)

- **helm 기본 동사**: `install`(신규) / `upgrade`(변경) / `rollback`(되돌리기) /
  `uninstall`(제거) / `list` / `history`. CKA에서는 install/upgrade + `--set`
  오버라이드가 핵심이다.
- `helm upgrade`에서 주의: `--set`은 **누적되지 않는다**. 이전 릴리스의 오버라이드를
  유지하려면 다시 지정하거나 `--reuse-values`를 쓴다. 여기서는 replicaCount=2를
  다시 명시했다.
- 값 우선순위: `--set` > `-f values파일` > 차트의 기본 values.yaml.
  `helm get values webapp-rel -n helm-apps`로 현재 적용된 오버라이드를 확인할 수 있다.
- 원격 저장소 차트를 쓰는 경우: `helm repo add <name> <url>` → `helm repo update` →
  `helm install <rel> <name>/<chart>`. 시험에서 저장소가 이미 등록돼 있기도 하니
  `helm repo list`부터 확인.
- 공식 문서는 helm.sh/docs 참조 (시험 중 접근 허용 도메인).

## 채점 기준 (7점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | release deployed 상태 | `helm status` |
| 1 | revision ≥ 2 | `helm list -o json` |
| 2 | 이미지 nginx:1.29 | jsonpath |
| 2 | 2/2 Ready | `.status.readyReplicas` |
