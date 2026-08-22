# ca-11 정답지 — stacked-etcd HA control plane 확장

`cp1`에서 인증서를 다시 업로드하고 join 정보를 만듭니다. 출력되는 64자리
certificate key는 민감 정보이므로 답안이나 공유 로그에 남기지 않습니다.

```bash
kubeadm init phase upload-certs --upload-certs
kubeadm token create --print-join-command
```

두 출력을 합쳐 `cp2`, 이후 `cp3`에서 순서대로 실행합니다.

```bash
kubeadm join <load-balancer>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key>
```

각 join 뒤 `cp1`에서 해당 Node가 Ready인지 확인합니다. 두 노드가 합류하면
기존 workload를 건드리지 않고 완료 ConfigMap을 생성합니다.

```bash
kubectl get nodes
kubectl -n ha-survival create configmap ha-proof \
  --from-literal=completed=true
```

채점기는 control-plane Pod 수만 세지 않습니다. 실제 etcd member list와 각
local endpoint health, 고정 load balancer endpoint, 기존 CA (Certificate
Authority)·Node·Deployment UID, Service 응답을 결합해 확인합니다. 별도의 active
contract가 `cp1`을 중지한 동안 API 쓰기와 workload 요청이 계속되는지도 시험합니다.

kubeadm 공식 HA (High Availability) 절차는 load balancer의 주소를
`controlPlaneEndpoint`로 사용하고, 추가 control plane을
`--control-plane --certificate-key`로 join하도록 규정합니다. 업로드된 인증서와
복호화 키는 민감하며 기본 업로드 Secret은 2시간 후 만료됩니다.

공식 문서:

- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- https://v1-35.docs.kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/
