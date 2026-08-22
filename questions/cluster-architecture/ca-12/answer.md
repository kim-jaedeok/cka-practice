# ca-12 정답지 — kubeadm init/join

## 핵심 절차

`cp1`에서 제공된 구성을 검증하고 control plane을 초기화합니다.

```bash
kubeadm config validate --config /opt/cka/kubeadm-init.yaml
kubeadm init --config /opt/cka/kubeadm-init.yaml

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
kubectl apply -f /opt/cka/kindnet.yaml
kubeadm token create --print-join-command
```

마지막 명령이 출력한 `kubeadm join ...`을 `worker1`과 `worker2`에서 각각
실행합니다. 그 뒤 문제의 이름·이미지·selector에 맞춰 Deployment, Service와
client Pod를 만들고 다음처럼 실제 경로를 확인합니다.

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl -n bootstrap-check exec network-client -- \
  wget -qO- http://bootstrap-web
```

채점기는 파일 존재만 보지 않습니다. 정확한 3-node 집합, worker kubelet의
TLS (Transport Layer Security) bootstrap 인증서, CNI (Container Network
Interface)와 CoreDNS 수렴, 서로 다른 worker의 Endpoint와 실제 Service HTTP
응답을 함께 확인합니다.

공식 문서:

- kubeadm 클러스터 생성:
  https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- worker join:
  https://v1-35.docs.kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/
