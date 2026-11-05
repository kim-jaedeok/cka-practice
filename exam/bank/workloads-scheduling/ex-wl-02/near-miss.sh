#!/usr/bin/env bash
# Near-miss fixture: the right keys and paths, but the default mode 0644.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n inference patch deploy predictor --type=strategic -p '
spec:
  template:
    spec:
      volumes:
        - name: bundle
          projected:
            sources:
              - configMap:
                  name: model-config
                  items:
                    - {key: model.yaml, path: config/model.yaml}
              - secret:
                  name: model-registry
                  items:
                    - {key: token, path: auth/token}
      containers:
        - name: server
          volumeMounts:
            - name: bundle
              mountPath: /etc/predictor
              readOnly: true
' >/dev/null
wait_deploy inference predictor 180s
