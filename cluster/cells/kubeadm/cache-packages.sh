#!/usr/bin/env bash
# Trusted online preparation for ca-06. Runtime performs no package download.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKA_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$CKA_ROOT/lib/common.sh"
source "$SCRIPT_DIR/package-cache.sh"

for command_name in curl docker sha256sum mktemp install; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "package cache preparation requires $command_name"
done
[ "$(uname -m)" = x86_64 ] || die "locked package cache supports amd64 only"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cka-kubeadm-packages.XXXXXX")"
cleanup_tmp() {
  case "$tmp" in
    "${TMPDIR:-/tmp}"/cka-kubeadm-packages.*) rm -rf -- "$tmp" ;;
    *) warn "refusing unexpected temporary path: $tmp" ;;
  esac
}
trap cleanup_tmp EXIT

while IFS='|' read -r side package repository file digest; do
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
    --output "$tmp/$file" "$repository/amd64/$file"
  [ "$(sha256sum "$tmp/$file" | awk '{print $1}')" = "$digest" ] \
    || die "official package checksum mismatch: $file"
done < <(kubeadm_package_entries)

pause_repository="${KUBEADM_PAUSE_IMAGE%:*}"
pause_ref="$pause_repository@$KUBEADM_PAUSE_DIGEST"
docker pull --platform linux/amd64 "$pause_ref" >/dev/null
docker tag "$pause_ref" "$KUBEADM_PAUSE_IMAGE"
pause_actual_id="$(docker image inspect --format '{{.Id}}' "$KUBEADM_PAUSE_IMAGE")"
pause_repo_digests="$(docker image inspect --format \
  '{{range .RepoDigests}}{{println .}}{{end}}' "$KUBEADM_PAUSE_IMAGE")"
if [ "$pause_actual_id" != "$KUBEADM_PAUSE_DIGEST" ]; then
  [ "$pause_actual_id" = "$KUBEADM_PAUSE_IMAGE_ID" ] \
    && grep -Fxq "$pause_ref" <<<"$pause_repo_digests" \
    || die "official pause image identity mismatch"
fi
docker image save --platform linux/amd64 \
  --output "$tmp/$KUBEADM_PAUSE_BUNDLE" \
  "$KUBEADM_PAUSE_IMAGE"

for workload in nginx busybox; do
  case "$workload" in
    nginx)
      workload_image="$KUBEADM_WORKLOAD_NGINX_IMAGE"
      workload_digest="$KUBEADM_WORKLOAD_NGINX_DIGEST"
      workload_image_id="$KUBEADM_WORKLOAD_NGINX_IMAGE_ID"
      ;;
    busybox)
      workload_image="$KUBEADM_WORKLOAD_BUSYBOX_IMAGE"
      workload_digest="$KUBEADM_WORKLOAD_BUSYBOX_DIGEST"
      workload_image_id="$KUBEADM_WORKLOAD_BUSYBOX_IMAGE_ID"
      ;;
  esac
  workload_repository="${workload_image%:*}"
  workload_ref="$workload_repository@$workload_digest"
  docker pull --platform linux/amd64 "$workload_ref" >/dev/null
  docker tag "$workload_ref" "$workload_image"
  workload_actual_id="$(docker image inspect --format '{{.Id}}' "$workload_image")"
  workload_repo_digests="$(docker image inspect --format \
    '{{range .RepoDigests}}{{println .}}{{end}}' "$workload_image")"
  if [ "$workload_actual_id" != "$workload_digest" ]; then
    [ "$workload_actual_id" = "$workload_image_id" ] \
      && { grep -Fxq "$workload_ref" <<<"$workload_repo_digests" \
        || grep -Fxq "${workload_repository#docker.io/library/}@$workload_digest" \
          <<<"$workload_repo_digests"; } \
      || die "official workload image identity mismatch: $workload_image"
  fi
done
docker image save --platform linux/amd64 \
  --output "$tmp/$KUBEADM_WORKLOAD_BUNDLE" \
  "$KUBEADM_WORKLOAD_NGINX_IMAGE" "$KUBEADM_WORKLOAD_BUSYBOX_IMAGE"

(cd "$tmp" && sha256sum ./*.deb "./$KUBEADM_PAUSE_BUNDLE" \
  "./$KUBEADM_WORKLOAD_BUNDLE" \
  | sed 's|  \./|  |' | sort -k2 > SHA256SUMS)
mkdir -p "$KUBEADM_PACKAGE_CACHE"
while IFS='|' read -r side package repository file digest; do
  install -m 0644 "$tmp/$file" "$KUBEADM_PACKAGE_CACHE/$file"
done < <(kubeadm_package_entries)
install -m 0644 "$tmp/$KUBEADM_PAUSE_BUNDLE" \
  "$KUBEADM_PACKAGE_CACHE/$KUBEADM_PAUSE_BUNDLE"
install -m 0644 "$tmp/$KUBEADM_WORKLOAD_BUNDLE" \
  "$KUBEADM_PACKAGE_CACHE/$KUBEADM_WORKLOAD_BUNDLE"
install -m 0644 "$tmp/SHA256SUMS" "$KUBEADM_PACKAGE_CACHE/SHA256SUMS"

kubeadm_package_cache_verify
kubeadm_pause_cache_verify
kubeadm_workload_cache_verify
ok "real Kubernetes packages cached: $KUBEADM_PACKAGE_CACHE"
