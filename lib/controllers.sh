#!/usr/bin/env bash
# Offline controller-cell runtime shared by real reconcile/data-path labs.

if [ -z "${CKA_ROOT:-}" ]; then
  # shellcheck source=common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

CONTROLLER_ROOT="${CONTROLLER_ROOT:-$CKA_ROOT/cluster/controllers}"
CONTROLLER_LOCK="${CONTROLLER_LOCK:-$CONTROLLER_ROOT/assets.lock}"
CONTROLLER_ASSET_DIR="${CONTROLLER_ASSET_DIR:-$CONTROLLER_ROOT/assets}"
CONTROLLER_WORKLOAD_ASSET_DIR="$CKA_ROOT/cluster/cells/kubeadm/packages"
CONTROLLER_ARCHIVE_VERIFIER="$CKA_ROOT/cluster/controllers/verify-oci-archive.py"

controller_lock_get() { # <key>
  local key="$1"
  awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*" {
      count++; value=$0
      sub("^" key ":[[:space:]]*", "", value)
      sub("\\r$", "", value)
      if (value !~ /^"[^"]+"$/) invalid=1
      else value=substr(value, 2, length(value)-2)
    }
    END { if (count != 1 || invalid) exit 1; print value }
  ' "$CONTROLLER_LOCK"
}

_controller_assign() { # <var> <key>
  local value
  value="$(controller_lock_get "$2")" \
    || die "controller lock key missing or invalid: $2"
  printf -v "$1" '%s' "$value"
  export "$1"
}

controller_lock_load() {
  [ -r "$CONTROLLER_LOCK" ] || die "controller lock unavailable: $CONTROLLER_LOCK"
  _controller_assign CONTROLLER_LOCK_SCHEMA schema_version
  _controller_assign CONTROLLER_PLATFORM platform
  _controller_assign CERT_MANAGER_VERSION cert_manager_version
  _controller_assign CERT_MANAGER_MANIFEST cert_manager_manifest
  _controller_assign CERT_MANAGER_MANIFEST_URL cert_manager_manifest_url
  _controller_assign CERT_MANAGER_MANIFEST_SHA256 cert_manager_manifest_sha256
  _controller_assign CERT_MANAGER_IMAGES_BUNDLE cert_manager_images_bundle
  _controller_assign CERT_MANAGER_CONTROLLER_IMAGE cert_manager_controller_image
  _controller_assign CERT_MANAGER_CONTROLLER_DIGEST cert_manager_controller_digest
  _controller_assign CERT_MANAGER_CONTROLLER_IMAGE_ID cert_manager_controller_image_id
  _controller_assign CERT_MANAGER_WEBHOOK_IMAGE cert_manager_webhook_image
  _controller_assign CERT_MANAGER_WEBHOOK_DIGEST cert_manager_webhook_digest
  _controller_assign CERT_MANAGER_WEBHOOK_IMAGE_ID cert_manager_webhook_image_id
  _controller_assign CERT_MANAGER_CAINJECTOR_IMAGE cert_manager_cainjector_image
  _controller_assign CERT_MANAGER_CAINJECTOR_DIGEST cert_manager_cainjector_digest
  _controller_assign CERT_MANAGER_CAINJECTOR_IMAGE_ID cert_manager_cainjector_image_id
  _controller_assign CONTROLLER_GATEWAY_API_VERSION gateway_api_version
  _controller_assign GATEWAY_API_MANIFEST gateway_api_manifest
  _controller_assign GATEWAY_API_MANIFEST_URL gateway_api_manifest_url
  _controller_assign GATEWAY_API_MANIFEST_SHA256 gateway_api_manifest_sha256
  _controller_assign ENVOY_GATEWAY_VERSION envoy_gateway_version
  _controller_assign ENVOY_GATEWAY_MANIFEST envoy_gateway_manifest
  _controller_assign ENVOY_GATEWAY_MANIFEST_URL envoy_gateway_manifest_url
  _controller_assign ENVOY_GATEWAY_MANIFEST_SHA256 envoy_gateway_manifest_sha256
  _controller_assign ENVOY_GATEWAY_IMAGES_BUNDLE envoy_gateway_images_bundle
  _controller_assign ENVOY_GATEWAY_IMAGE envoy_gateway_image
  _controller_assign ENVOY_GATEWAY_DIGEST envoy_gateway_digest
  _controller_assign ENVOY_GATEWAY_IMAGE_ID envoy_gateway_image_id
  _controller_assign ENVOY_PROXY_IMAGE envoy_proxy_image
  _controller_assign ENVOY_PROXY_DIGEST envoy_proxy_digest
  _controller_assign ENVOY_PROXY_IMAGE_ID envoy_proxy_image_id
  _controller_assign ENVOY_RATELIMIT_IMAGE envoy_ratelimit_image
  _controller_assign ENVOY_RATELIMIT_DIGEST envoy_ratelimit_digest
  _controller_assign ENVOY_RATELIMIT_IMAGE_ID envoy_ratelimit_image_id
  _controller_assign GATEWAY_WORKLOAD_BUNDLE gateway_workload_bundle
  _controller_assign GATEWAY_WORKLOAD_ATTACHMENT_DIGESTS gateway_workload_attachment_digests
  _controller_assign GATEWAY_BACKEND_IMAGE gateway_backend_image
  _controller_assign GATEWAY_BACKEND_REGISTRY_DIGEST gateway_backend_registry_digest
  _controller_assign GATEWAY_BACKEND_DIGEST gateway_backend_digest
  _controller_assign GATEWAY_BACKEND_IMAGE_ID gateway_backend_image_id
  _controller_assign GATEWAY_PROBE_IMAGE gateway_probe_image
  _controller_assign GATEWAY_PROBE_REGISTRY_DIGEST gateway_probe_registry_digest
  _controller_assign GATEWAY_PROBE_DIGEST gateway_probe_digest
  _controller_assign GATEWAY_PROBE_IMAGE_ID gateway_probe_image_id

  [ "$CONTROLLER_LOCK_SCHEMA" = 1 ] || die "unsupported controller lock schema"
  [[ "$CONTROLLER_PLATFORM" =~ ^linux/(amd64|arm64)$ ]] \
    || die "invalid controller platform: $CONTROLLER_PLATFORM"
  local digest
  for digest in \
    "$CERT_MANAGER_MANIFEST_SHA256" "$GATEWAY_API_MANIFEST_SHA256" \
    "$ENVOY_GATEWAY_MANIFEST_SHA256"; do
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "invalid controller asset sha256"
  done
  for digest in \
    "$CERT_MANAGER_CONTROLLER_DIGEST" "$CERT_MANAGER_WEBHOOK_DIGEST" \
    "$CERT_MANAGER_CAINJECTOR_DIGEST" "$ENVOY_GATEWAY_DIGEST" \
    "$ENVOY_PROXY_DIGEST" "$ENVOY_RATELIMIT_DIGEST" \
    "$GATEWAY_BACKEND_REGISTRY_DIGEST" "$GATEWAY_BACKEND_DIGEST" \
    "$GATEWAY_PROBE_REGISTRY_DIGEST" "$GATEWAY_PROBE_DIGEST"; do
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid controller image digest"
  done
  for digest in \
    "$CERT_MANAGER_CONTROLLER_IMAGE_ID" "$CERT_MANAGER_WEBHOOK_IMAGE_ID" \
    "$CERT_MANAGER_CAINJECTOR_IMAGE_ID" "$ENVOY_GATEWAY_IMAGE_ID" \
    "$ENVOY_PROXY_IMAGE_ID" "$ENVOY_RATELIMIT_IMAGE_ID" \
    "$GATEWAY_BACKEND_IMAGE_ID" "$GATEWAY_PROBE_IMAGE_ID"; do
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid controller image config id"
  done
  [ "$GATEWAY_WORKLOAD_BUNDLE" = kubeadm-workloads-linux-amd64.tar ] \
    && [ "$GATEWAY_BACKEND_IMAGE" = docker.io/library/nginx:1.29 ] \
    && [ "$GATEWAY_PROBE_IMAGE" = docker.io/library/busybox:1.36 ] \
    || die "invalid Gateway workload image lock"
  local -a attachment_digests=()
  read -r -a attachment_digests <<<"$GATEWAY_WORKLOAD_ATTACHMENT_DIGESTS"
  [ "${#attachment_digests[@]}" -eq 2 ] \
    || die "invalid Gateway workload attachment lock"
  [ "${attachment_digests[0]}" != "${attachment_digests[1]}" ] \
    || die "duplicate Gateway workload attachment lock"
  for digest in "${attachment_digests[@]}"; do
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || die "invalid Gateway workload attachment digest"
  done
}

controller_lock_load

controller_host_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "$os" "$arch"
}

controller_sha256_matches() { # <path> <sha256>
  local actual
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  actual="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')" || return 1
  [ "$actual" = "$2" ]
}

controller_asset_path() { # cert-manager | gateway-api | envoy-gateway
  case "$1" in
    cert-manager) printf '%s/%s\n' "$CONTROLLER_ASSET_DIR" "$CERT_MANAGER_MANIFEST" ;;
    gateway-api) printf '%s/%s\n' "$CONTROLLER_ASSET_DIR" "$GATEWAY_API_MANIFEST" ;;
    envoy-gateway) printf '%s/%s\n' "$CONTROLLER_ASSET_DIR" "$ENVOY_GATEWAY_MANIFEST" ;;
    *) return 1 ;;
  esac
}

controller_manifest_verify() { # profile name
  local path expected
  path="$(controller_asset_path "$1")" || return 1
  case "$1" in
    cert-manager) expected="$CERT_MANAGER_MANIFEST_SHA256" ;;
    gateway-api) expected="$GATEWAY_API_MANIFEST_SHA256" ;;
    envoy-gateway) expected="$ENVOY_GATEWAY_MANIFEST_SHA256" ;;
    *) return 1 ;;
  esac
  controller_sha256_matches "$path" "$expected"
}

controller_pinned_image_ref() { # <locked-tag>
  local digest
  digest="$(controller_expected_manifest_digest "$1")" || return 1
  printf '%s@%s\n' "$1" "$digest"
}

controller_pinned_manifest_render() { # cert-manager | envoy-gateway
  local profile="$1" path policy_count old_gateway
  local -a replacements=()
  controller_manifest_verify "$profile" || return 1
  path="$(controller_asset_path "$profile")" || return 1
  case "$profile" in
    cert-manager)
      policy_count=3
      replacements+=(
        "$CERT_MANAGER_CONTROLLER_IMAGE" "$(controller_pinned_image_ref "$CERT_MANAGER_CONTROLLER_IMAGE")" 1
        "$CERT_MANAGER_WEBHOOK_IMAGE" "$(controller_pinned_image_ref "$CERT_MANAGER_WEBHOOK_IMAGE")" 1
        "$CERT_MANAGER_CAINJECTOR_IMAGE" "$(controller_pinned_image_ref "$CERT_MANAGER_CAINJECTOR_IMAGE")" 1
      )
      ;;
    envoy-gateway)
      policy_count=3
      old_gateway="${ENVOY_GATEWAY_IMAGE#docker.io/}"
      replacements+=(
        "$old_gateway" "$(controller_pinned_image_ref "$ENVOY_GATEWAY_IMAGE")" 3
        "$ENVOY_RATELIMIT_IMAGE" "$(controller_pinned_image_ref "$ENVOY_RATELIMIT_IMAGE")" 1
      )
      ;;
    *) return 1 ;;
  esac
  python3 - "$path" "$policy_count" "${replacements[@]}" <<'PY'
import pathlib,sys
path=pathlib.Path(sys.argv[1]); policy_count=int(sys.argv[2]); args=sys.argv[3:]
if len(args) % 3:
    raise SystemExit("invalid pinned-manifest replacement contract")
text=path.read_text(encoding="utf-8")
for index in range(0,len(args),3):
    old,new,count=args[index],args[index+1],int(args[index+2])
    if text.count(old) != count:
        raise SystemExit(f"locked image occurrence mismatch: {old}")
    text=text.replace(old,new)
old_policy="imagePullPolicy: IfNotPresent"
if text.count(old_policy) != policy_count:
    raise SystemExit("locked imagePullPolicy occurrence mismatch")
text=text.replace(old_policy,"imagePullPolicy: Never")
sys.stdout.write(text)
PY
}

controller_pinned_manifest_verify() {
  controller_pinned_manifest_render "$1" >/dev/null
}

controller_envoy_profile_file_verify() {
  local path="$CONTROLLER_ROOT/profiles/envoy-clusterip.yaml" pinned
  pinned="$(controller_pinned_image_ref "$ENVOY_PROXY_IMAGE")" || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  python3 - "$path" "$pinned" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
ok=(text.count("image: "+sys.argv[2])==1
    and text.count("imagePullPolicy: Never")==1
    and text.count("type: ClusterIP")==1)
raise SystemExit(0 if ok else 1)
PY
}

controller_bundle_path() { # bundle file name
  case "$1" in
    "$CERT_MANAGER_IMAGES_BUNDLE"|"$ENVOY_GATEWAY_IMAGES_BUNDLE")
      printf '%s/%s\n' "$CONTROLLER_ASSET_DIR" "$1"
      ;;
    "$GATEWAY_WORKLOAD_BUNDLE")
      printf '%s/%s\n' "$CONTROLLER_WORKLOAD_ASSET_DIR" "$1"
      ;;
    *) return 1 ;;
  esac
}

controller_bundle_verify() { # bundle image...
  local bundle_name="$1" bundle image manifest_digest config_digest
  local -a locked=() attachment_digests=()
  bundle="$(controller_bundle_path "$bundle_name")" || return 1
  shift
  [ "$#" -gt 0 ] && [ -f "$bundle" ] && [ ! -L "$bundle" ] \
    && [ -f "$CONTROLLER_ARCHIVE_VERIFIER" ] \
    && [ ! -L "$CONTROLLER_ARCHIVE_VERIFIER" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  for image in "$@"; do
    manifest_digest="$(controller_expected_manifest_digest "$image")" || return 1
    config_digest="$(controller_expected_image_id "$image")" || return 1
    locked+=("$image" "$manifest_digest" "$config_digest")
  done
  if [ "$bundle_name" = "$GATEWAY_WORKLOAD_BUNDLE" ]; then
    read -r -a attachment_digests <<<"$GATEWAY_WORKLOAD_ATTACHMENT_DIGESTS"
    locked+=(--attachments "${attachment_digests[@]}")
  fi
  python3 "$CONTROLLER_ARCHIVE_VERIFIER" \
    "$bundle" "$CONTROLLER_PLATFORM" "${locked[@]}"
}

controller_expected_image_id() { # <locked-tag>
  case "$1" in
    "$CERT_MANAGER_CONTROLLER_IMAGE") printf '%s\n' "$CERT_MANAGER_CONTROLLER_IMAGE_ID" ;;
    "$CERT_MANAGER_WEBHOOK_IMAGE") printf '%s\n' "$CERT_MANAGER_WEBHOOK_IMAGE_ID" ;;
    "$CERT_MANAGER_CAINJECTOR_IMAGE") printf '%s\n' "$CERT_MANAGER_CAINJECTOR_IMAGE_ID" ;;
    "$ENVOY_GATEWAY_IMAGE") printf '%s\n' "$ENVOY_GATEWAY_IMAGE_ID" ;;
    "$ENVOY_PROXY_IMAGE") printf '%s\n' "$ENVOY_PROXY_IMAGE_ID" ;;
    "$ENVOY_RATELIMIT_IMAGE") printf '%s\n' "$ENVOY_RATELIMIT_IMAGE_ID" ;;
    "$GATEWAY_BACKEND_IMAGE") printf '%s\n' "$GATEWAY_BACKEND_IMAGE_ID" ;;
    "$GATEWAY_PROBE_IMAGE") printf '%s\n' "$GATEWAY_PROBE_IMAGE_ID" ;;
    *) return 1 ;;
  esac
}

controller_expected_manifest_digest() { # <locked-tag>
  case "$1" in
    "$CERT_MANAGER_CONTROLLER_IMAGE") printf '%s\n' "$CERT_MANAGER_CONTROLLER_DIGEST" ;;
    "$CERT_MANAGER_WEBHOOK_IMAGE") printf '%s\n' "$CERT_MANAGER_WEBHOOK_DIGEST" ;;
    "$CERT_MANAGER_CAINJECTOR_IMAGE") printf '%s\n' "$CERT_MANAGER_CAINJECTOR_DIGEST" ;;
    "$ENVOY_GATEWAY_IMAGE") printf '%s\n' "$ENVOY_GATEWAY_DIGEST" ;;
    "$ENVOY_PROXY_IMAGE") printf '%s\n' "$ENVOY_PROXY_DIGEST" ;;
    "$ENVOY_RATELIMIT_IMAGE") printf '%s\n' "$ENVOY_RATELIMIT_DIGEST" ;;
    "$GATEWAY_BACKEND_IMAGE") printf '%s\n' "$GATEWAY_BACKEND_DIGEST" ;;
    "$GATEWAY_PROBE_IMAGE") printf '%s\n' "$GATEWAY_PROBE_DIGEST" ;;
    *) return 1 ;;
  esac
}

controller_docker_image_id_matches() { # <locked-tag>
  local expected_config expected_manifest repository expected_repo_digest actual repo_digests
  expected_config="$(controller_expected_image_id "$1")" || return 1
  expected_manifest="$(controller_expected_manifest_digest "$1")" || return 1
  repository="${1%:*}"
  expected_repo_digest="$repository@$expected_manifest"
  actual="$(docker image inspect --format '{{.Id}}' "$1" 2>/dev/null)" || return 1
  repo_digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    "$1" 2>/dev/null)" || return 1

  # The classic Docker image store reports the config digest as .Id, while
  # Docker's containerd image store reports the platform manifest digest.
  # Accept either representation, but bind it to the locked manifest digest:
  # a classic-store image must retain the exact RepoDigest and a containerd-
  # store image may prove the same digest directly through .Id.
  if [ "$actual" = "$expected_manifest" ]; then
    return 0
  fi
  [ "$actual" = "$expected_config" ] \
    && grep -Fxq "$expected_repo_digest" <<<"$repo_digests"
}

controller_node_ref_manifest_matches() { # <container-id> <image-ref> <manifest-digest>
  controller_docker exec "$1" ctr --namespace=k8s.io images list "name==$2" 2>/dev/null \
    | python3 -c '
import sys
ref,digest=sys.argv[1:3]
rows=[]
for line in sys.stdin:
    fields=line.split()
    if len(fields) >= 3 and fields[0] == ref:
        rows.append(fields)
ok=(len(rows)==1 and rows[0][2]==digest)
raise SystemExit(0 if ok else 1)
' "$2" "$3"
}

controller_node_manifest_config_matches() { # <container-id> <manifest-digest> <config-digest>
  controller_docker exec "$1" ctr --namespace=k8s.io content get "$2" 2>/dev/null \
    | python3 -c '
import json,sys
obj=json.load(sys.stdin); config=obj.get("config") or {}
raise SystemExit(0 if config.get("digest")==sys.argv[1] else 1)
' "$3"
}

controller_node_image_id_matches() { # <container-id> <locked-tag>
  local expected_config expected_manifest repository expected_repo_digest
  local short_tag short_repo_digest
  expected_config="$(controller_expected_image_id "$2")" || return 1
  expected_manifest="$(controller_expected_manifest_digest "$2")" || return 1
  repository="${2%:*}"
  expected_repo_digest="$repository@$expected_manifest"
  short_tag="$2"
  short_repo_digest="$expected_repo_digest"
  case "$short_tag" in docker.io/*) short_tag="${short_tag#docker.io/}" ;; esac
  case "$short_repo_digest" in docker.io/*) short_repo_digest="${short_repo_digest#docker.io/}" ;; esac

  # A CRI RepoDigest is not sufficient proof for an image imported with ctr:
  # ctr may synthesize an import-* digest reference. Bind both the tag and the
  # canonical repository digest directly to the locked containerd target, then
  # prove that target's manifest points at the locked image config.
  controller_node_ref_manifest_matches "$1" "$2" "$expected_manifest" \
    && controller_node_ref_manifest_matches "$1" "$expected_repo_digest" "$expected_manifest" \
    && controller_node_manifest_config_matches "$1" "$expected_manifest" "$expected_config" \
    && controller_docker exec "$1" crictl inspecti "$expected_repo_digest" 2>/dev/null \
      | python3 -c '
import json,sys
obj=json.load(sys.stdin); status=obj.get("status") or {}
image_id=status.get("id","")
tags=status.get("repoTags") or status.get("RepoTags") or []
digests=status.get("repoDigests") or status.get("RepoDigests") or []
expected_id,full_tag,short_tag,full_digest,short_digest=sys.argv[1:6]
ok=(image_id==expected_id and isinstance(tags,list) and isinstance(digests,list)
    and any(value in {full_tag,short_tag} for value in tags if isinstance(value,str))
    and any(value in {full_digest,short_digest} for value in digests if isinstance(value,str)))
raise SystemExit(0 if ok else 1)
' "$expected_config" "$2" "$short_tag" "$expected_repo_digest" "$short_repo_digest"
}

controller_node_publish_pinned_ref() { # <container-id> <locked-tag>
  local expected_config expected_manifest repository expected_repo_digest attempt
  expected_config="$(controller_expected_image_id "$2")" || return 1
  expected_manifest="$(controller_expected_manifest_digest "$2")" || return 1
  repository="${2%:*}"
  expected_repo_digest="$repository@$expected_manifest"

  # kind imports archives with `ctr images import --digests`. containerd may
  # name the generated digest reference import-<date>@sha256:..., which cannot
  # satisfy a Pod pinned to the original repository digest. Only after proving
  # the imported tag's exact manifest and config do we publish that immutable
  # target under the locked canonical digest reference.
  controller_node_ref_manifest_matches "$1" "$2" "$expected_manifest" \
    && controller_node_manifest_config_matches "$1" "$expected_manifest" "$expected_config" \
    || return 1
  controller_docker exec "$1" ctr --namespace=k8s.io images tag --local --force \
    "$2" "$expected_repo_digest" >/dev/null 2>&1 || return 1

  # The CRI image cache consumes containerd metadata asynchronously. Bound the
  # wait so a missing or wrong canonical reference still fails closed.
  for attempt in $(seq 1 30); do
    controller_node_image_id_matches "$1" "$2" && return 0
    sleep 1
  done
  return 1
}

controller_assets_verify() { # cert-manager | envoy-gateway | all
  local which="${1:-all}"
  [ "$(controller_host_platform)" = "$CONTROLLER_PLATFORM" ] || return 1
  case "$which" in
    cert-manager)
      controller_manifest_verify cert-manager \
        && controller_bundle_verify "$CERT_MANAGER_IMAGES_BUNDLE" \
          "$CERT_MANAGER_CONTROLLER_IMAGE" "$CERT_MANAGER_WEBHOOK_IMAGE" \
          "$CERT_MANAGER_CAINJECTOR_IMAGE" \
        && controller_pinned_manifest_verify cert-manager
      ;;
    envoy-gateway)
      controller_manifest_verify gateway-api \
        && controller_manifest_verify envoy-gateway \
        && controller_bundle_verify "$ENVOY_GATEWAY_IMAGES_BUNDLE" \
          "$ENVOY_GATEWAY_IMAGE" "$ENVOY_PROXY_IMAGE" "$ENVOY_RATELIMIT_IMAGE" \
        && controller_bundle_verify "$GATEWAY_WORKLOAD_BUNDLE" \
          "$GATEWAY_BACKEND_IMAGE" "$GATEWAY_PROBE_IMAGE" \
        && controller_pinned_manifest_verify envoy-gateway \
        && controller_envoy_profile_file_verify
      ;;
    all)
      controller_assets_verify cert-manager && controller_assets_verify envoy-gateway
      ;;
    *) return 1 ;;
  esac
}

controller_require_disposable_cell() { # <qid> <environment>
  local expected_qid="${1:-}" expected_environment="${2:-}"
  [ -n "$expected_qid" ] && [ -n "$expected_environment" ] \
    || die "controller cell identity is required"
  # Reload the trusted implementation so an inherited shell function cannot
  # downgrade the active-selection and sealed-manifest checks.
  # shellcheck source=cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  cell_qid_valid "$expected_qid" \
    || die "invalid controller cell question: $expected_qid"
  case "$expected_environment" in operator-cell|gateway-cell) ;; *)
    die "invalid controller cell environment: $expected_environment" ;;
  esac
  cell_active_identity_matches "$expected_qid" "$expected_environment" \
    || die "controller mutation requires the selected native cell and its sealed identity"
}

controller_external_timeout() { timeout --foreground --kill-after=5s "$@"; }
controller_docker() { controller_external_timeout 45s docker "$@"; }

controller_kind_name() {
  if [ -n "${CKA_CELL_KIND_NAME:-}" ]; then
    printf '%s\n' "$CKA_CELL_KIND_NAME"
  else
    case "$CKA_CONTEXT" in
      kind-?*) printf '%s\n' "${CKA_CONTEXT#kind-}" ;;
      *) return 1 ;;
    esac
  fi
}

controller_bundle_load_into_cell() { # bundle <image...>
  local bundle="$1" bundle_path cluster_name image role node_id
  shift
  # Fail before kind receives an archive, including when this helper is called
  # directly instead of through controller_cell_prepare.
  controller_require_disposable_cell "${CKA_CELL_QID:-}" "${CKA_CELL_ENVIRONMENT:-}"
  bundle_path="$(controller_bundle_path "$bundle")" \
    || die "unsupported offline image bundle: $bundle"
  controller_bundle_verify "$bundle" "$@" \
    || die "offline image bundle missing or corrupt: $bundle; run cache-assets.sh"
  command -v docker >/dev/null 2>&1 || die "controller cell image preload requires docker"
  [ "${CKA_CONTROLLER_IMAGE_PRELOAD:-kind}" = kind ] \
    || die "controller image preload cannot be disabled"
  command -v kind >/dev/null 2>&1 || die "controller cell image preload requires kind"
  command -v timeout >/dev/null 2>&1 || die "controller cell image preload requires timeout"
  cluster_name="$(controller_kind_name)" \
    || die "set CKA_CELL_KIND_NAME for a non kind-* context"
  # Import the already verified archive directly. Avoiding a host image-store
  # keeps correctness independent of Docker's classic vs containerd image-store
  # representation and prevents the archive from retagging unrelated host images.
  controller_external_timeout 300s kind load image-archive \
    --name "$cluster_name" "$bundle_path" >/dev/null \
    || die "controller image archive import failed or exceeded 300s"
  # Re-check after the external import before publishing canonical digest
  # aliases in case selection or sealed topology changed while it was running.
  controller_require_disposable_cell "${CKA_CELL_QID:-}" "${CKA_CELL_ENVIRONMENT:-}"
  cell_manifest_load "$CKA_CELL_QID" || die "controller cell manifest disappeared during image load"
  while IFS= read -r role; do
    [ "$role" = lb ] && continue
    node_id="${CELL_CONTAINER_IDS[$role]:-}"
    cell_docker_id_valid "$node_id" || die "controller cell node id is invalid: $role"
    for image in "$@"; do
      controller_node_publish_pinned_ref "$node_id" "$image" \
        || die "locked controller image manifest/config or canonical digest reference was not imported into $role: $image"
    done
  done < <(cell_expected_roles "$CELL_PROFILE")
}

controller_apply_local_manifest() { # cert-manager | gateway-api | envoy-gateway
  case "$1" in cert-manager|envoy-gateway) ;; *)
    die "unsupported pinned controller manifest: $1" ;;
  esac
  controller_pinned_manifest_render "$1" \
    | kctx apply --server-side --force-conflicts -f - >/dev/null \
    || die "locked pinned manifest could not be applied: $1"
}

controller_apply_crds_only() { # manifest profile
  local path
  controller_manifest_verify "$1" || die "locked manifest missing or corrupt: $1"
  path="$(controller_asset_path "$1")"
  awk '
    function emit() {
      if (doc ~ /(^|\n)kind:[ \t]*CustomResourceDefinition[ \t]*(\r?\n|$)/) {
        print "---"; printf "%s", doc
      }
    }
    /^---[ \t]*\r?$/ { emit(); doc=""; next }
    { doc=doc $0 ORS }
    END { emit() }
  ' "$path" | kctx apply --server-side --force-conflicts -f - >/dev/null
}

controller_publish_candidate_asset() { # profile <destination>
  local destination="$2" tmp
  case "$1" in cert-manager|envoy-gateway) ;; *)
    die "unsupported candidate controller manifest: $1" ;;
  esac
  mkdir -p "$(dirname "$destination")"
  tmp="${destination}.tmp.$$"
  if ! controller_pinned_manifest_render "$1" > "$tmp"; then
    rm -f -- "$tmp"
    die "locked pinned candidate manifest could not be rendered: $1"
  fi
  chmod 0444 "$tmp"
  mv -f "$tmp" "$destination"
}

controller_deployment_runtime_locked() { # namespace deployment container locked-tag
  local namespace="$1" deployment="$2" container="$3" image="$4"
  local pinned manifest_digest config_digest
  pinned="$(controller_pinned_image_ref "$image")" || return 1
  manifest_digest="$(controller_expected_manifest_digest "$image")" || return 1
  config_digest="$(controller_expected_image_id "$image")" || return 1
  {
    kctx -n "$namespace" get deployment "$deployment" -o json 2>/dev/null || return 1
    kctx -n "$namespace" get pods -o json 2>/dev/null || return 1
  } | python3 -c '
import json,sys
decoder=json.JSONDecoder(); text=sys.stdin.read(); pos=0; values=[]
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    value,pos=decoder.raw_decode(text,pos); values.append(value)
if len(values) != 2: raise SystemExit(1)
deployment,pod_list=values; container,pinned,manifest_digest,config_digest=sys.argv[1:5]

def canonical_repo(value):
    value=value.removeprefix("docker-pullable://").removeprefix("containerd://")
    value=value.split("@",1)[0]
    slash=value.rfind("/"); colon=value.rfind(":")
    if colon > slash: value=value[:colon]
    first=value.split("/",1)[0]
    if "." not in first and ":" not in first and first != "localhost":
        value=("docker.io/"+value) if "/" in value else ("docker.io/library/"+value)
    return value

expected_repo=canonical_repo(pinned)
def runtime_id_locked(value):
    if not isinstance(value,str): return False
    value=value.removeprefix("docker-pullable://").removeprefix("containerd://")
    if value == config_digest: return True
    if "@" not in value: return False
    repo,digest=value.rsplit("@",1)
    return canonical_repo(repo)==expected_repo and digest==manifest_digest

spec=deployment.get("spec",{}); template=spec.get("template",{}).get("spec",{})
containers=template.get("containers",[])
matches=[item for item in containers if item.get("name")==container]
if len(matches)!=1 or matches[0].get("image")!=pinned or matches[0].get("imagePullPolicy")!="Never":
    raise SystemExit(1)
selector=spec.get("selector",{}).get("matchLabels",{})
desired=spec.get("replicas",1)
if not isinstance(selector,dict) or not selector or not isinstance(desired,int) or desired < 1:
    raise SystemExit(1)
pods=[]
for pod in pod_list.get("items",[]):
    meta=pod.get("metadata",{}); labels=meta.get("labels",{})
    if meta.get("deletionTimestamp") is None and all(labels.get(k)==v for k,v in selector.items()):
        pods.append(pod)
if len(pods) < desired: raise SystemExit(1)
for pod in pods:
    pod_spec=pod.get("spec",{}); statuses=pod.get("status",{}).get("containerStatuses",[])
    pod_containers=[item for item in pod_spec.get("containers",[]) if item.get("name")==container]
    pod_statuses=[item for item in statuses if item.get("name")==container]
    if (pod.get("status",{}).get("phase")!="Running" or len(pod_containers)!=1
        or pod_containers[0].get("image")!=pinned or pod_containers[0].get("imagePullPolicy")!="Never"
        or len(pod_statuses)!=1 or pod_statuses[0].get("ready") is not True
        or not runtime_id_locked(pod_statuses[0].get("imageID"))):
        raise SystemExit(1)
' "$container" "$pinned" "$manifest_digest" "$config_digest"
}

controller_cert_manager_runtime_locked() {
  controller_deployment_runtime_locked cert-manager cert-manager \
    cert-manager-controller "$CERT_MANAGER_CONTROLLER_IMAGE" \
    && controller_deployment_runtime_locked cert-manager cert-manager-cainjector \
      cert-manager-cainjector "$CERT_MANAGER_CAINJECTOR_IMAGE" \
    && controller_deployment_runtime_locked cert-manager cert-manager-webhook \
      cert-manager-webhook "$CERT_MANAGER_WEBHOOK_IMAGE"
}

controller_cert_manager_webhook_endpoint_ready() {
  kctx -n cert-manager get endpointslices \
    -l kubernetes.io/service-name=cert-manager-webhook -o json 2>/dev/null \
    | python3 -c '
import json,sys
items=(json.load(sys.stdin).get("items") or [])
ready=any(
    (endpoint.get("conditions") or {}).get("ready") in (None, True)
    and bool(endpoint.get("addresses"))
    for item in items
    for endpoint in (item.get("endpoints") or [])
)
raise SystemExit(0 if ready else 1)
'
}

controller_cert_manager_diagnostic_summary() {
  err "cert-manager readiness summary follows (no Secret data is printed)"
  kctx -n cert-manager get deployments \
    -o custom-columns='NAME:.metadata.name,AVAILABLE:.status.availableReplicas,IMAGE:.spec.template.spec.containers[*].image' \
    >&2 || true
  kctx -n cert-manager get pods \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,IMAGE:.spec.containers[*].image,IMAGE-ID:.status.containerStatuses[*].imageID' \
    >&2 || true
  kctx -n cert-manager get endpointslices \
    -l kubernetes.io/service-name=cert-manager-webhook -o wide >&2 || true
}

controller_envoy_gateway_runtime_locked() {
  controller_deployment_runtime_locked envoy-gateway-system envoy-gateway \
    envoy-gateway "$ENVOY_GATEWAY_IMAGE"
}

controller_cell_node_images_locked() { # controller profile
  local profile="$1" role node_id image
  local -a images=()
  case "$profile" in
    cert-manager-configure|cert-manager-install)
      images=("$CERT_MANAGER_CONTROLLER_IMAGE" "$CERT_MANAGER_WEBHOOK_IMAGE" \
        "$CERT_MANAGER_CAINJECTOR_IMAGE")
      ;;
    envoy-gateway)
      images=("$ENVOY_GATEWAY_IMAGE" "$ENVOY_PROXY_IMAGE" "$ENVOY_RATELIMIT_IMAGE" \
        "$GATEWAY_BACKEND_IMAGE" "$GATEWAY_PROBE_IMAGE")
      ;;
    *) return 1 ;;
  esac
  while IFS= read -r role; do
    [ "$role" = lb ] && continue
    node_id="${CELL_CONTAINER_IDS[$role]:-}"
    cell_docker_id_valid "$node_id" || return 1
    for image in "${images[@]}"; do
      controller_node_image_id_matches "$node_id" "$image" || return 1
    done
  done < <(cell_expected_roles "$CELL_PROFILE")
}

controller_wait_cert_manager() {
  local attempt endpoint_ready=0
  if ! kctx -n cert-manager wait --for=condition=Available \
      deployment/cert-manager deployment/cert-manager-cainjector \
      deployment/cert-manager-webhook --timeout=180s >/dev/null; then
    err "cert-manager deployments did not all become Available within 180 seconds"
    controller_cert_manager_diagnostic_summary
    return 1
  fi
  # Deployment availability and EndpointSlice publication are separate
  # controller observations. Give the webhook endpoint a short bounded window
  # instead of treating that expected convergence gap as an unexplained setup
  # failure.
  for attempt in $(seq 1 30); do
    if controller_cert_manager_webhook_endpoint_ready; then
      endpoint_ready=1
      break
    fi
    sleep 1
  done
  if [ "$endpoint_ready" -ne 1 ]; then
    err "cert-manager webhook has no Ready EndpointSlice address after 30 seconds"
    controller_cert_manager_diagnostic_summary
    return 1
  fi
  if ! controller_cert_manager_runtime_locked; then
    err "cert-manager Deployment or Pod image identity differs from the locked digest/pull policy"
    controller_cert_manager_diagnostic_summary
    return 1
  fi
}

controller_wait_envoy_gateway() {
  kctx -n envoy-gateway-system wait --for=condition=Available \
    deployment/envoy-gateway --timeout=240s >/dev/null
  kctx wait --for=condition=Established \
    crd/gateways.gateway.networking.k8s.io \
    crd/httproutes.gateway.networking.k8s.io \
    crd/envoyproxies.gateway.envoyproxy.io --timeout=120s >/dev/null
  controller_envoy_gateway_runtime_locked
}

controller_gateway_bundle_is_locked() {
  local version channel
  version="$(kctx get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null)" \
    || return 1
  channel="$(kctx get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}' 2>/dev/null)" \
    || return 1
  [ "$version" = "$CONTROLLER_GATEWAY_API_VERSION" ] \
    && [ "$channel" = experimental ]
}

controller_envoy_profile_is_locked() {
  local pinned json
  pinned="$(controller_pinned_image_ref "$ENVOY_PROXY_IMAGE")" || return 1
  json="$(kctx -n envoy-gateway-system get envoyproxy cka-clusterip -o json 2>/dev/null)" \
    || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
spec=json.load(sys.stdin).get("spec",{}); kubernetes=spec.get("provider",{}).get("kubernetes",{})
deployment=kubernetes.get("envoyDeployment",{}); container=deployment.get("container",{})
patch=deployment.get("patch",{}); value=patch.get("value",{})
containers=value.get("spec",{}).get("template",{}).get("spec",{}).get("containers",[])
ok=(container.get("image")==sys.argv[1] and patch.get("type")=="StrategicMerge"
    and len(containers)==1 and containers[0].get("name")=="envoy"
    and containers[0].get("imagePullPolicy")=="Never")
raise SystemExit(0 if ok else 1)
' "$pinned"
}

controller_profile_for() { # <qid> <environment>
  local qid="$1" environment="$2"
  case "$qid|$environment" in
    ca-09\|operator-cell|ca-09\|operator-configure|ca-09\|cert-manager-configure) printf '%s\n' cert-manager-configure ;;
    ca-13\|operator-cell|ca-13\|operator-install|ca-13\|cert-manager-install) printf '%s\n' cert-manager-install ;;
    sn-05\|gateway-cell|sn-05\|gateway-data-path|sn-05\|envoy-gateway) printf '%s\n' envoy-gateway ;;
    *) return 1 ;;
  esac
}

# Stable integration API for the generic disposable-cell adapter.
controller_cell_prepare() { # <qid> <environment>
  local profile
  profile="$(controller_profile_for "$1" "$2")" \
    || die "unsupported controller cell profile: $1/$2"
  controller_require_disposable_cell "$1" "$2"
  require_cluster_readonly
  case "$profile" in
    cert-manager-configure)
      controller_assets_verify cert-manager \
        || die "cert-manager offline assets are not ready"
      controller_bundle_load_into_cell "$CERT_MANAGER_IMAGES_BUNDLE" \
        "$CERT_MANAGER_CONTROLLER_IMAGE" "$CERT_MANAGER_WEBHOOK_IMAGE" \
        "$CERT_MANAGER_CAINJECTOR_IMAGE"
      controller_apply_local_manifest cert-manager
      ;;
    cert-manager-install)
      controller_assets_verify cert-manager \
        || die "cert-manager offline assets are not ready"
      controller_bundle_load_into_cell "$CERT_MANAGER_IMAGES_BUNDLE" \
        "$CERT_MANAGER_CONTROLLER_IMAGE" "$CERT_MANAGER_WEBHOOK_IMAGE" \
        "$CERT_MANAGER_CAINJECTOR_IMAGE"
      controller_apply_crds_only cert-manager
      ;;
    envoy-gateway)
      controller_assets_verify envoy-gateway \
        || die "Envoy Gateway offline assets are not ready"
      controller_bundle_load_into_cell "$ENVOY_GATEWAY_IMAGES_BUNDLE" \
        "$ENVOY_GATEWAY_IMAGE" "$ENVOY_PROXY_IMAGE" "$ENVOY_RATELIMIT_IMAGE"
      controller_bundle_load_into_cell "$GATEWAY_WORKLOAD_BUNDLE" \
        "$GATEWAY_BACKEND_IMAGE" "$GATEWAY_PROBE_IMAGE"
      # The exact Envoy v1.9.0 install asset already embeds its compatible
      # Gateway API v1.6.1 experimental bundle. Applying the separately cached
      # Standard bundle first would trigger Gateway API's safe-upgrade policy.
      controller_apply_local_manifest envoy-gateway
      ;;
  esac
}

controller_cell_activate() { # <qid> <environment>
  local profile
  profile="$(controller_profile_for "$1" "$2")" \
    || die "unsupported controller cell profile: $1/$2"
  controller_require_disposable_cell "$1" "$2"
  controller_cell_node_images_locked "$profile" \
    || die "controller cell node image identity drifted from the lock"
  case "$profile" in
    cert-manager-configure) controller_wait_cert_manager ;;
    cert-manager-install)
      kctx wait --for=condition=Established \
        crd/certificates.cert-manager.io crd/issuers.cert-manager.io \
        --timeout=120s >/dev/null
      ;;
    envoy-gateway)
      controller_wait_envoy_gateway
      controller_gateway_bundle_is_locked \
        || die "Envoy cell did not install the locked Gateway API bundle"
      kctx apply --server-side --force-conflicts \
        -f "$CONTROLLER_ROOT/profiles/envoy-clusterip.yaml" >/dev/null
      controller_envoy_profile_is_locked \
        || die "Envoy data-plane image profile drifted from the lock"
      ;;
  esac
}

controller_cell_status() { # <qid> <environment>
  local profile
  profile="$(controller_profile_for "$1" "$2")" || return 1
  controller_require_disposable_cell "$1" "$2"
  controller_cell_node_images_locked "$profile" || return 1
  case "$profile" in
    cert-manager-configure) controller_wait_cert_manager >/dev/null ;;
    cert-manager-install)
      kctx wait --for=condition=Established \
        crd/certificates.cert-manager.io crd/issuers.cert-manager.io \
        --timeout=5s >/dev/null 2>&1 \
        && ! kctx -n cert-manager get deployment cert-manager >/dev/null 2>&1
      ;;
    envoy-gateway)
      controller_wait_envoy_gateway >/dev/null \
        && controller_gateway_bundle_is_locked \
        && controller_envoy_profile_is_locked \
        && [ "$(kctx get gatewayclass envoy-cka -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" = True ]
      ;;
  esac
}

controller_cleanup_kubectl() { # <kubectl arguments...>
  local timeout_bin kubectl_bin
  timeout_bin="$(type -P timeout)" || {
    err "controller cleanup requires GNU timeout"
    return 127
  }
  kubectl_bin="$(type -P kubectl)" || {
    err "controller cleanup requires kubectl"
    return 127
  }

  # --request-timeout bounds a single API request.  The outer process timeout
  # also bounds client-side discovery, authentication plugins, DNS and a
  # kubectl process that does not honor TERM.  --kill-after keeps that outer
  # bound finite even if the child ignores the initial signal.
  "$timeout_bin" --foreground --kill-after=2s 10s \
    "$kubectl_bin" --context "$CKA_CONTEXT" --request-timeout=5s "$@"
}

controller_cleanup_delete_manifest() { # <description> <manifest-path>
  local description="$1" manifest="$2" rc=0
  controller_cleanup_kubectl delete -f "$manifest" \
    --ignore-not-found --wait=false >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    err "controller cleanup failed for $description (exit $rc); continuing remaining cleanup steps"
  fi
  return "$rc"
}

controller_cell_cleanup() { # <qid> <environment>
  local profile failed=0
  profile="$(controller_profile_for "$1" "$2")" \
    || die "unsupported controller cell profile: $1/$2"
  controller_require_disposable_cell "$1" "$2"
  case "$profile" in
    cert-manager-configure|cert-manager-install)
      controller_cleanup_delete_manifest \
        "cert-manager manifest" "$(controller_asset_path cert-manager)" \
        || failed=$((failed+1))
      ;;
    envoy-gateway)
      controller_cleanup_delete_manifest \
        "EnvoyProxy profile" "$CONTROLLER_ROOT/profiles/envoy-clusterip.yaml" \
        || failed=$((failed+1))
      controller_cleanup_delete_manifest \
        "Envoy Gateway manifest" "$(controller_asset_path envoy-gateway)" \
        || failed=$((failed+1))
      controller_cleanup_delete_manifest \
        "Gateway API manifest" "$(controller_asset_path gateway-api)" \
        || failed=$((failed+1))
      ;;
  esac
  return "$failed"
}

controller_tls_secret_valid() { # <namespace> <secret> <dns-name>
  local dir cert key cert_pub key_pub host_ok
  command -v openssl >/dev/null 2>&1 || return 2
  dir="$(mktemp -d "${TMPDIR:-/tmp}/cka-tls-check.XXXXXX")" || return 2
  chmod 0700 "$dir"
  cert="$dir/tls.crt"; key="$dir/tls.key"
  if ! kctx -n "$1" get secret "$2" -o jsonpath='{.data.tls\.crt}' \
      | base64 -d > "$cert" 2>/dev/null \
      || ! kctx -n "$1" get secret "$2" -o jsonpath='{.data.tls\.key}' \
      | base64 -d > "$key" 2>/dev/null; then
    rm -f -- "$cert" "$key"; rmdir -- "$dir" 2>/dev/null || true
    return 1
  fi
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}')"
  if openssl x509 -in "$cert" -noout -checkhost "$3" >/dev/null 2>&1; then
    host_ok=0
  else
    host_ok=1
  fi
  rm -f -- "$cert" "$key"; rmdir -- "$dir" 2>/dev/null || true
  [ "$host_ok" -eq 0 ] && [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ]
}
