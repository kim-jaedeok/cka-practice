#!/usr/bin/env bash
# Parser and verifier for the real kubeadm upgrade package cache.

KUBEADM_PACKAGE_ROOT="${KUBEADM_PACKAGE_ROOT:-$CKA_ROOT/cluster/cells/kubeadm}"
KUBEADM_PACKAGE_LOCK="${KUBEADM_PACKAGE_LOCK:-$KUBEADM_PACKAGE_ROOT/packages.lock}"
KUBEADM_PACKAGE_CACHE="${KUBEADM_PACKAGE_CACHE:-$KUBEADM_PACKAGE_ROOT/packages}"

kubeadm_package_lock_get() {
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
  ' "$KUBEADM_PACKAGE_LOCK"
}

_kubeadm_package_assign() {
  local value
  value="$(kubeadm_package_lock_get "$2")" \
    || die "kubeadm package lock key missing: $2"
  printf -v "$1" '%s' "$value"
  export "$1"
}

kubeadm_package_lock_load() {
  [ -r "$KUBEADM_PACKAGE_LOCK" ] || die "package lock unavailable"
  _kubeadm_package_assign KUBEADM_PACKAGE_SCHEMA schema_version
  _kubeadm_package_assign KUBEADM_PACKAGE_ARCH architecture
  _kubeadm_package_assign KUBEADM_PACKAGE_FROM_VERSION from_version
  _kubeadm_package_assign KUBEADM_PACKAGE_TO_VERSION to_version
  _kubeadm_package_assign KUBEADM_PACKAGE_FROM_REPOSITORY from_repository
  _kubeadm_package_assign KUBEADM_PACKAGE_TO_REPOSITORY to_repository
  _kubeadm_package_assign KUBEADM_PAUSE_IMAGE pause_image
  _kubeadm_package_assign KUBEADM_PAUSE_DIGEST pause_digest
  _kubeadm_package_assign KUBEADM_PAUSE_IMAGE_ID pause_image_id
  _kubeadm_package_assign KUBEADM_PAUSE_BUNDLE pause_bundle
  _kubeadm_package_assign KUBEADM_WORKLOAD_BUNDLE workload_bundle
  _kubeadm_package_assign KUBEADM_WORKLOAD_NGINX_IMAGE workload_nginx_image
  _kubeadm_package_assign KUBEADM_WORKLOAD_NGINX_DIGEST workload_nginx_digest
  _kubeadm_package_assign KUBEADM_WORKLOAD_NGINX_IMAGE_ID workload_nginx_image_id
  _kubeadm_package_assign KUBEADM_WORKLOAD_BUSYBOX_IMAGE workload_busybox_image
  _kubeadm_package_assign KUBEADM_WORKLOAD_BUSYBOX_DIGEST workload_busybox_digest
  _kubeadm_package_assign KUBEADM_WORKLOAD_BUSYBOX_IMAGE_ID workload_busybox_image_id
  _kubeadm_package_assign KUBEADM_PACKAGE_CRI_TOOLS_FROM_VERSION cri_tools_from_version
  _kubeadm_package_assign KUBEADM_PACKAGE_CRI_TOOLS_TO_VERSION cri_tools_to_version
  _kubeadm_package_assign KUBEADM_PACKAGE_KUBERNETES_CNI_FROM_VERSION kubernetes_cni_from_version
  _kubeadm_package_assign KUBEADM_PACKAGE_KUBERNETES_CNI_TO_VERSION kubernetes_cni_to_version
  local package key side var file_var digest_var file digest expected_version
  for package in cri-tools kubernetes-cni kubeadm kubelet kubectl; do
    key="${package//-/_}"
    for side in from to; do
      var="${key^^}_${side^^}"
      _kubeadm_package_assign "KUBEADM_PACKAGE_${var}_FILE" "${key}_${side}_file"
      _kubeadm_package_assign "KUBEADM_PACKAGE_${var}_SHA256" "${key}_${side}_sha256"
    done
  done

  [ "$KUBEADM_PACKAGE_SCHEMA" = 1 ] && [ "$KUBEADM_PACKAGE_ARCH" = amd64 ] \
    || die "unsupported kubeadm package lock"
  [[ "$KUBEADM_PACKAGE_FROM_VERSION" =~ ^1\.34\.[0-9]+-1\.1$ ]] \
    && [[ "$KUBEADM_PACKAGE_TO_VERSION" =~ ^1\.35\.[0-9]+-1\.1$ ]] \
    || die "upgrade package versions must be adjacent 1.34 -> 1.35"
  [ "$KUBEADM_PACKAGE_FROM_REPOSITORY" = \
      "https://pkgs.k8s.io/core:/stable:/v1.34/deb" ] \
    && [ "$KUBEADM_PACKAGE_TO_REPOSITORY" = \
      "https://pkgs.k8s.io/core:/stable:/v1.35/deb" ] \
    || die "unexpected Kubernetes package repository"
  [ "$KUBEADM_PACKAGE_CRI_TOOLS_FROM_VERSION" = 1.34.0-1.1 ] \
    && [ "$KUBEADM_PACKAGE_CRI_TOOLS_TO_VERSION" = 1.35.0-1.1 ] \
    && [ "$KUBEADM_PACKAGE_KUBERNETES_CNI_FROM_VERSION" = 1.7.1-1.1 ] \
    && [ "$KUBEADM_PACKAGE_KUBERNETES_CNI_TO_VERSION" = 1.8.0-1.1 ] \
    || die "unexpected Kubernetes dependency package versions"
  [ "$KUBEADM_PAUSE_IMAGE" = registry.k8s.io/pause:3.10.1 ] \
    && [[ "$KUBEADM_PAUSE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [[ "$KUBEADM_PAUSE_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [ "$KUBEADM_PAUSE_BUNDLE" = kubeadm-pause-linux-amd64.tar ] \
    || die "invalid kubeadm pause image lock"
  [ "$KUBEADM_WORKLOAD_BUNDLE" = kubeadm-workloads-linux-amd64.tar ] \
    && [ "$KUBEADM_WORKLOAD_NGINX_IMAGE" = docker.io/library/nginx:1.29 ] \
    && [ "$KUBEADM_WORKLOAD_BUSYBOX_IMAGE" = docker.io/library/busybox:1.36 ] \
    && [[ "$KUBEADM_WORKLOAD_NGINX_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [[ "$KUBEADM_WORKLOAD_NGINX_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [[ "$KUBEADM_WORKLOAD_BUSYBOX_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [[ "$KUBEADM_WORKLOAD_BUSYBOX_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "invalid kubeadm workload image lock"
  for package in cri-tools kubernetes-cni kubeadm kubelet kubectl; do
    key="${package//-/_}"
    for side in FROM TO; do
      file_var="KUBEADM_PACKAGE_${key^^}_${side}_FILE"
      digest_var="KUBEADM_PACKAGE_${key^^}_${side}_SHA256"
      file="${!file_var}"
      digest="${!digest_var}"
      expected_version="$(kubeadm_package_version "$package" "$side")" \
        || die "package version mapping unavailable"
      [ "$file" = "${package}_${expected_version}_amd64.deb" ] \
        && [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "invalid package lock entry"
    done
  done
}

kubeadm_package_version() { # <package> <FROM|TO>
  local package="$1" side="$2" version_var
  case "$package" in
    cri-tools) version_var="KUBEADM_PACKAGE_CRI_TOOLS_${side}_VERSION" ;;
    kubernetes-cni) version_var="KUBEADM_PACKAGE_KUBERNETES_CNI_${side}_VERSION" ;;
    kubeadm|kubelet|kubectl) version_var="KUBEADM_PACKAGE_${side}_VERSION" ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${!version_var}"
}

kubeadm_package_entries() { # prints side|package|repository|file|sha
  local side package key repository file digest file_var digest_var
  for side in FROM TO; do
    if [ "$side" = FROM ]; then repository="$KUBEADM_PACKAGE_FROM_REPOSITORY"; else repository="$KUBEADM_PACKAGE_TO_REPOSITORY"; fi
    for package in cri-tools kubernetes-cni kubeadm kubelet kubectl; do
      key="${package//-/_}"
      file_var="KUBEADM_PACKAGE_${key^^}_${side}_FILE"
      digest_var="KUBEADM_PACKAGE_${key^^}_${side}_SHA256"
      file="${!file_var}"
      digest="${!digest_var}"
      printf '%s|%s|%s|%s|%s\n' "$side" "$package" "$repository" "$file" "$digest"
    done
  done
}

kubeadm_package_cache_verify() {
  local side package repository file digest actual count=0
  [ -d "$KUBEADM_PACKAGE_CACHE" ] && [ ! -L "$KUBEADM_PACKAGE_CACHE" ] || return 1
  while IFS='|' read -r side package repository file digest; do
    [ -f "$KUBEADM_PACKAGE_CACHE/$file" ] && [ ! -L "$KUBEADM_PACKAGE_CACHE/$file" ] \
      || return 1
    actual="$(sha256sum "$KUBEADM_PACKAGE_CACHE/$file" | awk '{print $1}')" || return 1
    [ "$actual" = "$digest" ] || return 1
    count=$((count + 1))
  done < <(kubeadm_package_entries)
  [ "$count" -eq 10 ] || return 1
  [ -f "$KUBEADM_PACKAGE_CACHE/SHA256SUMS" ] \
    && [ ! -L "$KUBEADM_PACKAGE_CACHE/SHA256SUMS" ] || return 1
  (cd "$KUBEADM_PACKAGE_CACHE" && sha256sum --check --strict SHA256SUMS >/dev/null)
}

kubeadm_pause_cache_verify() {
  local bundle="$KUBEADM_PACKAGE_CACHE/$KUBEADM_PAUSE_BUNDLE" expected actual
  [ -f "$bundle" ] && [ ! -L "$bundle" ] || return 1
  [ -f "$KUBEADM_PACKAGE_CACHE/SHA256SUMS" ] \
    && [ ! -L "$KUBEADM_PACKAGE_CACHE/SHA256SUMS" ] || return 1
  expected="$(awk -v file="$KUBEADM_PAUSE_BUNDLE" '$2 == file {count++; value=$1} END {if (count != 1) exit 1; print value}' \
    "$KUBEADM_PACKAGE_CACHE/SHA256SUMS")" || return 1
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "$bundle" | awk '{print $1}')" || return 1
  [ "$actual" = "$expected" ]
}

_kubeadm_bundle_cache_verify() { # <bundle-name>
  local name="$1" bundle="$KUBEADM_PACKAGE_CACHE/$1" expected actual
  [ -f "$bundle" ] && [ ! -L "$bundle" ] || return 1
  [ -f "$KUBEADM_PACKAGE_CACHE/SHA256SUMS" ] \
    && [ ! -L "$KUBEADM_PACKAGE_CACHE/SHA256SUMS" ] || return 1
  expected="$(awk -v file="$name" '$2 == file {count++; value=$1} END {if (count != 1) exit 1; print value}' \
    "$KUBEADM_PACKAGE_CACHE/SHA256SUMS")" || return 1
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "$bundle" | awk '{print $1}')" || return 1
  [ "$actual" = "$expected" ]
}

kubeadm_workload_cache_verify() {
  _kubeadm_bundle_cache_verify "$KUBEADM_WORKLOAD_BUNDLE"
}

kubeadm_package_lock_load
