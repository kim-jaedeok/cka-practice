#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-09
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" operators

kctx apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.stable.example.com
spec:
  group: stable.example.com
  scope: Namespaced
  names:
    plural: backups
    singular: backup
    kind: Backup
    shortNames: [bk]
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                source:
                  type: string
                  description: Filesystem path to back up.
                schedule:
                  type: string
                  description: Backup schedule in cron format.
EOF

# CRD 등록 대기
kctx wait --for=condition=Established crd/backups.stable.example.com --timeout=60s >/dev/null
