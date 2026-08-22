# sn-09 정답지 — 실제 LoadBalancer Service

## 모범 답안

```yaml
apiVersion: v1
kind: Service
metadata:
  name: store-lb
  namespace: lb-shop
spec:
  type: LoadBalancer
  selector:
    app: store
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
```

확인:

```bash
kubectl -n lb-shop get service store-lb
LB_IP=$(kubectl -n lb-shop get service store-lb \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl "http://${LB_IP}:80"
```

## 해설

- Kubernetes의 `LoadBalancer` Service는 외부 로드 밸런서 구현체가 있어야 한다.
  생성된 주소는 비동기로 `.status.loadBalancer.ingress`에 게시된다.
- 이 환경은 kind용 Cloud Provider KIND를 사용한다. 공급자는 `LoadBalancer`
  Service를 감시하고 실제 프록시 컨테이너와 외부 주소를 준비한다.
- 따라서 이 문제는 `spec.type`만 검사하지 않는다. Ready EndpointSlice, 외부 주소,
  외부 주소를 통한 실제 HTTP (Hypertext Transfer Protocol) 응답을 모두 확인한다.

공식 문서:

- [Kubernetes Service와 type: LoadBalancer](https://kubernetes.io/docs/concepts/services-networking/service/#loadbalancer)
- [kind LoadBalancer 가이드](https://kind.sigs.k8s.io/docs/user/loadbalancer/)
- [Cloud Provider KIND 공식 저장소](https://github.com/kubernetes-sigs/cloud-provider-kind)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---:|---|
| 2 | Service 타입·selector·단일 TCP 포트 의미 |
| 1 | Ready EndpointSlice 존재 |
| 2 | 외부 주소 할당 |
| 3 | 외부 주소를 통한 실제 HTTP 응답 |
