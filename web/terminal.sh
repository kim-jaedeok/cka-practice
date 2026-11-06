#!/usr/bin/env bash
# ttyd entry point for the web UI's right-hand terminal.
#
# While a supervised SSH exam is RUNNING, the terminal opens the candidate base
# host (`cka exam-ssh enter`), the same place the terminal flow uses.  The
# candidate then runs `ssh cka-target`.  Otherwise it opens the normal practice
# shell.  ttyd starts this script again for every new connection, so reloading
# the terminal after begin or finish switches the mode.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
export PATH="$ROOT/bin:$ROOT:$PATH"

ssh_phase() { python3 "$ROOT/web/server.py" --ssh-phase 2>/dev/null || printf 'NONE\n'; }

while [ "$(ssh_phase)" = RUNNING ]; do
  printf '\n[감독형 SSH 시험] base host에 들어갑니다. 여기서 ssh cka-target 으로 접속하세요.\n\n'
  "$ROOT/cka" exam-ssh enter
  printf '\n[감독형 SSH 시험] base host 연결이 끝났습니다.\n'
  printf '  다시 들어가려면 Enter를 누르세요. 시간이 끝났으면 왼쪽 「종료·채점」을 누르세요.\n'
  read -r _ || exit 0
done

exec bash
