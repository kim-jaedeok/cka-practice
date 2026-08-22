#!/usr/bin/env bash
# Cluster-free contracts for offline controller labs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/controllers.sh"

PASS=0; FAIL=0
check() {
  local description="$1"; shift
  if "$@"; then
    printf 'ok - %s\n' "$description"; PASS=$((PASS+1))
  else
    printf 'not ok - %s\n' "$description"; FAIL=$((FAIL+1))
  fi
}

contract_exact_release_lock() {
  [ "$CERT_MANAGER_VERSION" = v1.21.1 ] \
    && [ "$CONTROLLER_GATEWAY_API_VERSION" = v1.6.1 ] \
    && [ "$ENVOY_GATEWAY_VERSION" = v1.9.0 ] \
    && [ "$ENVOY_PROXY_IMAGE" = docker.io/envoyproxy/envoy:distroless-v1.39.0 ] \
    && [ "$GATEWAY_BACKEND_IMAGE" = docker.io/library/nginx:1.29 ] \
    && [ "$GATEWAY_PROBE_IMAGE" = docker.io/library/busybox:1.36 ] \
    && [[ "$CERT_MANAGER_CONTROLLER_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [[ "$ENVOY_GATEWAY_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [[ "$GATEWAY_BACKEND_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [[ "$GATEWAY_PROBE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
}

contract_image_config_ids_are_locked_and_verified() {
  local value runtime="$ROOT/lib/controllers.sh" cache
  cache="$ROOT/cluster/controllers/cache-assets.sh"
  for value in \
    "$CERT_MANAGER_CONTROLLER_IMAGE_ID" "$CERT_MANAGER_WEBHOOK_IMAGE_ID" \
    "$CERT_MANAGER_CAINJECTOR_IMAGE_ID" "$ENVOY_GATEWAY_IMAGE_ID" \
    "$ENVOY_PROXY_IMAGE_ID" "$ENVOY_RATELIMIT_IMAGE_ID" \
    "$GATEWAY_BACKEND_IMAGE_ID" "$GATEWAY_PROBE_IMAGE_ID"; do
    [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  done
  grep -Fq 'controller_docker_image_id_matches' "$runtime" \
    && grep -Fq 'controller_node_image_id_matches' "$runtime" \
    && grep -Fq 'controller_node_publish_pinned_ref' "$runtime" \
    && grep -Fq 'kind load image-archive' "$runtime" \
    && grep -Fq 'ctr --namespace=k8s.io images list' "$runtime" \
    && grep -Fq 'ctr --namespace=k8s.io content get' "$runtime" \
    && grep -Fq 'ctr --namespace=k8s.io images tag --local --force' "$runtime" \
    && grep -Fq 'crictl inspecti "$expected_repo_digest"' "$runtime" \
    && grep -Fq 'repoDigests' "$runtime" \
    && grep -Fq 'verify-oci-archive.py' "$runtime" \
    && grep -Fq 'locked config digest mismatch' "$cache" \
    && grep -Fq 'verify_file(path, child_digest, child_size, "image blob")' "$cache" \
    && [ "$(grep -Ec '^  "\$(CERT_MANAGER_(CONTROLLER|WEBHOOK|CAINJECTOR)|ENVOY_(GATEWAY|PROXY|RATELIMIT))_IMAGE_ID"' "$cache")" -eq 6 ]
}

contract_runtime_has_no_network_fetch() {
  ! grep -Eq '(^|[[:space:]])(curl|wget)[[:space:]]|https?://' "$ROOT/lib/controllers.sh" \
    && grep -Fq 'controller_manifest_verify' "$ROOT/lib/controllers.sh" \
    && grep -Fq 'kind load image-archive' "$ROOT/lib/controllers.sh" \
    && ! grep -Eq 'docker[[:space:]]+load' "$ROOT/lib/controllers.sh"
}

contract_preload_bypass_is_closed() {
  local runtime="$ROOT/lib/controllers.sh"
  grep -Fq '[ "${CKA_CONTROLLER_IMAGE_PRELOAD:-kind}" = kind ]' "$runtime" \
    && grep -Fq 'controller image preload cannot be disabled' "$runtime" \
    && ! grep -Eq 'CKA_CONTROLLER_IMAGE_PRELOAD.*(skip|none|disable)' "$runtime"
}

contract_controller_preload_is_process_bounded() {
  local runtime="$ROOT/lib/controllers.sh" body guard_line load_line
  body="$(sed -n '/^controller_bundle_load_into_cell()/,/^}/p' "$runtime")" \
    || return 1
  guard_line="$(grep -n 'controller_require_disposable_cell' <<<"$body" \
    | head -1 | cut -d: -f1)" || return 1
  load_line="$(grep -n 'controller_external_timeout 300s kind load image-archive' \
    <<<"$body" | head -1 | cut -d: -f1)" || return 1
  grep -Fq 'controller_external_timeout() { timeout --foreground --kill-after=5s "$@"; }' \
      "$runtime" \
    && grep -Fq 'controller_docker exec' "$runtime" \
    && grep -Fq 'controller_external_timeout 300s kind load image-archive' "$runtime" \
    && grep -Fq 'controller image archive import failed or exceeded 300s' "$runtime" \
    && ! grep -Eq '^[[:space:]]+docker exec' "$runtime" \
    && [ "$guard_line" -lt "$load_line" ]
}

contract_archives_are_verified_from_the_lock() {
  local runtime="$ROOT/lib/controllers.sh"
  grep -Fq 'controller_bundle_verify "$CERT_MANAGER_IMAGES_BUNDLE"' "$runtime" \
    && grep -Fq 'controller_bundle_verify "$ENVOY_GATEWAY_IMAGES_BUNDLE"' "$runtime" \
    && grep -Fq 'controller_bundle_verify "$GATEWAY_WORKLOAD_BUNDLE"' "$runtime" \
    && grep -Fq 'GATEWAY_WORKLOAD_ATTACHMENT_DIGESTS' "$runtime" \
    && grep -Fq 'unreferenced archive members' \
      "$ROOT/cluster/controllers/verify-oci-archive.py" \
    && grep -Fq 'unexpected or duplicate OCI image' \
      "$ROOT/cluster/controllers/verify-oci-archive.py"
}

contract_node_identity_publishes_and_requires_canonical_digest() (
  local image="$CERT_MANAGER_CONTROLLER_IMAGE"
  local expected_manifest="$CERT_MANAGER_CONTROLLER_DIGEST"
  local expected_config="$CERT_MANAGER_CONTROLLER_IMAGE_ID"
  local expected_repo="${image%:*}@$expected_manifest"
  local wrong_digest="sha256:$(printf '0%.0s' {1..64})"
  local fake_source_manifest="$wrong_digest"
  local fake_digest_manifest=""
  local fake_config="$expected_config"
  local fake_repo="$expected_repo"
  local tag_calls=0 ref target
  controller_external_timeout() { shift; "$@"; }
  docker() {
    case "$*" in
      *'ctr --namespace=k8s.io images list name=='*)
        ref="${@: -1}"; ref="${ref#name==}"
        case "$ref" in
          "$image") target="$fake_source_manifest" ;;
          "$expected_repo") target="$fake_digest_manifest" ;;
          *) return 1 ;;
        esac
        [ -n "$target" ] || return 0
        printf 'REF TYPE DIGEST SIZE PLATFORMS LABELS\n'
        printf '%s application/vnd.docker.distribution.manifest.v2+json %s 1MiB linux/amd64 -\n' \
          "$ref" "$target"
        ;;
      *'ctr --namespace=k8s.io content get'*)
        printf '{"schemaVersion":2,"config":{"digest":"%s"},"layers":[]}\n' \
          "$fake_config"
        ;;
      *'ctr --namespace=k8s.io images tag --local --force'*)
        tag_calls=$((tag_calls+1))
        fake_digest_manifest="$fake_source_manifest"
        ;;
      *'crictl inspecti'*)
        printf '{"status":{"id":"%s","repoTags":["%s"],"repoDigests":["%s"]}}\n' \
          "$fake_config" "$image" "$fake_repo"
        ;;
      *) return 1 ;;
    esac
  }

  ! controller_node_publish_pinned_ref fake-node "$image" \
    || return 1
  [ "$tag_calls" -eq 0 ] || return 1

  fake_source_manifest="$expected_manifest"
  controller_node_publish_pinned_ref fake-node "$image" \
    || return 1
  [ "$tag_calls" -eq 1 ] \
    && [ "$fake_digest_manifest" = "$expected_manifest" ] \
    || return 1

  fake_repo="quay.io/attacker/controller@$CERT_MANAGER_CONTROLLER_DIGEST"
  ! controller_node_image_id_matches fake-node "$image" \
    || return 1
  fake_repo="$expected_repo"
  fake_digest_manifest="$wrong_digest"
  ! controller_node_image_id_matches fake-node "$image" \
    || return 1
  fake_digest_manifest="$expected_manifest"
  fake_config="$wrong_digest"
  ! controller_node_image_id_matches fake-node "$image"
)

contract_runtime_requires_pinned_spec_and_image_id() (
  local image="$CERT_MANAGER_CONTROLLER_IMAGE" pinned manifest config repository
  local deployment_json pod_json locked_runtime wrong_digest
  pinned="$(controller_pinned_image_ref "$image")" || return 1
  manifest="$(controller_expected_manifest_digest "$image")" || return 1
  config="$(controller_expected_image_id "$image")" || return 1
  repository="${image%:*}"
  locked_runtime="$repository@$manifest"
  wrong_digest="sha256:$(printf '1%.0s' {1..64})"
  deployment_json="{\"spec\":{\"replicas\":1,\"selector\":{\"matchLabels\":{\"app\":\"locked\"}},\"template\":{\"spec\":{\"containers\":[{\"name\":\"controller\",\"image\":\"$pinned\",\"imagePullPolicy\":\"Never\"}]}}}}"
  pod_json="{\"items\":[{\"metadata\":{\"labels\":{\"app\":\"locked\"}},\"spec\":{\"containers\":[{\"name\":\"controller\",\"image\":\"$pinned\",\"imagePullPolicy\":\"Never\"}]},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"name\":\"controller\",\"ready\":true,\"imageID\":\"$locked_runtime\"}]}}]}"
  kctx() {
    case "$*" in
      *'get deployment locked'*) printf '%s' "$deployment_json" ;;
      *'get pods'*) printf '%s' "$pod_json" ;;
      *) return 1 ;;
    esac
  }

  controller_deployment_runtime_locked test locked controller "$image" || return 1
  pod_json="${pod_json//$locked_runtime/$repository@$wrong_digest}"
  ! controller_deployment_runtime_locked test locked controller "$image" || return 1
  pod_json="${pod_json//$repository@$wrong_digest/$config}"
  controller_deployment_runtime_locked test locked controller "$image" || return 1
  deployment_json="${deployment_json//$pinned/$image}"
  ! controller_deployment_runtime_locked test locked controller "$image" || return 1
)

contract_webhook_requires_a_ready_endpoint_address() (
  local payload
  kctx() { printf '%s' "$payload"; }

  payload='{"items":[{"endpoints":[{"addresses":["10.0.0.8"],"conditions":{"ready":true}}]}]}'
  controller_cert_manager_webhook_endpoint_ready || return 1

  # EndpointSlice v1 defines an omitted ready condition as ready.
  payload='{"items":[{"endpoints":[{"addresses":["10.0.0.8"]}]}]}'
  controller_cert_manager_webhook_endpoint_ready || return 1

  payload='{"items":[{"endpoints":[{"addresses":["10.0.0.8"],"conditions":{"ready":false}}]}]}'
  ! controller_cert_manager_webhook_endpoint_ready || return 1

  payload='{"items":[{"endpoints":[{"addresses":[],"conditions":{"ready":true}}]}]}'
  ! controller_cert_manager_webhook_endpoint_ready || return 1

  payload='{"items":[]}'
  ! controller_cert_manager_webhook_endpoint_ready
)

contract_cert_manager_readiness_failure_is_actionable() (
  local output
  kctx() {
    case "$*" in
      *' wait '*) return 1 ;;
      *' get deployments '*) printf 'NAME AVAILABLE IMAGE\n' ;;
      *' get pods '*) printf 'NAME PHASE READY IMAGE IMAGE-ID\n' ;;
      *' get endpointslices '*) printf 'No resources found\n' ;;
      *) return 1 ;;
    esac
  }

  if output="$(controller_wait_cert_manager 2>&1)"; then
    return 1
  fi
  grep -Fq 'cert-manager deployments did not all become Available within 180 seconds' <<<"$output" \
    && grep -Fq 'cert-manager readiness summary follows (no Secret data is printed)' <<<"$output"
)

contract_ca09_setup_preserves_failure_stage() {
  local setup="$ROOT/questions/cluster-architecture/ca-09/setup.sh"
  grep -Fq 'set -Eeuo pipefail' "$setup" \
    && grep -Fq 'trap '\''ca09_setup_error "$?" "$LINENO"'\'' ERR' "$setup" \
    && grep -Fq 'ca-09 setup failed during '\''$CA09_SETUP_STAGE' "$setup" \
    && grep -Fq 'CA09_SETUP_STAGE="cert-manager readiness and locked-runtime validation"' "$setup" \
    && grep -Fq 'CA09_SETUP_STAGE="cert-manager sentinel reconciliation"' "$setup" \
    && grep -Fq 'cert-manager webhook has no Ready EndpointSlice address after 30 seconds' \
      "$ROOT/lib/controllers.sh" \
    && grep -Fq 'cert-manager Deployment or Pod image identity differs from the locked digest/pull policy' \
      "$ROOT/lib/controllers.sh"
}

contract_applied_manifests_are_digest_pinned_and_no_pull() {
  local cert envoy profile="$ROOT/cluster/controllers/profiles/envoy-clusterip.yaml"
  cert="$(controller_pinned_manifest_render cert-manager)" || return 1
  envoy="$(controller_pinned_manifest_render envoy-gateway)" || return 1
  [ "$(grep -Ec '^[[:space:]]*image:[[:space:]]*"?[^"[:space:]]+@sha256:[0-9a-f]{64}"?$' <<<"$cert")" -eq 3 ] \
    && [ "$(grep -Ec '^[[:space:]]*imagePullPolicy: Never$' <<<"$cert")" -eq 3 ] \
    && [ "$(grep -Ec '^[[:space:]]*image:[[:space:]]*"?[^"[:space:]]+@sha256:[0-9a-f]{64}"?$' <<<"$envoy")" -eq 4 ] \
    && [ "$(grep -Ec '^[[:space:]]*(-[[:space:]]+)?imagePullPolicy: Never$' <<<"$envoy")" -eq 3 ] \
    && ! grep -Fq 'imagePullPolicy: IfNotPresent' <<<"$cert$envoy" \
    && grep -Fq "image: $(controller_pinned_image_ref "$ENVOY_PROXY_IMAGE")" "$profile" \
    && grep -Fq 'imagePullPolicy: Never' "$profile"
}

contract_network_isolated_to_cache_step() {
  grep -Fq "curl --fail --location --proto '=https'" \
    "$ROOT/cluster/controllers/cache-assets.sh" \
    && grep -Fq 'class RegistryClient:' "$ROOT/cluster/controllers/cache-assets.sh" \
    && grep -Fq 'through the Distribution API instead' \
      "$ROOT/cluster/controllers/cache-assets.sh" \
    && grep -Fq 'url = f"https://{host}/v2/{repository}/{path}"' \
      "$ROOT/cluster/controllers/cache-assets.sh" \
    && grep -Fq 'controller_bundle_verify "$GATEWAY_WORKLOAD_BUNDLE"' \
      "$ROOT/cluster/controllers/cache-assets.sh" \
    && grep -Fq 'first run: bash cluster/cells/kubeadm/cache-packages.sh' \
      "$ROOT/cluster/controllers/cache-assets.sh" \
    && ! grep -Eq '^[[:space:]]*docker[[:space:]]+(pull|tag|save)([[:space:]]|$)' \
      "$ROOT/cluster/controllers/cache-assets.sh"
}

contract_stable_cell_api() {
  declare -F controller_cell_prepare >/dev/null \
    && declare -F controller_cell_activate >/dev/null \
    && declare -F controller_cell_cleanup >/dev/null \
    && declare -F controller_cell_status >/dev/null \
    && [ "$(controller_profile_for ca-09 operator-cell)" = cert-manager-configure ] \
    && [ "$(controller_profile_for ca-13 operator-cell)" = cert-manager-install ] \
    && [ "$(controller_profile_for sn-05 gateway-cell)" = envoy-gateway ]
}

contract_controller_cleanup_calls_are_bounded() {
  local library="$ROOT/lib/controllers.sh" cleanup
  cleanup="$(sed -n '/^controller_cleanup_kubectl()/,/^}/p' "$library")" \
    || return 1
  grep -Fq 'type -P timeout' <<<"$cleanup" \
    && grep -Fq 'type -P kubectl' <<<"$cleanup" \
    && grep -Fq -- '--foreground --kill-after=2s 10s' <<<"$cleanup" \
    && grep -Fq -- '--request-timeout=5s' <<<"$cleanup"
}

contract_controller_cleanup_aggregates_faults() (
  local call_count=0 call_log="" cleanup_rc=0
  controller_profile_for() { printf '%s\n' envoy-gateway; }
  controller_require_disposable_cell() { return 0; }
  controller_asset_path() { printf '/locked/%s.yaml\n' "$1"; }
  controller_cleanup_kubectl() {
    call_count=$((call_count+1))
    call_log+="${*}"$'\n'
    case "$call_count" in
      1) return 124 ;; # GNU timeout: simulated API/process blackhole
      2) return 1 ;;   # kubectl: simulated bounded API failure
      3) return 0 ;;
      *) return 99 ;;
    esac
  }

  controller_cell_cleanup sn-05 gateway-cell >/dev/null 2>&1
  cleanup_rc=$?
  [ "$cleanup_rc" -eq 2 ] \
    && [ "$call_count" -eq 3 ] \
    && [ "$(grep -Fc -- '--ignore-not-found --wait=false' <<<"$call_log")" -eq 3 ] \
    && grep -Fq '/profiles/envoy-clusterip.yaml' <<<"$call_log" \
    && grep -Fq '/locked/envoy-gateway.yaml' <<<"$call_log" \
    && grep -Fq '/locked/gateway-api.yaml' <<<"$call_log"
)

contract_profile_cleanup_failure_still_reaches_exact_cell_cleanup() {
  local runtime="$ROOT/lib/question-runtime.sh" body
  body="$(sed -n '/^_question_runtime_cleanup_disposable()/,/^}/p' "$runtime")" \
    || return 1
  grep -Fq '_question_runtime_profile_cleanup "$qid" "$environment" || failed=$((failed+1))' \
      <<<"$body" \
    && grep -Fq 'if (cell_cleanup "$qid" "$environment"); then' <<<"$body" \
    && [ "$(grep -n '_question_runtime_profile_cleanup' <<<"$body" | cut -d: -f1)" \
         -lt "$(grep -n 'if (cell_cleanup' <<<"$body" | cut -d: -f1)" ]
}

contract_shared_cluster_refused() (
  CKA_CONTEXT=kind-cka
  if (controller_require_disposable_cell >/dev/null 2>&1); then
    return 1
  fi
  return 0
)

contract_controller_mutation_is_manifest_bound() {
  local library="$ROOT/lib/controllers.sh"
  grep -Fq 'cell_active_identity_matches "$expected_qid" "$expected_environment"' \
      "$library" \
    && grep -Fq 'selected native cell and its sealed identity' "$library"
}

contract_question_scripts_fail_closed() {
  local qdir
  for qdir in \
    "$ROOT/questions/cluster-architecture/ca-09" \
    "$ROOT/questions/cluster-architecture/ca-13" \
    "$ROOT/questions/services-networking/sn-05"; do
    grep -Fq 'controller_require_disposable_cell' "$qdir/setup.sh" || return 1
    grep -Fq 'controller_require_disposable_cell' "$qdir/teardown.sh" || return 1
  done
}

contract_question_setup_uses_cell_api() {
  grep -Fq 'controller_cell_prepare "$QID" operator-cell' \
      "$ROOT/questions/cluster-architecture/ca-09/setup.sh" \
    && grep -Fq 'controller_cell_prepare "$QID" operator-cell' \
      "$ROOT/questions/cluster-architecture/ca-13/setup.sh" \
    && grep -Fq 'controller_cell_prepare "$QID" gateway-cell' \
      "$ROOT/questions/services-networking/sn-05/setup.sh"
}

contract_reference_solves_reactivate_exact_cell() {
  grep -Fq 'cell_activate ca-09 operator-cell' \
      "$ROOT/questions/cluster-architecture/ca-09/solve.sh" \
    && grep -Fq 'cell_activate ca-13 operator-cell' \
      "$ROOT/questions/cluster-architecture/ca-13/solve.sh" \
    && grep -Fq 'cell_activate sn-05 gateway-cell' \
      "$ROOT/questions/services-networking/sn-05/solve.sh"
}

contract_controller_prepare_is_readonly() {
  local setup
  ! grep -Eq '^[[:space:]]*require_cluster[[:space:]]*$' "$ROOT/lib/controllers.sh" \
    && grep -Fq 'require_cluster_readonly' "$ROOT/lib/controllers.sh" \
    || return 1
  for setup in \
    "$ROOT/questions/cluster-architecture/ca-09/setup.sh" \
    "$ROOT/questions/cluster-architecture/ca-13/setup.sh" \
    "$ROOT/questions/services-networking/sn-05/setup.sh"; do
    grep -Fq 'controller_require_disposable_cell' "$setup" || return 1
    grep -Fq 'require_cluster_readonly' "$setup" || return 1
    ! grep -Eq '^[[:space:]]*require_cluster[[:space:]]*$' "$setup" || return 1
  done
}

contract_operator_graders_are_semantic() {
  local ca09="$ROOT/questions/cluster-architecture/ca-09/grade.sh"
  local ca13="$ROOT/questions/cluster-architecture/ca-13/grade.sh"
  grep -Fq 'observedGeneration' "$ca09" \
    && grep -Fq 'ownerReferences' "$ca09" \
    && grep -Fq 'controller_tls_secret_valid' "$ca09" \
    && grep -Fq 'controller_cert_manager_runtime_locked' "$ca09" \
    && grep -Fq 'controller_cert_manager_runtime_locked' "$ca13" \
    && grep -Fq 'ca13_owned_request_ready' "$ca13" \
    && grep -Fq 'controller_tls_secret_valid' "$ca13"
}

contract_gateway_grader_uses_live_data_path() {
  local grade="$ROOT/questions/services-networking/sn-05/grade.sh"
  local setup="$ROOT/questions/services-networking/sn-05/setup.sh"
  grep -Fq 'sn05_gateway_status_current' "$grade" \
    && grep -Fq 'sn05_route_status_current' "$grade" \
    && grep -Fq 'sn05_data_service_ref' "$grade" \
    && grep -Fq 'sn05_data_plane_runtime_locked' "$grade" \
    && grep -Fq 'sn05_workload_runtime_locked' "$grade" \
    && grep -Fq 'exec deploy/sn05-probe' "$grade" \
    && grep -Fq 'wrong.example.com /store' "$grade" \
    && grep -Fq 'shop.example.com /not-store' "$grade" \
    && grep -Eq '^[[:space:]]+store:[[:space:]]*\|[[:space:]]*$' "$setup" \
    && grep -Fq 'mountPath: /usr/share/nginx/html' "$setup" \
    && [ "$(grep -Fc 'imagePullPolicy: Never' "$setup")" -eq 2 ] \
    && grep -Fq 'controller_pinned_image_ref "$GATEWAY_BACKEND_IMAGE"' "$setup" \
    && grep -Fq 'controller_pinned_image_ref "$GATEWAY_PROBE_IMAGE"' "$setup" \
    && grep -Fq 'type: ClusterIP' "$ROOT/cluster/controllers/profiles/envoy-clusterip.yaml"
}

contract_operator_condition_rejects_stale_generation() (
  export CKA_QUESTION_SOURCE_ONLY=1
  source "$ROOT/questions/cluster-architecture/ca-09/grade.sh"
  local fixture
  _resource_json() { printf '%s' "$fixture"; }
  fixture='{"metadata":{"generation":4},"status":{"conditions":[{"type":"Ready","status":"True","observedGeneration":4}]}}'
  ca09_condition_current certificate db-api-tls operators Ready || return 1
  fixture='{"metadata":{"generation":5},"status":{"conditions":[{"type":"Ready","status":"True","observedGeneration":4}]}}'
  ! ca09_condition_current certificate db-api-tls operators Ready
)

contract_gateway_status_rejects_stale_listener() (
  export CKA_QUESTION_SOURCE_ONLY=1
  source "$ROOT/questions/services-networking/sn-05/grade.sh"
  local fixture
  _resource_json() { printf '%s' "$fixture"; }
  fixture='{"metadata":{"generation":7},"status":{"conditions":[{"type":"Accepted","status":"True","observedGeneration":7},{"type":"Programmed","status":"True","observedGeneration":7}],"listeners":[{"name":"http","attachedRoutes":1,"conditions":[{"type":"Accepted","status":"True","observedGeneration":7},{"type":"ResolvedRefs","status":"True","observedGeneration":7}]}]}}'
  sn05_gateway_status_current || return 1
  fixture='{"metadata":{"generation":8},"status":{"conditions":[{"type":"Accepted","status":"True","observedGeneration":8},{"type":"Programmed","status":"True","observedGeneration":8}],"listeners":[{"name":"http","attachedRoutes":1,"conditions":[{"type":"Accepted","status":"True","observedGeneration":7},{"type":"ResolvedRefs","status":"True","observedGeneration":8}]}]}}'
  ! sn05_gateway_status_current
)

contract_tamper_is_fail_not_invalid() {
  local grade
  for grade in \
    "$ROOT/questions/cluster-architecture/ca-09/grade.sh" \
    "$ROOT/questions/cluster-architecture/ca-13/grade.sh" \
    "$ROOT/questions/services-networking/sn-05/grade.sh"; do
    grep -Eq 'TAMPERED=1' "$grade" || return 1
  done
  ! grep -R -E 'TAMPERED.*grade_invalid|grade_invalid.*TAMPERED' \
    "$ROOT/questions/cluster-architecture/ca-09/grade.sh" \
    "$ROOT/questions/cluster-architecture/ca-13/grade.sh" \
    "$ROOT/questions/services-networking/sn-05/grade.sh"
}

contract_gateway_network_policy_tamper_is_candidate_fail() {
  local grade="$ROOT/questions/services-networking/sn-05/grade.sh"
  grep -Fq 'sn05_candidate_network_policy_present' "$grade" \
    && grep -Fq 'SN05_TAMPERED=1' "$grade" \
    && grep -Fq 'traffic cka-controller-system envoy-gateway-system' "$grade"
}

contract_gateway_generated_data_plane_tamper_is_candidate_fail() {
  local grade="$ROOT/questions/services-networking/sn-05/grade.sh"
  ! grep -Fq 'programmed Envoy data plane cannot reach' "$grade" \
    && ! grep -Eq 'sn05_(http_contains|data_plane_runtime_locked).*grade_invalid|grade_invalid.*sn05_(http_contains|data_plane_runtime_locked)' \
      "$grade" \
    && grep -Fq 'sn05_data_plane_runtime_locked &&' "$grade" \
    && grep -Fq 'sn05_http_contains shop.example.com /store' "$grade"
}

contract_graders_point_totals() {
  local qdir points sum
  for qdir in \
    "$ROOT/questions/cluster-architecture/ca-09" \
    "$ROOT/questions/cluster-architecture/ca-13" \
    "$ROOT/questions/services-networking/sn-05"; do
    points="$(awk '$1=="points:" {print $2}' "$qdir/meta.yaml")"
    sum="$(awk '/^[[:space:]]*criterion[[:space:]]+[0-9]+/ {total += $2} END {print total+0}' "$qdir/grade.sh")"
    [ "$points" = "$sum" ] || return 1
  done
}

contract_live_runner_enforces_metadata_and_unsolved_baseline() {
  local runner="$ROOT/tests/operator-gateway-live-test.sh"
  grep -Fq 'read_timeout setup_timeout_seconds' "$runner" \
    && grep -Fq 'read_timeout grade_timeout_seconds' "$runner" \
    && grep -Fq 'timeout --foreground "${SETUP_TIMEOUT}s" "$ROOT/cka" start' "$runner" \
    && grep -Fq 'timeout --foreground "${GRADE_TIMEOUT}s" "$ROOT/cka" grade' "$runner" \
    && grep -Fq 'already fully solved before the reference solution' "$runner" \
    && grep -Fq 'run_cleanup || die' "$runner" \
    && ! grep -Fq 'cleanup "$QID" >/dev/null 2>&1 || true' "$runner"
}

contract_common_cleanup_tolerates_absent_gateway_api() {
  local common="$ROOT/lib/common.sh"
  grep -Fq 'kctx get crd gatewayclasses.gateway.networking.k8s.io' "$common" \
    && grep -Fq 'kctx delete gatewayclass -l "$CKA_LABEL_KEY=$id"' "$common"
}

contract_shell_syntax() {
  local script
  while IFS= read -r script; do
    bash -n "$script" || return 1
  done < <(find "$ROOT/cluster/controllers" "$ROOT/questions/cluster-architecture/ca-09" \
    "$ROOT/questions/cluster-architecture/ca-13" "$ROOT/questions/services-networking/sn-05" \
    -type f -name '*.sh' -print)
  bash -n "$ROOT/lib/controllers.sh"
}

[ "${CKA_CONTRACT_SOURCE_ONLY:-0}" = 1 ] && return 0

check 'exact cert-manager, Gateway API and Envoy releases are locked' contract_exact_release_lock
check 'controller image config IDs are locked on host and every cell node' contract_image_config_ids_are_locked_and_verified
check 'runtime controller library performs no network fetch' contract_runtime_has_no_network_fetch
check 'controller image preload bypass is closed' contract_preload_bypass_is_closed
check 'controller image preload commands have process deadlines' contract_controller_preload_is_process_bounded
check 'image archives are verified from the trusted exact allowlist' contract_archives_are_verified_from_the_lock
check 'node image identity publishes and verifies the locked canonical digest' contract_node_identity_publishes_and_requires_canonical_digest
check 'runtime Pods require pinned specs and actual locked imageID' contract_runtime_requires_pinned_spec_and_image_id
check 'cert-manager webhook requires a Ready EndpointSlice address' contract_webhook_requires_a_ready_endpoint_address
check 'cert-manager readiness failures include a safe diagnostic summary' contract_cert_manager_readiness_failure_is_actionable
check 'ca-09 setup preserves the exact failing stage' contract_ca09_setup_preserves_failure_stage
check 'applied manifests are digest-pinned with offline pull policy' contract_applied_manifests_are_digest_pinned_and_no_pull
check 'network access is isolated to the trusted cache step' contract_network_isolated_to_cache_step
check 'stable controller cell adapter API is exposed' contract_stable_cell_api
check 'controller cleanup kubectl calls have request and process bounds' contract_controller_cleanup_calls_are_bounded
check 'controller cleanup aggregates faults and continues every safe step' contract_controller_cleanup_aggregates_faults
check 'profile cleanup failure still reaches exact immutable cell cleanup' contract_profile_cleanup_failure_still_reaches_exact_cell_cleanup
check 'shared kind-cka is rejected fail-closed' contract_shared_cluster_refused
check 'controller mutations require the exact immutable disposable cell' contract_controller_mutation_is_manifest_bound
check 'question setup and teardown fail closed outside disposable cells' contract_question_scripts_fail_closed
check 'all three labs prepare their disposable controller profile' contract_question_setup_uses_cell_api
check 'reference solutions reactivate the exact disposable cell' contract_reference_solves_reactivate_exact_cell
check 'controller cells check API readiness without repairing shared add-ons' contract_controller_prepare_is_readonly
check 'operator graders verify reconcile generation, ownership and TLS' contract_operator_graders_are_semantic
check 'Gateway grader probes positive and negative Envoy data paths' contract_gateway_grader_uses_live_data_path
check 'operator Ready condition rejects stale observedGeneration' contract_operator_condition_rejects_stale_generation
check 'Gateway listener status rejects stale observedGeneration' contract_gateway_status_rejects_stale_listener
check 'candidate infrastructure tamper maps to FAIL, not INVALID' contract_tamper_is_fail_not_invalid
check 'candidate NetworkPolicy data-path sabotage remains FAIL' contract_gateway_network_policy_tamper_is_candidate_fail
check 'candidate generated data-plane sabotage remains FAIL' contract_gateway_generated_data_plane_tamper_is_candidate_fail
check 'question metadata and criterion point totals agree' contract_graders_point_totals
check 'live runner enforces metadata timeouts, baseline and cleanup' contract_live_runner_enforces_metadata_and_unsolved_baseline
check 'common cleanup treats an absent Gateway API as already clean' contract_common_cleanup_tolerates_absent_gateway_api
check 'controller lab shell files parse successfully' contract_shell_syntax

printf '\noperator-gateway-contract-test: pass %d / fail %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
