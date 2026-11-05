# ex-sn-03 정답지 — Allow different peers on different ports with one NetworkPolicy

## 모범 답안

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: collector-access, namespace: telemetry}
spec:
  podSelector:
    matchLabels: {app: collector}
  policyTypes: ["Ingress"]
  ingress:
    - from:                                  # rule 1: edge namespace → 8080
        - namespaceSelector:
            matchLabels: {team: edge}
      ports:
        - {protocol: TCP, port: 8080}
    - from:                                  # rule 2: 같은 namespace의 admin Pod → 9090
        - podSelector:
            matchLabels: {role: admin}
      ports:
        - {protocol: TCP, port: 9090}
```

```bash
kubectl apply -f collector-access.yaml
kubectl -n edge-ingest exec shipper -- wget -qO- -T 3 http://collector.telemetry:8080   # 성공
kubectl -n edge-ingest exec shipper -- wget -qO- -T 3 http://collector.telemetry:9090   # timeout
kubectl -n telemetry exec admin-shell -- wget -qO- -T 3 http://collector:9090           # 성공
kubectl -n telemetry exec admin-shell -- wget -qO- -T 3 http://collector:8080           # timeout
```

## 해설

- **rule 하나 안의 `from`과 `ports`는 곱(AND)이다.** `from`의 peer 목록은 OR이고, 그 모든
  peer가 `ports`의 모든 port를 쓸 수 있다. 그래서 두 peer와 두 port를 한 rule에 넣으면
  edge Pod도 9090에, admin Pod도 8080에 접근한다.
- **peer마다 port가 다르면 rule을 나눈다.** `ingress` 목록의 rule들은 OR로 합쳐진다.
- **`podSelector`만 있는 peer**는 policy와 같은 namespace의 Pod만 뜻한다.
  `namespaceSelector`만 있는 peer는 그 namespace의 모든 Pod를 뜻한다.
- policy가 Pod를 하나라도 선택하면, 그 Pod의 ingress는 허용된 트래픽 외에 모두 막힌다.

공식 문서:
[Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) ·
[Behavior of to and from selectors](https://kubernetes.io/docs/concepts/services-networking/network-policies/#behavior-of-to-and-from-selectors)

## 채점 기준 (9점)

| 배점 | 검증 항목 |
|---|---|
| 1 | `collector-access`가 `app=collector`를 Ingress 방향으로 선택 |
| 2 | `edge-ingest/shipper` → 8080 성공 |
| 1 | `edge-ingest/shipper` → 9090 차단 |
| 2 | `telemetry/admin-shell` → 9090 성공 |
| 1 | `telemetry/admin-shell` → 8080 차단 |
| 1 | `telemetry/app-shell` → 두 port 모두 차단 |
| 1 | `edge-other/shipper` → 8080 차단 |
