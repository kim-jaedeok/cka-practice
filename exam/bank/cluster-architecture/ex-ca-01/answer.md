# ex-ca-01 정답지 — Define a CustomResourceDefinition with validation

## 모범 답안

```yaml
# crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backuppolicies.dataprotection.example.org   # <plural>.<group>
spec:
  group: dataprotection.example.org
  scope: Namespaced
  names:
    kind: BackupPolicy
    plural: backuppolicies
    singular: backuppolicy
    shortNames: ["bkp"]
  versions:
    - name: v1
      served: true
      storage: true
      additionalPrinterColumns:
        - name: Schedule
          type: string
          jsonPath: .spec.schedule
      schema:
        openAPIV3Schema:
          type: object
          required: ["spec"]
          properties:
            spec:
              type: object
              required: ["schedule"]
              properties:
                schedule: {type: string}
                retentionDays: {type: integer, minimum: 1, maximum: 90}
                target: {type: string}
```

```bash
kubectl apply -f crd.yaml
kubectl wait --for=condition=Established crd/backuppolicies.dataprotection.example.org
cat <<'EOF' | kubectl apply -f -
apiVersion: dataprotection.example.org/v1
kind: BackupPolicy
metadata: {name: nightly-db, namespace: backup-ops}
spec: {schedule: "0 2 * * *", retentionDays: 14, target: orders-db}
EOF
kubectl -n backup-ops get bkp            # SCHEDULE 열이 보인다

# 검증: 둘 다 거부되어야 한다
kubectl -n backup-ops create --dry-run=server -f - <<'EOF'
apiVersion: dataprotection.example.org/v1
kind: BackupPolicy
metadata: {name: bad}
spec: {retentionDays: 120}
EOF
```

## 해설

- **CRD 이름 규칙**: `metadata.name`은 반드시 `<plural>.<group>`이다. 다르면 API server가
  거부한다.
- **structural schema**: `apiextensions.k8s.io/v1`은 schema가 필수다. `required`는 상위
  object에 적고, `minimum`·`maximum`은 integer 필드에 적는다. 위반하면 API server가
  `Invalid value` 오류로 생성을 거부한다.
- **storage version**: version이 여러 개여도 `storage: true`는 정확히 하나여야 한다.
- **printer column**: `kubectl get` 출력의 열을 정한다. `jsonPath`는 `.spec.schedule`처럼
  객체 기준 경로다.

공식 문서:
[Extend the Kubernetes API with CustomResourceDefinitions](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/) ·
[Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---|---|
| 2 | CRD Established, group·kind·plural·singular·short name·scope 일치 |
| 1 | version `v1`만 있고 served·storage |
| 2 | server dry-run으로 schema 검증: 정상 객체 허용, spec 없음·schedule 없음·retentionDays 0/120·문자열 거부 |
| 1 | printer column `Schedule` = `.spec.schedule` |
| 2 | `backup-ops/nightly-db`의 spec 일치 |
