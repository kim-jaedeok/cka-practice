# ca-09 정답지 — Work with CRDs and custom resources

## 모범 답안

```bash
# 1. CRD 목록 저장
mkdir -p ~/cka/ca-09
kubectl get crd -o name | sed 's|^customresourcedefinition.*/||' > ~/cka/ca-09/crds.txt
# (kubectl get crd --no-headers -o custom-columns=NAME:.metadata.name 도 가능)

# 2. 커스텀 리소스 스펙 문서 저장
kubectl explain backup.spec > ~/cka/ca-09/spec.txt

# 3. 커스텀 리소스 생성
kubectl apply -f - <<'YAML'
apiVersion: stable.example.com/v1
kind: Backup
metadata:
  name: db-backup
  namespace: operators
spec:
  source: /data
  schedule: "0 2 * * *"
YAML
```

## 해설 (한국어)

- **CRD 탐색 3종 세트**: `kubectl get crd`(설치된 CRD 목록),
  `kubectl api-resources | grep <group>`(kind/약어 확인),
  `kubectl explain <kind>.spec`(필드 문서). 오퍼레이터 관련 문제의 출발점이다.
- 커스텀 리소스의 `apiVersion`은 `<group>/<version>` 형식 — CRD의
  `spec.group`(stable.example.com)과 `versions[].name`(v1)을 조합한다.
- `schedule: "0 2 * * *"` 처럼 `*`가 들어가는 값은 **반드시 따옴표**로 감싼다 —
  YAML 파서가 alias로 오해석하는 것을 방지.
- CRD는 API를 확장하는 정의일 뿐이고, 실제 동작(백업 수행)은 **오퍼레이터
  컨트롤러**가 CR을 watch하며 수행한다 — 이 개념 구분(공식 역량: "Understand
  CRDs, install and configure operators")을 물어보는 서술도 출제된다.
- 공식 문서 참조 경로: **Tasks → Extend Kubernetes → Custom Resources**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | crds.txt에 전체 CRD 목록 | 대표 CRD 2종 포함 확인 |
| 1 | spec.txt에 explain 출력 | source/schedule 필드 확인 |
| 1 | CR db-backup 존재 | 리소스 조회 |
| 2 | spec 필드 값 일치 | jsonpath |
