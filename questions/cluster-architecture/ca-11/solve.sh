#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/cell.sh"

export CKA_CELL_DOCKER_TIMEOUT="${CKA_CELL_KUBEADM_DOCKER_TIMEOUT:-420}"

cell_activate ca-11 kubeadm-ha
certificate_key="$(cell_exec ca-11 cp1 kubeadm init phase upload-certs --upload-certs \
  | awk '/^[0-9a-f]{64}$/ {key=$0} END {print key}')"
[[ "$certificate_key" =~ ^[0-9a-f]{64}$ ]]

join_command="$(cell_exec ca-11 cp1 kubeadm token create --print-join-command)"
read -r -a join_args <<< "$join_command"
[ "${#join_args[@]}" -eq 7 ]
[ "${join_args[0]}" = kubeadm ] && [ "${join_args[1]}" = join ]
[[ "${join_args[2]}" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]]
[ "${join_args[3]}" = --token ]
[[ "${join_args[4]}" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]]
[ "${join_args[5]}" = --discovery-token-ca-cert-hash ]
[[ "${join_args[6]}" =~ ^sha256:[0-9a-f]{64}$ ]]
control_plane_join=(
  "${join_args[@]}"
  --control-plane
  --certificate-key "$certificate_key"
)

cell_manifest_load ca-11
for role in cp2 cp3; do
  node="$(cell_role_node_name "$CELL_CLUSTER_NAME" "$role")"
  cell_exec ca-11 "$role" "${control_plane_join[@]}"
  cell_kubectl ca-11 wait --for=condition=Ready "node/$node" --timeout=300s
done

cell_kubectl ca-11 -n ha-survival create configmap ha-proof \
  --from-literal=completed=true
