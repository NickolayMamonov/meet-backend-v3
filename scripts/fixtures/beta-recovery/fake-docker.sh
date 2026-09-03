#!/usr/bin/env bash
set -euo pipefail

state=${FAKE_DOCKER_STATE:?}
root=${FAKE_DOCKER_ROOT:?}
event_log=${FAKE_RECOVERY_EVENT_LOG:-}
log_event() {
  [ -n "$event_log" ] || return 0
  if [ "${FAKE_RUNTIME_PROBE:-0}" = 1 ]; then
    printf 'runtime-docker-%s\n' "$1" >>"$event_log"
  else
    printf 'docker-%s\n' "$1" >>"$event_log"
  fi
}
mkdir -p "$state" "$root/volumes"
volume=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
volume_root="$root/volumes/$volume/_data"
label_value() {
  local key=$1 arg
  shift
  for arg in "$@"; do
    case "$arg" in "$key="*) printf '%s\n' "${arg#*=}"; return 0;; esac
  done
  return 1
}
container_owner_token() {
  [ -f "$state/container-owner-token" ] && cat "$state/container-owner-token" ||
    printf '%s' "${FAKE_DOCKER_OWNER_TOKEN:-}"
}
network_owner_token() {
  [ -f "$state/network-owner-token" ] && cat "$state/network-owner-token" ||
    printf '%s' "${FAKE_DOCKER_OWNER_TOKEN:-}"
}

json_container() {
  local mounts=${FAKE_DOCKER_MOUNT_MODE:-valid}
  local token
  token=$(container_owner_token)
  case "$mounts" in
    valid)
      jq -cn --arg volume "$volume" --arg source "$volume_root" --arg token "$token" '
        [{Id:"fixture-container",Image:"repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          Config:{Labels:{"com.meet-backend.beta-recovery/owner":"restore",
            "com.meet-backend.beta-recovery/recovery-id":env.FAKE_RECOVERY_ID,
            "com.meet-backend.beta-recovery/owner-token":$token}},
          HostConfig:{Binds:[],Mounts:[]},
          Mounts:[{Type:"volume",Name:$volume,Destination:"/var/lib/postgresql/data",RW:true,Source:$source}]}]'
      ;;
    bind)
      jq -cn --arg source "$state/bind" --arg token "$token" '
        [{Id:"fixture-container",Image:"repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          Config:{Labels:{"com.meet-backend.beta-recovery/owner":"restore",
            "com.meet-backend.beta-recovery/recovery-id":env.FAKE_RECOVERY_ID,
            "com.meet-backend.beta-recovery/owner-token":$token}},
          HostConfig:{Binds:[$source],Mounts:[]},
          Mounts:[{Type:"bind",Source:$source,Destination:"/var/lib/postgresql/data",RW:true}]}]'
      ;;
    named)
      jq -cn --arg source "$root/volumes/meet-production_postgres_data/_data" --arg token "$token" '
        [{Id:"fixture-container",Image:"repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          Config:{Labels:{"com.meet-backend.beta-recovery/owner":"restore",
            "com.meet-backend.beta-recovery/recovery-id":env.FAKE_RECOVERY_ID,
            "com.meet-backend.beta-recovery/owner-token":$token}},
          HostConfig:{Binds:[],Mounts:[]},
          Mounts:[{Type:"volume",Name:"meet-production_postgres_data",
            Destination:"/var/lib/postgresql/data",RW:true,Source:$source}]}]'
      ;;
    duplicate)
      jq -cn --arg volume "$volume" --arg source "$volume_root" --arg token "$token" '
        [{Id:"fixture-container",Image:"repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          Config:{Labels:{"com.meet-backend.beta-recovery/owner":"restore",
            "com.meet-backend.beta-recovery/recovery-id":env.FAKE_RECOVERY_ID,
            "com.meet-backend.beta-recovery/owner-token":$token}},
          HostConfig:{Binds:[],Mounts:[]},
          Mounts:[
            {Type:"volume",Name:$volume,Destination:"/var/lib/postgresql/data",RW:true,Source:$source},
            {Type:"volume",Name:$volume,Destination:"/other",RW:true,Source:$source}]}]'
      ;;
    unexpected)
      jq -cn --arg volume "$volume" --arg source "$volume_root" --arg token "$token" '
        [{Id:"fixture-container",Image:"repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          Config:{Labels:{"com.meet-backend.beta-recovery/owner":"restore",
            "com.meet-backend.beta-recovery/recovery-id":env.FAKE_RECOVERY_ID,
            "com.meet-backend.beta-recovery/owner-token":$token}},
          HostConfig:{Binds:[],Mounts:[]},
          Mounts:[{Type:"volume",Name:$volume,Destination:"/unexpected",RW:true,Source:$source}]}]'
      ;;
    missing)
      jq -cn --arg token "$token" '
        [{Id:"fixture-container",Image:"repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          Config:{Labels:{"com.meet-backend.beta-recovery/owner":"restore",
            "com.meet-backend.beta-recovery/recovery-id":env.FAKE_RECOVERY_ID,
            "com.meet-backend.beta-recovery/owner-token":$token}},
          HostConfig:{Binds:[],Mounts:[]},Mounts:[]}]'
      ;;
    *) exit 2 ;;
  esac
}

case "${1:-}" in
  info)
    log_event info
    if [ "${2:-}" = --format ]; then printf '%s\n' "$root"; else printf 'fixture\n'; fi
    ;;
  compose)
    log_event compose
    printf '%s\n' "$*" | grep -Fq 'ps -q backend' ||
      { echo 'unsupported fixture compose operation' >&2; exit 2; }
    printf '%s\n' fixture-container
    ;;
  inspect)
    log_event inspect
    [ "${2:-}" = fixture-container ] || exit 1
    format=${4:-}
    case "$format" in
      *State.Running*) printf 'true\n' ;;
      *State.Health*) printf 'healthy\n' ;;
      *'.Image'*) printf '%s\n' 'repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
      *config-hash*) printf '%s\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
      *'.Mounts'*) printf '%s\n' 'volume|meet-production_uploads_data' ;;
      *) exit 2 ;;
    esac
    ;;
  pull) log_event pull ;;
  image)
    log_event image-"${2:-}"
    [ "${2:-}" = inspect ] || exit 2
    case "${!#}" in
      *RepoDigests*) printf '%s\n' '["repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' ;;
      *Config.Volumes*) printf '%s\n' '{"\/var\/lib\/postgresql\/data":{}}' ;;
      *) exit 2 ;;
    esac
    ;;
  network)
    log_event network-"${2:-}"
    case "${2:-}" in
      create)
        touch "$state/network"
        label_value com.meet-backend.beta-recovery/owner-token "$@" >"$state/network-owner-token" || :
        ;;
      inspect)
        [ -e "$state/network" ] || { echo 'No such network' >&2; exit 1; }
        jq -cn --arg id "$FAKE_RECOVERY_ID" --arg token "$(network_owner_token)" \
          '[{Labels:{"com.meet-backend.beta-recovery/owner":"restore",
            "com.meet-backend.beta-recovery/recovery-id":$id,
            "com.meet-backend.beta-recovery/owner-token":$token}}]' ;;
      rm) rm -f "$state/network" "$state/network-owner-token" ;;
      *) exit 2 ;;
    esac
    ;;
  container)
    log_event container-"${2:-}"
    case "${2:-}" in
      inspect)
        [ -e "$state/container" ] || { echo 'No such container' >&2; exit 1; }
        json_container ;;
      rm)
        if [ "${FAKE_DOCKER_FAIL_CONTAINER_RM_ONCE:-0}" = 1 ] &&
          [ ! -e "$state/container-rm-failed" ]; then
          touch "$state/container-rm-failed"
          exit 1
        fi
        rm -f "$state/container" "$state/container-owner-token"
        if [ "${3:-}" = --force ] && [ "${4:-}" = --volumes ] &&
          [ "${FAKE_DOCKER_PRESERVE_VOLUME:-0}" != 1 ]; then
          rm -f "$state/volume"
          [ ! -e "$root/volumes/$volume" ] || rm -r -- "$root/volumes/$volume"
        fi
        ;;
      *) exit 2 ;;
    esac
    ;;
  create)
    log_event create
    touch "$state/container"
    label_value com.meet-backend.beta-recovery/owner-token "$@" >"$state/container-owner-token" || :
    if [ "${FAKE_DOCKER_MOUNT_MODE:-valid}" = valid ] ||
      [ "${FAKE_DOCKER_MOUNT_MODE:-valid}" = duplicate ] ||
      [ "${FAKE_DOCKER_MOUNT_MODE:-valid}" = unexpected ]; then
      mkdir -p "$volume_root"
      touch "$state/volume"
    fi
    if [ "${FAKE_DOCKER_INTERRUPT_AFTER_CREATE:-0}" = 1 ]; then
      exit 137
    fi
    ;;
  start) log_event start ;;
  exec)
    log_event exec
    if printf '%s\n' "$*" | grep -Fq pg_isready; then exit 0; fi
    if printf '%s\n' "$*" | grep -Fq 'pg_restore --list'; then printf 'fixture archive list\n'; exit 0; fi
    if [ "${FAKE_DOCKER_FAIL_RESTORE:-0}" = 1 ] &&
      printf '%s\n' "$*" | grep -Fq 'pg_restore --no-owner'; then exit 1; fi
    if printf '%s\n' "$*" | grep -Fq 'psql'; then
      if printf '%s\n' "$*" | grep -Fq -- '-f /tmp/proof.sql'; then
        cat "$FAKE_DATABASE_PROOF"
      elif printf '%s\n' "$*" | grep -Fq 'regexp_replace(image_url'; then
        [ -z "${FAKE_MEDIA_REFERENCE:-}" ] || printf '%s\n' "$FAKE_MEDIA_REFERENCE"
      fi
      exit 0
    fi
    exit 0
    ;;
  cp) log_event cp ;;
  volume)
    log_event volume-"${2:-}"
    case "${2:-}" in
      inspect)
        [ "${3:-}" = "$volume" ] && [ -e "$state/volume" ] || { echo 'No such volume' >&2; exit 1; }
        jq -cn --arg volume "$volume" --arg source "$volume_root" \
          '[{Name:$volume,Driver:"local",Mountpoint:$source,Labels:{},Options:{}}]' ;;
      rm)
        if [ "${FAKE_DOCKER_FAIL_VOLUME_RM_ONCE:-0}" = 1 ] &&
          [ ! -e "$state/volume-rm-failed" ]; then
          touch "$state/volume-rm-failed"
          exit 1
        fi
        [ "${FAKE_DOCKER_FAIL_VOLUME_RM:-0}" = 1 ] && exit 1
        [ ! -e "$root/volumes/$volume" ] || rm -r -- "$root/volumes/$volume"
        rm -f "$state/volume" ;;
      *) exit 2 ;;
    esac
    ;;
  *) echo "unsupported fake docker operation: $*" >&2; exit 2 ;;
esac
