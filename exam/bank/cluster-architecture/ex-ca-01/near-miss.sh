#!/usr/bin/env bash
# Near-miss fixture: the CRD and the object exist, but the schema has no
# required fields and no bounds, so invalid objects are accepted.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backuppolicies.dataprotection.example.org
spec:
  group: dataprotection.example.org
  scope: Namespaced
  names:
    kind: BackupPolicy
    plural: backuppolicies
    singular: backuppolicy
    shortNames: ["bkp"]
  versions:
    - name: v1
      served: true
      storage: true
      additionalPrinterColumns:
        - name: Schedule
          type: string
          jsonPath: .spec.schedule
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                schedule:
                  type: string
                retentionDays:
                  type: integer
                target:
                  type: string
EOF
kctx wait --for=condition=Established crd/backuppolicies.dataprotection.example.org \
  --timeout=60s >/dev/null

kctx apply -f - >/dev/null <<'EOF'
apiVersion: dataprotection.example.org/v1
kind: BackupPolicy
metadata:
  name: nightly-db
  namespace: backup-ops
spec:
  schedule: "0 2 * * *"
  retentionDays: 14
  target: orders-db
EOF
