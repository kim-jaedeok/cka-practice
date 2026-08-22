#!/usr/bin/env bash
# Docker-free structural and safety contract for disposable kubeadm cells.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

check() {
  local description="$1"; shift
  if "$@"; then
    printf 'ok - %s\n' "$description"
    PASS=$((PASS + 1))
  else
    printf 'not ok - %s\n' "$description"
    FAIL=$((FAIL + 1))
  fi
}

all_shell_syntax_valid() {
  local file
  while IFS= read -r file; do
    bash -n "$file" || return 1
  done < <(find "$CKA_ROOT/cluster/cells" "$CKA_ROOT/questions/cluster-architecture/ca-11" \
    "$CKA_ROOT/questions/cluster-architecture/ca-12" -type f -name '*.sh' -print)
  bash -n "$CKA_ROOT/lib/cell.sh" \
    && bash -n "$CKA_ROOT/lib/cell-grader.sh" \
    && bash -n "$CKA_ROOT/tests/kubeadm-live-test.sh"
}

points_match() {
  local qid="$1" qdir meta total
  qdir="$CKA_ROOT/questions/cluster-architecture/$qid"
  meta="$(sed -n 's/^points:[[:space:]]*//p' "$qdir/meta.yaml")"
  total="$(awk '/^[[:space:]]*criterion[[:space:]]+[0-9]+/ {sum += $2} END {print sum+0}' \
    "$qdir/grade.sh")"
  [ "$meta" = "$total" ]
}

live_gate_points_match_metadata() {
  local live="$CKA_ROOT/tests/kubeadm-live-test.sh" qid meta
  for qid in ca-12 ca-11 ca-06; do
    meta="$(sed -n 's/^points:[[:space:]]*//p' \
      "$CKA_ROOT/questions/cluster-architecture/$qid/meta.yaml")" || return 1
    grep -Fq "$qid) run_question \"\$qid\" $meta ;;" "$live" || return 1
  done
}

cleanup_is_id_and_owner_bound() {
  local lib="$CKA_ROOT/lib/cell.sh"
  grep -Fq 'container rm --force "$id"' "$lib" \
    && grep -Fq '_cell_docker volume rm "$name"' "$lib" \
    && grep -Fq '_cell_volume_fingerprint "$name"' "$lib" \
    && grep -Fq '_cell_volume_attachment_ids "$name"' "$lib" \
    && grep -Fq 'network rm "$CELL_NETWORK_ID"' "$lib" \
    && grep -Fq 'io.x-k8s.kind.cluster' "$lib" \
    && grep -Fq '$CKA_CELL_OWNER_LABEL=$CELL_RUN_ID' "$lib" \
    && grep -Fq 'manifest에 없는 동일-cluster 컨테이너' "$lib" \
    && ! grep -Eq 'kind[[:space:]]+delete|docker[[:space:]]+(rm|network rm)[[:space:]]+.*\$CELL_CLUSTER_NAME|volume[[:space:]]+prune' "$lib"
}

shared_cluster_is_not_referenced() {
  ! grep -R -Fq -- 'kind-cka' "$CKA_ROOT/cluster/cells" \
    "$CKA_ROOT/questions/cluster-architecture/ca-11" \
    "$CKA_ROOT/questions/cluster-architecture/ca-12" \
    || grep -R -Fq -- 'Do not use the shared `kind-cka`' \
      "$CKA_ROOT/questions/cluster-architecture/ca-12/question.md"
  ! grep -R -Eq -- 'docker (exec|stop|rm)[[:space:]]+cka-' "$CKA_ROOT/cluster/cells"
}

blank_contract_is_real() {
  local blank="$CKA_ROOT/cluster/cells/kubeadm/blank-node.sh"
  grep -Fq 'kubeadm reset --force --cleanup-tmp-dir' "$blank" \
    && grep -Fq 'KUBELET_EXTRA_ARGS=--fail-swap-on=false' "$blank" \
    && grep -Fq '/etc/cni/net.d' "$blank" \
    && grep -Fq '/var/lib/etcd' "$blank" \
    && grep -Fq 'systemctl stop kubelet' "$blank"
}

ha_blank_nodes_preserve_only_the_owned_lb_name() {
  local blank="$CKA_ROOT/cluster/cells/kubeadm/blank-node.sh"
  local seed="$CKA_ROOT/cluster/cells/kubeadm/seed-ha.sh"
  grep -Fq 'load_balancer_host="${4:-}"' "$blank" \
    && grep -Fq '[ "$qid" = ca-11 ]' "$blank" \
    && grep -Fq '[[ "$role" =~ ^cp[23]$ ]]' "$blank" \
    && grep -Fq "printf '%s\\t%s\\n' \"\$load_balancer_ip\" \"\$load_balancer_host\" >> /etc/hosts" "$blank" \
    && grep -Fq 'load_balancer_host="$CELL_CLUSTER_NAME-external-load-balancer"' "$seed" \
    && grep -Fq '"$CELL_RUN_ID" "$qid" "$role" "$load_balancer_host" "$load_balancer_ip"' "$seed"
}

bootstrap_cni_is_rendered_offline() {
  local stage="$CKA_ROOT/cluster/cells/kubeadm/stage-bootstrap-assets.sh"
  grep -Fq '/kind/manifests/default-cni.yaml' "$stage" \
    && grep -Fq '10.244.0.0\/16' "$stage" \
    && grep -Fq 'CONTROL_PLANE_ENDPOINT' "$stage" \
    && grep -Fq "! grep -Fq '{{'" "$stage"
}

bootstrap_kubeadm_config_is_bounded() {
  local stage="$CKA_ROOT/cluster/cells/kubeadm/stage-bootstrap-assets.sh"
  local solve="$CKA_ROOT/questions/cluster-architecture/ca-12/solve.sh"
  grep -Fq 'apiVersion: kubeadm.k8s.io/v1beta4' "$stage" \
    && grep -Fq 'failSwapOn: false' "$stage" \
    && grep -Fq 'maxPerCore: 0' "$stage" \
    && grep -Fq 'kubeadm config validate --config "$init_tmp"' "$stage" \
    && grep -Fq 'kubeadm init --config /opt/cka/kubeadm-init.yaml' "$solve"
}

bootstrap_join_command_is_tokenized() {
  local solve="$CKA_ROOT/questions/cluster-architecture/ca-12/solve.sh"
  grep -Fq 'read -r -a join_args' "$solve" \
    && grep -Fq '[ "${#join_args[@]}" -eq 7 ]' "$solve" \
    && grep -Fq 'cell_exec ca-12 worker1 "${join_args[@]}"' "$solve" \
    && ! grep -Fq 'bash -c "$join_command"' "$solve"
}

ha_join_command_is_tokenized() {
  local solve="$CKA_ROOT/questions/cluster-architecture/ca-11/solve.sh"
  grep -Fq 'read -r -a join_args' "$solve" \
    && grep -Fq '[ "${#join_args[@]}" -eq 7 ]' "$solve" \
    && grep -Fq 'control_plane_join=(' "$solve" \
    && grep -Fq 'cell_exec ca-11 "$role" "${control_plane_join[@]}"' "$solve" \
    && ! grep -Fq 'bash -c "$control_plane_join"' "$solve"
}

bootstrap_manifest_uses_verified_stdin() {
  local lib="$CKA_ROOT/lib/cell.sh"
  local solve="$CKA_ROOT/questions/cluster-architecture/ca-12/solve.sh"
  grep -Fq 'cell_exec_stdin()' "$lib" \
    && grep -Fq '_cell_docker exec --interactive "$id" "$@"' "$lib" \
    && grep -Fq 'cell_exec_stdin ca-12 cp1 kubectl apply -f -' "$solve"
}

upgrade_seed_forwards_install_script_stdin() {
  local seed="$CKA_ROOT/cluster/cells/kubeadm/seed-upgrade.sh"
  grep -Fq 'cell_exec_stdin "$qid" worker2 bash -s -- "${from_files[@]}"' "$seed" \
    && ! grep -Fq 'cell_exec "$qid" worker2 bash -s -- "${from_files[@]}"' "$seed"
}

upgrade_packages_preserve_kind_kubelet_defaults_noninteractively() {
  local seed="$CKA_ROOT/cluster/cells/kubeadm/seed-upgrade.sh"
  local solve="$CKA_ROOT/questions/cluster-architecture/ca-06/solve.sh"
  local setup="$CKA_ROOT/questions/cluster-architecture/ca-06/setup.sh"
  local grade="$CKA_ROOT/questions/cluster-architecture/ca-06/grade.sh"
  grep -Fq 'export DEBIAN_FRONTEND=noninteractive' "$seed" \
    && grep -Fq 'dpkg --force-confold --install "$@"' "$seed" \
    && grep -Fq 'kubelet_defaults_sha256="$(sha256sum "$kubelet_defaults"' "$seed" \
    && grep -Fq 'export DEBIAN_FRONTEND=noninteractive' "$solve" \
    && [ "$(grep -Fc 'Dpkg::Options::=--force-confold' "$solve")" -eq 2 ] \
    && grep -Fq 'kubelet_defaults_sha256=' "$setup" \
    && grep -Fq 'cell_evidence_get ca-06 kubelet_defaults_sha256' "$grade"
}

ha_contract_is_live() {
  local grader="$CKA_ROOT/lib/cell-grader.sh"
  local active="$CKA_ROOT/cluster/cells/kubeadm/failover-test.sh"
  grep -Fq 'member list --write-out=json' "$grader" \
    && grep -Fq 'endpoint health' "$grader" \
    && grep -Fq 'container stop --time 10 "$cp1_id"' "$active" \
    && grep -Fq 'create configmap "$proof"' "$active" \
    && grep -Fq "jsonpath='{.spec.clusterIP}'" "$active" \
    && grep -Fq 'wget -qO- --timeout=5 "http://$service_ip"' "$active" \
    && grep -Fq '[ "$service_ready" -eq 1 ]' "$active" \
    && grep -Fq "'{{.State.Running}}' \"\$cp1_id\"" "$active"
}

ha_seed_waits_for_stable_membership() {
  local seed="$CKA_ROOT/cluster/cells/kubeadm/seed-ha.sh"
  grep -Fq 'get --raw=/readyz 2>/dev/null || true' "$seed" \
    && grep -Fq 'cell_etcd_members_wait "$cp1" "$cp2"' "$seed" \
    && [ "$(grep -Fc 'cell_etcd_members_wait "$cp1"' "$seed")" -ge 2 ] \
    && grep -Fq 'not member.get("isLearner", False)' "$seed" \
    && grep -Fq -- '--ignore-not-found --wait=true' "$seed"
}

blank_grading_is_bounded() {
  grep -Fq -- '--request-timeout=8s' "$CKA_ROOT/lib/cell-grader.sh" \
    && grep -Fq 'attempts=30' "$CKA_ROOT/lib/cell-grader.sh" \
    && grep -Fq 'test -s /etc/kubernetes/admin.conf' "$CKA_ROOT/lib/cell-grader.sh" \
    && grep -Fq -- '--request-timeout=3s get nodes' "$CKA_ROOT/lib/cell-grader.sh" \
    && grep -Fq '_CELL_GRADER_API_ABSENT=1' "$CKA_ROOT/lib/cell-grader.sh" \
    && grep -Fq '[ "$_CELL_GRADER_API_ABSENT" -eq 0 ] || return 1' \
      "$CKA_ROOT/lib/cell-grader.sh"
}

kubeadm_mutations_have_a_long_but_bounded_timeout() {
  grep -Fq 'CKA_CELL_KUBEADM_DOCKER_TIMEOUT:-300' \
    "$CKA_ROOT/cluster/cells/kubeadm/cell.sh" || return 1
  local qid
  for qid in ca-06 ca-11 ca-12; do
    grep -Fq 'CKA_CELL_KUBEADM_DOCKER_TIMEOUT:-420' \
      "$CKA_ROOT/questions/cluster-architecture/$qid/solve.sh" || return 1
  done
}

manifest_parser_rejects_duplicates() (
  set -euo pipefail
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  export CKA_CELL_RUNTIME_DIR="$temp/runtime"
  export CKA_CELL_ALLOW_NON_NATIVE_STATE=1
  mkdir "$CKA_CELL_RUNTIME_DIR"
  source "$CKA_ROOT/lib/cell.sh"
  mkdir "$CKA_CELL_RUNTIME_DIR/ca-12"
  manifest="$CKA_CELL_RUNTIME_DIR/ca-12/manifest"
  {
    printf 'schema=2\n'
    printf 'run_id=%032d\n' 0
    printf 'question_id=ca-12\n'
    printf 'profile=kubeadm-bootstrap\n'
    printf 'cluster_name=cka-cell-ca-12-000000000000\n'
    printf 'network_name=cka-cell-ca-12-000000000000\n'
    printf 'network_id=%064d\n' 0
    printf 'status=PREPARING\n'
    printf 'volume_count_cp1=0\n'
    printf 'volume_count_worker1=0\n'
    printf 'volume_count_worker2=0\n'
  } > "$manifest"
  chmod 0600 "$manifest"
  cell_manifest_load ca-12
  printf 'status=READY\n' >> "$manifest"
  ! cell_manifest_load ca-12
)

preparing_manifest_supports_crash_cleanup() (
  set -euo pipefail
  local temp
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  export CKA_CELL_RUNTIME_DIR="$temp/runtime"
  export CKA_CELL_ALLOW_NON_NATIVE_STATE=1
  mkdir -m 0700 "$CKA_CELL_RUNTIME_DIR"
  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  mkdir -m 0700 "$CKA_CELL_RUNTIME_DIR/ca-12"
  CELL_RUN_ID=00000000000000000000000000000000
  CELL_QID=ca-12
  CELL_PROFILE=kubeadm-bootstrap
  CELL_CLUSTER_NAME=cka-cell-ca-12-000000000000
  CELL_NETWORK_NAME="$CELL_CLUSTER_NAME"
  CELL_NETWORK_ID=0000000000000000000000000000000000000000000000000000000000000000
  CELL_STATUS=PREPARING
  declare -gA CELL_CONTAINER_IDS=()
  _cell_volume_arrays_init
  CELL_VOLUME_COUNTS[cp1]=0
  CELL_VOLUME_COUNTS[worker1]=0
  CELL_VOLUME_COUNTS[worker2]=0
  _cell_manifest_write ca-12
  cell_manifest_load ca-12
  [ "${#CELL_CONTAINER_IDS[@]}" -eq 0 ]
  CELL_STATUS=DELETING
  _cell_manifest_write ca-12
  cell_manifest_load ca-12
  [ "$CELL_STATUS" = DELETING ] && [ "${#CELL_CONTAINER_IDS[@]}" -eq 0 ]
)

cell_journal_default_is_persistent_across_sessions() (
  set -euo pipefail
  local temp
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  unset CKA_CELL_RUNTIME_DIR
  export HOME="$temp/home"
  export XDG_STATE_HOME="$temp/persistent-state"
  export XDG_RUNTIME_DIR="$temp/session-runtime"
  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  [ "$CKA_CELL_RUNTIME_DIR" = "$XDG_STATE_HOME/cka-practice/cells" ] \
    && [[ "$CKA_CELL_RUNTIME_DIR" != "$XDG_RUNTIME_DIR"/* ]]
)

docker_mount_template_emits_record_newlines() (
  set -euo pipefail
  local id volume expected actual
  id="$(printf 'a%.0s' {1..64})"
  volume="$(printf 'b%.0s' {1..64})"
  expected='{{range .Mounts}}{{if eq .Type "volume"}}{{printf "%s|%s\n" .Name .Destination}}{{end}}{{end}}'
  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  _cell_docker() {
    [ "${1:-}" = container ] && [ "${2:-}" = inspect ] \
      && [ "${3:-}" = --format ] && [ "${4:-}" = "$expected" ] \
      && [ "${5:-}" = "$id" ] || return 97
    printf '%s|/var\n' "$volume"
  }
  actual="$(_cell_container_volume_mounts "$id")"
  [ "$actual" = "$volume|/var" ]
)

docker_network_template_emits_record_newlines() (
  set -euo pipefail
  local network_id first_id second_id expected actual
  network_id="$(printf 'c%.0s' {1..64})"
  first_id="$(printf 'a%.0s' {1..64})"
  second_id="$(printf 'b%.0s' {1..64})"
  expected='{{range .Containers}}{{printf "%s\n" .Name}}{{end}}'
  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  _cell_docker() {
    case "${1:-}:${2:-}" in
      network:inspect)
        [ "${3:-}" = --format ] && [ "${4:-}" = "$expected" ] \
          && [ "${5:-}" = "$network_id" ] || return 97
        printf 'node-a\nnode-b\n'
        ;;
      container:inspect)
        [ "${3:-}" = --format ] && [ "${4:-}" = '{{.Id}}|{{.Name}}' ] \
          || return 96
        case "${5:-}" in
          node-a) printf '%s|/node-a\n' "$first_id" ;;
          node-b) printf '%s|/node-b\n' "$second_id" ;;
          *) return 95 ;;
        esac
        ;;
      *) return 94 ;;
    esac
  }
  actual="$(_cell_network_attachment_ids "$network_id")"
  [ "$actual" = "$first_id"$'\n'"$second_id" ]
)

_preparing_recovery_fake_case() ( # <success|extra|admin>
  set -uo pipefail
  local mode="$1" case_root state_dir rc=0
  local cp1_id worker1_id extra_id network_id cp1_volume worker1_volume
  case_root="$(mktemp -d "${TMPDIR:-/tmp}/cka-cell-recovery.XXXXXX")" || return 1
  case "$case_root" in /tmp/*|/var/tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$case_root"' EXIT
  export CKA_CELL_RUNTIME_DIR="$case_root/runtime"
  export CKA_CELL_ALLOW_NON_NATIVE_STATE=1
  export CKA_ENABLE_DISPOSABLE_CELLS=1
  mkdir -m 0700 "$CKA_CELL_RUNTIME_DIR"
  : > "$case_root/docker.log"

  cp1_id="$(printf 'a%.0s' {1..64})"
  worker1_id="$(printf 'b%.0s' {1..64})"
  extra_id="$(printf 'f%.0s' {1..64})"
  network_id="$(printf 'c%.0s' {1..64})"
  cp1_volume="$(printf 'd%.0s' {1..64})"
  worker1_volume="$(printf 'e%.0s' {1..64})"
  export CKA_FAKE_RECOVERY_NETWORK_ID="$network_id"
  export CKA_FAKE_RECOVERY_RUN_ID=00000000000000000000000000000000

  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  _cell_lock() { :; }
  _cell_docker() {
    local object="${1:-}" action="${2:-}" template="${4:-}" target="${!#}"
    local filter="${!#}" id name volume
    printf '%s\n' "$*" >> "$case_root/docker.log"
    case "$object:$action" in
      info:*) return 0 ;;
      network:inspect)
        if [[ "$template" == *'range .Containers'* ]]; then
          printf '%s-control-plane\n%s-worker\n' \
            "$CELL_CLUSTER_NAME" "$CELL_CLUSTER_NAME"
          [ "$mode" != extra ] || printf 'foreign-extra\n'
        elif [[ "$template" == *'.Name'* ]]; then
          printf '%s|%s|%s|ca-12\n' \
            "$CKA_FAKE_RECOVERY_NETWORK_ID" "$CELL_NETWORK_NAME" \
            "$CKA_FAKE_RECOVERY_RUN_ID"
        else
          printf '%s|%s|ca-12\n' \
            "$CKA_FAKE_RECOVERY_NETWORK_ID" "$CKA_FAKE_RECOVERY_RUN_ID"
        fi
        ;;
      container:inspect)
        case "$target" in
          "$CELL_CLUSTER_NAME-control-plane"|"$cp1_id")
            id="$cp1_id"; name="$CELL_CLUSTER_NAME-control-plane"; volume="$cp1_volume"
            ;;
          "$CELL_CLUSTER_NAME-worker"|"$worker1_id")
            id="$worker1_id"; name="$CELL_CLUSTER_NAME-worker"; volume="$worker1_volume"
            ;;
          *) return 1 ;;
        esac
        if [[ "$template" == *'.Mounts'* ]]; then
          printf '%s|/var\n' "$volume"
        elif [ "$template" = '{{.Id}}|{{.Name}}' ]; then
          printf '%s|/%s\n' "$id" "$name"
        elif [[ "$template" == *'.State.Running'* ]]; then
          printf '%s|%s|true|{"%s":{}}\n' \
            "$id" "$CELL_CLUSTER_NAME" "$CELL_NETWORK_NAME"
        else
          printf '%s|/%s|%s|{"%s":{}}\n' \
            "$id" "$name" "$CELL_CLUSTER_NAME" "$CELL_NETWORK_NAME"
        fi
        ;;
      volume:inspect)
        case "$target" in
          "$cp1_volume"|"$worker1_volume") ;;
          *) return 1 ;;
        esac
        printf '%s|local|local|/var/lib/docker/volumes/%s/_data|sealed|null|null\n' \
          "$target" "$target"
        ;;
      ps:--all)
        case "$filter" in
          label=io.x-k8s.kind.cluster=*)
            printf '%s\n%s\n' "$cp1_id" "$worker1_id"
            [ "$mode" != extra ] || printf '%s\n' "$extra_id"
            ;;
          volume=*)
            case "${filter#volume=}" in
              "$cp1_volume") printf '%s\n' "$cp1_id" ;;
              "$worker1_volume") printf '%s\n' "$worker1_id" ;;
              *) return 1 ;;
            esac
            ;;
          *) return 1 ;;
        esac
        ;;
      container:rm|volume:rm|network:rm)
        return 96
        ;;
      *) return 95 ;;
    esac
  }

  state_dir="$CKA_CELL_RUNTIME_DIR/ca-12"
  CELL_RUN_ID=00000000000000000000000000000000
  CELL_QID=ca-12
  CELL_PROFILE=operator-cell
  CELL_CLUSTER_NAME=cka-cell-ca-12-000000000000
  CELL_NETWORK_NAME="$CELL_CLUSTER_NAME"
  CELL_NETWORK_ID=PENDING
  CELL_STATUS=PREPARING
  declare -gA CELL_CONTAINER_IDS=()
  _cell_volume_arrays_init
  CELL_VOLUME_COUNTS[cp1]=0
  CELL_VOLUME_COUNTS[worker1]=0
  if [ "$mode" != admin ]; then
    mkdir -m 0700 "$state_dir"
    _cell_manifest_write ca-12 || return 1
  fi

  if [ "$mode" = success ]; then
    _cell_recover_preparing_manifest ca-12 || return 1
    cell_manifest_load ca-12 || return 1
    [ "$CELL_NETWORK_ID" = "$network_id" ] \
      && [ "${CELL_CONTAINER_IDS[cp1]}" = "$cp1_id" ] \
      && [ "${CELL_CONTAINER_IDS[worker1]}" = "$worker1_id" ] \
      && [ "${CELL_VOLUME_COUNTS[cp1]}" -eq 1 ] \
      && [ "${CELL_VOLUME_NAMES[cp1:0]}" = "$cp1_volume" ] \
      && [ "${CELL_VOLUME_COUNTS[worker1]}" -eq 1 ] \
      && [ "${CELL_VOLUME_NAMES[worker1:0]}" = "$worker1_volume" ]
  elif [ "$mode" = extra ]; then
    cell_destroy ca-12 >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] && [ -f "$state_dir/manifest" ] \
      && ! grep -Eq -- '(container|volume|network) rm' "$case_root/docker.log"
  else
    cell_recover_preparing ca-12 operator-cell "$CELL_CLUSTER_NAME" >/dev/null \
      || return 1
    cell_manifest_load ca-12 || return 1
    [ "$CELL_STATUS" = PREPARING ] && [ "$CELL_NETWORK_ID" = "$network_id" ] \
      && [ "${CELL_CONTAINER_IDS[cp1]}" = "$cp1_id" ] \
      && [ "${CELL_CONTAINER_IDS[worker1]}" = "$worker1_id" ] \
      && ! grep -Eq -- '(container|volume|network) rm' "$case_root/docker.log"
  fi
)

preparing_journal_recovers_verified_objects() {
  _preparing_recovery_fake_case success
}

preparing_recovery_rejects_unowned_extras() {
  _preparing_recovery_fake_case extra
}

lost_journal_can_be_reconstructed_without_mutation() {
  _preparing_recovery_fake_case admin
}

pending_intent_without_objects_cleans_local_only() (
  set -euo pipefail
  local case_root state_dir
  case_root="$(mktemp -d "${TMPDIR:-/tmp}/cka-cell-pending.XXXXXX")"
  case "$case_root" in /tmp/*|/var/tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$case_root"' EXIT
  export CKA_CELL_RUNTIME_DIR="$case_root/runtime"
  export CKA_CELL_ALLOW_NON_NATIVE_STATE=1
  export CKA_ENABLE_DISPOSABLE_CELLS=1
  mkdir -m 0700 "$CKA_CELL_RUNTIME_DIR"
  : > "$case_root/docker.log"
  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  _cell_lock() { :; }
  _cell_docker() {
    printf '%s\n' "$*" >> "$case_root/docker.log"
    case "${1:-}:${2:-}" in
      info:*) return 0 ;;
      network:inspect) return 1 ;;
      network:ls|ps:--all) return 0 ;;
      container:rm|volume:rm|network:rm) return 96 ;;
      *) return 95 ;;
    esac
  }
  state_dir="$CKA_CELL_RUNTIME_DIR/ca-12"
  mkdir -m 0700 "$state_dir"
  CELL_RUN_ID=00000000000000000000000000000000
  CELL_QID=ca-12
  CELL_PROFILE=operator-cell
  CELL_CLUSTER_NAME=cka-cell-ca-12-000000000000
  CELL_NETWORK_NAME="$CELL_CLUSTER_NAME"
  CELL_NETWORK_ID=PENDING
  CELL_STATUS=PREPARING
  declare -gA CELL_CONTAINER_IDS=()
  _cell_volume_arrays_init
  CELL_VOLUME_COUNTS[cp1]=0
  CELL_VOLUME_COUNTS[worker1]=0
  _cell_manifest_write ca-12
  cell_destroy ca-12 >/dev/null 2>&1
  [ ! -e "$state_dir" ] \
    && ! grep -Eq -- '(container|volume|network) rm' "$case_root/docker.log"
)

stable_api_present() {
  local lib="$CKA_ROOT/lib/cell.sh" function
  for function in cell_prepare cell_activate cell_cleanup cell_status \
      cell_select cell_selected_qid cell_selection_clear \
      cell_selection_clear_current; do
    grep -Eq "^${function}\(\)" "$lib" || return 1
  done
}

active_identity_rejects_context_alias_and_manifest_drift() (
  set -euo pipefail
  local temp expected_context
  temp="$(mktemp -d "${TMPDIR:-/tmp}/cka-cell-identity.XXXXXX")" || return 1
  case "$temp" in /tmp/*|/var/tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  : > "$temp/kubeconfig"
  cell_runtime_readonly_ok() { return "${FAKE_NATIVE_RC:-0}"; }
  cell_selected_qid() { printf '%s\n' "${FAKE_SELECTED_QID:-st-06}"; }
  cell_kubeconfig_path() { printf '%s\n' "$temp/kubeconfig"; }
  cell_manifest_load() {
    CELL_QID=st-06
    CELL_PROFILE="${FAKE_PROFILE:-csi-cell}"
    CELL_STATUS=READY
    CELL_RUN_ID=0123456789abcdef0123456789abcdef
    CELL_CLUSTER_NAME=cka-cell-st-06-0123456789ab
  }
  cell_verify_topology() { return "${FAKE_TOPOLOGY_RC:-0}"; }
  expected_context=kind-cka-cell-st-06-0123456789ab
  export CKA_CELL_QID=st-06 CKA_CELL_ENVIRONMENT=csi-cell
  export CKA_CELL_RUN_ID=0123456789abcdef0123456789abcdef
  export CKA_CELL_CLUSTER_NAME=cka-cell-st-06-0123456789ab
  export CKA_CONTEXT="$expected_context" KUBECONFIG="$temp/kubeconfig"

  cell_active_identity_matches st-06 csi-cell \
    && ! CKA_CONTEXT=kind-cka cell_active_identity_matches st-06 csi-cell \
    && ! CKA_CONTEXT="$expected_context" FAKE_SELECTED_QID=ca-09 \
      cell_active_identity_matches st-06 csi-cell \
    && ! CKA_CONTEXT="$expected_context" FAKE_PROFILE=operator-cell \
      cell_active_identity_matches st-06 csi-cell \
    && ! CKA_CONTEXT="$expected_context" FAKE_NATIVE_RC=1 \
      cell_active_identity_matches st-06 csi-cell \
    && ! CKA_CONTEXT="$expected_context" FAKE_TOPOLOGY_RC=1 \
      cell_active_identity_matches st-06 csi-cell
)

cell_creation_and_readiness_are_bounded() {
  local library="$CKA_ROOT/lib/cell.sh" create ready prepare
  create="$(sed -n '/^cell_create() (/,/^)/p' "$library")" || return 1
  ready="$(sed -n '/^cell_mark_ready() (/,/^)/p' "$library")" || return 1
  prepare="$(sed -n '/^cell_prepare()/,/^}/p' "$library")" || return 1
  grep -Fq '_cell_external_timeout "${CKA_CELL_KIND_CREATE_TIMEOUT_SECONDS}s"' <<<"$create" \
    && grep -Fq -- '--wait "${CKA_CELL_KIND_WAIT_SECONDS}s"' <<<"$create" \
    && grep -Fq 'cell_wait_api_ready "$qid"' <<<"$ready" \
    && grep -Fq 'kubeadm-bootstrap)' <<<"$ready" \
    && [ "$(grep -Fc '_cell_external_timeout "${timeout_seconds}s"' <<<"$prepare")" -eq 2 ] \
    && grep -Fq 'timeout --foreground --kill-after=5s' "$library" \
    && grep -Fq -- '--request-timeout=3s get --raw=/readyz' "$library"
}

lifecycle_lock_acquisition_is_bounded() {
  local library="$CKA_ROOT/lib/cell.sh" runtime="$CKA_ROOT/lib/question-runtime.sh" body
  body="$(sed -n '/^_cell_lock()/,/^}/p' "$library")" || return 1
  grep -Fq 'CKA_CELL_LOCK_WAIT_SECONDS="${CKA_CELL_LOCK_WAIT_SECONDS:-15}"' "$library" \
    && grep -Fq 'CKA_CELL_LOCK_WAIT_MAX_SECONDS=120' "$library" \
    && grep -Fq 'CKA_CELL_LOCK_TIMEOUT_RC=75' "$library" \
    && grep -Fq -- '--wait "$CKA_CELL_LOCK_WAIT_SECONDS"' <<<"$body" \
    && grep -Fq -- '--conflict-exit-code "$CKA_CELL_LOCK_TIMEOUT_RC"' <<<"$body" \
    && grep -Fq 'rc=$?' <<<"$body" \
    && grep -Fq 'exec {CELL_LOCK_FD}>&-' <<<"$body" \
    && [ "$(grep -Fc '_cell_lock || return $?' "$library")" -eq 4 ] \
    && grep -Fq 'active selection is cleared only after exact cleanup succeeds' "$runtime" \
    && grep -Fq 'return "$cleanup_rc"' "$runtime"
}

selection_pointer_is_strict() (
  set -euo pipefail
  local temp
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  export CKA_STATE_DIR="$temp/state"
  export CKA_CELL_RUNTIME_DIR="$temp/runtime"
  export CKA_CELL_ALLOW_NON_NATIVE_STATE=1
  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  cell_status() { return 0; }
  cell_manifest_load() { CELL_STATUS=READY; return 0; }
  cell_select ca-12 kubeadm-bootstrap
  [ "$(cell_selected_qid)" = ca-12 ]
  printf 'unexpected\n' >> "$(cell_selection_path)"
  ! cell_selected_qid >/dev/null 2>&1
  sed -i '$d' "$(cell_selection_path)"
  cell_selection_clear ca-12
  [ ! -e "$(cell_selection_path)" ]
)

ssh_wrapper_uses_verified_cell_ids() {
  local wrapper="$CKA_ROOT/bin/ssh"
  grep -Fq 'cell_selected_qid' "$wrapper" \
    && grep -Fq 'cell_verify_topology' "$wrapper" \
    && grep -Fq 'cell_verify_container_id' "$wrapper" \
    && grep -Fq 'ACTIVE_CELL_SELECTION_SEEN' "$wrapper" \
    && grep -Fq 'must fail closed instead of silently reaching the shared' "$wrapper" \
    && grep -Fq 'docker exec -it "$ACTIVE_CELL_CONTAINER_ID"' "$wrapper" \
    && ! grep -Fq 'docker exec -it "$ACTIVE_CELL_CLUSTER_NAME"' "$wrapper"
}

ssh_wrapper_never_falls_back_from_broken_selection() (
  local temp rc
  temp="$(mktemp -d "${TMPDIR:-/tmp}/cka-cell-ssh.XXXXXX")" || return 1
  case "$temp" in /tmp/*|/var/tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  mkdir -p "$temp/state" "$temp/cells" "$temp/bin"
  printf 'ca-06\n' > "$temp/state/active-cell"
  printf '%s\n' '#!/usr/bin/env bash' 'printf called > "$CKA_FAKE_DOCKER_LOG"' 'exit 0' \
    > "$temp/bin/docker"
  chmod 0755 "$temp/bin/docker"
  set +e
  CKA_STATE_DIR="$temp/state" CKA_CELL_RUNTIME_DIR="$temp/cells" \
    CKA_FAKE_DOCKER_LOG="$temp/docker-called" PATH="$temp/bin:$PATH" \
    bash "$CKA_ROOT/bin/ssh" worker2 true >"$temp/out" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 255 ] \
    && [ ! -e "$temp/docker-called" ] \
    && grep -Fq '일회용 셀을 안전하게 검증할 수 없어' "$temp/out"
)

ssh_wrapper_never_falls_back_when_cell_library_is_unavailable() (
  local temp wrapper rc
  wrapper="$CKA_ROOT/bin/ssh"
  temp="$(mktemp -d "${TMPDIR:-/tmp}/cka-cell-ssh-lib.XXXXXX")" || return 1
  case "$temp" in /tmp/*|/var/tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  mkdir -p "$temp/state" "$temp/bin"
  printf 'ca-06\n' > "$temp/state/active-cell"
  printf '%s\n' '#!/usr/bin/env bash' 'printf called > "$CKA_FAKE_DOCKER_LOG"' 'exit 0' \
    > "$temp/bin/docker"
  chmod 0755 "$temp/bin/docker"
  set +e
  CKA_ROOT="$temp" CKA_STATE_DIR="$temp/state" \
    CKA_FAKE_DOCKER_LOG="$temp/docker-called" PATH="$temp/bin:$PATH" \
    bash "$wrapper" worker2 true >"$temp/out" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 255 ] \
    && [ ! -e "$temp/docker-called" ] \
    && grep -Fq '일회용 셀을 안전하게 검증할 수 없어' "$temp/out"
)

_volume_cleanup_fake_case() ( # <success|stopped|foreign-endpoint|foreign-mount|linked|fingerprint-drift>
  set -uo pipefail
  local mode="$1" case_root state_dir rc=0
  local cp1_id worker1_id network_id cp1_volume worker1_volume sentinel_volume foreign_id
  case_root="$(mktemp -d "${TMPDIR:-/tmp}/cka-cell-volumes.XXXXXX")" || return 1
  case "$case_root" in /tmp/*|/var/tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$case_root"' EXIT
  export CKA_CELL_RUNTIME_DIR="$case_root/runtime"
  export CKA_CELL_ALLOW_NON_NATIVE_STATE=1
  export CKA_ENABLE_DISPOSABLE_CELLS=1
  export CKA_FAKE_VOLUME_MODE="$mode"
  export CKA_FAKE_VOLUME_GENERATION=sealed
  mkdir -m 0700 "$CKA_CELL_RUNTIME_DIR"
  : > "$case_root/docker.log"

  cp1_id="$(printf 'a%.0s' {1..64})"
  worker1_id="$(printf 'b%.0s' {1..64})"
  network_id="$(printf 'c%.0s' {1..64})"
  cp1_volume="$(printf 'd%.0s' {1..64})"
  worker1_volume="$(printf 'e%.0s' {1..64})"
  foreign_id="$(printf 'f%.0s' {1..64})"
  sentinel_volume="$(printf '9%.0s' {1..64})"
  printf '%s\n%s\n' "$cp1_id" "$worker1_id" > "$case_root/containers"
  printf '%s\n%s\n%s\n' "$cp1_volume" "$worker1_volume" "$sentinel_volume" \
    > "$case_root/volumes"

  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  _cell_lock() { :; }
  _cell_docker() {
    local object="${1:-}" action="${2:-}" template="${4:-}" target="${!#}"
    local filter="${!#}" own_id="" volume_name=""
    printf '%s\n' "$*" >> "$case_root/docker.log"
    case "$object:$action" in
      info:*) return 0 ;;
      container:inspect)
        case "$target" in
          "$CELL_CLUSTER_NAME-control-plane")
            own_id="$cp1_id"; volume_name="$CELL_CLUSTER_NAME-control-plane"
            ;;
          "$CELL_CLUSTER_NAME-worker")
            own_id="$worker1_id"; volume_name="$CELL_CLUSTER_NAME-worker"
            ;;
          "$CELL_CLUSTER_NAME-foreign")
            own_id="$foreign_id"; volume_name="$CELL_CLUSTER_NAME-foreign"
            ;;
          *) own_id="$target" ;;
        esac
        if ! grep -Fxq -- "$own_id" "$case_root/containers" \
            && ! { [ "$CKA_FAKE_VOLUME_MODE" = foreign-endpoint ] \
              && [ "$own_id" = "$foreign_id" ]; }; then
          return 1
        fi
        if [ "${3:-}" != --format ]; then
          printf '{}\n'
        elif [[ "$template" == *'.Mounts'* ]]; then
          if [ "$own_id" = "$cp1_id" ]; then
            printf '%s|/var\n' "$cp1_volume"
            if [ "$CKA_FAKE_VOLUME_MODE" = foreign-mount ]; then
              printf '%s|/foreign\n' "$sentinel_volume"
            fi
          elif [ "$own_id" = "$worker1_id" ]; then
            printf '%s|/var\n' "$worker1_volume"
          else
            return 1
          fi
        elif [ "$template" = '{{.Id}}|{{.Name}}' ]; then
          [ -n "$volume_name" ] || {
            if [ "$own_id" = "$cp1_id" ]; then
              volume_name="$CELL_CLUSTER_NAME-control-plane"
            else
              volume_name="$CELL_CLUSTER_NAME-worker"
            fi
          }
          printf '%s|/%s\n' "$own_id" "$volume_name"
        else
          if [ "$CKA_FAKE_VOLUME_MODE" = stopped ] && [ "$own_id" = "$cp1_id" ]; then
            printf '%s|%s|false|{"%s":{}}\n' \
              "$own_id" "$CELL_CLUSTER_NAME" "$CELL_NETWORK_NAME"
          else
            printf '%s|%s|true|{"%s":{}}\n' \
              "$own_id" "$CELL_CLUSTER_NAME" "$CELL_NETWORK_NAME"
          fi
        fi
        ;;
      volume:inspect)
        grep -Fxq -- "$target" "$case_root/volumes" || return 1
        printf '%s|local|local|/var/lib/docker/volumes/%s/_data|%s|null|null\n' \
          "$target" "$target" "$CKA_FAKE_VOLUME_GENERATION"
        ;;
      ps:*)
        case "$filter" in
          label=io.x-k8s.kind.cluster=*)
            sed '/^$/d' "$case_root/containers"
            ;;
          volume=*)
            volume_name="${filter#volume=}"
            if [ "$volume_name" = "$cp1_volume" ]; then own_id="$cp1_id"; fi
            if [ "$volume_name" = "$worker1_volume" ]; then own_id="$worker1_id"; fi
            if [ -n "$own_id" ] && grep -Fxq -- "$own_id" "$case_root/containers"; then
              printf '%s\n' "$own_id"
            fi
            if [ "$CKA_FAKE_VOLUME_MODE" = linked ] \
                && [ "$volume_name" = "$cp1_volume" ]; then
              printf '%s\n' "$foreign_id"
            fi
            ;;
          *) return 1 ;;
        esac
        ;;
      container:rm)
        target="${!#}"
        grep -Fxq -- "$target" "$case_root/containers" || return 1
        awk -v target="$target" '$0 != target' "$case_root/containers" \
          > "$case_root/containers.next" || return 1
        mv -- "$case_root/containers.next" "$case_root/containers"
        ;;
      volume:rm)
        target="${!#}"
        grep -Fxq -- "$target" "$case_root/volumes" || return 1
        awk -v target="$target" '$0 != target' "$case_root/volumes" \
          > "$case_root/volumes.next" || return 1
        mv -- "$case_root/volumes.next" "$case_root/volumes"
        ;;
      network:inspect)
        if [[ "$template" == *'len .Containers'* ]]; then
          printf '0\n'
        elif [[ "$template" == *'range .Containers'* ]]; then
          if [ "$CKA_FAKE_VOLUME_MODE" != stopped ]; then
            grep -Fxq -- "$cp1_id" "$case_root/containers" \
              && printf '%s-control-plane\n' "$CELL_CLUSTER_NAME"
          fi
          grep -Fxq -- "$worker1_id" "$case_root/containers" \
            && printf '%s-worker\n' "$CELL_CLUSTER_NAME"
          [ "$CKA_FAKE_VOLUME_MODE" != foreign-endpoint ] \
            || printf '%s-foreign\n' "$CELL_CLUSTER_NAME"
        else
          printf '%s|%s|ca-12\n' "$network_id" "$CELL_RUN_ID"
        fi
        ;;
      network:rm) return 0 ;;
      *) return 97 ;;
    esac
  }

  state_dir="$CKA_CELL_RUNTIME_DIR/ca-12"
  mkdir -m 0700 "$state_dir"
  CELL_RUN_ID=00000000000000000000000000000000
  CELL_QID=ca-12
  CELL_PROFILE=operator-cell
  CELL_CLUSTER_NAME=cka-cell-ca-12-000000000000
  CELL_NETWORK_NAME="$CELL_CLUSTER_NAME"
  CELL_NETWORK_ID="$network_id"
  CELL_STATUS=READY
  declare -gA CELL_CONTAINER_IDS=([cp1]="$cp1_id" [worker1]="$worker1_id")
  _cell_volume_arrays_init
  CELL_VOLUME_COUNTS[cp1]=1
  CELL_VOLUME_COUNTS[worker1]=1
  CELL_VOLUME_NAMES[cp1:0]="$cp1_volume"
  CELL_VOLUME_NAMES[worker1:0]="$worker1_volume"
  CELL_VOLUME_DESTINATIONS[cp1:0]=/var
  CELL_VOLUME_DESTINATIONS[worker1:0]=/var
  CELL_VOLUME_FINGERPRINTS[cp1:0]="$(_cell_volume_fingerprint "$cp1_volume")"
  CELL_VOLUME_FINGERPRINTS[worker1:0]="$(_cell_volume_fingerprint "$worker1_volume")"
  _cell_manifest_write ca-12 || return 1
  if [ "$mode" = fingerprint-drift ]; then
    CKA_FAKE_VOLUME_GENERATION=recreated
  fi

  cell_destroy ca-12 >/dev/null 2>&1 || rc=$?
  case "$mode" in
    success|stopped)
      [ "$rc" -eq 0 ] && [ ! -e "$state_dir" ] \
        && [ "$(sed '/^$/d' "$case_root/volumes")" = "$sentinel_volume" ] \
        && [ "$(grep -Fc -- "volume rm $cp1_volume" "$case_root/docker.log")" -eq 1 ] \
        && [ "$(grep -Fc -- "volume rm $worker1_volume" "$case_root/docker.log")" -eq 1 ] \
        && ! grep -Fq -- "volume rm $sentinel_volume" "$case_root/docker.log" \
        && ! grep -Fq -- 'volume prune' "$case_root/docker.log"
      ;;
    foreign-endpoint|foreign-mount|linked|fingerprint-drift)
      [ "$rc" -ne 0 ] && [ -f "$state_dir/manifest" ] \
        && ! grep -Fq -- 'container rm --force' "$case_root/docker.log" \
        && ! grep -Fq -- 'volume rm ' "$case_root/docker.log" \
        && ! grep -Fq -- 'network rm ' "$case_root/docker.log"
      ;;
    *) return 1 ;;
  esac
)

owned_anonymous_volumes_are_removed_exactly() {
  _volume_cleanup_fake_case success
}

foreign_volume_mount_fails_closed() {
  _volume_cleanup_fake_case foreign-mount
}

foreign_volume_attachment_fails_closed() {
  _volume_cleanup_fake_case linked
}

recreated_volume_generation_fails_closed() {
  _volume_cleanup_fake_case fingerprint-drift
}

stopped_sealed_container_may_lack_a_live_network_endpoint() {
  _volume_cleanup_fake_case stopped
}

foreign_network_endpoint_fails_closed() {
  _volume_cleanup_fake_case foreign-endpoint
}

host_space_preflight_is_bounded_and_explicit() (
  set -uo pipefail
  # shellcheck source=../lib/cell.sh
  source "$CKA_ROOT/lib/cell.sh"
  local fake_available=10485760
  _cell_df() {
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf 'fake 99999999 1 %s 1%% /workspace\n' "$fake_available"
  }
  CKA_CELL_ALLOW_LOW_HOST_SPACE=0 cell_host_storage_preflight >/dev/null 2>&1
  fake_available=10485759
  ! CKA_CELL_ALLOW_LOW_HOST_SPACE=0 cell_host_storage_preflight >/dev/null 2>&1 \
    && CKA_CELL_ALLOW_LOW_HOST_SPACE=1 cell_host_storage_preflight >/dev/null 2>&1 \
    && ! CKA_CELL_ALLOW_LOW_HOST_SPACE=unexpected \
      cell_host_storage_preflight >/dev/null 2>&1
)

host_space_preflight_precedes_docker_access() {
  local body preflight_line docker_line network_line
  body="$(sed -n '/^cell_create() (/,/^)/p' "$CKA_ROOT/lib/cell.sh")" || return 1
  preflight_line="$(printf '%s\n' "$body" | grep -n -F \
    'cell_host_storage_preflight || return 1' | cut -d: -f1)" || return 1
  docker_line="$(printf '%s\n' "$body" | grep -n -F \
    '_cell_docker info >/dev/null' | cut -d: -f1)" || return 1
  network_line="$(printf '%s\n' "$body" | grep -n -F \
    'network_id="$(_cell_docker network create' | cut -d: -f1)" || return 1
  [ "$preflight_line" -lt "$docker_line" ] && [ "$docker_line" -lt "$network_line" ] \
    && grep -Fxq 'CKA_CELL_MIN_HOST_FREE_KIB=10485760' "$CKA_ROOT/lib/cell.sh" \
    && ! grep -Eq 'CKA_CELL_MIN_HOST_FREE_KIB=.*:-' "$CKA_ROOT/lib/cell.sh"
}

check "all new shell files pass bash -n" all_shell_syntax_valid
check "ca-11 criterion points match metadata" points_match ca-11
check "ca-12 criterion points match metadata" points_match ca-12
check "kubeadm live gate expected scores match question metadata" \
  live_gate_points_match_metadata
check "cleanup is immutable-ID and owner bound" cleanup_is_id_and_owner_bound
check "cell code never targets shared cluster objects" shared_cluster_is_not_referenced
check "blank-node contract performs real kubeadm reset and residue scrub" blank_contract_is_real
check "HA blank nodes retain only the run-owned load-balancer host mapping" \
  ha_blank_nodes_preserve_only_the_owned_lb_name
check "bootstrap CNI template is rendered offline and rejects leftovers" \
  bootstrap_cni_is_rendered_offline
check "bootstrap kubeadm config pins runtime compatibility settings" \
  bootstrap_kubeadm_config_is_bounded
check "bootstrap join command is validated and executed without shell reparse" \
  bootstrap_join_command_is_tokenized
check "HA join command tolerates output whitespace without shell reparse" \
  ha_join_command_is_tokenized
check "bootstrap manifest stdin keeps immutable cell verification" \
  bootstrap_manifest_uses_verified_stdin
check "upgrade seed forwards its package-install script through verified stdin" \
  upgrade_seed_forwards_install_script_stdin
check "upgrade installs are non-interactive and preserve KIND kubelet defaults" \
  upgrade_packages_preserve_kind_kubelet_defaults_noninteractively
check "HA grader and active contract inspect real etcd and failover paths" ha_contract_is_live
check "HA seed waits for stable API and exact sequential etcd membership" \
  ha_seed_waits_for_stable_membership
check "blank-node grader API calls have an authoritative timeout" blank_grading_is_bounded
check "kubeadm mutations have a long but bounded Docker timeout" \
  kubeadm_mutations_have_a_long_but_bounded_timeout
check "strict manifest parser rejects duplicate keys" manifest_parser_rejects_duplicates
check "PREPARING manifests without containers remain safely cleanup-readable" \
  preparing_manifest_supports_crash_cleanup
check "cell journal defaults to persistent XDG state instead of session runtime" \
  cell_journal_default_is_persistent_across_sessions
check "Docker mount template uses a real Go-template newline escape" \
  docker_mount_template_emits_record_newlines
check "Docker network template uses a real Go-template newline escape" \
  docker_network_template_emits_record_newlines
check "PREPARING journal recovers and seals only verified cell objects" \
  preparing_journal_recovers_verified_objects
check "PREPARING recovery refuses an unjournaled same-cluster container" \
  preparing_recovery_rejects_unowned_extras
check "an exact lost PREPARING journal can be reconstructed without Docker mutation" \
  lost_journal_can_be_reconstructed_without_mutation
check "an unallocated PREPARING intent removes local state without Docker mutation" \
  pending_intent_without_objects_cleans_local_only
check "runner-facing stable cell API exists" stable_api_present
check "cell mutation identity rejects shared aliases and sealed-state drift" \
  active_identity_rejects_context_alias_and_manifest_drift
check "cell creation, prepare and API readiness have explicit deadlines" \
  cell_creation_and_readiness_are_bounded
check "lifecycle lock contention is bounded and preserves its timeout status" \
  lifecycle_lock_acquisition_is_bounded
check "active cell selection rejects extra data and clears exactly" selection_pointer_is_strict
check "ssh wrapper enters disposable nodes by verified immutable ID" ssh_wrapper_uses_verified_cell_ids
check "broken active-cell selection never falls back to shared nodes" \
  ssh_wrapper_never_falls_back_from_broken_selection
check "unavailable cell library never falls back from an active selection" \
  ssh_wrapper_never_falls_back_when_cell_library_is_unavailable
check "cleanup removes only manifest-sealed anonymous volumes by exact name" \
  owned_anonymous_volumes_are_removed_exactly
check "cleanup rejects an unexpected foreign volume mount before mutation" \
  foreign_volume_mount_fails_closed
check "cleanup rejects a sealed volume linked to a foreign container" \
  foreign_volume_attachment_fails_closed
check "cleanup rejects a same-name recreated volume generation" \
  recreated_volume_generation_fails_closed
check "cleanup permits a stopped sealed container without a live network endpoint" \
  stopped_sealed_container_may_lack_a_live_network_endpoint
check "cleanup rejects a network endpoint outside the sealed container allowlist" \
  foreign_network_endpoint_fails_closed
check "host-space guard enforces the 10 GiB floor with explicit opt-in only" \
  host_space_preflight_is_bounded_and_explicit
check "host-space guard runs before Docker access or object allocation" \
  host_space_preflight_precedes_docker_access

printf '%s\n' "kubeadm-cell-contract-test: pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
