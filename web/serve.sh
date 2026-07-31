#!/usr/bin/env bash
# cka web — 왼쪽 지문/오른쪽 터미널 스플릿 뷰를 로컬에서 띄운다.
#   web 포트(기본 7681) = Python 백엔드,  web+1(7682) = ttyd 실제 터미널
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

WEB_PORT="${1:-7681}"
TTYD_PORT=$((WEB_PORT + 1))
TTYD_VERSION="1.7.7"
TTYD_BIN="$HOME/.local/bin/ttyd"

command -v python3 >/dev/null || die "python3 가 필요합니다."

# ── ttyd 준비 (없으면 정적 바이너리 다운로드) ──
ensure_ttyd() {
  if command -v ttyd >/dev/null; then TTYD_BIN="$(command -v ttyd)"; return; fi
  if [ -x "$TTYD_BIN" ]; then return; fi
  command -v curl >/dev/null || die "curl 이 필요합니다 (ttyd 자동 설치용)."
  info "ttyd(터미널 서버)가 없어 정적 바이너리를 내려받습니다..."
  mkdir -p "$HOME/.local/bin"
  local url="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"
  curl -fsSL "$url" -o "$TTYD_BIN" || die "ttyd 다운로드 실패: $url"
  chmod +x "$TTYD_BIN"
  ok "ttyd 설치 완료: $TTYD_BIN"
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
