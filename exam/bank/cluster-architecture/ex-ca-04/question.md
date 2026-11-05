Solve this question on: `cka-use-context ex-ca-04`

A new auditor, user `dana`, needs read access to Pod logs in namespace
`audit-zone`. The user's private key and certificate signing request are in
`~/cka/ex-ca-04/dana.key` and `~/cka/ex-ca-04/dana.csr`.

1. Create a Kubernetes CertificateSigningRequest named `dana-csr` from
   `dana.csr` with:
   - signer `kubernetes.io/kube-apiserver-client`
   - usage `client auth`
   - an expiration of `86400` seconds
2. Approve `dana-csr`.
3. Save the issued certificate in PEM format to `~/cka/ex-ca-04/dana.crt`.
4. In namespace `audit-zone`, create a Role `log-reader` that allows `get` and
   `list` on Pods and `get` on Pod logs, and a RoleBinding `dana-log-reader`
   that grants it to the user `dana`. `dana` must not be able to delete Pods.
