#!/usr/bin/env bash
# Trusted online preparation. The exercise runtime only consumes this bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/csi.sh
source "$ROOT/lib/csi.sh"

for command_name in docker grep sha256sum mktemp install; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "CSI cache preparation requires $command_name"
done

[ "$(csi_host_platform)" = "$CSI_PLATFORM" ] \
  || die "locked CSI bundle supports $CSI_PLATFORM only"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cka-csi-cache.XXXXXX")"
cleanup_tmp() {
  case "$tmp" in
    "${TMPDIR:-/tmp}"/cka-csi-cache.*) rm -rf -- "$tmp" ;;
    *) warn "refusing to remove unexpected temporary path: $tmp" ;;
  esac
}
trap cleanup_tmp EXIT

declare -a locked_tags=()
while IFS='|' read -r image digest image_id; do
  repository="${image%:*}"
  ref="${repository}@${digest}"
  docker pull --platform "$CSI_PLATFORM" "$ref" >/dev/null
  [ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$ref")" = \
      "$CSI_PLATFORM" ] \
    || die "CSI image platform mismatch: $ref"
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" \
    | grep -Fxq "$ref" || die "CSI child manifest digest mismatch: $ref"
  docker image tag "$ref" "$image"
  locked_tags+=("$image")
done < <(csi_locked_images)

docker image save --platform "$CSI_PLATFORM" \
  --output "$tmp/$CSI_IMAGE_BUNDLE" "${locked_tags[@]}"
csi_archive_verify "$tmp/$CSI_IMAGE_BUNDLE" \
  || die "generated CSI image archive failed locked semantic verification"
sha256sum "$tmp/$CSI_IMAGE_BUNDLE" | awk '{print $1}' \
  > "$tmp/$CSI_IMAGE_BUNDLE.sha256"

mkdir -p "$CSI_ASSET_DIR"
install -m 0644 "$tmp/$CSI_IMAGE_BUNDLE" "$CSI_ASSET_DIR/$CSI_IMAGE_BUNDLE"
install -m 0644 "$tmp/$CSI_IMAGE_BUNDLE.sha256" \
  "$CSI_ASSET_DIR/$CSI_IMAGE_BUNDLE.sha256"
csi_bundle_verify
ok "CSI image bundle cached: $CSI_ASSET_DIR/$CSI_IMAGE_BUNDLE"
