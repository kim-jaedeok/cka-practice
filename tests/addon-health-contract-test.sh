#!/usr/bin/env bash
# Cluster-free contract tests for the read-only addon health predicates.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# These values normally come from versions.lock through lib/common.sh.  Keep
# this fixture focused on addon state interpretation by supplying fixed locks.
CALICO_VERSION=v3.32.1
CALICO_MANIFEST_URL=https://example.invalid/calico.yaml
METRICS_SERVER_VERSION=v0.9.0
INGRESS_NGINX_VERSION=controller-v1.15.1
INGRESS_NGINX_URL=https://example.invalid/ingress-nginx.yaml
INGRESS_NGINX_CONTROLLER_IMAGE=registry.k8s.io/ingress-nginx/controller:v1.15.1@sha256:594ceea76b01c592858f803f9ff4d2cb40542cae2060410b2c95f75907d659e1
CKA_CLUSTER_NAME=cka
CKA_CONTEXT=kind-cka
source "$ROOT/lib/addons.sh"

cka_node_names() {
  printf '%s\n' cka-control-plane cka-worker cka-worker2
}

PASS=0
FAIL=0
DRIFT=healthy
INGRESS_REPAIR_MODE=0
INGRESS_MUTATION_TRACE=""
GATEWAY_CALL_FILE="$(mktemp /tmp/cka-addon-health.gateway.XXXXXX)" || exit 1
SLEEP_CALL_FILE="$(mktemp /tmp/cka-addon-health.sleep.XXXXXX)" || exit 1
trap 'rm -f -- "$GATEWAY_CALL_FILE" "$SLEEP_CALL_FILE"' EXIT
printf '0\n' > "$GATEWAY_CALL_FILE"
printf '0\n' > "$SLEEP_CALL_FILE"

ok_test() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail_test() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
expect_success() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok_test "$label"; else fail_test "$label"; fi
}

emit_deployment_state() { # <component> <healthy-image>
  local component="$1" image="$2"
  local generation=7 observed=7 desired=1 replicas=1 updated=1 ready=1 available=1 unavailable=""
  case "$DRIFT" in
    "$component-generation") observed=6 ;;
    "$component-replicas") replicas=2 ;;
    "$component-updated") updated=0 ;;
    "$component-readiness") ready=0 ;;
    "$component-availability") available=0 ;;
    "$component-unavailable") unavailable=1 ;;
    "$component-image") image=example.invalid/drifted:latest ;;
  esac
  if [ "$component" = ingress ] && [ "$DRIFT" = ingress-adjacent-version ]; then
    image=registry.k8s.io/ingress-nginx/controller:v1.15.10
  elif [ "$component" = ingress ] && [ "$DRIFT" = ingress-malformed-digest ]; then
    image=registry.k8s.io/ingress-nginx/controller:v1.15.1@sha256:abc
  elif [ "$component" = ingress ] && [ "$DRIFT" = ingress-wrong-digest ]; then
    image="registry.k8s.io/ingress-nginx/controller:v1.15.1@sha256:$(printf 'b%.0s' {1..64})"
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$generation" "$observed" "$desired" "$replicas" "$updated" "$ready" \
    "$available" "$unavailable" "$image"
}

emit_calico_daemonset_state() {
  local generation=9 observed=9 desired=3 updated=3 ready=3 misscheduled=0
  local node_image="quay.io/calico/node:$CALICO_VERSION"
  local install_cni_image="quay.io/calico/cni:$CALICO_VERSION"
  local upgrade_ipam_image="quay.io/calico/cni:$CALICO_VERSION"
  local bootstrap_image="quay.io/calico/node:$CALICO_VERSION"
  case "$DRIFT" in
    calico-generation) observed=8 ;;
    calico-readiness) ready=2 ;;
    calico-scope) desired=1; updated=1; ready=1 ;;
    calico-updated) updated=2 ;;
    calico-misscheduled) misscheduled=1 ;;
    calico-image) node_image=quay.io/calico/node:v0.0.0 ;;
    calico-install-cni-image) install_cni_image=quay.io/calico/cni:v0.0.0 ;;
    calico-upgrade-ipam-image) upgrade_ipam_image=quay.io/calico/cni:v0.0.0 ;;
    calico-bootstrap-image) bootstrap_image=quay.io/calico/node:v0.0.0 ;;
  esac
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$generation" "$observed" "$desired" "$updated" "$ready" "$misscheduled" \
    "$node_image" "$install_cni_image" "$upgrade_ipam_image" "$bootstrap_image"
}

emit_gateway_crds() {
  local crd version channel established attempt=0
  case "$DRIFT" in
    gateway-eventual|gateway-persistent)
      attempt="$(increment_counter "$GATEWAY_CALL_FILE")" || return 1
      ;;
  esac
  for crd in "${GATEWAY_API_STANDARD_CRDS[@]}"; do
    if [ "$DRIFT" = gateway-missing-crd ] \
        && [ "$crd" = "${GATEWAY_API_STANDARD_CRDS[0]}" ]; then
      continue
    fi
    version="$GATEWAY_API_VERSION"
    channel=standard
    established=True
    if [ "$DRIFT" = gateway-persistent ] \
        || { [ "$DRIFT" = gateway-eventual ] && [ "$attempt" -lt 3 ]; }; then
      established=False
    fi
    if [ "$crd" = "${GATEWAY_API_STANDARD_CRDS[0]}" ]; then
      case "$DRIFT" in
        gateway-wrong-version) version=v0.0.0 ;;
        gateway-wrong-channel) channel=experimental ;;
        gateway-not-established) established=False ;;
      esac
    fi
    printf '%s|%s|%s|%s\n' "$crd" "$version" "$channel" "$established"
  done
}

increment_counter() { # <file>; increment atomically enough for this serial fixture
  local file="$1" value
  IFS= read -r value < "$file" || return 1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  value=$((value + 1))
  printf '%s\n' "$value" > "$file" || return 1
  printf '%s\n' "$value"
}

reset_wait_counters() {
  printf '0\n' > "$GATEWAY_CALL_FILE" \
    && printf '0\n' > "$SLEEP_CALL_FILE"
}

read_counter() {
  local value
  IFS= read -r value < "$1" || return 1
  printf '%s' "$value"
}

sleep() {
  increment_counter "$SLEEP_CALL_FILE" >/dev/null
}

record_ingress_mutation() {
  INGRESS_MUTATION_TRACE="${INGRESS_MUTATION_TRACE}$1 "
}

# Mock only the read operations issued by addon_ok_* helpers.  Any new or
# misspelled query returns 98, so a healthy-case failure exposes contract drift.
kctx() {
  local call=" $* "
  case "$call" in
    *" get namespace ingress-nginx "*)
      return 0
      ;;
    *" delete job/ingress-nginx-admission-create job/ingress-nginx-admission-patch "*)
      record_ingress_mutation delete-admission-jobs
      ;;
    *" delete secret/ingress-nginx-admission "*)
      record_ingress_mutation delete-admission-secret
      ;;
    *" apply -f $INGRESS_NGINX_URL "*)
      record_ingress_mutation apply-manifest
      if [ "$INGRESS_REPAIR_MODE" -eq 1 ]; then DRIFT=healthy; fi
      ;;
    *" patch deploy ingress-nginx-controller "*)
      record_ingress_mutation patch-deployment
      ;;
    *" patch service ingress-nginx-controller "*)
      record_ingress_mutation patch-service
      ;;
    *" rollout restart deployment/ingress-nginx-controller "*)
      record_ingress_mutation restart-controller
      ;;
    *" rollout status deploy/ingress-nginx-controller "*)
      record_ingress_mutation wait-controller
      ;;
    *" get daemonset calico-node "*)
      emit_calico_daemonset_state
      ;;
    *" get deploy calico-kube-controllers "*)
      emit_deployment_state calico-controller \
        "quay.io/calico/kube-controllers:$CALICO_VERSION"
      ;;
    *" get deploy metrics-server "*)
      emit_deployment_state metrics \
        "registry.k8s.io/metrics-server/metrics-server:$METRICS_SERVER_VERSION"
      ;;
    *" get deployment metrics-server "*)
      [[ "$call" == *'{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}'* ]] \
        || return 98
      if [ "$DRIFT" = metrics-tls-arg ]; then
        printf '%s\n' --secure-port=10250
      else
        printf '%s\n' --secure-port=10250 --kubelet-insecure-tls
      fi
      ;;
    *" get apiservice v1beta1.metrics.k8s.io "*)
      case "$DRIFT" in
        metrics-api-service) printf '%s\n' 'other|metrics-server|True' ;;
        metrics-api-unavailable) printf '%s\n' 'kube-system|metrics-server|False' ;;
        *) printf '%s\n' 'kube-system|metrics-server|True' ;;
      esac
      ;;
    *" get ingressclass nginx "*)
      if [ "$DRIFT" = ingress-controller ]; then
        printf '%s\n' example.invalid/controller
      else
        printf '%s\n' k8s.io/ingress-nginx
      fi
      ;;
    *" get service ingress-nginx-controller "*)
      if [ "$DRIFT" = ingress-service ]; then
        printf '%s\n' LoadBalancer
      else
        printf '%s\n' ClusterIP
      fi
      ;;
    *" get service ingress-nginx-controller-admission "*)
      case "$DRIFT" in
        ingress-admission-service) printf '%s\n' 'LoadBalancer|controller|443|webhook' ;;
        ingress-admission-service-ref) printf '%s\n' 'ClusterIP|other|443|webhook' ;;
        *) printf '%s\n' 'ClusterIP|controller|443|webhook' ;;
      esac
      ;;
    *" get validatingwebhookconfiguration ingress-nginx-admission "*" go-template="*)
      case "$DRIFT" in
        ingress-admission-ca-mismatch) printf '%s\n' Y2E= ;;
        *) printf '%s\n' Y2E= ;;
      esac
      ;;
    *" get validatingwebhookconfiguration ingress-nginx-admission "*)
      case "$DRIFT" in
        ingress-admission-webhook-missing) return 1 ;;
        ingress-admission-webhook-service)
          printf '%s\n' 'ingress-nginx|other|/networking/v1/ingresses|443|Fail|Y2E='
          ;;
        ingress-admission-webhook-policy)
          printf '%s\n' 'ingress-nginx|ingress-nginx-controller-admission|/networking/v1/ingresses|443|Ignore|Y2E='
          ;;
        ingress-admission-webhook-ca)
          printf '%s\n' 'ingress-nginx|ingress-nginx-controller-admission|/networking/v1/ingresses|443|Fail|'
          ;;
        *)
          printf '%s\n' 'ingress-nginx|ingress-nginx-controller-admission|/networking/v1/ingresses|443|Fail|Y2E='
          ;;
      esac
      ;;
    *" get secret ingress-nginx-admission "*" go-template="*)
      case "$DRIFT" in
        ingress-admission-ca-mismatch) printf '%s\n' ZGlmZmVyZW50 ;;
        *) printf '%s\n' Y2E= ;;
      esac
      ;;
    *" get secret ingress-nginx-admission "*)
      case "$DRIFT" in
        ingress-admission-secret-missing) return 1 ;;
        ingress-admission-secret-ca) printf '%s\n' '|Y2VydA==|a2V5' ;;
        ingress-admission-secret-cert) printf '%s\n' 'Y2E=||a2V5' ;;
        ingress-admission-secret-key) printf '%s\n' 'Y2E=|Y2VydA==|' ;;
        *) printf '%s\n' 'Y2E=|Y2VydA==|a2V5' ;;
      esac
      ;;
    *" get deploy ingress-nginx-controller "*)
      emit_deployment_state ingress \
        "$INGRESS_NGINX_CONTROLLER_IMAGE"
      ;;
    *" get deployment ingress-nginx-controller "*" go-template="*)
      if [ "$DRIFT" = ingress-node-selector ]; then
        printf '%s\n' 'false|linux'
      else
        printf '%s\n' 'true|linux'
      fi
      ;;
    *" get deployment ingress-nginx-controller "*)
      if [ "$DRIFT" = ingress-toleration ]; then
        printf '%s\n' 'Equal|NoSchedule'
      else
        printf '%s\n' 'Exists|NoSchedule'
      fi
      ;;
    *" get gatewayclass nginx "*)
      if [ "$DRIFT" = gateway-controller ]; then
        printf '%s\n' example.invalid/controller
      else
        printf '%s\n' example.com/nginx-gateway-controller
      fi
      ;;
    *" get crd "*)
      emit_gateway_crds
      ;;
    *" get validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io "*)
      case "$DRIFT" in
        gateway-missing-policy) return 1 ;;
        gateway-policy-version) printf '%s\n' 'v0.0.0|standard|Fail' ;;
        gateway-policy-channel) printf '%s\n' "$GATEWAY_API_VERSION|experimental|Fail" ;;
        gateway-policy-action) printf '%s\n' "$GATEWAY_API_VERSION|standard|Ignore" ;;
        *) printf '%s\n' "$GATEWAY_API_VERSION|standard|Fail" ;;
      esac
      ;;
    *" get validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io "*)
      case "$DRIFT" in
        gateway-missing-binding) return 1 ;;
        gateway-binding-version)
          printf '%s\n' 'v0.0.0|standard|safe-upgrades.gateway.networking.k8s.io|Deny,'
          ;;
        gateway-binding-channel)
          printf '%s\n' "$GATEWAY_API_VERSION|experimental|safe-upgrades.gateway.networking.k8s.io|Deny,"
          ;;
        gateway-binding-policy-name)
          printf '%s\n' "$GATEWAY_API_VERSION|standard|other.gateway.networking.k8s.io|Deny,"
          ;;
        gateway-binding-actions)
          printf '%s\n' "$GATEWAY_API_VERSION|standard|safe-upgrades.gateway.networking.k8s.io|Warn,"
          ;;
        *)
          printf '%s\n' "$GATEWAY_API_VERSION|standard|safe-upgrades.gateway.networking.k8s.io|Deny,"
          ;;
      esac
      ;;
    *" get deploy grader-client "*)
      emit_deployment_state grader busybox:1.36
      ;;
    *" get deployment grader-client "*)
      [[ "$call" == *'{range .spec.template.spec.containers[0].command[*]}{@}{" "}{end}'* ]] \
        || return 98
      case "$DRIFT" in
        grader-selector) printf '%s\n' 'other|grader-client|client|sleep infinity ' ;;
        grader-template-label) printf '%s\n' 'grader-client|other|client|sleep infinity ' ;;
        grader-container) printf '%s\n' 'grader-client|grader-client|other|sleep infinity ' ;;
        grader-command) printf '%s\n' 'grader-client|grader-client|client|sh -c ' ;;
        *) printf '%s\n' 'grader-client|grader-client|client|sleep infinity ' ;;
      esac
      ;;
    *)
      printf 'unexpected mocked kctx call:%s\n' "$call" >&2
      return 98
      ;;
  esac
}

all_healthy() {
  DRIFT=healthy
  addon_ok_calico \
    && addon_ok_metrics_server \
    && addon_ok_ingress_nginx \
    && addon_ok_gateway_api \
    && addon_ok_grader_client
}

reject_drifts() { # <predicate> <drift>...
  local predicate="$1" drift
  shift
  for drift in "$@"; do
    DRIFT="$drift"
    if "$predicate"; then
      printf '%s unexpectedly accepted %s\n' "$predicate" "$drift" >&2
      DRIFT=healthy
      return 1
    fi
  done
  DRIFT=healthy
}

gateway_wait_eventually_succeeds() {
  local calls sleeps
  reset_wait_counters || return 1
  DRIFT=gateway-eventual
  addon_wait_gateway_api || { DRIFT=healthy; return 1; }
  calls="$(read_counter "$GATEWAY_CALL_FILE")" || return 1
  sleeps="$(read_counter "$SLEEP_CALL_FILE")" || return 1
  DRIFT=healthy
  [ "$calls" -eq 3 ] && [ "$sleeps" -eq 2 ]
}

gateway_wait_persistent_failure_is_bounded() {
  local calls sleeps
  reset_wait_counters || return 1
  DRIFT=gateway-persistent
  if addon_wait_gateway_api; then
    DRIFT=healthy
    return 1
  fi
  calls="$(read_counter "$GATEWAY_CALL_FILE")" || return 1
  sleeps="$(read_counter "$SLEEP_CALL_FILE")" || return 1
  DRIFT=healthy
  [ "$calls" -eq 60 ] && [ "$sleeps" -eq 59 ]
}

ingress_missing_secret_is_recreated_and_controller_restarted() {
  local trace success=0
  DRIFT=ingress-admission-secret-missing
  INGRESS_REPAIR_MODE=1
  INGRESS_MUTATION_TRACE=""
  if addon_install_ingress_nginx && addon_wait_ingress_nginx; then
    trace="$INGRESS_MUTATION_TRACE"
    [ "$trace" = \
      'delete-admission-jobs delete-admission-secret apply-manifest patch-deployment patch-service restart-controller wait-controller ' ] \
      && success=1
  fi
  DRIFT=healthy
  INGRESS_REPAIR_MODE=0
  INGRESS_MUTATION_TRACE=""
  [ "$success" -eq 1 ]
}

ingress_missing_webhook_reruns_patch_job_without_rotating_secret() {
  local trace success=0
  DRIFT=ingress-admission-webhook-missing
  INGRESS_REPAIR_MODE=1
  INGRESS_MUTATION_TRACE=""
  if addon_install_ingress_nginx && addon_wait_ingress_nginx; then
    trace="$INGRESS_MUTATION_TRACE"
    [ "$trace" = \
      'delete-admission-jobs apply-manifest patch-deployment patch-service wait-controller ' ] \
      && success=1
  fi
  DRIFT=healthy
  INGRESS_REPAIR_MODE=0
  INGRESS_MUTATION_TRACE=""
  [ "$success" -eq 1 ]
}

provider_proc_state_contract() {
  local parsed state
  parsed="$(_cloud_provider_kind_parse_proc_stat \
    '123 (cloud) provider kind) T 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22')" \
    || return 1
  [ "$parsed" = 'T|22' ] || return 1
  for state in R S D; do
    _cloud_provider_kind_process_state_healthy "$state" || return 1
  done
  for state in T t X x Z I W P ''; do
    ! _cloud_provider_kind_process_state_healthy "$state" || return 1
  done
}

expect_success 'all strengthened addon predicates accept the healthy fixture' all_healthy
expect_success 'Calico rejects generation, scheduling, readiness, and locked-image drift' \
  reject_drifts addon_ok_calico \
    calico-generation calico-updated calico-readiness calico-scope \
    calico-misscheduled \
    calico-image calico-install-cni-image calico-upgrade-ipam-image \
    calico-bootstrap-image calico-controller-generation \
    calico-controller-readiness calico-controller-image
expect_success 'metrics-server rejects rollout, image, TLS-argument, and APIService drift' \
  reject_drifts addon_ok_metrics_server \
    metrics-generation metrics-replicas metrics-updated metrics-readiness \
    metrics-availability metrics-unavailable metrics-image metrics-tls-arg \
    metrics-api-service metrics-api-unavailable
expect_success 'ingress-nginx rejects controller, admission, scheduling, and rollout drift' \
  reject_drifts addon_ok_ingress_nginx \
    ingress-controller ingress-service ingress-node-selector ingress-toleration \
    ingress-generation ingress-replicas ingress-updated ingress-readiness \
    ingress-availability ingress-unavailable ingress-image ingress-adjacent-version \
    ingress-malformed-digest ingress-wrong-digest ingress-admission-service \
    ingress-admission-service-ref ingress-admission-webhook-missing \
    ingress-admission-webhook-service ingress-admission-webhook-policy \
    ingress-admission-webhook-ca ingress-admission-secret-missing \
    ingress-admission-secret-ca ingress-admission-secret-cert \
    ingress-admission-secret-key ingress-admission-ca-mismatch
expect_success 'ingress-nginx recreates missing admission TLS material and restarts its controller' \
  ingress_missing_secret_is_recreated_and_controller_restarted
expect_success 'ingress-nginx reruns admission jobs without rotating a valid Secret' \
  ingress_missing_webhook_reruns_patch_job_without_rotating_secret
expect_success 'Gateway API rejects controller, incomplete/wrong bundles, and missing admission resources' \
  reject_drifts addon_ok_gateway_api \
    gateway-controller gateway-missing-crd gateway-wrong-version \
    gateway-wrong-channel gateway-not-established gateway-missing-policy \
    gateway-policy-version gateway-policy-channel gateway-policy-action \
    gateway-missing-binding gateway-binding-version gateway-binding-channel \
    gateway-binding-policy-name gateway-binding-actions
expect_success 'Gateway API wait accepts CRDs that become Established' \
  gateway_wait_eventually_succeeds
expect_success 'Gateway API wait bounds persistent readiness failures' \
  gateway_wait_persistent_failure_is_bounded
expect_success 'grader-client rejects rollout, image, selector, pod, container, and command drift' \
  reject_drifts addon_ok_grader_client \
    grader-generation grader-replicas grader-updated grader-readiness \
    grader-availability grader-unavailable grader-image grader-selector \
    grader-template-label grader-container grader-command
expect_success '/proc state parsing rejects stopped, traced, dead, zombie, and unknown provider tasks' \
  provider_proc_state_contract

printf '\naddon health contract: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
