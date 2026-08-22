Connect with `ssh operator-admin`, then solve this question on the designated
disposable controller cell.

The cert-manager Custom Resource Definitions are installed, but its controller,
cainjector and webhook are not. The exact offline v1.21.1 installation manifest
is available at:

`~/cka/ca-13/cert-manager-v1.21.1.yaml`

1. Install that manifest with server-side apply. Do not edit the manifest and do
   not fetch anything from the network.
2. Wait for all three cert-manager Deployments in namespace `cert-manager` to
   become Available.
3. Confirm that the existing `operator-verify/install-proof` Certificate is
   reconciled to Ready and that Secret `install-proof-tls` is produced.

Only the pinned v1.21.1 images are accepted.
