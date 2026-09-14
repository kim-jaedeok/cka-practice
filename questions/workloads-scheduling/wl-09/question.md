Solve this question on: `kubectl config use-context kind-cka`

In namespace `file-config`, Deployment `config-web` and Secret `web-config`
already exist. The Secret key `server.conf` contains a complete nginx
configuration that listens on port 8080 and returns `secret-file-ready`.

Modify Deployment `config-web` in place:

1. Mount Secret `web-config` as a Secret volume in container `web`, at
   `/etc/app`, with `readOnly: true`. Its `server.conf` key must be available
   as `/etc/app/server.conf`. The volume name is your choice.
2. Keep image `nginx:1.29` and one replica. Set `command` and/or `args` so
   that the container runs this exact command:
   `nginx -c /etc/app/server.conf -g 'daemon off;'`.
3. Ensure the Deployment rolls out successfully. The existing Service
   `config-web` must return `secret-file-ready` on port 8080.

Do not change the Secret data or the Service. Do not copy the configuration
into an image or an `emptyDir`; the application must read the Secret volume.
No certificate issuance or client trust configuration is required.

The nginx configuration is supplied; you do not need to write nginx syntax.
