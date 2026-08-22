#!/usr/bin/env bash
# Offline CSI cell assets and runner-facing lifecycle hooks.

if [ -z "${CKA_ROOT:-}" ]; then
  CKA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=common.sh
source "$CKA_ROOT/lib/common.sh"

CSI_ROOT="${CSI_ROOT:-$CKA_ROOT/cluster/csi}"
CSI_LOCK="${CSI_LOCK:-$CSI_ROOT/assets.lock}"
CSI_ASSET_DIR="${CSI_ASSET_DIR:-$CSI_ROOT/assets}"
CSI_DRIVER_MANIFEST_PATH="$CSI_ROOT/csi-hostpath-driver.yaml"
CSI_ARCHIVE_VERIFIER="$CKA_ROOT/cluster/controllers/verify-oci-archive.py"

csi_lock_get() { # <key>
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
  ' "$CSI_LOCK"
}

_csi_assign() { # <shell-var> <lock-key>
  local value
  value="$(csi_lock_get "$2")" || die "CSI lock key missing or invalid: $2"
  printf -v "$1" '%s' "$value"
  export "$1"
}

csi_lock_load() {
  [ -r "$CSI_LOCK" ] || die "CSI asset lock unavailable: $CSI_LOCK"
  _csi_assign CSI_LOCK_SCHEMA schema_version
  _csi_assign CSI_SOURCE_REPOSITORY source_repository
  _csi_assign CSI_SOURCE_TAG source_tag
  _csi_assign CSI_SOURCE_COMMIT source_commit
  _csi_assign CSI_PLATFORM platform
  _csi_assign CSI_DRIVER_MANIFEST driver_manifest
  _csi_assign CSI_DRIVER_MANIFEST_SHA256 driver_manifest_sha256
  _csi_assign CSI_IMAGE_BUNDLE image_bundle
  _csi_assign CSI_HOSTPATH_IMAGE hostpath_image
  _csi_assign CSI_HOSTPATH_DIGEST hostpath_digest
  _csi_assign CSI_HOSTPATH_IMAGE_ID hostpath_image_id
  _csi_assign CSI_REGISTRAR_IMAGE registrar_image
  _csi_assign CSI_REGISTRAR_DIGEST registrar_digest
  _csi_assign CSI_REGISTRAR_IMAGE_ID registrar_image_id
  _csi_assign CSI_LIVENESS_IMAGE liveness_image
  _csi_assign CSI_LIVENESS_DIGEST liveness_digest
  _csi_assign CSI_LIVENESS_IMAGE_ID liveness_image_id
  _csi_assign CSI_PROVISIONER_IMAGE provisioner_image
  _csi_assign CSI_PROVISIONER_DIGEST provisioner_digest
  _csi_assign CSI_PROVISIONER_IMAGE_ID provisioner_image_id
  _csi_assign CSI_ATTACHER_IMAGE attacher_image
  _csi_assign CSI_ATTACHER_DIGEST attacher_digest
  _csi_assign CSI_ATTACHER_IMAGE_ID attacher_image_id

  [ "$CSI_LOCK_SCHEMA" = 2 ] || die "unsupported CSI lock schema"
  [ "$CSI_SOURCE_REPOSITORY" = \
      "https://github.com/kubernetes-csi/csi-driver-host-path" ] \
    || die "unexpected CSI source repository"
  [[ "$CSI_SOURCE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "invalid CSI source tag"
  [[ "$CSI_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "invalid CSI source commit"
  [[ "$CSI_PLATFORM" =~ ^linux/(amd64|arm64)$ ]] || die "invalid CSI platform"
  [ "$CSI_DRIVER_MANIFEST" = csi-hostpath-driver.yaml ] \
    || die "unexpected CSI manifest name"
  [[ "$CSI_DRIVER_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "invalid CSI manifest checksum"
  [[ "$CSI_IMAGE_BUNDLE" =~ ^[A-Za-z0-9._-]+\.tar$ ]] \
    || die "invalid CSI image bundle name"

  local image digest image_id
  while IFS='|' read -r image digest image_id; do
    [[ "$image" =~ ^registry\.k8s\.io/sig-storage/[a-z0-9-]+:v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die "invalid CSI image reference: $image"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || die "invalid CSI image digest: $digest"
    [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || die "invalid CSI image config ID: $image_id"
  done < <(csi_locked_images)
}

csi_locked_images() {
  printf '%s|%s|%s\n' \
    "$CSI_HOSTPATH_IMAGE" "$CSI_HOSTPATH_DIGEST" "$CSI_HOSTPATH_IMAGE_ID" \
    "$CSI_REGISTRAR_IMAGE" "$CSI_REGISTRAR_DIGEST" "$CSI_REGISTRAR_IMAGE_ID" \
    "$CSI_LIVENESS_IMAGE" "$CSI_LIVENESS_DIGEST" "$CSI_LIVENESS_IMAGE_ID" \
    "$CSI_PROVISIONER_IMAGE" "$CSI_PROVISIONER_DIGEST" "$CSI_PROVISIONER_IMAGE_ID" \
    "$CSI_ATTACHER_IMAGE" "$CSI_ATTACHER_DIGEST" "$CSI_ATTACHER_IMAGE_ID"
}

csi_host_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "$os" "$arch"
}

csi_sha256_matches() { # <path> <sha256>
  local actual
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  actual="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')" || return 1
  [ "$actual" = "$2" ]
}

csi_manifest_verify() {
  csi_sha256_matches "$CSI_DRIVER_MANIFEST_PATH" "$CSI_DRIVER_MANIFEST_SHA256"
}

csi_archive_verify() { # <archive>
  local image digest image_id
  local -a locked=()
  [ -f "$1" ] && [ ! -L "$1" ] \
    && [ -f "$CSI_ARCHIVE_VERIFIER" ] && [ ! -L "$CSI_ARCHIVE_VERIFIER" ] \
    || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  while IFS='|' read -r image digest image_id; do
    locked+=("$image" "$digest" "$image_id")
  done < <(csi_locked_images)
  python3 "$CSI_ARCHIVE_VERIFIER" "$1" "$CSI_PLATFORM" "${locked[@]}"
}

csi_bundle_verify() {
  local bundle checksum expected
  bundle="$CSI_ASSET_DIR/$CSI_IMAGE_BUNDLE"
  checksum="$bundle.sha256"
  [ -f "$bundle" ] && [ ! -L "$bundle" ] \
    && [ -f "$checksum" ] && [ ! -L "$checksum" ] || return 1
  expected="$(tr -d '\r\n' < "$checksum")" || return 1
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  csi_sha256_matches "$bundle" "$expected" || return 1
  csi_archive_verify "$bundle"
}

csi_disposable_context() {
  # Reload the trusted implementation so an inherited shell function cannot
  # downgrade the active-selection and sealed-manifest checks.
  # shellcheck source=cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  cell_active_identity_matches st-06 csi-cell
}

csi_require_disposable_cell() { # [qid] [environment]
  local qid="${1:-st-06}" environment="${2:-csi-cell}"
  [ "$qid" = st-06 ] && [ "$environment" = csi-cell ] \
    && csi_disposable_context \
    || die "CSI mutation requires the selected native disposable st-06 cell"
}

csi_cell_cluster_name() {
  csi_disposable_context || return 1
  printf '%s\n' "$CELL_CLUSTER_NAME"
}

csi_external_timeout() { timeout --foreground --kill-after=5s "$@"; }
csi_docker() { csi_external_timeout 45s docker "$@"; }

csi_node_image_matches() { # <node> <reference> <config-id> [repo-digest]
  local expected_repo_digest="${4:-}"
  csi_docker exec "$1" crictl inspecti "$2" 2>/dev/null | python3 -c '
import json,sys
try:
    obj=json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(1)
status=obj.get("status") or {}
image_id=status.get("id", "")
digests=status.get("repoDigests") or status.get("RepoDigests") or []
expected_id,expected_repo_digest=sys.argv[1:3]
ok=(image_id == expected_id and isinstance(digests, list)
    and (not expected_repo_digest or expected_repo_digest in digests))
raise SystemExit(0 if ok else 1)
' "$3" "$expected_repo_digest"
}

csi_node_ref_manifest_matches() { # <node> <reference> <manifest-digest>
  csi_docker exec "$1" ctr --namespace=k8s.io images list "name==$2" 2>/dev/null \
    | python3 -c '
import sys
ref,digest=sys.argv[1:3]
rows=[]
for line in sys.stdin:
    fields=line.split()
    if len(fields) >= 3 and fields[0] == ref:
        rows.append(fields)
raise SystemExit(0 if len(rows) == 1 and rows[0][2] == digest else 1)
' "$2" "$3"
}

csi_node_manifest_config_matches() { # <node> <manifest-digest> <config-id>
  csi_docker exec "$1" ctr --namespace=k8s.io content get "$2" 2>/dev/null \
    | python3 -c '
import json,sys
obj=json.load(sys.stdin); config=obj.get("config") or {}
raise SystemExit(0 if config.get("digest") == sys.argv[1] else 1)
' "$3"
}

csi_node_publish_pinned_ref() { # <node> <tag> <manifest-digest> <config-id>
  local repository ref attempt
  repository="${2%:*}"
  ref="${repository}@${3}"

  # Prove the exact imported manifest/config before giving it the immutable
  # name consumed by the offline driver manifest.
  csi_node_ref_manifest_matches "$1" "$2" "$3" \
    && csi_node_manifest_config_matches "$1" "$3" "$4" \
    || return 1
  csi_docker exec "$1" ctr --namespace=k8s.io images tag --local --force \
    "$2" "$ref" >/dev/null 2>&1 || return 1

  # CRI consumes containerd metadata events asynchronously. Bound the wait and
  # verify both containerd's target and CRI's config/repository identity.
  for ((attempt=1; attempt<=30; attempt++)); do
    csi_node_ref_manifest_matches "$1" "$ref" "$3" \
      && csi_node_image_matches "$1" "$ref" "$4" "$ref" \
      && return 0
    sleep 1
  done
  return 1
}

csi_preload_images() {
  local cluster_name bundle nodes node image digest image_id count=0
  csi_bundle_verify \
    || die "CSI image bundle missing or corrupt; run cluster/csi/cache-images.sh"
  command -v kind >/dev/null 2>&1 || die "kind is required to preload CSI images"
  command -v docker >/dev/null 2>&1 || die "docker is required to preload CSI images"
  command -v timeout >/dev/null 2>&1 || die "timeout is required to preload CSI images"
  cluster_name="$(csi_cell_cluster_name)" || die "CSI cell name is unavailable"
  bundle="$CSI_ASSET_DIR/$CSI_IMAGE_BUNDLE"
  csi_external_timeout 300s kind load image-archive \
    --name "$cluster_name" "$bundle" >/dev/null \
    || die "CSI image archive import failed or exceeded 300s"
  nodes="$(csi_external_timeout 30s kind get nodes --name "$cluster_name")" \
    || die "CSI cell nodes are unavailable"
  [ -n "$nodes" ] || die "CSI cell has no nodes"
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    while IFS='|' read -r image digest image_id; do
      csi_node_publish_pinned_ref "$node" "$image" "$digest" "$image_id" \
        || die "locked CSI manifest/config or canonical digest reference was not imported into $node: $image"
    done < <(csi_locked_images)
    count=$((count + 1))
  done <<< "$nodes"
  [ "$count" -ge 1 ] || die "CSI image import was not verified"
}

csi_publish_candidate_asset() { # <destination>
  local destination="$1" tmp
  csi_manifest_verify || die "locked CSI driver manifest is corrupt"
  mkdir -p "$(dirname "$destination")"
  tmp="${destination}.tmp.$$"
  install -m 0444 "$CSI_DRIVER_MANIFEST_PATH" "$tmp"
  mv -f -- "$tmp" "$destination"
}

# Stable generic-runtime API.
csi_cell_prepare() { # <qid> <environment>
  [ "$1" = st-06 ] && [ "$2" = csi-cell ] \
    || die "unsupported CSI cell profile: $1/$2"
  csi_require_disposable_cell "$1" "$2"
  [ "$(csi_host_platform)" = "$CSI_PLATFORM" ] \
    || die "locked CSI bundle supports $CSI_PLATFORM only"
  csi_manifest_verify || die "locked CSI manifest verification failed"
  csi_preload_images
}

csi_cell_activate() { # <qid> <environment>
  [ "$1" = st-06 ] && [ "$2" = csi-cell ] && csi_disposable_context \
    || return 1
  cell_wait_api_ready "$1"
}

csi_cell_status() { # <qid> <environment>
  csi_cell_activate "$@" && csi_manifest_verify && csi_bundle_verify
}

csi_cell_cleanup() { # <qid> <environment>
  [ "$1" = st-06 ] && [ "$2" = csi-cell ] || return 1
  return 0
}

csi_lock_load
