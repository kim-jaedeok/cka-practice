# ex-sn-01 정답지 — Expose a fixed address through a Service without a selector

## 모범 답안

```bash
kubectl -n legacy-host get pod legacy-app -o jsonpath='{.status.podIP}'   # 예: 192.168.x.y
```

```yaml
apiVersion: v1
kind: Service
metadata: {name: legacy-api, namespace: bridge}
spec:                       # selector가 없다 → EndpointSlice를 controller가 만들지 않는다
  ports:
    - {name: http, port: 8080, protocol: TCP}
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: legacy-api-1
  namespace: bridge
  labels:
    kubernetes.io/service-name: legacy-api   # Service와 연결하는 label
addressType: IPv4
ports:
  - {name: http, port: 80, protocol: TCP}    # name이 Service port name과 같아야 한다
endpoints:
  - addresses: ["192.168.x.y"]
```

```bash
kubectl apply -f legacy.yaml
kubectl -n bridge run probe --image=busybox:1.36 --rm -it --restart=Never -- \
  wget -qO- -T 3 http://legacy-api:8080/          # legacy inventory system v1
```

## 해설

- **selector 없는 Service**: control plane은 EndpointSlice를 만들지 않는다. 사용자가
  직접 만든 EndpointSlice를 `kubernetes.io/service-name` label로 Service에 연결한다.
- **port 연결 규칙**: kube-proxy는 Service port와 EndpointSlice port를 **이름**으로
  짝짓는다. Service port에 이름(`http`)이 있으면 slice port에도 같은 이름이 필요하다.
  이름이 다르거나 없으면 그 Service port에는 backend가 없다.
- **port 번호 변환**: Service port(8080)와 slice port(80)는 달라도 된다. slice port가
  실제 목적지 port다(targetPort 역할).
- v1 `Endpoints` API는 v1.33부터 deprecated다. 새 구성은 EndpointSlice로 만든다.

공식 문서:
[Service — Services without selectors](https://kubernetes.io/docs/concepts/services-networking/service/#services-without-selectors) ·
[EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 1 | Service `legacy-api`: selector 없음, ClusterIP, port `http`/8080/TCP |
| 2 | EndpointSlice `legacy-api-1`: service-name label, IPv4, `legacy-app` IP, port `http`/80 |
| 1 | `legacy-app`가 원래 Pod 그대로 Ready |
| 2 | 상주 채점 Pod에서 `legacy-api.bridge:8080` 응답이 `legacy-app` 내용 |
