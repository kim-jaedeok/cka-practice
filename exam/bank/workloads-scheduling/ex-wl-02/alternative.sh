#!/usr/bin/env bash
# Alternative fixture: set the mode on each item instead of defaultMode. The
# effective mode of both files is still 0440.
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
                    - {key: model.yaml, path: config/model.yaml, mode: 0440}
              - secret:
                  name: model-registry
                  items:
                    - {key: token, path: auth/token, mode: 0440}
      containers:
        - name: server
          volumeMounts:
            - name: bundle
              mountPath: /etc/predictor
              readOnly: true
' >/dev/null
wait_deploy inference predictor 180s
