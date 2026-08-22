#!/usr/bin/env bash
# 클러스터 애드온 설치·점검 단일 소스.
# setup-cluster.sh(최초 설치), cka cluster doctor(점검·복구),
# require_cluster(문제 시작 전 자동 자가치유)에서 공통으로 사용한다.
#
# 여기서 다루는 애드온은 "클러스터 생성 후 원격 매니페스트로 얹는" 취약 계층이다.
# (coredns·StorageClass는 노드 이미지 내장, Calico는 setup-cluster.sh가 직접 관리)
#
# 모든 install 함수는 kubectl apply 기반이라 멱등하다 — 이미 정상이어도 재호출은
# 무해(unchanged)하므로, 점검이 애매하면 그냥 install을 불러도 안전하다.

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.0}"
METRICS_SERVER_URL="${METRICS_SERVER_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml}"
INGRESS_NGINX_URL="${INGRESS_NGINX_URL:-https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml}"
CLOUD_PROVIDER_KIND_BIN="${CLOUD_PROVIDER_KIND_BIN:-$HOME/.local/bin/cloud-provider-kind}"
# The provider is a host-global process which watches every KIND cluster.  Keep
# its mutable ownership state on the native Linux filesystem, not below the repo
# on /mnt/c where DrvFS may ignore chmod metadata.
CLOUD_PROVIDER_KIND_STATE_ROOT="${CLOUD_PROVIDER_KIND_STATE_ROOT:-${XDG_RUNTIME_DIR:-$HOME/.local/state}/cka-practice}"
CLOUD_PROVIDER_KIND_RUNTIME_DIR="${CLOUD_PROVIDER_KIND_RUNTIME_DIR:-$CLOUD_PROVIDER_KIND_STATE_ROOT/cloud-provider-kind}"
CLOUD_PROVIDER_KIND_PID_FILE="$CLOUD_PROVIDER_KIND_RUNTIME_DIR/process"
CLOUD_PROVIDER_KIND_LOG_FILE="$CLOUD_PROVIDER_KIND_RUNTIME_DIR/provider.log"

# 자가치유 대상 애드온 목록 (순서 = 점검·복구 순서). "key|사람이 읽는 이름"
CKA_ADDONS=(
  "cloud_provider_kind|Cloud Provider KIND (working LoadBalancer data plane)"
  "metrics_server|metrics-server (kubectl top / HPA)"
  "ingress_nginx|ingress-nginx + IngressClass/nginx"
  "gateway_api|Gateway API CRD + GatewayClass/nginx"
  "grader_client|cka-system/grader-client (채점용)"
)

# ── Cloud Provider KIND ─────────────────────────────────────────
# KIND 자체에는 Service type=LoadBalancer 구현이 없다. 공식 host binary를
# exact release checksum으로 설치해 백그라운드에서 관리한다. 현재 lock의
# Gateway API v1.6 CRD보다 provider v0.11.1 내장 CRD가 오래됐으므로 Gateway
# controller는 명시적으로 끄고, 여기서는 LoadBalancer data plane만 맡긴다.
cloud_provider_kind_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s' amd64 ;;
    aarch64|arm64) printf '%s' arm64 ;;
    *) return 1 ;;
  esac
}

cloud_provider_kind_binary_sha() {
  case "$(cloud_provider_kind_arch 2>/dev/null || true)" in
    amd64) printf '%s' "$CLOUD_PROVIDER_KIND_LINUX_AMD64_BINARY_SHA256" ;;
    arm64) printf '%s' "$CLOUD_PROVIDER_KIND_LINUX_ARM64_BINARY_SHA256" ;;
    *) return 1 ;;
  esac
}

cloud_provider_kind_binary_ok() {
  local actual images expected_sha actual_sha
  [ -f "$CLOUD_PROVIDER_KIND_BIN" ] && [ ! -L "$CLOUD_PROVIDER_KIND_BIN" ] \
    && [ -x "$CLOUD_PROVIDER_KIND_BIN" ] || return 1
  expected_sha="$(cloud_provider_kind_binary_sha)" || return 1
  actual_sha="$(sha256sum "$CLOUD_PROVIDER_KIND_BIN" 2>/dev/null | awk '{print $1}')"
  [ "$actual_sha" = "$expected_sha" ] || return 1
  actual="$("$CLOUD_PROVIDER_KIND_BIN" version 2>/dev/null || true)"
  [ "$actual" = "cloud-provider-kind ${CLOUD_PROVIDER_KIND_VERSION#v}" ] || return 1
  images="$("$CLOUD_PROVIDER_KIND_BIN" list-images 2>/dev/null || true)"
  [ "$images" = "$CLOUD_PROVIDER_KIND_PROXY_IMAGE" ]
}

cloud_provider_kind_proxy_image_ok() {
  docker image inspect "$CLOUD_PROVIDER_KIND_PROXY_IMAGE" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
    | grep -Fxq -- "$CLOUD_PROVIDER_KIND_PROXY_REPO_DIGEST"
}

ensure_cloud_provider_kind_proxy_image() {
  cloud_provider_kind_proxy_image_ok && return 0
  docker pull "$CLOUD_PROVIDER_KIND_PROXY_IMAGE@${CLOUD_PROVIDER_KIND_PROXY_REPO_DIGEST#*@}" \
    >/dev/null 2>&1 || return 1
  docker tag "$CLOUD_PROVIDER_KIND_PROXY_IMAGE@${CLOUD_PROVIDER_KIND_PROXY_REPO_DIGEST#*@}" \
    "$CLOUD_PROVIDER_KIND_PROXY_IMAGE" >/dev/null 2>&1 || return 1
  cloud_provider_kind_proxy_image_ok
}

cloud_provider_kind_verified_cluster_lb_ids() { # <kind-cluster-name>; print preflighted immutable IDs
  local cluster="$1" ids candidate record object_id object_name expected_object_name actual_cluster lb_name extra lb_hash
  local lb_cluster lb_remainder lb_namespace lb_service
  _cloud_provider_kind_validate_cluster_name "$cluster" 2>/dev/null || return 1
  ids="$(cloud_provider_kind_cluster_lb_ids "$cluster")" || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [[ "$candidate" =~ ^[0-9a-f]{64}$ ]] || return 1
    record="$(docker container inspect --format \
      '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.x-k8s.cloud-provider-kind.cluster"}}|{{index .Config.Labels "io.x-k8s.cloud-provider-kind.loadbalancer.name"}}' \
      "$candidate" 2>/dev/null)" || return 1
    IFS='|' read -r object_id object_name actual_cluster lb_name extra <<< "$record"
    lb_cluster="${lb_name%%/*}"
    lb_remainder="${lb_name#*/}"
    lb_namespace="${lb_remainder%%/*}"
    lb_service="${lb_remainder#*/}"
    lb_hash="$(printf '%s' "$lb_name" | sha256sum 2>/dev/null)" || return 1
    lb_hash="${lb_hash%% *}"
    [[ "$lb_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    expected_object_name="/kindccm-${lb_hash:0:12}"
    [ -z "${extra:-}" ] \
      && [ "$object_id" = "$candidate" ] \
      && [ "$object_name" = "$expected_object_name" ] \
      && [ "$actual_cluster" = "$cluster" ] \
      && [ "$lb_cluster" = "$cluster" ] \
      && [ "$lb_remainder" != "$lb_name" ] \
      && [ "$lb_service" != "$lb_remainder" ] \
      && [[ "$lb_namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
      && [[ "$lb_service" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || return 1
    printf '%s\n' "$object_id"
  done <<< "$ids"
}

cloud_provider_kind_cluster_proxy_images_ok() { # <kind-cluster-name>; 0=healthy, 1=confirmed drift, 2=inventory unknown
  local cluster="$1" expected_image_id candidate record object_id image_id
  local running paused restarting extra ids unhealthy=0
  _cloud_provider_kind_validate_cluster_name "$cluster" 2>/dev/null || return 1
  expected_image_id="$(docker image inspect "$CLOUD_PROVIDER_KIND_PROXY_REPO_DIGEST" \
    --format '{{.Id}}' 2>/dev/null)" || return 2
  [[ "$expected_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 2
  ids="$(cloud_provider_kind_verified_cluster_lb_ids "$cluster")" || return 2
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    record="$(docker container inspect --format \
      '{{.Id}}|{{.Image}}|{{.State.Running}}|{{.State.Paused}}|{{.State.Restarting}}' \
      "$candidate" 2>/dev/null)" || return 2
    IFS='|' read -r object_id image_id running paused restarting extra <<< "$record"
    [ -z "${extra:-}" ] && [ "$object_id" = "$candidate" ] || return 2
    if [ "$image_id" = "$expected_image_id" ] \
        && [ "$running" = "true" ] \
        && [ "$paused" = "false" ] \
        && [ "$restarting" = "false" ]; then
      :
    else
      unhealthy=1
    fi
  done <<< "$ids"
  [ "$unhealthy" -eq 0 ]
}

_cloud_provider_kind_prepare_runtime() {
  local root_real runtime_real path owner mode
  case "$CLOUD_PROVIDER_KIND_STATE_ROOT:$CLOUD_PROVIDER_KIND_RUNTIME_DIR" in
    /*:/*) ;;
    *) warn "Cloud Provider KIND runtime 경로는 절대경로여야 합니다." >&2; return 1 ;;
  esac
  umask 077
  mkdir -p "$CLOUD_PROVIDER_KIND_STATE_ROOT" || return 1
  [ -d "$CLOUD_PROVIDER_KIND_STATE_ROOT" ] \
    && [ ! -L "$CLOUD_PROVIDER_KIND_STATE_ROOT" ] || {
      warn "Cloud Provider KIND state root가 안전한 디렉터리가 아닙니다." >&2
      return 1
    }
  root_real="$(realpath -e "$CLOUD_PROVIDER_KIND_STATE_ROOT" 2>/dev/null)" || return 1
  runtime_real="$(realpath -m "$CLOUD_PROVIDER_KIND_RUNTIME_DIR" 2>/dev/null)" || return 1
  case "$runtime_real" in
    "$root_real"/cloud-provider-kind) ;;
    *) warn "Cloud Provider KIND runtime이 전용 state root 밖입니다: $runtime_real" >&2; return 1 ;;
  esac
  mkdir -p "$runtime_real" || return 1
  [ -d "$runtime_real" ] && [ ! -L "$runtime_real" ] || return 1
  for path in "$root_real" "$runtime_real"; do
    owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    [ "$owner" = "$(id -u)" ] || {
      warn "Cloud Provider KIND state 경로 소유자가 현재 사용자와 다릅니다: $path" >&2
      return 1
    }
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    if (( (8#$mode & 0022) != 0 )); then
      chmod 700 "$path" 2>/dev/null || return 1
      mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
      (( (8#$mode & 0022) == 0 )) || {
        warn "Cloud Provider KIND state 경로 권한을 보호할 수 없습니다: $path ($mode)" >&2
        return 1
      }
    fi
  done
  CLOUD_PROVIDER_KIND_RUNTIME_DIR="$runtime_real"
  CLOUD_PROVIDER_KIND_PID_FILE="$runtime_real/process"
  CLOUD_PROVIDER_KIND_LOG_FILE="$runtime_real/provider.log"
}

_cloud_provider_kind_boot_id() {
  local boot_id
  IFS= read -r boot_id < /proc/sys/kernel/random/boot_id || return 1
  [[ "$boot_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || return 1
  printf '%s' "$boot_id"
}

_cloud_provider_kind_record() { # prints pid|start-time|boot-id|version|binary-sha
  [ -f "$CLOUD_PROVIDER_KIND_PID_FILE" ] \
    && [ ! -L "$CLOUD_PROVIDER_KIND_PID_FILE" ] || return 1
  local record pid start boot_id version sha extra
  IFS= read -r record < "$CLOUD_PROVIDER_KIND_PID_FILE" || return 1
  IFS='|' read -r pid start boot_id version sha extra <<< "$record"
  [ -z "${extra:-}" ] \
    && [[ "$pid" =~ ^[1-9][0-9]*$ ]] \
    && [[ "$start" =~ ^[1-9][0-9]*$ ]] \
    && [[ "$boot_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    && [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    && [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$record"
}

_cloud_provider_kind_process_owned() {
  local record pid expected_start record_boot record_version record_sha current_start owner exe first_arg args
  record="$(_cloud_provider_kind_record)" || return 1
  IFS='|' read -r pid expected_start record_boot record_version record_sha <<< "$record"
  [ "$record_boot" = "$(_cloud_provider_kind_boot_id)" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -r "/proc/$pid/stat" ] && [ -r "/proc/$pid/cmdline" ] || return 1
  current_start="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
  [ "$current_start" = "$expected_start" ] || return 1
  owner="$(stat -c '%u' "/proc/$pid" 2>/dev/null || true)"
  [ "$owner" = "$(id -u)" ] || return 1
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
  case "$exe" in
    "$CLOUD_PROVIDER_KIND_BIN"|"$CLOUD_PROVIDER_KIND_BIN (deleted)") ;;
    *) return 1 ;;
  esac
  first_arg="$(tr '\0' '\n' < "/proc/$pid/cmdline" | sed -n '1p')"
  [ "$first_arg" = "$CLOUD_PROVIDER_KIND_BIN" ] || return 1
  args="$(tr '\0' '\n' < "/proc/$pid/cmdline")"
  printf '%s\n' "$args" | grep -Fxq -- '--gateway-channel' || return 1
  printf '%s\n' "$args" | grep -Fxq -- 'disabled' || return 1
}

_cloud_provider_kind_controller_ready() {
  local server
  _cloud_provider_kind_process_owned || return 1
  [ -f "$CLOUD_PROVIDER_KIND_LOG_FILE" ] \
    && [ ! -L "$CLOUD_PROVIDER_KIND_LOG_FILE" ] || return 1
  server="$(kubectl config view --context "$CKA_CONTEXT" --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)" || return 1
  [ -n "$server" ] || return 1
  awk -v cluster="$CKA_CLUSTER_NAME" -v host="$server" '
    index($0, "\"Connected successfully\" cluster=\"" cluster "\" host=\"" host "\"") { connected=1 }
    connected && index($0, "\"Caches are synced\"") { ready=1 }
    END { exit(ready ? 0 : 1) }
  ' "$CLOUD_PROVIDER_KIND_LOG_FILE"
}

_cloud_provider_kind_other_clusters_exist() {
  local clusters cluster
  clusters="$(kind get clusters 2>/dev/null)" || return 2
  while IFS= read -r cluster; do
    [ -n "$cluster" ] || continue
    [ "$cluster" = "$CKA_CLUSTER_NAME" ] || return 0
  done <<< "$clusters"
  return 1
}

addon_ok_cloud_provider_kind() {
  local record pid start boot_id version recorded_sha actual_sha
  cloud_provider_kind_binary_ok || return 1
  cloud_provider_kind_proxy_image_ok || return 1
  cloud_provider_kind_cluster_proxy_images_ok "$CKA_CLUSTER_NAME" || return 1
  _cloud_provider_kind_controller_ready || return 1
  # A second host-global controller can race the managed process even when the
  # latter is healthy.  Treat that state as unhealthy, but never signal the
  # process that is not sealed by our PID/start-time/boot-ID record.
  _cloud_provider_kind_process_inventory_clear || return 1
  record="$(_cloud_provider_kind_record)" || return 1
  IFS='|' read -r pid start boot_id version recorded_sha <<< "$record"
  [ "$version" = "$CLOUD_PROVIDER_KIND_VERSION" ] || return 1
  actual_sha="$(sha256sum "$CLOUD_PROVIDER_KIND_BIN" 2>/dev/null | awk '{print $1}')"
  [ -n "$actual_sha" ] && [ "$actual_sha" = "$recorded_sha" ]
}

install_cloud_provider_kind_binary() {
  local arch sha binary_sha version archive_name url tmp archive extracted actual actual_binary_sha
  arch="$(cloud_provider_kind_arch)" \
    || { warn "지원하지 않는 Cloud Provider KIND 아키텍처: $(uname -m)" >&2; return 1; }
  case "$arch" in
    amd64)
      sha="$CLOUD_PROVIDER_KIND_LINUX_AMD64_SHA256"
      binary_sha="$CLOUD_PROVIDER_KIND_LINUX_AMD64_BINARY_SHA256"
      ;;
    arm64)
      sha="$CLOUD_PROVIDER_KIND_LINUX_ARM64_SHA256"
      binary_sha="$CLOUD_PROVIDER_KIND_LINUX_ARM64_BINARY_SHA256"
      ;;
    *) return 1 ;;
  esac
  version="${CLOUD_PROVIDER_KIND_VERSION#v}"
  archive_name="cloud-provider-kind_${version}_linux_${arch}.tar.gz"
  url="$CLOUD_PROVIDER_KIND_RELEASE_BASE_URL/$archive_name"
  tmp="$(mktemp -d /tmp/cka-cloud-provider-kind.XXXXXX)" || return 1
  case "$tmp" in
    /tmp/cka-cloud-provider-kind.??????) ;;
    *) warn "예상 밖 임시 경로라 설치를 중단합니다: $tmp" >&2; return 1 ;;
  esac
  archive="$tmp/$archive_name"
  extracted="$tmp/cloud-provider-kind"

  if ! curl -fsSL "$url" -o "$archive" \
      || ! printf '%s  %s\n' "$sha" "$archive" | sha256sum -c - >/dev/null \
      || ! tar -xzf "$archive" -C "$tmp" cloud-provider-kind \
      || [ ! -f "$extracted" ] || [ -L "$extracted" ]; then
    rm -rf -- "$tmp"
    warn "Cloud Provider KIND 다운로드·checksum·압축 검증 실패: $url" >&2
    return 1
  fi
  chmod 0755 "$extracted" || { rm -rf -- "$tmp"; return 1; }
  actual_binary_sha="$(sha256sum "$extracted" 2>/dev/null | awk '{print $1}')"
  [ "$actual_binary_sha" = "$binary_sha" ] \
    || { rm -rf -- "$tmp"; warn "Cloud Provider KIND binary checksum 불일치" >&2; return 1; }
  actual="$("$extracted" version 2>/dev/null || true)"
  if [ "$actual" != "cloud-provider-kind $version" ]; then
    rm -rf -- "$tmp"
    warn "Cloud Provider KIND archive 내부 버전 불일치: ${actual:-unknown}" >&2
    return 1
  fi
  mkdir -p "$(dirname "$CLOUD_PROVIDER_KIND_BIN")" || { rm -rf -- "$tmp"; return 1; }
  [ ! -L "$CLOUD_PROVIDER_KIND_BIN" ] \
    || { rm -rf -- "$tmp"; warn "설치 대상이 symlink라 중단합니다: $CLOUD_PROVIDER_KIND_BIN" >&2; return 1; }
  install -m 0755 "$extracted" "$CLOUD_PROVIDER_KIND_BIN" \
    || { rm -rf -- "$tmp"; return 1; }
  rm -rf -- "$tmp"
  cloud_provider_kind_binary_ok
}

_cloud_provider_kind_remove_record() {
  [ -e "$CLOUD_PROVIDER_KIND_PID_FILE" ] || [ -L "$CLOUD_PROVIDER_KIND_PID_FILE" ] || return 0
  rm -f -- "$CLOUD_PROVIDER_KIND_PID_FILE"
}

_cloud_provider_kind_untracked_process_exists() {
  local proc pid record tracked_pid="" exe exe_base first_arg arg_base comm expected_comm canonical_comm proc_options
  proc_options="$(awk '$2 == "/proc" {print $4; found=1; exit} END {if (!found) exit 1}' \
    /proc/mounts 2>/dev/null)" || return 2
  case ",$proc_options," in
    *,hidepid=1,*|*,hidepid=2,*|*,hidepid=invisible,*|*,hidepid=noaccess,*) return 2 ;;
  esac
  if _cloud_provider_kind_process_owned; then
    record="$(_cloud_provider_kind_record)" || return 0
    tracked_pid="${record%%|*}"
  fi
  expected_comm="${CLOUD_PROVIDER_KIND_BIN##*/}"
  expected_comm="${expected_comm:0:15}"
  canonical_comm="cloud-provider-kind"
  canonical_comm="${canonical_comm:0:15}"
  for proc in /proc/[1-9]*; do
    [ -d "$proc" ] || continue
    pid="${proc##*/}"
    [ "$pid" = "$tracked_pid" ] && continue
    exe="$(readlink "$proc/exe" 2>/dev/null || true)"
    case "$exe" in
      "$CLOUD_PROVIDER_KIND_BIN"|"$CLOUD_PROVIDER_KIND_BIN (deleted)") return 0 ;;
    esac
    exe_base="${exe##*/}"
    case "$exe_base" in
      cloud-provider-kind|'cloud-provider-kind (deleted)') return 0 ;;
    esac
    first_arg=""
    if [ -r "$proc/cmdline" ]; then
      first_arg="$(tr '\0' '\n' < "$proc/cmdline" 2>/dev/null | sed -n '1p')"
    fi
    arg_base="${first_arg##*/}"
    [ "$arg_base" = cloud-provider-kind ] && return 0
    # exe and cmdline can be hidden by procfs/ptrace policy.  comm is a
    # separate kernel-provided hint (limited to 15 visible bytes), so use it
    # as a conservative final detector.  A match only blocks launch; it never
    # grants ownership or permission to signal the process.
    if [ -r "$proc/comm" ]; then
      comm="$(tr -d '\r\n' < "$proc/comm" 2>/dev/null)" || {
        [ -d "$proc" ] && return 2
        continue
      }
    elif [ -d "$proc" ]; then
      return 2
    else
      continue
    fi
    [ -n "$comm" ] \
      && { [ "$comm" = "$expected_comm" ] || [ "$comm" = "$canonical_comm" ]; } \
      && return 0
  done
  return 1
}

_cloud_provider_kind_process_inventory_clear() {
  local process_rc
  if _cloud_provider_kind_untracked_process_exists; then
    process_rc=0
  else
    process_rc=$?
  fi
  [ "$process_rc" -eq 1 ]
}

_cloud_provider_kind_reclaim_stale_record() {
  local record pid start record_boot version sha current_boot
  [ -e "$CLOUD_PROVIDER_KIND_PID_FILE" ] || [ -L "$CLOUD_PROVIDER_KIND_PID_FILE" ] \
    || return 0
  record="$(_cloud_provider_kind_record)" || {
    warn "Cloud Provider KIND PID 기록이 손상되어 자동 정리하지 않습니다." >&2
    return 1
  }
  IFS='|' read -r pid start record_boot version sha <<< "$record"
  current_boot="$(_cloud_provider_kind_boot_id)" || return 1
  [ "$record_boot" != "$current_boot" ] || return 0

  # Linux boot IDs do not repeat within a boot.  A record from another boot can
  # therefore be reclaimed without inspecting or signalling the recycled PID.
  _cloud_provider_kind_remove_record || return 1
  if ! _cloud_provider_kind_process_inventory_clear; then
    warn "재부팅 뒤 Cloud Provider KIND 전역 프로세스 inventory가 안전하지 않아 중복 기동을 막습니다." >&2
    return 1
  fi
}

_cloud_provider_kind_lifecycle_mutation_allowed() {
  local action="${1:-변경}" other_rc
  if _cloud_provider_kind_other_clusters_exist; then
    other_rc=0
  else
    other_rc=$?
  fi
  if [ "$other_rc" -eq 0 ]; then
    warn "다른 KIND cluster가 있어 host-global Cloud Provider KIND를 자동 ${action}하지 않습니다." >&2
    return 1
  elif [ "$other_rc" -gt 1 ]; then
    warn "KIND cluster 목록을 확인하지 못해 host-global Cloud Provider KIND를 자동 ${action}하지 않습니다." >&2
    return 1
  fi
}

_cloud_provider_kind_prepare_proxy_repair_if_needed() { # 0=no repair, 10=repair after provider stops, 1=unsafe/unknown
  local proxy_rc verified_ids
  # Only classify a repair when every current proxy has a fully verified
  # immutable ID and ownership-label tuple.  No container is removed here:
  # the caller must first quiesce the controller so it cannot recreate the old
  # image between removal and restart.
  if cloud_provider_kind_cluster_proxy_images_ok "$CKA_CLUSTER_NAME"; then
    return 0
  else
    proxy_rc=$?
  fi
  if [ "$proxy_rc" -ne 1 ]; then
    warn "CKA LoadBalancer proxy inventory를 검증할 수 없어 자동 재시작하지 않습니다." >&2
    return 1
  fi
  _cloud_provider_kind_lifecycle_mutation_allowed "CKA LoadBalancer proxy를 삭제·재생성" \
    || return 1
  cluster_ready || {
    warn "CKA API를 확인할 수 없어 LoadBalancer proxy를 자동 삭제하지 않습니다." >&2
    return 1
  }
  verified_ids="$(cloud_provider_kind_verified_cluster_lb_ids "$CKA_CLUSTER_NAME")" || {
    warn "CKA LoadBalancer proxy의 immutable ID/소유권을 모두 검증하지 못했습니다." >&2
    return 1
  }
  [ -n "$verified_ids" ] || {
    warn "drift 상태와 CKA LoadBalancer proxy inventory가 일치하지 않습니다." >&2
    return 1
  }
  return 10
}

_cloud_provider_kind_signal_owned_term() { # <pid> <start-time> <boot-id>; 0=exited, 3=already absent, 4=timeout
  local pid="$1" expected_start="$2" record_boot="$3"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$pid" "$expected_start" "$record_boot" "$CLOUD_PROVIDER_KIND_BIN" <<'PY'
import errno
import os
import select
import signal
import sys

pid_text, expected_start, expected_boot, expected_binary = sys.argv[1:5]
try:
    pid = int(pid_text)
except ValueError:
    raise SystemExit(1)

if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
    raise SystemExit(1)

try:
    pidfd = os.pidfd_open(pid, 0)
except ProcessLookupError:
    raise SystemExit(3)
except OSError:
    raise SystemExit(1)

try:
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as stream:
            if stream.read().strip() != expected_boot:
                raise SystemExit(1)

        stat_text = open(f"/proc/{pid}/stat", encoding="ascii").read()
        closing = stat_text.rfind(")")
        if closing < 0:
            raise SystemExit(1)
        # Fields after comm begin at field 3; starttime is field 22.
        fields_after_comm = stat_text[closing + 2:].split()
        if len(fields_after_comm) < 20 or fields_after_comm[19] != expected_start:
            raise SystemExit(1)
        if os.stat(f"/proc/{pid}").st_uid != os.getuid():
            raise SystemExit(1)

        executable = os.readlink(f"/proc/{pid}/exe")
        if executable not in (expected_binary, expected_binary + " (deleted)"):
            raise SystemExit(1)
        with open(f"/proc/{pid}/cmdline", "rb") as stream:
            argv = [part.decode(errors="surrogateescape") for part in stream.read().split(b"\0") if part]
        if not argv or argv[0] != expected_binary:
            raise SystemExit(1)
        if not any(
            argv[index] == "--gateway-channel" and argv[index + 1] == "disabled"
            for index in range(len(argv) - 1)
        ):
            raise SystemExit(1)
    except (FileNotFoundError, PermissionError, OSError, UnicodeError):
        raise SystemExit(1)

    try:
        signal.pidfd_send_signal(pidfd, signal.SIGTERM, None, 0)
    except ProcessLookupError:
        # The sealed process exited after pidfd_open; no other PID can receive
        # this signal through the retained descriptor.
        raise SystemExit(0)
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            raise SystemExit(0)
        raise SystemExit(1)

    poller = select.poll()
    poller.register(pidfd, select.POLLIN)
    raise SystemExit(0 if poller.poll(5000) else 4)
finally:
    os.close(pidfd)
PY
}

_cloud_provider_kind_stop_unlocked() {
  local record pid start boot_id current_boot version sha signal_rc
  _cloud_provider_kind_reclaim_stale_record || return 1
  _cloud_provider_kind_lifecycle_mutation_allowed "정지·재시작" || return 1
  if [ -e "$CLOUD_PROVIDER_KIND_PID_FILE" ] || [ -L "$CLOUD_PROVIDER_KIND_PID_FILE" ]; then
    record="$(_cloud_provider_kind_record)" || {
      warn "Cloud Provider KIND PID 기록이 손상되어 자동 정지·재시작하지 않습니다." >&2
      return 1
    }
    IFS='|' read -r pid start boot_id version sha <<< "$record"
    current_boot="$(_cloud_provider_kind_boot_id)" || return 1
    if [ "$boot_id" != "$current_boot" ]; then
      warn "Cloud Provider KIND boot ID가 잠금 구간에서 변경되어 정지를 중단합니다." >&2
      return 1
    fi
    # KIND creation does not participate in our runtime flock.  Recheck at the
    # last possible point before the host-global controller receives a signal.
    _cloud_provider_kind_lifecycle_mutation_allowed "정지·재시작" || return 1
    if _cloud_provider_kind_signal_owned_term "$pid" "$start" "$boot_id"; then
      signal_rc=0
    else
      signal_rc=$?
    fi
    case "$signal_rc" in
      0|3) ;;
      4)
        warn "Cloud Provider KIND가 SIGTERM 후 종료되지 않았습니다 (PID $pid). 강제 종료하지 않습니다." >&2
        return 1
        ;;
      *)
        warn "Cloud Provider KIND 프로세스 소유권을 pidfd로 봉인하지 못해 신호를 보내지 않습니다." >&2
        return 1
        ;;
    esac
  else
    _cloud_provider_kind_process_inventory_clear || {
      warn "Cloud Provider KIND 전역 프로세스 inventory가 안전하지 않아 중복 기동을 막습니다." >&2
      return 1
    }
  fi
  _cloud_provider_kind_remove_record
}

_cloud_provider_kind_quiesce_for_start() { # caller holds the runtime flock
  local prepare_rc repair_needed=0

  if ! _cloud_provider_kind_process_inventory_clear; then
    warn "소유 기록 밖의 Cloud Provider KIND 프로세스가 있어 중복 기동을 막습니다." >&2
    return 1
  fi

  if _cloud_provider_kind_prepare_proxy_repair_if_needed; then
    prepare_rc=0
  else
    prepare_rc=$?
  fi
  case "$prepare_rc" in
    0) ;;
    10) repair_needed=1 ;;
    *) return 1 ;;
  esac

  _cloud_provider_kind_stop_unlocked || return 1

  # Re-scan after the owned process exits.  This catches a second provider
  # that was previously hidden by a valid managed record or appeared during
  # shutdown; it is never signalled by this code.
  if ! _cloud_provider_kind_process_inventory_clear; then
    warn "Cloud Provider KIND 정지 후 소유 불명 프로세스가 확인되어 재기동을 막습니다." >&2
    return 1
  fi

  if [ "$repair_needed" -eq 1 ]; then
    # Re-check the sole-cluster condition after shutdown and preflight every
    # proxy again before the first destructive operation.
    _cloud_provider_kind_lifecycle_mutation_allowed "CKA LoadBalancer proxy를 삭제·재생성" \
      || return 1
    cloud_provider_kind_force_remove_cluster_lbs "$CKA_CLUSTER_NAME" || {
      warn "검증된 CKA LoadBalancer proxy 정리에 실패했습니다." >&2
      return 1
    }
  fi

  if ! _cloud_provider_kind_process_inventory_clear; then
    warn "Cloud Provider KIND 시작 직전 소유 불명 프로세스가 확인되어 중복 기동을 막습니다." >&2
    return 1
  fi
}

cloud_provider_kind_stop() {
  local lock_fd rc
  _cloud_provider_kind_prepare_runtime || return 1
  command -v flock >/dev/null 2>&1 || return 1
  exec {lock_fd}< "$CLOUD_PROVIDER_KIND_RUNTIME_DIR" || return 1
  flock -w 10 "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  _cloud_provider_kind_stop_unlocked
  rc=$?
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return "$rc"
}

cloud_provider_kind_start() {
  local lock_fd rc=0 pid start boot_id sha tmp_record i log_owner log_links spawned=0
  _cloud_provider_kind_prepare_runtime || return 1
  cloud_provider_kind_binary_ok || return 1
  command -v flock >/dev/null 2>&1 || return 1
  exec {lock_fd}< "$CLOUD_PROVIDER_KIND_RUNTIME_DIR" || return 1
  flock -w 10 "$lock_fd" || { exec {lock_fd}>&-; return 1; }

  if addon_ok_cloud_provider_kind; then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  fi
  _cloud_provider_kind_quiesce_for_start || rc=1
  if [ "$rc" -eq 0 ]; then
    if [ -e "$CLOUD_PROVIDER_KIND_LOG_FILE" ] || [ -L "$CLOUD_PROVIDER_KIND_LOG_FILE" ]; then
      [ -f "$CLOUD_PROVIDER_KIND_LOG_FILE" ] && [ ! -L "$CLOUD_PROVIDER_KIND_LOG_FILE" ] || rc=1
      log_owner="$(stat -c '%u' "$CLOUD_PROVIDER_KIND_LOG_FILE" 2>/dev/null || true)"
      log_links="$(stat -c '%h' "$CLOUD_PROVIDER_KIND_LOG_FILE" 2>/dev/null || true)"
      [ "$log_owner" = "$(id -u)" ] && [ "$log_links" = 1 ] || rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    : > "$CLOUD_PROVIDER_KIND_LOG_FILE" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    _cloud_provider_kind_process_inventory_clear || {
      warn "Cloud Provider KIND 실행 직전 전역 프로세스 inventory가 안전하지 않습니다." >&2
      rc=1
    }
  fi
  if [ "$rc" -eq 0 ]; then
    _cloud_provider_kind_lifecycle_mutation_allowed "기동" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    nohup "$CLOUD_PROVIDER_KIND_BIN" --gateway-channel disabled \
      --enable-default-ingress=false > "$CLOUD_PROVIDER_KIND_LOG_FILE" 2>&1 &
    pid=$!
    spawned=1
    for i in $(seq 1 30); do
      [ -r "/proc/$pid/stat" ] && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    start="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
    boot_id="$(_cloud_provider_kind_boot_id 2>/dev/null || true)"
    sha="$(sha256sum "$CLOUD_PROVIDER_KIND_BIN" 2>/dev/null | awk '{print $1}')"
    if [[ ! "$start" =~ ^[1-9][0-9]*$ ]] \
        || [[ ! "$boot_id" =~ ^[0-9a-f-]{36}$ ]] \
        || [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
      rc=1
    else
      tmp_record="$CLOUD_PROVIDER_KIND_PID_FILE.tmp.$$"
      printf '%s|%s|%s|%s|%s\n' \
        "$pid" "$start" "$boot_id" "$CLOUD_PROVIDER_KIND_VERSION" "$sha" > "$tmp_record" \
        && chmod 600 "$tmp_record" \
        && mv -f -- "$tmp_record" "$CLOUD_PROVIDER_KIND_PID_FILE" || rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    for i in $(seq 1 150); do
      addon_ok_cloud_provider_kind && break
      sleep 0.1
    done
    addon_ok_cloud_provider_kind || rc=1
  fi
  if [ "$rc" -ne 0 ] && [ "$spawned" -eq 1 ]; then
    _cloud_provider_kind_stop_unlocked >/dev/null 2>&1 || true
  fi
  if [ "$rc" -ne 0 ]; then
    warn "Cloud Provider KIND 시작 실패. 로그: $CLOUD_PROVIDER_KIND_LOG_FILE" >&2
  fi
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return "$rc"
}

addon_install_cloud_provider_kind() {
  local other_rc
  if ! cloud_provider_kind_binary_ok; then
    if _cloud_provider_kind_process_owned; then
      if _cloud_provider_kind_other_clusters_exist; then
        other_rc=0
      else
        other_rc=$?
      fi
      if [ "$other_rc" -eq 0 ]; then
        warn "다른 KIND cluster가 있어 host-global Cloud Provider KIND binary를 자동 교체하지 않습니다." >&2
        return 1
      elif [ "$other_rc" -gt 1 ]; then
        warn "KIND cluster 목록을 확인하지 못해 host-global Cloud Provider KIND binary를 자동 교체하지 않습니다." >&2
        return 1
      fi
    fi
    cloud_provider_kind_stop >/dev/null 2>&1 || return 1
    _cloud_provider_kind_lifecycle_mutation_allowed "binary를 교체" || return 1
    _cloud_provider_kind_process_inventory_clear || {
      warn "Cloud Provider KIND binary 교체 직전 전역 프로세스 inventory가 안전하지 않습니다." >&2
      return 1
    }
    install_cloud_provider_kind_binary || return 1
  fi
  ensure_cloud_provider_kind_proxy_image || return 1
  cloud_provider_kind_start
}

addon_wait_cloud_provider_kind() {
  local i
  for i in $(seq 1 30); do
    addon_ok_cloud_provider_kind && return 0
    sleep 1
  done
  return 1
}

_cloud_provider_kind_validate_cluster_name() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9.-]{0,62}$ ]]
}

cloud_provider_kind_cluster_lb_ids() { # <kind-cluster-name>
  local cluster="$1"
  _cloud_provider_kind_validate_cluster_name "$cluster" || return 1
  docker ps -aq --no-trunc --filter \
    "label=io.x-k8s.cloud-provider-kind.cluster=$cluster"
}

cloud_provider_kind_cluster_lbs_absent() { # <kind-cluster-name>
  local ids
  ids="$(cloud_provider_kind_cluster_lb_ids "$1")" || return 1
  [ -z "$ids" ]
}

cloud_provider_kind_force_remove_cluster_lbs() { # API-unavailable fallback
  local cluster="$1" verified_ids confirmed_ids normalized_verified normalized_confirmed
  local -a sealed_ids=()
  _cloud_provider_kind_validate_cluster_name "$cluster" || return 1
  # Seal and validate the complete set before deleting the first object.  A
  # partial/ambiguous or changing inventory therefore causes zero mutation.
  verified_ids="$(cloud_provider_kind_verified_cluster_lb_ids "$cluster")" || {
    warn "소유권 label 계약이 불완전한 LoadBalancer 컨테이너가 있어 아무것도 삭제하지 않습니다." >&2
    return 1
  }
  confirmed_ids="$(cloud_provider_kind_verified_cluster_lb_ids "$cluster")" || {
    warn "LoadBalancer 컨테이너 inventory 재검증에 실패해 아무것도 삭제하지 않습니다." >&2
    return 1
  }
  normalized_verified="$(printf '%s\n' "$verified_ids" | sed '/^$/d' | sort)" || return 1
  normalized_confirmed="$(printf '%s\n' "$confirmed_ids" | sed '/^$/d' | sort)" || return 1
  [ "$normalized_verified" = "$normalized_confirmed" ] || {
    warn "LoadBalancer 컨테이너 inventory가 검증 중 변경되어 아무것도 삭제하지 않습니다." >&2
    return 1
  }
  [ -n "$normalized_verified" ] || return 0
  mapfile -t sealed_ids <<< "$normalized_verified" || return 1
  # One Docker request carries only the twice-verified full IDs.  Docker has no
  # transactional list-and-remove primitive, so the final absence check still
  # fails closed if an uncooperative external creator races this request.
  docker container rm --force "${sealed_ids[@]}" >/dev/null 2>&1 || return 1
  cloud_provider_kind_cluster_lbs_absent "$cluster"
}

cloud_provider_kind_cleanup_cluster_loadbalancers() { # <kind-cluster-name>
  local cluster="$1" entry namespace name i service_output
  local -a services=()
  _cloud_provider_kind_validate_cluster_name "$cluster" || return 1
  [ "$cluster" = "$CKA_CLUSTER_NAME" ] || {
    warn "현재 kube context와 다른 KIND cluster의 Service는 정리하지 않습니다: $cluster" >&2
    return 1
  }

  if cluster_ready; then
    service_output="$(kctx get services -A \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
      2>/dev/null)" || return 1
    if [ -n "$service_output" ]; then
      mapfile -t services <<< "$service_output" || return 1
    fi
    if [ "${#services[@]}" -gt 0 ]; then
      _cloud_provider_kind_process_owned || {
        warn "LoadBalancer Service가 있지만 소유한 Provider가 실행 중이 아닙니다." >&2
        return 1
      }
    fi
    for entry in "${services[@]}"; do
      namespace="${entry%%$'\t'*}"
      name="${entry#*$'\t'}"
      [[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
        && [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || return 1
      kctx -n "$namespace" delete service "$name" --wait=true --timeout=120s \
        >/dev/null 2>&1 || return 1
    done
    for i in $(seq 1 120); do
      cloud_provider_kind_cluster_lbs_absent "$cluster" && return 0
      sleep 1
    done
    warn "$cluster LoadBalancer 컨테이너가 controller 정리 후에도 남았습니다." >&2
    return 1
  fi

  # With no API there is no finalizer path left.  Delete only immutable IDs
  # whose two upstream ownership labels and generated name all agree.
  cloud_provider_kind_force_remove_cluster_lbs "$cluster"
}

cloud_provider_kind_stop_if_no_clusters() {
  local clusters
  clusters="$(kind get clusters 2>/dev/null)" || return 1
  if [ -n "$clusters" ]; then
    info "다른 KIND cluster가 있어 host-global Cloud Provider KIND는 계속 실행합니다."
    return 0
  fi
  cloud_provider_kind_stop
}

addon_deploy_ready_with_image() { # <ns> <deployment> <exact-image|prefix*>
  local ns="$1" deploy="$2" expected="$3" state image generation observed desired ready
  state="$(kctx -n "$ns" get deploy "$deploy" \
    -o jsonpath='{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.spec.replicas}{"|"}{.status.readyReplicas}{"|"}{.spec.template.spec.containers[0].image}' \
    2>/dev/null)" || return 1
  IFS='|' read -r generation observed desired ready image <<< "$state"
  [ -n "$generation" ] && [ "$observed" = "$generation" ] \
    && [ "${desired:-0}" -gt 0 ] && [ "${ready:-0}" = "$desired" ] || return 1
  case "$expected" in
    *\*) [[ "$image" == ${expected%\*}* ]] ;;
    *) [ "$image" = "$expected" ] ;;
  esac
}

# ── metrics-server ───────────────────────────────────────────────
addon_ok_metrics_server() {
  addon_deploy_ready_with_image kube-system metrics-server \
    "registry.k8s.io/metrics-server/metrics-server:$METRICS_SERVER_VERSION"
}
addon_install_metrics_server() {
  kctx apply -f "$METRICS_SERVER_URL" || return 1
  # kind는 kubelet 인증서가 자체서명이라 --kubelet-insecure-tls 필요 (중복 적용 방지)
  if ! kctx -n kube-system get deploy metrics-server \
      -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q kubelet-insecure-tls; then
    kctx -n kube-system patch deployment metrics-server --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
      >/dev/null 2>&1 || return 1
  fi
}
addon_wait_metrics_server() {
  kctx -n kube-system rollout status deploy/metrics-server --timeout=180s >/dev/null 2>&1 \
    && addon_ok_metrics_server
}

# ── ingress-nginx ────────────────────────────────────────────────
# IngressClass와 컨트롤러 Deployment가 모두 있어야 정상으로 본다.
addon_ok_ingress_nginx() {
  kctx get ingressclass nginx >/dev/null 2>&1 \
    && [ "$(kctx -n ingress-nginx get service ingress-nginx-controller \
      -o jsonpath='{.spec.type}' 2>/dev/null)" = ClusterIP ] \
    && addon_deploy_ready_with_image ingress-nginx ingress-nginx-controller \
      "registry.k8s.io/ingress-nginx/controller:${INGRESS_NGINX_VERSION#controller-}*"
}
addon_install_ingress_nginx() {
  kctx apply -f "$INGRESS_NGINX_URL" || return 1
  # 컨트롤러를 control-plane(ingress-ready, hostPort 80→호스트 8080 매핑 노드)에 고정.
  # 이 patch가 빠지면 IngressClass가 있어도 curl localhost:8080 실측이 실패한다.
  kctx -n ingress-nginx patch deploy ingress-nginx-controller --type=strategic -p '{
    "spec":{"template":{"spec":{
      "nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"},
      "tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]
    }}}}' >/dev/null 2>&1 || return 1
  # 이 클러스터는 control-plane hostPort 80/443을 Windows의 8080/8443에
  # 이미 매핑한다. upstream KIND manifest의 LoadBalancer Service까지 provider가
  # 관리하면 Docker Desktop에서 다른 연습 Service와 host port 80이 충돌하므로,
  # Ingress controller Service는 내부 ClusterIP로 고정한다.
  kctx -n ingress-nginx patch service ingress-nginx-controller --type=merge \
    -p='{"spec":{"type":"ClusterIP"}}' >/dev/null 2>&1 || return 1
}
addon_wait_ingress_nginx() {
  kctx -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s \
    >/dev/null 2>&1 && addon_ok_ingress_nginx
}

# ── Gateway API ──────────────────────────────────────────────────
# CRD가 있어야 gatewayclass 리소스 타입이 존재하고, 그 위에 GatewayClass/nginx.
addon_ok_gateway_api() {
  [ "$(kctx get gatewayclass nginx \
      -o jsonpath='{.spec.controllerName}' 2>/dev/null)" = \
      example.com/nginx-gateway-controller ] \
    && kctx get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
    && kctx get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1
}
addon_install_gateway_api() {
  kctx apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" \
    || return 1
  # 문제에서 참조할 GatewayClass (컨트롤러는 두지 않음 — 스펙 작성 연습용)
  kctx apply -f - >/dev/null <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: example.com/nginx-gateway-controller
EOF
}
addon_wait_gateway_api() { addon_ok_gateway_api; }

# ── 채점용 상주 파드 ─────────────────────────────────────────────
addon_ok_grader_client() {
  addon_deploy_ready_with_image cka-system grader-client busybox:1.36
}
addon_install_grader_client() {
  kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: cka-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grader-client
  namespace: cka-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: grader-client}
  template:
    metadata:
      labels: {app: grader-client}
    spec:
      containers:
        - name: client
          image: busybox:1.36
          command: ["sleep", "infinity"]
EOF
}
addon_wait_grader_client() {
  kctx -n cka-system rollout status deploy/grader-client --timeout=180s >/dev/null 2>&1 \
    && addon_ok_grader_client
}

# 빠진 애드온만 재설치. 조용히 동작하고, 실제로 복구한 개수를 반환(exit code 아님, echo).
# 사용: repaired=$(ensure_addons); [ "$repaired" -gt 0 ] && ...
ensure_addons() {
  local entry key human repaired=0 failed=0
  for entry in "${CKA_ADDONS[@]}"; do
    key="${entry%%|*}"
    human="${entry#*|}"
    if ! "addon_ok_$key"; then
      info "자가치유: $human 재설치 중..." >&2
      if "addon_install_$key" >/dev/null 2>&1; then
        if "addon_wait_$key"; then
          repaired=$((repaired + 1))
        else
          warn "$human 설치 후 readiness/version 검증 실패" >&2
          failed=1
        fi
      else
        warn "$human 재설치 실패 — 'cka cluster up' 을 직접 실행해 보세요." >&2
        failed=1
      fi
    fi
  done
  printf '%s' "$repaired"
  return "$failed"
}
