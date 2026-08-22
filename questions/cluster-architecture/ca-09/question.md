Connect with `ssh operator-admin`, then solve this question on the designated
disposable controller cell.

cert-manager is already installed. Work in namespace `operators`.

1. Create a namespaced Issuer named `operator-selfsigned` that uses the
   self-signed issuer type.

2. Create a Certificate named `db-api-tls` with:
   - `secretName: db-api-tls`
   - `commonName: db.operators.svc`
   - exactly one DNS name: `db.operators.svc`
   - duration `24h` and renew-before period `8h`
   - private key algorithm RSA, size 2048
   - usages `digital signature`, `key encipherment`, and `server auth`
   - issuer reference `operator-selfsigned`, kind `Issuer`

3. Wait until the Issuer and Certificate report `Ready=True`. Do not create
   the TLS Secret or CertificateRequest by hand; they must be reconciled by
   cert-manager.
