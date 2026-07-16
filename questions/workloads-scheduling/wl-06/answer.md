# wl-06 정답지 — ConfigMap, Secret and PriorityClass

## 모범 답안

```bash
# 1. ConfigMap
kubectl -n dept-z create configmap app-config \
  --from-literal=DB_HOST=db.example.com \
  --from-literal=LOG_LEVEL=warn

# 2. Secret
kubectl -n dept-z create secret generic app-secret \
  --from-literal=DB_PASS='S3cretPass!'
```

```yaml
# 3. PriorityClass (cluster-scoped)
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 100000
globalDefault: false
description: "High priority workloads"
---
# 4. Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-app
  namespace: dept-z
spec:
  replicas: 1
  selector:
    matchLabels: {app: config-app}
  template:
    metadata:
      labels: {app: config-app}
    spec:
      priorityClassName: high-priority
      containers:
        - name: app
          image: busybox:1.36
          command: ["sleep", "infinity"]
          envFrom:                          # CM 전체 키를 env로
            - configMapRef:
                name: app-config
          env:                              # Secret 단일 키를 env로
            - name: DB_PASS
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: DB_PASS
```

확인:

```bash
kubectl -n dept-z exec deploy/config-app -- printenv | grep -E "DB_|LOG_"
```

## 해설 (한국어)

- **envFrom vs env.valueFrom**: `envFrom.configMapRef`는 ConfigMap의 **모든 키**를
  환경변수로 노출한다. 특정 키만 골라 쓰려면 `env[].valueFrom.configMapKeyRef/secretKeyRef`.
  문제가 "all keys"라고 하면 envFrom, 특정 키만 지목하면 valueFrom을 쓴다.
- Secret 생성 시 `--from-literal`은 base64 인코딩을 자동으로 처리한다. YAML로 만들 때는
  `data:`(base64) 또는 `stringData:`(평문) 필드를 구분할 것. 특수문자(!)가 있으면
  셸에서 작은따옴표로 감싼다.
- **PriorityClass**는 cluster-scoped이며 `value`가 클수록 우선순위가 높다.
  스케줄러가 자원이 부족할 때 낮은 우선순위 Pod를 선점(preemption)할 수 있게 한다.
  `globalDefault: true`는 클러스터 전체 기본값이 되므로 문제에서 금지하면 반드시 false.
- CM/Secret을 **env로 주입한 경우 값 변경 시 자동 반영되지 않는다** (volume mount는 반영됨).
- 공식 문서 참조 경로: **Concepts → Configuration → ConfigMaps / Secrets**,
  **Concepts → Scheduling → Pod Priority and Preemption**.

## 채점 기준 (8점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | ConfigMap 데이터 2건 | `.data` jsonpath |
| 1 | Secret DB_PASS 값 | base64 디코딩 비교 |
| 2 | PriorityClass value/globalDefault | jsonpath |
| 1 | priorityClassName 지정 | jsonpath |
| 2 | 컨테이너 안 실측 env (CM) | `kubectl exec printenv` |
| 1 | 컨테이너 안 실측 env (Secret) | `kubectl exec printenv` |
