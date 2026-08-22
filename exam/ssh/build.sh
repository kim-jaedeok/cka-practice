#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

base_image="${CKA_SSH_BASE_IMAGE:-cka-practice/ssh-base:v1}"
target_image="${CKA_SSH_TARGET_IMAGE:-cka-practice/ssh-target:v1}"

usage() {
  printf 'usage: %s [--base-image IMAGE] [--target-image IMAGE]\n' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-image) [ "$#" -ge 2 ] || ssh_exam_die '--base-image needs a value'; base_image="$2"; shift 2 ;;
    --target-image) [ "$#" -ge 2 ] || ssh_exam_die '--target-image needs a value'; target_image="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; ssh_exam_die "unknown argument: $1" ;;
  esac
done

ssh_exam_require_docker

docker_arch="$(docker info --format '{{.Architecture}}')"
case "$docker_arch" in
  x86_64|amd64) target_arch=amd64 ;;
  aarch64|arm64) target_arch=arm64 ;;
  *) ssh_exam_die "unsupported Docker architecture: $docker_arch" ;;
esac

# Each image receives only its narrow build context.  The repository and answer
# files therefore cannot be copied into the base image accidentally.
docker build --pull --tag "$base_image" "$SSH_REPO_ROOT/images/base"
docker build --pull --build-arg "TARGETARCH=$target_arch" \
  --tag "$target_image" "$SSH_REPO_ROOT/images/target"

ssh_exam_require_image_role "$base_image" base
ssh_exam_require_image_role "$target_image" target
ssh_exam_require_image_label "$target_image" org.cka-practice.tool.kubectl v1.35.0
ssh_exam_require_image_label "$target_image" org.cka-practice.tool.yq v4.48.2

printf 'built: %s\n' "$base_image"
printf 'built: %s\n' "$target_image"
