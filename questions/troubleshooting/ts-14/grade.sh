#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

QID=ts-14
BACKUP_DIR="$CKA_STATE_DIR/backup/$QID"
grade_init ts-14

ts14_cni_restored() {
  local expected actual checksum_line
  [ -f "$BACKUP_DIR/10-calico.conflist.sha256" ] || return 1
  read -r expected < "$BACKUP_DIR/10-calico.conflist.sha256"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  checksum_line="$(node_exec_out cka-worker 'sha256sum /etc/cni/net.d/10-calico.conflist 2>/dev/null')" \
    || return 1
  actual="${checksum_line%% *}"
  [ "$actual" = "$expected" ] \
    && node_exec cka-worker 'test ! -e /etc/cni/net.d/10-calico.conflist.cka-disabled'
}

criterion 2 "containerd is active and CRI responds" \
  "[ \"\$(node_exec_out cka-worker 'systemctl is-active containerd')\" = active ] && node_exec cka-worker 'crictl info >/dev/null'"

criterion 1 "containerd is enabled across reboot" \
  "[ \"\$(node_exec_out cka-worker 'systemctl is-enabled containerd')\" = enabled ]"

criterion 2 "original Calico CNI configuration is restored" \
  "ts14_cni_restored"

criterion 1 "cka-worker reports Ready" \
  "jp_eq node cka-worker - '{.status.conditions[?(@.type==\"Ready\")].status}' True"

criterion 2 "runtime-probe is Running and Ready" \
  "jp_eq pod runtime-probe runtime-check '{.status.phase}' Running && pod_ready runtime-check runtime-probe"

grade_finish
