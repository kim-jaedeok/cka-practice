# ex-sn-05 정답지 — Serve a site over HTTPS with a provided certificate

## 모범 답안

```bash
cd ~/cka/ex-sn-05
kubectl -n secure-vault create secret tls vault-tls --cert=vault.crt --key=vault.key
kubectl -n secure-vault get secret vault-tls      # TYPE kubernetes.io/tls
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault
  namespace: secure-vault
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - vault.secure.test
      secretName: vault-tls
  rules:
    - host: vault.secure.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vault-ui
                port:
                  number: 80
```

`kubectl -n secure-vault create ingress vault --class=nginx
--rule="vault.secure.test/*=vault-ui:80,tls=vault-tls"`로도 같은 Ingress를 만들 수 있다.

확인: controller로 port-forward한 뒤 작업 host에서 SNI 이름을 넣어 요청한다.

```bash
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8443:443 &
curl -vk --resolve vault.secure.test:8443:127.0.0.1 https://vault.secure.test:8443/
#   subject: CN=vault.secure.test; O=secure-vault   ← 제공된 인증서
#   vault-ui-ok
```

## 해설

- **TLS Secret**은 type `kubernetes.io/tls`이고 `tls.crt`, `tls.key` 두 key를 가진다.
  `kubectl create secret tls`가 이 형식을 만든다.
- **Ingress `tls`**의 `hosts`는 rule의 host와 같아야 한다. controller는 TLS handshake의 SNI 이름으로
  어떤 인증서를 쓸지 고른다. `tls` 항목이 없으면 ingress-nginx는 자체 기본 인증서
  (`Kubernetes Ingress Controller Fake Certificate`)를 보인다.
- Secret은 Ingress와 같은 namespace에 있어야 한다.
- ingress-nginx는 TLS host에 대한 HTTP 요청을 기본으로 HTTPS로 redirect(308)한다.

공식 문서:
[Ingress: TLS](https://kubernetes.io/docs/concepts/services-networking/ingress/#tls) ·
[Secrets: TLS Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets) ·
[ingress-nginx: TLS/HTTPS](https://kubernetes.github.io/ingress-nginx/user-guide/tls/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 2 | Secret `vault-tls`가 `kubernetes.io/tls` type이고 제공된 인증서를 담는다 |
| 1 | Ingress `vault`(class nginx)가 `vault.secure.test` `/` Prefix를 `vault-ui:80`으로 보낸다 |
| 1 | Ingress `vault`의 tls가 `vault.secure.test`와 `vault-tls`를 쓴다 |
| 2 | 실측: SNI `vault.secure.test`로 HTTPS 요청하면 제공된 인증서가 보이고 `vault-ui`가 답한다 |
