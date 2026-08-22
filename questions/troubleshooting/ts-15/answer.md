# ts-15 정답지 — Service/kube-proxy/CNI 계층 진단

Kubernetes 공식 Service 디버깅 순서에 맞춰 애플리케이션 Pod, Service,
EndpointSlice, kube-proxy, node network를 차례로 확인한다.

## 1. Service와 EndpointSlice

Service selector는 대상 Pod를 결정하며, control plane은 일치하는 Pod로
EndpointSlice를 자동 생성·갱신한다.

```bash
kubectl -n service-chain get pod --show-labels -o wide
kubectl -n service-chain get svc web-service -o yaml
kubectl -n service-chain get endpointslice \
  -l kubernetes.io/service-name=web-service -o wide
kubectl -n service-chain patch svc web-service --type=merge \
  -p '{"spec":{"selector":{"app":"web"}}}'
```

## 2. kube-proxy

```bash
kubectl -n kube-system get pod -l k8s-app=kube-proxy -o wide
kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=30
kubectl -n kube-system edit configmap kube-proxy
# clientConnection.kubeconfig 값을 다음과 같이 복구:
# /var/lib/kube-proxy/kubeconfig.conf

kubectl -n kube-system delete pod -l k8s-app=kube-proxy \
  --field-selector spec.nodeName=cka-worker
kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=120s
```

kube-proxy configuration API에서 `clientConnection.kubeconfig`는 client가
사용할 kubeconfig 파일 경로이다.

## 3. CNI (Container Network Interface)

```bash
ssh cka-worker2
ls -la /etc/cni/net.d
mv -f /etc/cni/net.d/10-calico.conflist.cka-disabled \
  /etc/cni/net.d/10-calico.conflist
exit

kubectl -n service-chain rollout status deploy/cni-probe --timeout=120s
kubectl -n service-chain exec service-client -- \
  wget -qO- -T 3 http://web-service
# service-chain-ok
```

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---:|---|
| 2 | Service selector와 ready EndpointSlice backend 2개 |
| 1 | kube-proxy ConfigMap 원상복구 |
| 1 | kube-proxy 3/3 Ready |
| 1 | worker2 CNI 설정 원상복구 |
| 1 | cni-probe Ready |
| 2 | Service 실측 응답 성공 |

## 공식 문서

- Kubernetes, Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Kubernetes, Service: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes, EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Kubernetes, kube-proxy Configuration API: https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
- Kubernetes, Network Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
