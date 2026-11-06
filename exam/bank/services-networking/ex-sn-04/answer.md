# ex-sn-04 정답지 — Keep traffic to a node agent on the local node

## 모범 답안

```yaml
apiVersion: v1
kind: Service
metadata:
  name: stats-agent
  namespace: node-agents
spec:
  selector:
    app: stats-agent
  internalTrafficPolicy: Local
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: metrics
      port: 9100
      targetPort: 9100
```

```bash
kubectl apply -f stats-agent-svc.yaml
kubectl -n node-agents get pods -l app=reporter -o wide
for p in $(kubectl -n node-agents get pods -l app=reporter -o name); do
  kubectl -n node-agents exec "$p" -- sh -c \
    'for i in 1 2 3 4; do wget -qO- http://stats-agent.node-agents.svc.cluster.local/; done'
done
#   reporter on cka-worker  → 항상 "agent on cka-worker"
#   reporter on cka-worker2 → 항상 "agent on cka-worker2"
```

`targetPort`에는 컨테이너 port 이름(`web`, `metrics`)을 써도 된다.

## 해설

- **`internalTrafficPolicy: Local`**은 클러스터 안의 Pod가 Service로 보낸 traffic을 같은 node의
  endpoint로만 보낸다. 같은 node에 endpoint가 없으면 traffic은 버려진다. DaemonSet처럼 node마다
  endpoint가 있는 경우에 맞다.
- **`externalTrafficPolicy`와 다르다.** 그 필드는 NodePort·LoadBalancer로 클러스터 밖에서 들어온
  traffic에만 적용된다.
- **여러 port를 가진 Service**는 각 port에 `name`이 있어야 한다. EndpointSlice와 SRV record가 이
  이름을 쓴다.
- 기본값 `Cluster`에서는 kube-proxy가 모든 node의 endpoint 중 하나를 고르므로 다른 node의 agent가
  답할 수 있다.

공식 문서:
[Service Internal Traffic Policy](https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/) ·
[Service: Multi-port Services](https://kubernetes.io/docs/concepts/services-networking/service/#multi-port-services)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 2 | Service가 ClusterIP이고 `app=stats-agent`를 고르며 `http` 80→8080, `metrics` 9100→9100이다 |
| 1 | `internalTrafficPolicy`가 `Local`이다 |
| 2 | 실측: 각 reporter Pod의 요청 6번이 모두 같은 node의 agent에서 답한다 (port 80) |
| 1 | 실측: 각 reporter Pod가 같은 node의 metrics를 받는다 (port 9100) |
