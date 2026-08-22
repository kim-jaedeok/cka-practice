#!/usr/bin/env bash
# Exact, fail-closed lifecycle for anonymous volumes owned by the disposable
# KIND nodes created by ssh-supervised-live-test.sh.
#
# Docker documents that anonymous volumes persist after their container is
# removed unless container creation used --rm.  Consequently this helper
# journals each volume generation before teardown and removes only that sealed
# allowlist after proving it is no longer attached.
# https://docs.docker.com/engine/storage/volumes/#named-and-anonymous-volumes

SSH_LIVE_DOCKER_BIN="${SSH_LIVE_DOCKER_BIN:-docker}"
SSH_LIVE_VOLUME_SCHEMA=1

ssh_live_volume_docker_id_valid() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
ssh_live_volume_destination_valid() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    && [[ "$1" != *'//'* ]] && [[ "$1" != *'/../'* ]] \
    && [[ "$1" != '/..' ]] && [[ "$1" != *'/./'* ]] && [[ "$1" != '/.' ]]
}

_ssh_live_volume_fingerprint() { # <64-hex-volume-name>
  local name="$1" record actual driver scope mountpoint created labels options extra fingerprint
  ssh_live_volume_docker_id_valid "$name" || return 1
  record="$("$SSH_LIVE_DOCKER_BIN" volume inspect --format \
    '{{.Name}}|{{.Driver}}|{{.Scope}}|{{.Mountpoint}}|{{.CreatedAt}}|{{json .Labels}}|{{json .Options}}' \
    "$name" 2>/dev/null)" || return 1
  [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
  IFS='|' read -r actual driver scope mountpoint created labels options extra <<< "$record"
  [ -z "${extra:-}" ] && [ "$actual" = "$name" ] && [ "$driver" = local ] \
    && [ "$scope" = local ] && [[ "$mountpoint" = /* ]] || return 1
  fingerprint="$(printf '%s' "$record" | sha256sum)" || return 1
  fingerprint="${fingerprint%% *}"
  ssh_live_volume_docker_id_valid "$fingerprint" || return 1
  printf '%s\n' "$fingerprint"
}

_ssh_live_node_volume_mounts() { # <exact-node-container-id>
  local id="$1" raw name destination extra
  local -a mounts=()
  ssh_live_volume_docker_id_valid "$id" || return 1
  raw="$("$SSH_LIVE_DOCKER_BIN" container inspect --format \
    '{{range .Mounts}}{{if eq .Type "volume"}}{{printf "%s|%s\n" .Name .Destination}}{{end}}{{end}}' \
    "$id" 2>/dev/null)" || return 1
  [ -z "$raw" ] || [[ "$raw" != *$'\r'* ]] || return 1
  if [ -n "$raw" ]; then
    while IFS='|' read -r name destination extra; do
      [ -z "${extra:-}" ] && ssh_live_volume_docker_id_valid "$name" \
        && ssh_live_volume_destination_valid "$destination" || return 1
      mounts+=("$name|$destination")
    done <<< "$raw"
  fi
  [ "${#mounts[@]}" -le 32 ] || return 1
  if [ "${#mounts[@]}" -gt 0 ]; then
    printf '%s\n' "${mounts[@]}" | LC_ALL=C sort
  fi
}

_ssh_live_volume_attachment_ids() { # <64-hex-volume-name>
  local name="$1" current id
  local -a ids=()
  ssh_live_volume_docker_id_valid "$name" || return 1
  current="$("$SSH_LIVE_DOCKER_BIN" ps --all --quiet --no-trunc \
    --filter "volume=$name" 2>/dev/null)" || return 1
  if [ -n "$current" ]; then
    while IFS= read -r id; do
      ssh_live_volume_docker_id_valid "$id" || return 1
      ids+=("$id")
    done <<< "$current"
  fi
  if [ "${#ids[@]}" -gt 0 ]; then
    printf '%s\n' "${ids[@]}" | LC_ALL=C sort -u
  fi
}

_ssh_live_volume_journal_load() { # <journal> <expected-node-id>...
  local journal="$1"; shift
  local header line node name destination fingerprint extra count=0
  local -A expected=() seen_nodes=() seen_names=() has_var=()
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  IFS= read -r header < "$journal" || return 1
  [ "$header" = "schema=$SSH_LIVE_VOLUME_SCHEMA" ] || return 1
  [ "$#" -le 32 ] || return 1
  for node in "$@"; do
    ssh_live_volume_docker_id_valid "$node" && [ -z "${expected[$node]+present}" ] || return 1
    expected[$node]=1
  done
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || return 1
    IFS='|' read -r node name destination fingerprint extra <<< "$line"
    [ -z "${extra:-}" ] && [ -n "${expected[$node]+present}" ] \
      && ssh_live_volume_docker_id_valid "$name" \
      && ssh_live_volume_destination_valid "$destination" \
      && ssh_live_volume_docker_id_valid "$fingerprint" \
      && [ -z "${seen_names[$name]+present}" ] || return 1
    seen_names[$name]=1
    seen_nodes[$node]=1
    [ "$destination" = /var ] && has_var[$node]=1
    count=$((count + 1))
    [ "$count" -le 96 ] || return 1
  done < <(tail -n +2 -- "$journal")
  for node in "$@"; do
    [ -n "${seen_nodes[$node]+present}" ] && [ -n "${has_var[$node]+present}" ] || return 1
  done
  [ "$count" -gt 0 ]
}

ssh_live_volume_journal_seal() { # <journal> <exact-node-id>...
  local journal="$1"; shift
  local parent tmp node mounts name destination extra fingerprint found_var
  local -A seen_names=()
  [ "$#" -gt 0 ] && [ "$#" -le 32 ] || return 1
  parent="$(dirname -- "$journal")"
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ -e "$journal" ]; then
    # An existing seal is immutable.  Never adopt a replacement generation.
    _ssh_live_volume_journal_load "$journal" "$@" \
      && ssh_live_volume_verify "$journal" 0 "$@"
    return
  fi
  tmp="$(mktemp "$parent/.kind-node-volumes.XXXXXX")" || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf 'schema=%s\n' "$SSH_LIVE_VOLUME_SCHEMA" > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  for node in "$@"; do
    ssh_live_volume_docker_id_valid "$node" || { rm -f -- "$tmp"; return 1; }
    mounts="$(_ssh_live_node_volume_mounts "$node")" \
      || { rm -f -- "$tmp"; return 1; }
    [ -n "$mounts" ] || { rm -f -- "$tmp"; return 1; }
    found_var=0
    while IFS='|' read -r name destination extra; do
      [ -z "${extra:-}" ] && [ -z "${seen_names[$name]+present}" ] \
        || { rm -f -- "$tmp"; return 1; }
      fingerprint="$(_ssh_live_volume_fingerprint "$name")" \
        || { rm -f -- "$tmp"; return 1; }
      printf '%s|%s|%s|%s\n' "$node" "$name" "$destination" "$fingerprint" >> "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
      seen_names[$name]=1
      [ "$destination" = /var ] && found_var=1
    done <<< "$mounts"
    [ "$found_var" -eq 1 ] || { rm -f -- "$tmp"; return 1; }
  done
  mv -- "$tmp" "$journal" || { rm -f -- "$tmp"; return 1; }
  _ssh_live_volume_journal_load "$journal" "$@" \
    && ssh_live_volume_verify "$journal" 0 "$@"
}

ssh_live_volume_verify() { # <journal> <allow-missing-node-and-volume:0|1> <node-id>...
  local journal="$1" allow_missing="$2"; shift 2
  local node name destination fingerprint actual_fp attached
  local actual_mounts expected_mounts
  case "$allow_missing" in 0|1) ;; *) return 1 ;; esac
  _ssh_live_volume_journal_load "$journal" "$@" || return 1
  for node in "$@"; do
    expected_mounts="$(awk -F'|' -v node="$node" 'NR > 1 && $1 == node {print $2 "|" $3}' \
      "$journal" | LC_ALL=C sort)" || return 1
    if "$SSH_LIVE_DOCKER_BIN" container inspect "$node" >/dev/null 2>&1; then
      actual_mounts="$(_ssh_live_node_volume_mounts "$node")" || return 1
      [ "$actual_mounts" = "$expected_mounts" ] || return 1
    elif "$SSH_LIVE_DOCKER_BIN" info >/dev/null 2>&1; then
      [ "$allow_missing" = 1 ] || return 1
    else
      return 1
    fi
  done
  while IFS='|' read -r node name destination fingerprint; do
    if actual_fp="$(_ssh_live_volume_fingerprint "$name")"; then
      [ "$actual_fp" = "$fingerprint" ] || return 1
      attached="$(_ssh_live_volume_attachment_ids "$name")" || return 1
      if "$SSH_LIVE_DOCKER_BIN" container inspect "$node" >/dev/null 2>&1; then
        [ "$attached" = "$node" ] || return 1
      else
        [ "$allow_missing" = 1 ] && [ -z "$attached" ] || return 1
      fi
    elif "$SSH_LIVE_DOCKER_BIN" info >/dev/null 2>&1; then
      if [ "$allow_missing" != 1 ] \
          || "$SSH_LIVE_DOCKER_BIN" container inspect "$node" >/dev/null 2>&1; then
        return 1
      fi
    else
      return 1
    fi
  done < <(tail -n +2 -- "$journal")
}

ssh_live_volume_remove_sealed() { # <journal> <exact-node-id>...
  local journal="$1"; shift
  local node name destination fingerprint actual_fp attached
  # Validate the complete remaining generation/attachment set before the first
  # delete. Missing entries are accepted only for an interrupted-cleanup retry.
  ssh_live_volume_verify "$journal" 1 "$@" || return 1
  while IFS='|' read -r node name destination fingerprint; do
    if actual_fp="$(_ssh_live_volume_fingerprint "$name")"; then
      [ "$actual_fp" = "$fingerprint" ] || return 1
      attached="$(_ssh_live_volume_attachment_ids "$name")" || return 1
      [ -z "$attached" ] || return 1
      # Exact sealed name only. Never prune and never discover deletion targets
      # by name/filter scans.
      "$SSH_LIVE_DOCKER_BIN" volume rm "$name" >/dev/null || return 1
    elif "$SSH_LIVE_DOCKER_BIN" info >/dev/null 2>&1; then
      : # Already absent after an interrupted cleanup.
    else
      return 1
    fi
  done < <(tail -n +2 -- "$journal")
}
