#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../lib/cell.sh"

usage() {
  printf '%s\n' \
    "usage: cell.sh up|down|status <question-id> operator-cell|gateway-cell|csi-cell" >&2
  exit 2
}

action="${1:-}"
qid="${2:-}"
profile="${3:-}"
[ "$#" -eq 3 ] || usage
cell_qid_valid "$qid" || usage
case "$profile" in operator-cell|gateway-cell|csi-cell) ;; *) usage ;; esac

case "$action" in
  up)
    if [ -e "$(cell_state_dir "$qid")" ]; then
      cell_destroy "$qid"
    fi
    cell_create "$qid" "$profile" "$SCRIPT_DIR/kind.yaml"
    cell_mark_ready "$qid"
    cell_status "$qid" "$profile"
    ;;
  down) cell_destroy "$qid" ;;
  status) cell_status "$qid" "$profile" ;;
  *) usage ;;
esac
