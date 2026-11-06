# ex-ca-08 정답지 — Prepare a time-limited join command for new workers

## 모범 답안

```bash
kubectl debug node/cka-control-plane -it --image=busybox:1.36 -- chroot /host bash
# node 안에서
kubeadm token create --ttl 3h --description "rack-b expansion" --print-join-command
#   kubeadm join cka-control-plane:6443 --token <id>.<secret> \
#     --discovery-token-ca-cert-hash sha256:<64자리 hex>
kubeadm token list                       # TTL 2h59m, DESCRIPTION rack-b expansion
exit

# 작업 host로 돌아와서, 출력된 한 줄을 그대로 저장한다
echo 'kubeadm join cka-control-plane:6443 --token <id>.<secret> --discovery-token-ca-cert-hash sha256:<hash>' \
  > ~/cka/ex-ca-08/join-worker.sh
```

다른 정답: kubectl로 `kube-system`에 `bootstrap.kubernetes.io/token` type Secret
`bootstrap-token-<id>`를 직접 만든다(`token-id`, `token-secret`, `expiration`, `description`,
`usage-bootstrap-authentication: "true"`, `usage-bootstrap-signing: "true"`,
`auth-extra-groups: system:bootstrappers:kubeadm:default-node-token`). CA hash는 control plane에서
계산한다.

```bash
openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt \
  | openssl pkey -pubin -outform der | sha256sum
```

## 해설

- **bootstrap token**은 `kube-system`의 `bootstrap-token-<token-id>` Secret이다. 형식은
  `[a-z0-9]{6}.[a-z0-9]{16}`이고, `expiration`이 지나면 controller-manager의 TokenCleaner가 지운다.
- `--ttl`을 주지 않으면 기본값 24시간이 적용된다.
- **`--discovery-token-ca-cert-hash`**는 cluster CA 공개키(SubjectPublicKeyInfo)의 SHA-256이다.
  새 node는 이 값으로 `kube-public/cluster-info`에서 받은 CA가 진짜인지 확인한다.
- **usage**: `authentication`은 token으로 API에 인증하는 권한이고, `signing`은 `cluster-info`
  ConfigMap 서명에 쓰인다. join에는 둘 다 필요하다. kubeadm 기본값이 이 둘이다.
- control-plane node를 추가할 때는 `--control-plane`과 `--certificate-key`가 더 필요하다. 이
  문제는 worker용이다.

공식 문서:
[kubeadm token](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/) ·
[kubeadm join: token-based discovery with CA pinning](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/#token-based-discovery-with-ca-pinning) ·
[Authenticating with Bootstrap Tokens](https://kubernetes.io/docs/reference/access-authn-authz/bootstrap-tokens/)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---|---|
| 1 | description이 `rack-b expansion`인 유효한 bootstrap token이 하나 있다 |
| 2 | token 수명(expiration − 생성 시각)이 3시간(±5분)이다 |
| 1 | authentication·signing usage와 `system:bootstrappers:kubeadm:default-node-token` group이 있다 |
| 2 | `join-worker.sh`가 그 token을 쓰는 `kubeadm join` 한 줄이다 (endpoint는 control plane 6443) |
| 1 | `--discovery-token-ca-cert-hash`가 cluster CA 공개키 hash와 같다 |
| 1 | setup 전에 있던 bootstrap token이 그대로 있다 |
