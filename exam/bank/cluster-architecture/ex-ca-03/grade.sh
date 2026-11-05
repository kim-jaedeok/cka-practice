#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ca-03

EXCA03_LABEL='{.metadata.labels.app\.kubernetes\.io/part-of}'

exca03_objects_labelled() {
  jp_eq deploy stg-catalog kz-staging "$EXCA03_LABEL" catalog && \
  jp_eq svc stg-catalog kz-staging "$EXCA03_LABEL" catalog
}

# MODE comes from a configMapKeyRef to a hash-suffixed generated ConfigMap that
# exists, holds MODE=staging and carries the part-of label.
exca03_generated_configmap() {
  local name
  name="$(_jp_get deploy stg-catalog kz-staging \
    '{.spec.template.spec.containers[0].env[?(@.name=="MODE")].valueFrom.configMapKeyRef.name}')" \
    || return 1
  [[ "$name" =~ ^stg-catalog-settings-[a-z0-9]{10}$ ]] || return 1
  jp_eq deploy stg-catalog kz-staging \
    '{.spec.template.spec.containers[0].env[?(@.name=="MODE")].valueFrom.configMapKeyRef.key}' MODE && \
  jp_eq configmap "$name" kz-staging '{.data.MODE}' staging && \
  jp_eq configmap "$name" kz-staging "$EXCA03_LABEL" catalog
}

exca03_live_env() {
  local pod
  pod="$(kctx -n kz-staging get pods -l app=catalog --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || return 1
  [ -n "$pod" ] || return 1
  [ "$(kctx -n kz-staging exec "$pod" -- printenv MODE 2>/dev/null)" = staging ]
}

criterion 1 "Deployment and Service stg-catalog exist with label part-of=catalog" \
  "exca03_objects_labelled"

criterion 1 "stg-catalog runs image nginx:1.29" \
  "jp_eq deploy stg-catalog kz-staging '{.spec.template.spec.containers[0].image}' nginx:1.29"

criterion 1 "stg-catalog has 2 Ready replicas" \
  "deploy_ready kz-staging stg-catalog 2"

criterion 2 "MODE comes from the generated, labelled ConfigMap stg-catalog-settings-<hash>" \
  "exca03_generated_configmap"

criterion 1 "실측: a running container sees MODE=staging" \
  "exca03_live_env"

criterion 1 "Service stg-catalog has ready endpoints" \
  "svc_has_endpoints kz-staging stg-catalog"

grade_finish
