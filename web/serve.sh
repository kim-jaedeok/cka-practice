#!/usr/bin/env bash
# cka web — 왼쪽 지문/오른쪽 터미널 스플릿 뷰를 로컬에서 띄운다.
#   web 포트(기본 7681) = Python 백엔드,  web+1(7682) = ttyd 실제 터미널
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

WEB_PORT="${1:-7681}"
TTYD_PORT=$((WEB_PORT + 1))
TTYD_BIN="$HOME/.local/bin/ttyd"

command -v python3 >/dev/null || die "python3 가 필요합니다."

# ── ttyd 준비 (실행 가능한 ttyd가 없으면 lock 버전 정적 바이너리를 검증 설치) ──
# 릴리스 asset 이름은 uname -m 표기를 따른다: ttyd.x86_64 / ttyd.aarch64
ttyd_locked_asset() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' ttyd.x86_64 ;;
    aarch64|arm64) printf '%s\n' ttyd.aarch64 ;;
    *) die "지원하지 않는 ttyd 아키텍처: $(uname -m)" ;;
  esac
}

ttyd_locked_sha256() {
  case "$1" in
    ttyd.x86_64) printf '%s\n' "$TTYD_LINUX_AMD64_SHA256" ;;
    ttyd.aarch64) printf '%s\n' "$TTYD_LINUX_ARM64_SHA256" ;;
    *) die "지원하지 않는 ttyd asset: $1" ;;
  esac
}

# 다른 아키텍처용 바이너리는 -x여도 exec format error로 실패하므로 실제로 실행해 본다.
ttyd_runnable() { [ -f "$1" ] && [ -x "$1" ] && "$1" --version >/dev/null 2>&1; }

ensure_ttyd() {
  local candidate asset expected_sha url tmp tool
  candidate="$(command -v ttyd 2>/dev/null || true)"
  if [ -n "$candidate" ] && ttyd_runnable "$candidate"; then TTYD_BIN="$candidate"; return; fi

  for tool in curl sha256sum mktemp chmod mv uname; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool 이 필요합니다 (ttyd 자동 설치용)."
  done
  asset="$(ttyd_locked_asset)" || exit 1
  expected_sha="$(ttyd_locked_sha256 "$asset")" || exit 1
  url="$TTYD_RELEASE_BASE_URL/$asset"

  [ ! -L "$TTYD_BIN" ] || die "ttyd 설치 경로가 심볼릭 링크입니다: $TTYD_BIN"
  if [ -e "$TTYD_BIN" ]; then
    info "기존 $TTYD_BIN 을 이 아키텍처($(uname -m))에서 실행할 수 없어 $asset 로 교체합니다..."
  else
    info "ttyd(터미널 서버)가 없어 정적 바이너리($asset)를 내려받습니다..."
  fi
  mkdir -p -- "$HOME/.local/bin" || die "ttyd 설치 경로 생성 실패: $HOME/.local/bin"

  tmp="$(mktemp "$HOME/.local/bin/.ttyd.download.XXXXXX")" || die "ttyd 임시 파일 생성 실패"
  if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$url" -o "$tmp"; then
    rm -f -- "$tmp"
    die "ttyd 다운로드 실패: $url"
  fi
  if ! printf '%s  %s\n' "$expected_sha" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f -- "$tmp"
    die "ttyd $TTYD_VERSION checksum 불일치: $asset"
  fi
  chmod 0755 -- "$tmp" || { rm -f -- "$tmp"; die "ttyd 실행 권한 설정 실패"; }
  if ! ttyd_runnable "$tmp"; then
    rm -f -- "$tmp"
    die "내려받은 ttyd를 실행할 수 없습니다: $asset ($(uname -m))"
  fi
  mv -f -- "$tmp" "$TTYD_BIN" || { rm -f -- "$tmp"; die "ttyd 설치 실패: $TTYD_BIN"; }
  ok "ttyd $TTYD_VERSION 설치 완료: $TTYD_BIN ($asset)"
}
ensure_ttyd

# ── 두 서버 기동 + 종료 정리 ──
PIDS=()
cleanup() {
  printf '\n'
  info "웹 서버를 종료합니다..."
  for p in "${PIDS[@]}"; do kill "$p" >/dev/null 2>&1 || true; done
  wait 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

# 오른쪽 패널: 실제 bash 터미널, 루프백만 바인딩
# PATH에 repo 루트(cka 명령) + bin/(ssh 래퍼 — 실전처럼 `ssh cka-worker` 접속)를 올린다.
chmod +x "$CKA_ROOT/bin/ssh" 2>/dev/null || true
CKA_ROOT="$CKA_ROOT" "$TTYD_BIN" -p "$TTYD_PORT" -i 127.0.0.1 -W \
  bash -lc "cd '$CKA_ROOT'; export PATH='$CKA_ROOT/bin':'$CKA_ROOT':\"\$PATH\"; exec bash" \
  >/dev/null 2>&1 &
PIDS+=($!)

# 왼쪽 패널: Python 백엔드
CKA_ROOT="$CKA_ROOT" python3 "$SCRIPT_DIR/server.py" "$WEB_PORT" &
PIDS+=($!)

sleep 1
URL="http://localhost:${WEB_PORT}"
printf '\n'
ok "cka 웹 스플릿 뷰 준비됨:  ${C_BLD}${URL}${C_RST}"
printf '%s\n' "  왼쪽=문제 지문·버튼, 오른쪽=실제 터미널 (여기서 kubectl로 풀이)"
printf '%s\n' "  종료: Ctrl-C"

# Windows 기본 브라우저로 열기 시도 (실패해도 무시)
if command -v powershell.exe >/dev/null; then
  powershell.exe -NoProfile -Command "Start-Process '$URL'" >/dev/null 2>&1 || true
fi

wait
