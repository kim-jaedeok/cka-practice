# sn-13 정답지 — Give StatefulSet Pods stable DNS names with a headless Service

## 모범 답안

```yaml
apiVersion: v1
kind: Service
metadata:
  name: workers
  namespace: training
spec:
  clusterIP: None          # headless
  selector: {app: worker}
  ports:
    - port: 80
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: worker
  namespace: training
spec:
  serviceName: workers     # governing Service
  replicas: 2
  selector:
    matchLabels: {app: worker}
  template:
    metadata:
      labels: {app: worker}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
```

```bash
kubectl apply -f workers.yaml
kubectl -n training rollout status statefulset/worker
echo worker-1.workers.training.svc.cluster.local > ~/cka/sn-13/worker-1-fqdn.txt

# 확인
kubectl -n training run tmp --image=busybox:1.36 --rm -it --restart=Never \
  -- nslookup worker-1.workers.training.svc.cluster.local
kubectl -n training run tmp --image=busybox:1.36 --rm -it --restart=Never \
  -- nslookup workers.training.svc.cluster.local      # Pod IP 2개
```

## 해설 (한국어)

- **headless Service**는 `clusterIP: None`인 Service다. Service 이름을 조회하면 가상 IP
  하나가 아니라 선택된 Pod들의 IP 목록이 돌아온다.
- StatefulSet의 Pod는 `spec.serviceName`이 가리키는 Service를 subdomain으로 쓴다. 공식 문서는
  같은 이름의 headless Service가 있을 때 `<pod>.<service>.<namespace>.svc.cluster.local`
  형식의 record가 생긴다고 설명한다. Pod가 다시 만들어져 IP가 바뀌어도 이름은 그대로다.
- 이 저장소의 v1.37 클러스터에서는 일반 ClusterIP Service를 써도 `worker-1.workers...` 이름이
  풀렸다(2026-11-04 관찰). 그러나 이 동작은 공식 문서가 보장하는 범위가 아니다. 그리고 일반
  Service의 이름(`workers.training...`)은 Pod IP 목록이 아니라 가상 IP 하나로 풀린다. 그래서
  worker 목록을 DNS로 찾는 분산 job에는 headless Service가 필요하다.
- **GPU 인프라와의 관계**: 여러 node에 걸친 분산 학습 job은 worker끼리 서로의 주소를 알아야
  한다. headless Service와 StatefulSet의 고정 이름이 이 주소를 찾는 기초가 된다.

공식 문서:
[DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/) ·
[StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/) ·
[Headless Services](https://kubernetes.io/docs/concepts/services-networking/service/#headless-services)

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | headless Service `workers`가 `app=worker`, port 80을 선택 | jsonpath 비교 |
| 2 | StatefulSet이 `workers`를 쓰고 2개 Pod가 Ready | jsonpath 비교 |
| 1 | `worker-1`의 Pod DNS 이름이 실제로 풀림 | 상주 채점 Pod의 nslookup |
| 1 | 제출 파일에 FQDN 저장 | 파일 내용 비교 (끝의 `.`은 허용) |
