#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

run_id=""
base_image="${CKA_SSH_BASE_IMAGE:-cka-practice/ssh-base:v1}"
target_image="${CKA_SSH_TARGET_IMAGE:-cka-practice/ssh-target:v1}"
cluster_network="${CKA_SSH_CLUSTER_NETWORK:-}"
active_question=""
workdir_root=""
questions_file=""
verify_api=0
declare -a kubeconfig_specs=()

usage() {
  cat <<'EOF'
usage: start.sh --run-id ID --kubeconfig QUESTION=PATH [options]

options:
  --kubeconfig QUESTION=PATH   repeat for each question
  --active-question QUESTION   initially selected kubeconfig (default: first)
  --cluster-network NETWORK    additionally attach target to the cluster network
  --workdir-root PATH          copy trusted question inputs from this host path
  --questions-file PATH        selected question IDs (required with --workdir-root)
  --verify-api                 require a live API request through base -> target SSH
  --base-image IMAGE
  --target-image IMAGE
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id) [ "$#" -ge 2 ] || ssh_exam_die '--run-id needs a value'; run_id="$2"; shift 2 ;;
    --kubeconfig) [ "$#" -ge 2 ] || ssh_exam_die '--kubeconfig needs a value'; kubeconfig_specs+=("$2"); shift 2 ;;
    --active-question) [ "$#" -ge 2 ] || ssh_exam_die '--active-question needs a value'; active_question="$2"; shift 2 ;;
    --cluster-network) [ "$#" -ge 2 ] || ssh_exam_die '--cluster-network needs a value'; cluster_network="$2"; shift 2 ;;
    --workdir-root) [ "$#" -ge 2 ] || ssh_exam_die '--workdir-root needs a value'; workdir_root="$2"; shift 2 ;;
    --questions-file) [ "$#" -ge 2 ] || ssh_exam_die '--questions-file needs a value'; questions_file="$2"; shift 2 ;;
    --verify-api) verify_api=1; shift ;;
    --base-image) [ "$#" -ge 2 ] || ssh_exam_die '--base-image needs a value'; base_image="$2"; shift 2 ;;
    --target-image) [ "$#" -ge 2 ] || ssh_exam_die '--target-image needs a value'; target_image="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; ssh_exam_die "unknown argument: $1" ;;
  esac
done

ssh_exam_validate_run_id "$run_id"
[ "${#kubeconfig_specs[@]}" -gt 0 ] || ssh_exam_die 'at least one --kubeconfig is required'
[ -z "$workdir_root" ] && [ -z "$questions_file" ] \
  || { [ -n "$workdir_root" ] && [ -n "$questions_file" ]; } \
  || ssh_exam_die '--workdir-root and --questions-file must be used together'
if [ -n "$workdir_root" ]; then
  ssh_exam_require_safe_work_root "$workdir_root"
  [ -r "$questions_file" ] || ssh_exam_die "questions file is not readable: $questions_file"
fi
ssh_exam_require_docker
ssh_exam_require_image_role "$base_image" base
ssh_exam_require_image_role "$target_image" target
ssh_exam_require_image_label "$target_image" org.cka-practice.tool.kubectl v1.35.0
ssh_exam_require_image_label "$target_image" org.cka-practice.tool.yq v4.48.2

prefix="$(ssh_exam_prefix "$run_id")"
base_container="${prefix}-base"
target_container="${prefix}-target"
run_network="${prefix}-net"

ssh_exam_container_exists "$base_container" && ssh_exam_die "container already exists: $base_container"
ssh_exam_container_exists "$target_container" && ssh_exam_die "container already exists: $target_container"
ssh_exam_network_exists "$run_network" && ssh_exam_die "network already exists: $run_network"

if [ -n "$cluster_network" ]; then
  [ "$cluster_network" != "$run_network" ] || ssh_exam_die 'cluster network must differ from run network'
  ssh_exam_network_exists "$cluster_network" || ssh_exam_die "cluster network not found: $cluster_network"
fi

declare -A kubeconfig_paths=()
first_question=""
for spec in "${kubeconfig_specs[@]}"; do
  case "$spec" in
    *=*) ;;
    *) ssh_exam_die "invalid --kubeconfig value: $spec" ;;
  esac
  question_id="${spec%%=*}"
  kubeconfig_path="${spec#*=}"
  ssh_exam_validate_question_id "$question_id"
  [ -z "${kubeconfig_paths[$question_id]+x}" ] || ssh_exam_die "duplicate question id: $question_id"
  [ -f "$kubeconfig_path" ] && [ -r "$kubeconfig_path" ] && [ -s "$kubeconfig_path" ] \
    || ssh_exam_die "kubeconfig must be a readable non-empty file: $kubeconfig_path"
  kubeconfig_paths[$question_id]="$kubeconfig_path"
  [ -n "$first_question" ] || first_question="$question_id"
done

if [ -z "$active_question" ]; then
  active_question="$first_question"
else
  ssh_exam_validate_question_id "$active_question"
  [ -n "${kubeconfig_paths[$active_question]+x}" ] \
    || ssh_exam_die "active question has no kubeconfig: $active_question"
fi

if [ -n "$questions_file" ]; then
  declare -A selected_questions=()
  while IFS= read -r question_id; do
    question_id="${question_id%$'\r'}"
    ssh_exam_validate_question_id "$question_id"
    [ -z "${selected_questions[$question_id]+x}" ] \
      || ssh_exam_die "duplicate question in questions file: $question_id"
    [ -n "${kubeconfig_paths[$question_id]+x}" ] \
      || ssh_exam_die "question has no kubeconfig: $question_id"
    selected_questions[$question_id]=1
  done < "$questions_file"
  [ "${#selected_questions[@]}" -gt 0 ] || ssh_exam_die 'questions file is empty'
fi

created=0
cleanup_on_failure() {
  local rc=$?
  trap - ERR INT TERM
  if [ "$created" -eq 1 ]; then
    bash "$SCRIPT_DIR/cleanup.sh" --run-id "$run_id" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup_on_failure ERR INT TERM

docker network create --driver bridge --internal \
  --label "org.cka-practice.ssh-run=$run_id" \
  --label 'org.cka-practice.ssh-purpose=designated-host' \
  "$run_network" >/dev/null
created=1

docker run --detach \
  --name "$target_container" \
  --hostname cka-target \
  --network "$run_network" \
  --network-alias cka-target \
  --label "org.cka-practice.ssh-run=$run_id" \
  --label 'org.cka-practice.ssh-role=target' \
  --pids-limit 512 \
  --cap-drop NET_RAW \
  --cap-drop MKNOD \
  "$target_image" >/dev/null

if [ -n "$cluster_network" ]; then
  docker network connect "$cluster_network" "$target_container"
fi

docker run --detach --interactive --tty \
  --name "$base_container" \
  --hostname base \
  --network "$run_network" \
  --label "org.cka-practice.ssh-run=$run_id" \
  --label 'org.cka-practice.ssh-role=base' \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 128 \
  --tmpfs /tmp:rw,noexec,nosuid,size=32m \
  "$base_image" >/dev/null

# Create an ephemeral candidate key in the base container.  Only its public
# half is copied to the designated host.
docker exec --user candidate "$base_container" bash -lc \
  'umask 077; mkdir -p "$HOME/.ssh"; chmod 0700 "$HOME/.ssh"; ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"'
public_key="$(docker exec --user candidate "$base_container" \
  cat /home/candidate/.ssh/id_ed25519.pub)"
printf '%s\n' "$public_key" | docker exec --interactive --user root "$target_container" sh -c \
  'umask 077; cat > /home/candidate/.ssh/authorized_keys; chown candidate:candidate /home/candidate/.ssh/authorized_keys; chmod 0600 /home/candidate/.ssh/authorized_keys'

for question_id in "${!kubeconfig_paths[@]}"; do
  kubeconfig_path="${kubeconfig_paths[$question_id]}"
  docker exec --interactive --user root "$target_container" sh -c \
    "umask 022; cat > /etc/cka/kubeconfigs/${question_id}.yaml; chmod 0444 /etc/cka/kubeconfigs/${question_id}.yaml" \
    < "$kubeconfig_path"
done

if [ -n "$workdir_root" ]; then
  bash "$SCRIPT_DIR/push-work.sh" \
    --run-id "$run_id" \
    --source-root "$workdir_root" \
    --questions-file "$questions_file"
fi

docker exec --user candidate --env HOME=/home/candidate "$target_container" \
  cka-use-context "$active_question" >/dev/null

docker exec --user candidate "$base_container" bash -lc '
  for attempt in $(seq 1 30); do
    if ssh-keyscan -T 2 -t ed25519 cka-target > "$HOME/.ssh/known_hosts" 2>/dev/null \
       && test -s "$HOME/.ssh/known_hosts"; then
      chmod 0600 "$HOME/.ssh/known_hosts"
      exit 0
    fi
    sleep 1
  done
  exit 1
'

# Fail closed if the image contract or the actual SSH path is broken.
docker exec --user candidate "$base_container" sh -c '
  set -eu
  command -v ssh >/dev/null
  for tool in kubectl k yq curl wget man sudo; do
    if command -v "$tool" >/dev/null 2>&1; then
      echo "unexpected base-host tool: $tool" >&2
      exit 1
    fi
  done
'
docker exec --user candidate "$base_container" ssh -o BatchMode=yes cka-target '
  set -euo pipefail
  test "$(id -un)" = candidate
  for tool in kubectl k yq curl wget man sudo; do command -v "$tool" >/dev/null; done
  ! command -v ssh >/dev/null 2>&1
  test -s "$HOME/.kube/config"
  case "$(uname -m)" in
    x86_64)
      kubectl_sha=a2e984a18a0c063279d692533031c1eff93a262afcc0afdc517375432d060989
      yq_sha=0ffc35320180d4911bc3a772934da508715e08af444cb33d4d43660065e25bcc
      ;;
    aarch64)
      kubectl_sha=58f82f9fe796c375c5c4b8439850b0f3f4d401a52434052f2df46035a8789e25
      yq_sha=3c21630fda217239a5b7d718d08f08e02503098230b3abd49195d315a6dcfe45
      ;;
    *) echo "unsupported target architecture" >&2; exit 1 ;;
  esac
  echo "$kubectl_sha  /usr/local/bin/kubectl" | sha256sum --check --strict >/dev/null
  echo "$yq_sha  /usr/local/bin/yq" | sha256sum --check --strict >/dev/null
  kubectl version --client | grep -Fx "Client Version: v1.35.0" >/dev/null
  yq --version | grep -F "version v4.48.2" >/dev/null
'

if [ "$verify_api" -eq 1 ]; then
  docker exec --user candidate "$base_container" ssh -o BatchMode=yes cka-target \
    'kubectl --request-timeout=10s get --raw=/readyz | grep -qx ok'
fi

trap - ERR INT TERM

printf 'SSH practice run is ready.\n'
printf '  enter base: docker exec -it %s bash\n' "$base_container"
printf '  then run:   ssh cka-target\n'
printf '  context:    cka-use-context <question-id>\n'
printf '  seal:       bash %s/seal.sh --run-id %s\n' "$SCRIPT_DIR" "$run_id"
printf '  cleanup:    bash %s/cleanup.sh --run-id %s\n' "$SCRIPT_DIR" "$run_id"
