# ts-13 정답지 — etcd/API server 정적 Pod 복구

## 진단

API (Application Programming Interface)가 내려가 있으므로 먼저 노드에서
CRI (Container Runtime Interface) 도구로 정적 Pod 상태와 로그를 확인한다.

```bash
ssh cka-control-plane
crictl ps -a --name etcd
crictl ps -a --name kube-apiserver
crictl logs $(crictl ps -a -q --name etcd | head -1) | tail -30
crictl logs $(crictl ps -a -q --name kube-apiserver | head -1) | tail -30
grep -- '--listen-client-urls' /etc/kubernetes/manifests/etcd.yaml
grep -- '--etcd-servers' /etc/kubernetes/manifests/kube-apiserver.yaml
```

`kubeadm`은 control-plane 구성 요소를 `/etc/kubernetes/manifests`의 정적
Pod로 관리하며, 파일 변경을 kubelet이 감지하면 해당 정적 Pod를 재시작한다.

## 복구

```bash
sed -i 's#127.0.0.1:12379#127.0.0.1:2379#' \
  /etc/kubernetes/manifests/etcd.yaml
sed -i 's#127.0.0.1:22379#127.0.0.1:2379#' \
  /etc/kubernetes/manifests/kube-apiserver.yaml

# TLS (Transport Layer Security) client authentication으로 etcd 확인
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint health
exit

kubectl --context kind-cka get --raw=/readyz
kubectl --context kind-cka -n kube-system get pod \
  etcd-cka-control-plane kube-apiserver-cka-control-plane
```

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---:|---|
| 2 | etcd loopback client listener가 2379로 복구됨 |
| 2 | API server의 etcd endpoint가 2379로 복구됨 |
| 2 | TLS를 사용한 etcd endpoint health가 성공함 |
| 2 | 두 정적 Pod와 API `/readyz`가 정상임 |

## 공식 문서

- Kubernetes, Reconfiguring a kubeadm cluster: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-reconfigure/
- Kubernetes, Static Pods: https://kubernetes.io/docs/concepts/workloads/pods/static-pods/
- Kubernetes, Debugging Kubernetes nodes with crictl: https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
