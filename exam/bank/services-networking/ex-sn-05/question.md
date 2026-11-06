Solve this question on: `cka-use-context ex-sn-05`

In namespace `secure-vault` the Service `vault-ui` (port `80`) serves a web
interface. It must be published through the cluster's ingress-nginx controller
(IngressClass `nginx`) at `https://vault.secure.test/`.

The security team issued a certificate for this host. The certificate and its
private key are `~/cka/ex-sn-05/vault.crt` and `~/cka/ex-sn-05/vault.key`.

1. In namespace `secure-vault`, create a TLS Secret named `vault-tls` from
   these two files.
2. In namespace `secure-vault`, create an Ingress named `vault` with the
   IngressClass `nginx` that:
   - routes host `vault.secure.test`, path `/` (path type `Prefix`) to the
     Service `vault-ui` on port `80`
   - terminates TLS for `vault.secure.test` with the Secret `vault-tls`
3. An HTTPS request for `vault.secure.test` must be answered by `vault-ui`, and
   the controller must present the provided certificate.

The controller is exposed by the Service `ingress-nginx-controller` in
namespace `ingress-nginx` (HTTPS on port `443`).
