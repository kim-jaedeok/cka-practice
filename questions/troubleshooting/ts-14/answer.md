# ts-14 정답지 — containerd/CRI/CNI 노드 복구

## 진단

CRI (Container Runtime Interface)는 kubelet과 container runtime 사이의
통신 규약이다. Kubernetes 1.26부터 runtime은 CRI v1 API를 지원해야 한다.

```bash
kubectl describe node cka-worker
kubectl -n runtime-check describe pod runtime-probe
ssh cka-worker
systemctl status containerd
journalctl -u containerd -u kubelet --since -15min
crictl info
ls -la /etc/cni/net.d
```

이 랩에서는 `containerd`가 정지·비활성화되어 있고, Calico CNI
(Container Network Interface) 설정이 `.cka-disabled`로 이동되어 있다.
Kubernetes 문서는 container runtime이 CNI plugin을 로드해야 Pod network를
구현할 수 있다고 설명한다.

## 복구

```bash
mv /etc/cni/net.d/10-calico.conflist.cka-disabled \
  /etc/cni/net.d/10-calico.conflist
systemctl enable --now containerd
crictl info
exit

kubectl wait node/cka-worker --for=condition=Ready --timeout=180s
kubectl -n runtime-check wait pod/runtime-probe \
  --for=condition=Ready --timeout=180s
```

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---:|---|
| 2 | containerd active 및 CRI 응답 |
| 1 | containerd enabled |
| 2 | 원래 Calico CNI 설정 복구 |
| 1 | 노드 Ready |
| 2 | runtime-probe Running/Ready |

## 공식 문서

- Kubernetes, Container Runtime Interface: https://kubernetes.io/docs/concepts/containers/cri/
- Kubernetes, Container Runtimes: https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Kubernetes, Network Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- Kubernetes, Debugging Kubernetes nodes with crictl: https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- Kubernetes, Node Status: https://kubernetes.io/docs/reference/node/node-status/
