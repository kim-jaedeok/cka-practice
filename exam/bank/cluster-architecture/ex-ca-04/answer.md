# ex-ca-04 정답지 — Issue a client certificate for a new user

## 모범 답안

```bash
cd ~/cka/ex-ca-04
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: dana-csr
spec:
  request: $(base64 -w0 < dana.csr)
  signerName: kubernetes.io/kube-apiserver-client
  usages: ["client auth"]
  expirationSeconds: 86400
EOF
kubectl get csr dana-csr                       # CONDITION: Pending
kubectl certificate approve dana-csr
kubectl get csr dana-csr -o jsonpath='{.status.certificate}' | base64 -d > dana.crt
head -1 dana.crt                               # -----BEGIN CERTIFICATE-----

kubectl -n audit-zone create role log-reader --verb=get,list --resource=pods
kubectl -n audit-zone edit role log-reader
#   rules에 추가: {apiGroups: [""], resources: ["pods/log"], verbs: ["get"]}
kubectl -n audit-zone create rolebinding dana-log-reader --role=log-reader --user=dana

kubectl -n audit-zone auth can-i get pods --subresource=log --as dana   # yes
kubectl -n audit-zone auth can-i delete pods --as dana                  # no
```

선택: 발급된 인증서로 kubeconfig 사용자를 만들어 직접 확인할 수 있다.

```bash
kubectl config set-credentials dana --client-key=dana.key --client-certificate=dana.crt --embed-certs
kubectl config set-context dana --cluster=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}') --user=dana
kubectl --context dana -n audit-zone get pods
```

## 해설

- **`spec.request`**는 PEM 파일 전체를 base64로 한 줄 인코딩한 값이다(`base64 -w0`).
- **signer**: `kubernetes.io/kube-apiserver-client`는 API server 클라이언트 인증용
  인증서를 발급한다. usage는 `client auth`여야 한다.
- **사용자 이름과 group**: API server는 인증서의 CN을 사용자 이름으로, O를 group으로
  쓴다. 그래서 RoleBinding subject는 `kind: User, name: dana`다.
- **`pods/log`**는 별도 subresource다. `pods` 권한만으로는 `kubectl logs`가 거부된다.
- 승인 뒤 controller-manager가 서명해야 `status.certificate`가 채워진다.

공식 문서:
[Certificates and Certificate Signing Requests](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/) ·
[Normal user 인증서 발급 절차](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/#normal-user) ·
[Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---|---|
| 1 | CSR signer·usage·expirationSeconds 일치 |
| 1 | CSR 요청이 제공된 `dana.csr`와 같음 (setup 때 저장한 사본 비교) |
| 2 | Approved 상태이고 인증서 발급됨 |
| 2 | `dana.crt`가 발급된 PEM 인증서와 같음 |
| 2 | `dana`가 `audit-zone`에서 Pod get·list와 log get 가능, Pod delete와 다른 namespace 접근 불가 |
