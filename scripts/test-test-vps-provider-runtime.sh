#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

prerequisite_missing() {
  echo "PREREQUISITE_MISSING" >&2
  exit 77
}

filesystem_only=false
previous_image=
target_image=
transport_source_host=${MEE2_93_IMAGE_TRANSPORT_SOURCE:-}
transport_target_host=${MEE2_93_IMAGE_TRANSPORT_TARGET:-}
transport_loaded=false
transport_map_dir=
transport_real_docker=
transport_previous_id=
transport_target_id=
transport_loaded_ids=()
transport_postgres_ref=
transport_postgres_id=${MEE2_93_IMAGE_TRANSPORT_POSTGRES_ID:-}
transport_postgres_run_owned=false
transport_record_loaded_id() {
  local id=$1 existing
  for existing in "${transport_loaded_ids[@]}"; do
    [ "$existing" = "$id" ] && return
  done
  transport_loaded_ids+=("$id")
}
transport_images_absent() {
  local id inspect_output
  for id in "${transport_loaded_ids[@]}"; do
    if inspect_output=$(timeout 30s env DOCKER_HOST="$transport_target_host" \
      "$transport_real_docker" image inspect "$id" 2>&1); then
      return 1
    fi
    inspect_output=${inspect_output,,}
    case "$inspect_output" in
      *"no such image"*|*"not found"*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}
transport_cleanup_body() {
  local status=$1
  local cleanup_status=0
  local -a remove_ids=()
  local images_clean=true
  local map_clean=true
  if [ "$transport_loaded" = true ]; then
    if [ "${#transport_loaded_ids[@]}" -gt 0 ]; then
      remove_ids+=("${transport_loaded_ids[@]}")
    fi
    if [ "$transport_postgres_run_owned" = true ] &&
      [ -n "$transport_postgres_id" ]; then
      remove_ids+=("$transport_postgres_id")
    fi
    if [ "${#remove_ids[@]}" -gt 0 ]; then
      if ! timeout 60s env DOCKER_HOST="$transport_target_host" \
        "$transport_real_docker" image rm "${remove_ids[@]}" >/dev/null 2>&1; then
        cleanup_status=1
        images_clean=false
      elif ! transport_images_absent; then
        cleanup_status=1
        images_clean=false
      fi
    fi
    if [ -n "$transport_map_dir" ]; then
      if ! timeout 30s rm -r -- "$transport_map_dir" >/dev/null 2>&1 ||
        [ -e "$transport_map_dir" ] || [ -L "$transport_map_dir" ]; then
        cleanup_status=1
        map_clean=false
      fi
    fi
    if [ "$images_clean" = true ] && [ "$map_clean" = true ]; then
      transport_loaded=false
      transport_loaded_ids=()
      transport_map_dir=
      transport_postgres_run_owned=false
    fi
  fi
  [ "$status" -ne 0 ] || [ "$cleanup_status" -eq 0 ] || status=1
  return "$status"
}
transport_cleanup() {
  local status=$?
  trap - EXIT
  set +e
  transport_cleanup_body "$status"
  status=$?
  set -e
  exit "$status"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --filesystem-only)
      [ "$filesystem_only" = false ] || exit 2
      filesystem_only=true
      shift
      ;;
    --previous-image)
      [ "$#" -ge 2 ] && [ -z "$previous_image" ] || exit 2
      previous_image=$2
      shift 2
      ;;
    --target-image)
      [ "$#" -ge 2 ] && [ -z "$target_image" ] || exit 2
      target_image=$2
      shift 2
      ;;
    *)
      echo "usage: $0 --filesystem-only | --previous-image IMAGE@sha256:DIGEST --target-image IMAGE@sha256:DIGEST" >&2
      exit 2
      ;;
  esac
done

if [ "$filesystem_only" = false ]; then
  [[ "$previous_image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
    prerequisite_missing
  [[ "$target_image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
    prerequisite_missing
  [ "$previous_image" != "$target_image" ] || prerequisite_missing
  command -v docker >/dev/null 2>&1 || {
    prerequisite_missing
  }
  transport_real_docker=$(command -v docker)
  if [ -n "$transport_target_host" ]; then
    [ -n "$transport_source_host" ] || prerequisite_missing
    timeout 30s env DOCKER_HOST="$transport_source_host" docker info >/dev/null 2>&1 ||
      prerequisite_missing
    timeout 30s env DOCKER_HOST="$transport_target_host" docker info >/dev/null 2>&1 ||
      prerequisite_missing
    transport_loaded=true
    trap transport_cleanup EXIT
    for image in "$previous_image" "$target_image"; do
      source_id=$(timeout 30s env DOCKER_HOST="$transport_source_host" \
        docker image inspect "$image" --format '{{.Id}}' 2>/dev/null) ||
        prerequisite_missing
      [[ "$source_id" =~ ^sha256:[0-9a-f]{64}$ ]] || prerequisite_missing
      target_ids_before=$(timeout 30s env DOCKER_HOST="$transport_target_host" \
        docker image ls --all --no-trunc --format '{{.ID}}' 2>/dev/null) ||
        prerequisite_missing
      if grep -Fxq "$source_id" <<<"$target_ids_before"; then
        prerequisite_missing
      fi
      if timeout 30s env DOCKER_HOST="$transport_target_host" \
        docker image inspect "$image" --format '{{.Id}}' >/dev/null 2>&1; then
        prerequisite_missing
      fi
      load_status=0
      load_output=$(
        timeout 300s env DOCKER_HOST="$transport_source_host" \
          docker save "$image" 2>/dev/null |
          timeout 300s env DOCKER_HOST="$transport_target_host" \
            docker load 2>/dev/null
      ) || load_status=$?
      target_ids_after=$(timeout 30s \
        env DOCKER_HOST="$transport_target_host" \
        docker image ls --all --no-trunc --format '{{.ID}}' 2>/dev/null) ||
        prerequisite_missing
      new_ids=()
      while IFS= read -r candidate_id; do
        [ -n "$candidate_id" ] || continue
        [[ "$candidate_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
          prerequisite_missing
        if ! grep -Fxq "$candidate_id" <<<"$target_ids_before"; then
          transport_record_loaded_id "$candidate_id"
          new_ids+=("$candidate_id")
        fi
      done <<<"$target_ids_after"
      loaded_id=$(sed -nE \
        's/^Loaded image ID: (sha256:[0-9a-f]{64})$/\1/p' <<<"$load_output")
      if ! [[ "$loaded_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        [ "${#new_ids[@]}" -eq 1 ] || prerequisite_missing
        loaded_id=${new_ids[0]}
      fi
      [[ "$loaded_id" =~ ^sha256:[0-9a-f]{64}$ ]] || prerequisite_missing
      if grep -Fxq "$loaded_id" <<<"$target_ids_before"; then
        prerequisite_missing
      fi
      grep -Fxq "$loaded_id" <<<"$target_ids_after" || prerequisite_missing
      case "$image" in
        "$previous_image") transport_previous_id=$loaded_id ;;
        "$target_image") transport_target_id=$loaded_id ;;
      esac
      [ "$load_status" -eq 0 ] || prerequisite_missing
      target_id=$(timeout 30s env DOCKER_HOST="$transport_target_host" \
        docker image inspect "$loaded_id" --format '{{.Id}}' 2>/dev/null) ||
        prerequisite_missing
      [ "$loaded_id" = "$target_id" ] || prerequisite_missing
      source_metadata=$(timeout 30s env DOCKER_HOST="$transport_source_host" \
        docker image inspect "$image" \
        --format '{{json .Config}}|{{json .RootFS}}|{{.Architecture}}|{{.Os}}' \
        2>/dev/null) ||
        prerequisite_missing
      target_metadata=$(timeout 30s env DOCKER_HOST="$transport_target_host" \
        docker image inspect "$loaded_id" \
        --format '{{json .Config}}|{{json .RootFS}}|{{.Architecture}}|{{.Os}}' \
        2>/dev/null) ||
        prerequisite_missing
      [ "$source_metadata" = "$target_metadata" ] || prerequisite_missing
    done
    transport_postgres_ref=$(sed -nE \
      's/^[[:space:]]*image:[[:space:]]*(postgres:16-alpine@sha256:[0-9a-f]{64})[[:space:]]*$/\1/p' \
      "$ROOT_DIR/docker-compose.production.yml")
    [ -n "$transport_postgres_ref" ] || prerequisite_missing
    if [ -n "$transport_postgres_id" ]; then
      [[ "$transport_postgres_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
        prerequisite_missing
    fi
    pinned_postgres_id=$(timeout 30s \
      env DOCKER_HOST="$transport_target_host" \
      docker image inspect "$transport_postgres_ref" --format '{{.Id}}' \
      2>/dev/null) || prerequisite_missing
    [[ "$pinned_postgres_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
      prerequisite_missing
    if [ -n "$transport_postgres_id" ]; then
      [ "$transport_postgres_id" = "$pinned_postgres_id" ] ||
        prerequisite_missing
    else
      transport_postgres_id=$pinned_postgres_id
    fi
    # The pinned database image is pre-provisioned on the target daemon; this
    # invocation never loads it, so an externally supplied ID is never owned.
    transport_postgres_run_owned=false
    transport_map_dir=$(mktemp -d /tmp/meet-provider-image-map.XXXXXX 2>/dev/null) ||
      prerequisite_missing
    chmod 700 "$transport_map_dir" 2>/dev/null || prerequisite_missing
    cat >"$transport_map_dir/docker" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

real_docker=${MEE2_93_REAL_DOCKER:?}
previous_ref=${MEE2_93_TRANSPORT_PREVIOUS_REF:?}
previous_id=${MEE2_93_TRANSPORT_PREVIOUS_ID:?}
target_ref=${MEE2_93_TRANSPORT_TARGET_REF:?}
target_id=${MEE2_93_TRANSPORT_TARGET_ID:?}
postgres_ref=${MEE2_93_TRANSPORT_POSTGRES_REF:-}
postgres_id=${MEE2_93_TRANSPORT_POSTGRES_ID:-}

map_image() {
  case "$1" in
    "$previous_ref") printf '%s' "$previous_id" ;;
    "$target_ref") printf '%s' "$target_id" ;;
    "$postgres_ref") printf '%s' "$postgres_id" ;;
    *) printf '%s' "$1" ;;
  esac
}

if [ "${1:-}" = image ] && [ "${2:-}" = inspect ] && [ "$#" -ge 3 ]; then
  set -- "$1" "$2" "$(map_image "$3")" "${@:4}"
elif [ "${1:-}" = image ] && [ "${2:-}" = rm ] && [ "$#" -ge 3 ]; then
  args=("$@")
  for ((index = 2; index < ${#args[@]}; index += 1)); do
    case "${args[index]}" in
      -*) ;;
      *) args[index]=$(map_image "${args[index]}") ;;
    esac
  done
  set -- "${args[@]}"
fi

if [ "${1:-}" = compose ]; then
  args=("$@")
  env_index=-1
  for ((index = 0; index + 1 < ${#args[@]}; index += 1)); do
    if [ "${args[index]}" = --env-file ]; then
      env_index=$((index + 1))
      break
    fi
  done
  if [ "$env_index" -ge 0 ]; then
    env_file=${args[env_index]}
    backend_line=$(grep '^BACKEND_IMAGE=' "$env_file" || true)
    if [ "$backend_line" = "BACKEND_IMAGE=$previous_ref" ]; then
      mapped_id=$previous_id
    elif [ "$backend_line" = "BACKEND_IMAGE=$target_ref" ]; then
      mapped_id=$target_id
    else
      exit 77
    fi
    mapped_env="$MEE2_93_TRANSPORT_MAP_DIR/compose-${BASHPID}.env"
    sed "s|^BACKEND_IMAGE=.*$|BACKEND_IMAGE=$mapped_id|" \
      "$env_file" >"$mapped_env"
    args[env_index]=$mapped_env
  fi
  for ((index = 0; index + 1 < ${#args[@]}; index += 1)); do
    if [ "${args[index]}" = -f ] || [ "${args[index]}" = --file ]; then
      compose_file=${args[index + 1]}
      mapped_compose="$MEE2_93_TRANSPORT_MAP_DIR/compose-${BASHPID}-${index}.yml"
      if [ -n "$postgres_id" ] &&
        grep -Fq "$postgres_ref" "$compose_file"; then
        sed "s|$postgres_ref|$postgres_id|g" \
          "$compose_file" >"$mapped_compose"
      else
        cp "$compose_file" "$mapped_compose"
      fi
      args[index + 1]=$mapped_compose
    fi
  done
  exec "$real_docker" "${args[@]}"
fi

exec "$real_docker" "$@"
SHIM
    chmod 700 "$transport_map_dir/docker"
    export MEE2_93_REAL_DOCKER="$transport_real_docker"
    export MEE2_93_TRANSPORT_PREVIOUS_REF="$previous_image"
    export MEE2_93_TRANSPORT_PREVIOUS_ID="$transport_previous_id"
    export MEE2_93_TRANSPORT_TARGET_REF="$target_image"
    export MEE2_93_TRANSPORT_TARGET_ID="$transport_target_id"
    export MEE2_93_TRANSPORT_POSTGRES_REF="$transport_postgres_ref"
    export MEE2_93_TRANSPORT_POSTGRES_ID="$transport_postgres_id"
    export MEE2_93_TRANSPORT_MAP_DIR="$transport_map_dir"
    export PATH="$transport_map_dir:$PATH"
    export DOCKER_HOST="$transport_target_host"
  fi
  timeout 30s docker info >/dev/null 2>&1 || {
    prerequisite_missing
  }
  previous_id=$(timeout 30s docker image inspect "$previous_image" \
    --format '{{.Id}}' 2>/dev/null) || {
    prerequisite_missing
  }
  target_id=$(timeout 30s docker image inspect "$target_image" \
    --format '{{.Id}}' 2>/dev/null) || {
    prerequisite_missing
  }
  [[ "$previous_id" =~ ^sha256:[0-9a-f]{64}$ ]] || prerequisite_missing
  [[ "$target_id" =~ ^sha256:[0-9a-f]{64}$ ]] || prerequisite_missing
  [ "$previous_id" != "$target_id" ] || prerequisite_missing
fi

if [ "$(id -u)" -ne 0 ]; then
  prerequisite_missing
fi

if [ "$filesystem_only" = true ]; then
  malformed_status=0
  malformed_output=$(
    timeout 30s "$0" \
      --previous-image malformed \
      --target-image ghcr.io/nickolaymamonov/meet-backend-v3@sha256:0000000000000000000000000000000000000000000000000000000000000000 \
      2>&1
  ) || malformed_status=$?
  [ "$malformed_status" -eq 77 ]
  grep -Fxq "PREREQUISITE_MISSING" <<<"$malformed_output"
fi

if [ "$filesystem_only" = false ]; then
  for command_name in docker curl jq flock openssl python3 timeout; do
    command -v "$command_name" >/dev/null 2>&1 || {
      prerequisite_missing
    }
  done
  timeout 30s docker compose version >/dev/null 2>&1 || {
    prerequisite_missing
  }

  image_label() {
    timeout 30s docker image inspect "$1" \
      --format "$2" 2>/dev/null
  }

  version_supported() {
    timeout 30s python3 - "$1" <<'PY'
import re
import sys

match = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", sys.argv[1])
raise SystemExit(
    0
    if match is not None and tuple(map(int, match.groups())) >= (1, 2, 0)
    else 1
)
PY
  }

  previous_revision=$(image_label "$previous_image" \
    '{{index .Config.Labels "org.opencontainers.image.revision"}}') || {
    prerequisite_missing
  }
  previous_version=$(image_label "$previous_image" \
    '{{index .Config.Labels "org.opencontainers.image.version"}}') || {
    prerequisite_missing
  }
  target_revision=$(image_label "$target_image" \
    '{{index .Config.Labels "org.opencontainers.image.revision"}}') || {
    prerequisite_missing
  }
  target_version=$(image_label "$target_image" \
    '{{index .Config.Labels "org.opencontainers.image.version"}}') || {
    prerequisite_missing
  }
  [[ "$previous_revision" =~ ^[0-9a-f]{40}$ ]] || prerequisite_missing
  [[ "$target_revision" =~ ^[0-9a-f]{40}$ ]] || prerequisite_missing
  version_supported "$previous_version" || prerequisite_missing
  version_supported "$target_version" || prerequisite_missing
  [ "$(image_label "$previous_image" \
    '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
    "https://github.com/NickolayMamonov/meet-backend-v3" ] ||
    prerequisite_missing
  [ "$(image_label "$target_image" \
    '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
    "https://github.com/NickolayMamonov/meet-backend-v3" ] ||
    prerequisite_missing
  [ "$(image_label "$previous_image" '{{.Config.User}}')" = "10001:10001" ] ||
    prerequisite_missing
  [ "$(image_label "$target_image" '{{.Config.User}}')" = "10001:10001" ] ||
    prerequisite_missing

  postgres_image=$(
    sed -nE \
      's/^[[:space:]]*image:[[:space:]]*(postgres:16-alpine@sha256:[0-9a-f]{64})[[:space:]]*$/\1/p' \
      "$ROOT_DIR/docker-compose.production.yml"
  )
  [ -n "$postgres_image" ] || prerequisite_missing
  postgres_expected_id=$(timeout 30s \
    docker image inspect "$postgres_image" --format '{{.Id}}' 2>/dev/null) ||
    prerequisite_missing
  [[ "$postgres_expected_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    prerequisite_missing
  timeout 30s python3 - "$ROOT_DIR/scripts/test-vps-provider-credential.py" \
    "$previous_image" "$target_image" <<'PY' 2>/dev/null
import json
import subprocess
import sys

helper, *images = sys.argv[1:]
for image in images:
    result = subprocess.run(
        ["docker", "image", "inspect", image],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    subprocess.run(
        ["python3", helper, "check-image"],
        check=True,
        input=result.stdout,
        text=True,
        stdout=subprocess.DEVNULL,
    )
PY

  matrix_fixture=$(mktemp -d /var/lib/meet-provider-image.XXXXXX 2>/dev/null) ||
    prerequisite_missing
  if ! chmod 700 "$matrix_fixture" 2>/dev/null; then
    timeout 30s rm -r -- "$matrix_fixture" >/dev/null 2>&1 || true
    prerequisite_missing
  fi
  matrix_cleanup() {
    local status=$?
    local cleanup_status=0
    local transport_status
    trap - EXIT
    if ! timeout 30s rm -r -- "$matrix_fixture"; then
      cleanup_status=1
    fi
    set +e
    transport_cleanup_body "$status"
    transport_status=$?
    set -e
    [ "$cleanup_status" -eq 0 ] || [ "$transport_status" -ne 0 ] ||
      transport_status=1
    exit "$transport_status"
  }
  trap matrix_cleanup EXIT

  run_image_case() (
    set -euo pipefail
    local case_name=$1
    local case_number=$2
    local rollback_run_key=$3
    local deploy_run_key=$4
    local provider_enabled=$5
    local case_root=/var/lib/meet-production
    local state_parent=/var/lib/meet-test-vps-deploy
    local state_root=/var/lib/meet-test-vps-deploy/mee2-93-runtime-$case_name
    local case_log="$matrix_fixture/$case_name.log"
    local case_secret="RUNTIME_IMAGE_PRIVATE_SECRET_${case_name}_9f7d8d"
    local credential_email="runtime-image-$case_name@example.invalid"
    local app_port=$((18080 + case_number))
    local probe_port=$((28080 + case_number))
    local public_url="https://127.0.0.1:$probe_port"
    local network_name=meet-production_default
    local network_created=false
    local probe_pid=
    local probe_cert="$case_root/probe-cert.pem"
    local probe_key="$case_root/probe-key.pem"
    local probe_log="$case_root/probe.log"
    local coordinator_pid=
    local case_root_created=false
    local state_parent_created=false
    local state_root_created=false
    local case_root_identity=
    local state_parent_identity=
    local state_root_identity=
    local backend postgres observed
    local rollback_output rollback_status deploy_output deploy_status
    local rollback_capture="$matrix_fixture/$case_name-rollback.out"
    local deploy_capture="$matrix_fixture/$case_name-deploy.out"
    local cleanup_capture="$matrix_fixture/$case_name-cleanup.out"
    local cleanup_network_capture="$matrix_fixture/$case_name-cleanup-network.out"
    local previous_state target_state legacy_before legacy_after

    runtime_stage() {
      printf 'image_runtime_stage case=%s stage=%s\n' "$case_name" "$1"
    }

    capture_command() {
      local output=$1
      shift
      local capture_status producer_status
      local restore_errexit=false
      case "$-" in
        *e*)
          restore_errexit=true
          set +e
          ;;
      esac
      : >"$output" 2>/dev/null || prerequisite_missing
      "$@" 2>&1 |
        python3 -c '
import sys

path = sys.argv[1]
limit = 8 * 1024 * 1024
written = 0
overflow = False
with open(path, "wb") as output:
    while True:
        chunk = sys.stdin.buffer.read(65536)
        if not chunk:
            break
        remaining = limit - written
        if remaining > 0:
            output.write(chunk[:remaining])
            written += min(len(chunk), remaining)
        if len(chunk) > remaining:
            overflow = True
sys.exit(125 if overflow else 0)
' "$output"
      local -a pipe_status=("${PIPESTATUS[@]}")
      producer_status=${pipe_status[0]}
      capture_status=${pipe_status[1]}
      if [ "$restore_errexit" = true ]; then
        set -e
      fi
      [ "$capture_status" -eq 0 ] || return "$capture_status"
      return "$producer_status"
    }

    root_identity() {
      stat -c '%d:%i:%f:%u:%g' -- "$1"
    }
    record_owned_root() {
      local path=$1 identity
      identity=$(root_identity "$path" 2>/dev/null) || prerequisite_missing
      case "$path" in
        "$case_root")
          case_root_created=true
          case_root_identity=$identity
          ;;
        "$state_parent")
          state_parent_created=true
          state_parent_identity=$identity
          ;;
        "$state_root")
          state_root_created=true
          state_root_identity=$identity
          ;;
      esac
    }
    create_owned_root() {
      local path=$1
      if ! mkdir -m 700 -- "$path" 2>/dev/null; then
        prerequisite_missing
      fi
      record_owned_root "$path"
      chown 0:0 -- "$path" 2>/dev/null || prerequisite_missing
      chmod 700 -- "$path" 2>/dev/null || prerequisite_missing
    }
    fixture_copy() {
      cp -- "$1" "$2" 2>/dev/null || prerequisite_missing
    }
    fixture_install_dir() {
      install -d -m "$1" -- "$2" 2>/dev/null || prerequisite_missing
    }
    fixture_write() {
      local path=$1
      local mode=$2
      cat >"$path" 2>/dev/null || prerequisite_missing
      chmod "$mode" "$path" 2>/dev/null || prerequisite_missing
    }
    fixture_append() {
      cat >>"$1" 2>/dev/null || prerequisite_missing
    }
    fixture_chown() {
      chown "$1" "$2" 2>/dev/null || prerequisite_missing
    }
    fixture_touch() {
      touch "$@" 2>/dev/null || prerequisite_missing
    }
    fixture_truncate() {
      : >"$1" 2>/dev/null || prerequisite_missing
    }
    fixture_tls() {
      timeout 30s openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj /CN=127.0.0.1 \
        -addext subjectAltName=IP:127.0.0.1 \
        -keyout "$probe_key" -out "$probe_cert" >/dev/null 2>&1 ||
        prerequisite_missing
      chmod 600 "$probe_key" "$probe_cert" 2>/dev/null ||
        prerequisite_missing
    }
    assert_resource_absent() {
      local kind=$1
      local name=$2
      local inspect_output inspect_status
      if inspect_output=$(timeout 30s docker "$kind" inspect "$name" 2>&1); then
        return 1
      else
        inspect_status=$?
      fi
      [ "$inspect_status" -eq 1 ] || return 1
      inspect_output=${inspect_output,,}
      case "$inspect_output" in
        *"no such "*|*"not found"*) return 0 ;;
        *) return 1 ;;
      esac
    }
    assert_no_compose_containers() {
      local containers
      containers=$(timeout 30s docker ps -aq \
        --filter label=com.docker.compose.project=meet-production \
        2>/dev/null) || return 1
      [ -z "$containers" ]
    }
    remove_owned_root() {
      local path=$1
      local expected_identity=$2
      local require_empty=${3:-false}
      [ -e "$path" ] || [ -L "$path" ] || return 0
      timeout 30s python3 - "$path" "$expected_identity" "$require_empty" <<'PY'
import fcntl
import os
import stat
import sys

path, expected, require_empty = sys.argv[1:]


def identity(info):
    return f"{info.st_dev}:{info.st_ino}:{info.st_mode:x}:{info.st_uid}:{info.st_gid}"


def same_inode(left, right):
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def fail():
    raise SystemExit(1)


parent_path, name = os.path.split(path)
parent_fd = os.open(
    parent_path or "/",
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
)
try:
    fcntl.flock(parent_fd, fcntl.LOCK_EX)
    root_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (
        not stat.S_ISDIR(root_info.st_mode)
        or identity(root_info) != expected
    ):
        fail()
    root_fd = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=parent_fd,
    )
    try:
        opened = os.fstat(root_fd)
        if not same_inode(opened, root_info) or identity(opened) != expected:
            fail()
        entries = list(os.scandir(f"/proc/self/fd/{root_fd}"))
        if require_empty == "true" and entries:
            fail()

        def remove_contents(directory_fd, directory_entries):
            for entry in directory_entries:
                child_info = os.stat(
                    entry.name,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                if stat.S_ISDIR(child_info.st_mode):
                    child_fd = os.open(
                        entry.name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=directory_fd,
                    )
                    try:
                        opened_child = os.fstat(child_fd)
                        if not same_inode(opened_child, child_info):
                            fail()
                        remove_contents(
                            child_fd,
                            list(os.scandir(f"/proc/self/fd/{child_fd}")),
                        )
                        current_child = os.stat(
                            entry.name,
                            dir_fd=directory_fd,
                            follow_symlinks=False,
                        )
                        if not same_inode(current_child, opened_child):
                            fail()
                    finally:
                        os.close(child_fd)
                    os.rmdir(entry.name, dir_fd=directory_fd)
                else:
                    current_child = os.stat(
                        entry.name,
                        dir_fd=directory_fd,
                        follow_symlinks=False,
                    )
                    if not same_inode(current_child, child_info):
                        fail()
                    os.unlink(entry.name, dir_fd=directory_fd)

        remove_contents(root_fd, entries)
        if next(os.scandir(f"/proc/self/fd/{root_fd}"), None) is not None:
            fail()
        current_root = os.stat(
            name,
            dir_fd=parent_fd,
            follow_symlinks=False,
        )
        if not same_inode(current_root, opened) or identity(current_root) != expected:
            fail()
    finally:
        os.close(root_fd)
    current_root = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if identity(current_root) != expected:
        fail()
    os.rmdir(name, dir_fd=parent_fd)
finally:
    os.close(parent_fd)
PY
    }

    cleanup_case() {
      local status=$?
      local cleanup_status=0
      trap - EXIT
      set +e
      if [ "$case_root_created" = true ]; then
        stop_owned_process() {
          local pid=$1
          local signal=$2
          local child
          [ -n "$pid" ] || return 0
          if kill -0 "$pid" 2>/dev/null; then
            for child in $(pgrep -P "$pid" 2>/dev/null || true); do
              stop_owned_process "$child" "$signal" || return 1
            done
            kill "-$signal" "$pid" 2>/dev/null || true
          fi
          return 0
        }
        reap_owned_process() {
          local pid=$1
          local child
          [ -n "$pid" ] || return 0
          for child in $(pgrep -P "$pid" 2>/dev/null || true); do
            reap_owned_process "$child" || return 1
          done
          wait "$pid" 2>/dev/null || true
          ! kill -0 "$pid" 2>/dev/null
        }
        for owned_pid in "$coordinator_pid" "$probe_pid"; do
          if [ -n "$owned_pid" ] && kill -0 "$owned_pid" 2>/dev/null; then
            stop_owned_process "$owned_pid" TERM || cleanup_status=1
            sleep 1
            stop_owned_process "$owned_pid" KILL || cleanup_status=1
          fi
          reap_owned_process "$owned_pid" || cleanup_status=1
        done
        scan_case_secrets || cleanup_status=1
        capture_command "$cleanup_capture" timeout 300s docker compose -p meet-production \
          --project-directory "$case_root" \
          --env-file "$case_root/.env.production" \
          -f "$case_root/docker-compose.production.yml" \
          -f "$case_root/isolated-network.yml" \
          down --volumes --remove-orphans ||
          cleanup_status=1
        if [ "$network_created" = true ]; then
          capture_command "$cleanup_network_capture" timeout 30s docker network rm \
            "$network_name" ||
            cleanup_status=1
          network_created=false
        fi
        assert_no_compose_containers || cleanup_status=1
        for resource in meet-production_default meet-production_postgres_data \
          meet-production_uploads_data; do
          assert_resource_absent network "$resource" || cleanup_status=1
          assert_resource_absent volume "$resource" || cleanup_status=1
        done
        scan_case_secrets || cleanup_status=1
      fi
      if [ "$case_root_created" = true ]; then
        remove_owned_root "$case_root" "$case_root_identity" ||
          cleanup_status=1
      fi
      if [ "$state_root_created" = true ]; then
        remove_owned_root "$state_root" "$state_root_identity" ||
          cleanup_status=1
        [ ! -e "$state_root" ] && [ ! -L "$state_root" ] ||
          cleanup_status=1
      fi
      if [ "$state_parent_created" = true ] &&
        [ "$state_root_created" = true ] &&
        [ ! -e "$state_root" ] && [ ! -L "$state_root" ]; then
        remove_owned_root "$state_parent" "$state_parent_identity" true ||
          cleanup_status=1
      fi
      [ "$status" -ne 0 ] || [ "$cleanup_status" -eq 0 ] ||
        status=1
      if [ "$status" -eq 0 ]; then
        printf 'image_runtime_cleanup case=%s containers=0 fixed_roots=0\\n' \
          "$case_name"
      fi
      exit "$status"
    }

    secret_sentinels=(
      "$case_secret"
      "$credential_email"
      "runtime-db-password-$case_name"
      "runtime-jwt-secret-$case_name-0123456789abcdef0123456789abcdef"
      "runtime-smtp-user"
      "runtime-smtp-password"
      "runtime-key"
      "cmVhbC1ydW50aW1lLWtleS1ieXRlcy1mb3ItdGVzdA=="
      '-----BEGIN PRIVATE KEY-----'
    )
    check_capture_bound() {
      [ "$(wc -c <"$1")" -le 8388608 ]
    }
    scan_file_for_pattern() {
      local pattern=$1
      local file=$2
      local scan_status
      if timeout 30s grep -r -F -n --binary-files=without-match \
        "$pattern" "$file" >/dev/null 2>&1; then
        return 1
      else
        scan_status=$?
      fi
      [ "$scan_status" -eq 1 ] || return 2
      return 0
    }
    scan_case_secrets() {
      local pattern file container container_list scan_status
      local evidence_files=(
        "$case_log"
        "$rollback_capture"
        "$deploy_capture"
        "$cleanup_capture"
        "$cleanup_network_capture"
        "$probe_log"
        "$matrix_fixture"/"$case_name"-*.out
      )
      scan_state_evidence() {
        local search_root=$1 search_pattern=$2
        timeout 30s grep -r -F -n --binary-files=without-match \
          --exclude='config.env.production' \
          --exclude='config.base-compose.yml' \
          --exclude='config.env.production.identity' \
          --exclude='config.base-compose.yml.identity' \
          --exclude='config.env.target' \
          --exclude='config.env.target.identity' \
          --exclude='config.env.previous' \
          --exclude='config.env.previous.identity' \
          "$search_pattern" "$search_root" >/dev/null 2>&1
      }
      for pattern in "${secret_sentinels[@]}"; do
        for file in "${evidence_files[@]}"; do
          [ -e "$file" ] || continue
          if scan_file_for_pattern "$pattern" "$file"; then
            :
          else
            scan_status=$?
            [ "$scan_status" -eq 1 ] && return 1
            return 2
          fi
        done
        if [ -e "$state_root" ] &&
          scan_state_evidence "$state_root" "$pattern"; then
          return 1
        else
          scan_status=$?
          [ "$scan_status" -eq 1 ] || return 2
        fi
        if ! container_list=$(timeout 30s docker ps -aq \
          --filter label=com.docker.compose.project=meet-production); then
          return 2
        fi
        while IFS= read -r container; do
          [ -n "$container" ] || continue
          local container_log="$matrix_fixture/$case_name-container-$container.log"
          if ! capture_command "$container_log" timeout 30s docker logs \
            --tail 10000 "$container"; then
            return 2
          fi
          check_capture_bound "$container_log" || return 2
          if scan_file_for_pattern "$pattern" "$container_log"; then
            :
          else
            scan_status=$?
            [ "$scan_status" -eq 1 ] && return 1
            return 2
          fi
        done <<<"$container_list"
      done
      return 0
    }
    assert_private_state_snapshots() {
      local state_path=$1 snapshot metadata mode uid gid size
      for snapshot in \
        "$state_path/config.env.production" \
        "$state_path/config.base-compose.yml" \
        "$state_path/config.env.production.identity" \
        "$state_path/config.base-compose.yml.identity" \
        "$state_path/config.env.target" \
        "$state_path/config.env.target.identity" \
        "$state_path/config.env.previous" \
        "$state_path/config.env.previous.identity"; do
        [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
        metadata=$(stat -c '%a:%u:%g:%s' -- "$snapshot") || return 1
        IFS=: read -r mode uid gid size <<<"$metadata"
        [ "$mode" = 600 ] && [ "$uid" = 0 ] && [ "$gid" = 0 ] || return 1
        [ "$size" -le 1048576 ] || return 1
      done
    }

    if [ -e "$case_root" ] || [ -L "$case_root" ] ||
      [ -e "$state_parent" ] || [ -L "$state_parent" ] ||
      [ -e "$state_root" ] || [ -L "$state_root" ]; then
      prerequisite_missing
    fi
    existing_containers=$(timeout 30s docker ps -aq \
      --filter label=com.docker.compose.project=meet-production \
      2>/dev/null) || prerequisite_missing
    if [ -n "$existing_containers" ]; then
      prerequisite_missing
    fi
    for resource in meet-production_default meet-production_postgres_data \
      meet-production_uploads_data; do
      if ! assert_resource_absent network "$resource" ||
        ! assert_resource_absent volume "$resource"; then
        prerequisite_missing
      fi
    done

    trap cleanup_case EXIT
    create_owned_root "$case_root"
    create_owned_root "$state_parent"
    create_owned_root "$state_root"
    fixture_copy "$ROOT_DIR/docker-compose.production.yml" \
      "$case_root/docker-compose.production.yml"
    chmod 600 "$case_root/docker-compose.production.yml" 2>/dev/null ||
      prerequisite_missing
    fixture_append "$case_root/docker-compose.production.yml" <<'EOF'

networks:
  default:
    external: true
    name: meet-production_default
EOF
    fixture_write "$case_root/.env.production" 600 <<EOF
APP_PORT=$app_port
BACKEND_MEMORY_LIMIT=768m
DOCKER_LOG_MAX_SIZE=10m
DOCKER_LOG_MAX_FILE=5
BACKEND_VERSION=$previous_version
BACKEND_REVISION=$previous_revision
BACKEND_IMAGE=$previous_image
DB_NAME=meet
DB_USERNAME=meet
DB_PASSWORD=runtime-db-password-$case_name
APP_JWT_SECRET=runtime-jwt-secret-$case_name-0123456789abcdef0123456789abcdef
APP_STORAGE_BASE_URL=http://127.0.0.1:$app_port/media
ADMIN_API_KEY=
APP_EMAIL_PROVIDER=smtp
APP_EMAIL_FROM=no-reply@example.invalid
APP_EMAIL_FROM_NAME=Meet
SPRING_MAIL_HOST=smtp.invalid
SPRING_MAIL_PORT=2525
SPRING_MAIL_USERNAME=runtime-smtp-user
SPRING_MAIL_PASSWORD=runtime-smtp-password
APP_EMAIL_CONNECT_TIMEOUT_MS=5000
APP_EMAIL_READ_TIMEOUT_MS=5000
APP_EMAIL_WRITE_TIMEOUT_MS=5000
APP_OTP_HMAC_CURRENT_KEY_ID=runtime-key
APP_OTP_HMAC_CURRENT_KEY_BASE64=cmVhbC1ydW50aW1lLWtleS1ieXRlcy1mb3ItdGVzdA==
APP_OTP_HMAC_PREVIOUS_KEY_ID=
APP_OTP_HMAC_PREVIOUS_KEY_BASE64=
APP_SMS_PROVIDER=disabled
APP_PUSH_PROVIDER_ENABLED=$provider_enabled
APP_PUSH_DISCOVERY_ENABLED=false
APP_PUSH_DISPATCH_ENABLED=false
APP_PUSH_DIAGNOSTIC_ENABLED=false
APP_PUSH_MAINTENANCE_ENABLED=false
APP_PUSH_PROJECT_ID=meeting-1d258
APP_PUSH_CREDENTIALS_FILE=$(
  if [ "$provider_enabled" = true ]; then
    printf '%s' /run/secrets/meet-firebase-service-account.json
  fi
)
INGESTION_ENABLED=false
INGESTION_CRON=
INGESTION_ZONE=
GEOCODER_ENABLED=false
LOCATIONIQ_KEY=
TIMEPAD_ENABLED=false
TIMEPAD_TOKEN=
TIMEPAD_CATEGORY_IDS=
TIMEPAD_KEYWORDS=
TIMEPAD_CITIES=
SPRINGDOC_API_DOCS_ENABLED=false
SPRINGDOC_SWAGGER_UI_ENABLED=false
EOF
    fixture_write "$case_root/isolated-network.yml" 600 <<'EOF'
services:
  backend:
    networks:
      - default
  postgres:
    networks:
      - default
networks:
  default:
    external: true
    name: meet-production_default
EOF
    if timeout 30s python3 - "$probe_port" 2>/dev/null <<'PY'
import socket
import sys

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
PY
    then
      :
    else
      prerequisite_missing
    fi
    if [ "$provider_enabled" = true ]; then
      fixture_install_dir 700 "$case_root/credentials"
      fixture_write "$case_root/credentials/firebase-service-account.json" 640 <<EOF
{"type":"service_account","project_id":"meeting-1d258","client_email":"$credential_email","client_id":"runtime-image-id","private_key_id":"runtime-image-key","private_key":"-----BEGIN PRIVATE KEY-----\n$case_secret\n-----END PRIVATE KEY-----","token_uri":"https://oauth2.example.invalid/token"}
EOF
      fixture_chown 0:10001 "$case_root/credentials/firebase-service-account.json"
    fi
    fixture_write "$case_root/probe.py" 700 <<'PY'
import http.client
import socket
import ssl
import sys

probe_port, backend_port, certificate, private_key = sys.argv[1:]
backend_port = int(backend_port)


def read_request(connection):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = connection.recv(4096)
        if not chunk:
            return None
        data.extend(chunk)
        if len(data) > 64 * 1024:
            return None
    head, _, remainder = bytes(data).partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    method, path, version = lines[0].split(" ", 2)
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    if length > 1024 * 1024:
        return None
    body = bytearray(remainder)
    while len(body) < length:
        chunk = connection.recv(min(4096, length - len(body)))
        if not chunk:
            return None
        body.extend(chunk)
    return method, path, version, headers, bytes(body[:length])


def response(connection, status, body=b"", headers=None):
    phrases = {200: "OK", 403: "Forbidden", 404: "Not Found", 308: "Permanent Redirect"}
    response_headers = dict(headers or {})
    response_headers.setdefault("Content-Type", "application/json")
    response_headers["Content-Length"] = str(len(body))
    response_headers["Connection"] = "close"
    lines = [f"HTTP/1.1 {status} {phrases.get(status, 'Error')}\r\n"]
    lines.extend(f"{key}: {value}\r\n" for key, value in response_headers.items())
    connection.sendall("".join(lines).encode("latin-1") + b"\r\n" + body)


def backend_request(method, path, body, request_headers):
    connection = http.client.HTTPConnection("127.0.0.1", backend_port, timeout=10)
    headers = {}
    if "content-type" in request_headers:
        headers["Content-Type"] = request_headers["content-type"]
    connection.request(method, path, body=body, headers=headers)
    result = connection.getresponse()
    data = result.read(8 * 1024 * 1024 + 1)
    if len(data) > 8 * 1024 * 1024:
        raise RuntimeError("bounded proxy response exceeded")
    return result.status, data, {
        "Content-Type": result.getheader("Content-Type", "application/json")
    }


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certificate, private_key)
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", int(probe_port)))
    listener.listen(16)
    listener.settimeout(1)
    while True:
        try:
            connection, _ = listener.accept()
        except socket.timeout:
            continue
        with connection:
            connection.settimeout(15)
            try:
                first = connection.recv(1, socket.MSG_PEEK)
                tls = first == b"\x16"
                if tls:
                    connection = context.wrap_socket(connection, server_side=True)
                request = read_request(connection)
                if request is None:
                    continue
                method, path, _version, headers, body = request
                if not tls:
                    host = headers.get("host", f"127.0.0.1:{probe_port}")
                    response(
                        connection,
                        308,
                        headers={"Location": f"https://{host}{path}"},
                    )
                    continue
                if path == "/actuator":
                    response(connection, 404)
                    continue
                if path == "/meetings" and method == "GET":
                    status, data, response_headers = backend_request(
                        method, path, body, headers
                    )
                    response(connection, status, data, response_headers)
                    continue
                if path == "/admin/demo-catalog/bootstrap" and method == "POST":
                    status, data, response_headers = backend_request(
                        method, path, body, headers
                    )
                    response(connection, status, data, response_headers)
                    continue
                response(connection, 404)
            except Exception:
                try:
                    response(connection, 404)
                except Exception:
                    pass
PY
    fixture_tls

    legacy_names=(
      31885558214-1-rollback-drill
      31886011287-1-rollback-drill
      31886542144-1-final-deploy
      31886542144-1-rollback-drill
      31887546557-1-final-deploy
      33076843662-1-final-deploy
      33076843662-1-rollback-drill
      35471104657-1-rollback-drill
    )
    legacy_digest() {
      local name path
      for name in "${legacy_names[@]}"; do
        path="$state_root/$name"
        find "$path" -xdev -printf '%p|%y|%m|%u|%g|%l|%T@\n' | sort
        find "$path" -xdev -type f -exec sha256sum {} +
      done
    }
    legacy_index=0
    for name in "${legacy_names[@]}"; do
      fixture_install_dir 700 "$state_root/$name"
      fixture_write "$state_root/$name/opaque.bin" 600 <<EOF
legacy immutable-runtime bytes: $name
EOF
      fixture_touch -d "@$((1700000000 + legacy_index)).123456789" \
        "$state_root/$name/opaque.bin" "$state_root/$name"
      legacy_index=$((legacy_index + 1))
    done
    legacy_before=$(legacy_digest)
    grep -Eq '\|[0-9]+\.[0-9]{9,}$' <<<"$legacy_before"

    compose() {
      timeout 300s docker compose -p meet-production \
        --project-directory "$case_root" \
        --env-file "$case_root/.env.production" \
        -f "$case_root/docker-compose.production.yml" "$@"
    }
    assert_internal_network() {
      [ "$(timeout 30s docker network inspect "$network_name" \
        --format '{{.Internal}}' 2>/dev/null)" = true ]
    }
    assert_outbound_blocked() {
      local container=$1
      local status
      if timeout 15s docker exec "$container" curl \
        --connect-timeout 3 --max-time 5 --silent --show-error \
        --output /dev/null https://example.com >/dev/null 2>&1; then
        return 1
      else
        status=$?
      fi
      case "$status" in
        6|7|28) return 0 ;;
        *) return 1 ;;
      esac
    }
    : >"$case_log"
    if ! timeout 30s docker network create --driver bridge --internal "$network_name" \
      >>"$case_log" 2>&1; then
      prerequisite_missing
    fi
    network_created=true
    assert_internal_network
    printf 'network_isolation internal=true name=%s\n' "$network_name" >>"$case_log"
    compose() {
      timeout 300s docker compose -p meet-production \
        --project-directory "$case_root" \
        --env-file "$case_root/.env.production" \
        -f "$case_root/docker-compose.production.yml" \
        -f "$case_root/isolated-network.yml" "$@"
    }
    assert_postgres_image() {
      local container=$1
      [ "$(timeout 30s docker inspect "$container" \
        --format '{{.Image}}' 2>/dev/null)" = "$postgres_expected_id" ]
    }
    runtime_stage fixture_ready
    capture_command "$case_log" compose up -d --wait --no-build --pull never
    check_capture_bound "$case_log"
    backend=$(compose ps -q backend)
    postgres=$(compose ps -q postgres)
    [ -n "$backend" ] && [ -n "$postgres" ]
    [ "$(timeout 30s docker inspect "$backend" --format '{{.Image}}')" = "$previous_id" ]
    [ "$(timeout 30s docker inspect "$postgres" --format '{{.State.Health.Status}}')" = healthy ]
    assert_postgres_image "$postgres"
    runtime_stage previous_compose_ready
    assert_internal_network
    assert_outbound_blocked "$backend"
    runtime_stage previous_network_ready
    capture_command "$probe_log" timeout 1800s python3 "$case_root/probe.py" \
      "$probe_port" "$app_port" "$probe_cert" "$probe_key" &
    probe_pid=$!
    probe_ready=false
    for _ in $(seq 1 30); do
      if ! kill -0 "$probe_pid" 2>/dev/null; then
        break
      fi
      probe_status=$(CURL_CA_BUNDLE="$probe_cert" timeout 3s curl \
        --silent --output /dev/null --write-out '%{http_code}' \
        "$public_url/actuator" 2>/dev/null || true)
      if [ "$probe_status" = 404 ]; then
        probe_ready=true
        break
      fi
      sleep 1
    done
    [ "$probe_ready" = true ]
    runtime_stage probe_ready

    verify_case_runtime() {
      local expected_id=$1
      local expected_revision=$2
      local expected_version=$3
      local current_backend current_hash
      current_backend=$(compose ps -q backend)
      [ -n "$current_backend" ]
      current_hash=$(timeout 30s docker inspect "$current_backend" \
        --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
      capture_command "$matrix_fixture/$case_name-runtime-$expected_version.out" \
        timeout 90s bash -c '
        set -euo pipefail
        source "$1"
        verify_runtime_invariants "$2" "$3" "$4" "$5" "$6" "$7"
        verify_environment_matches_container "$2" "$3"
      ' _ "$ROOT_DIR/scripts/test-vps-runtime-invariants.sh" \
        "$case_root" "$ROOT_DIR/scripts/production-compose.sh" \
        "$expected_id" "$expected_revision" "$expected_version" \
        "$current_hash"
      printf 'runtime_invariants case=%s version=%s passed\n' \
        "$case_name" "$expected_version" >>"$case_log"
    }

    observe_provider() {
      local current_backend
      current_backend=$(compose ps -q backend)
      timeout 30s docker inspect "$current_backend" |
        timeout 30s python3 "$ROOT_DIR/scripts/test-vps-provider-credential.py" observe
    }

    assert_provider_state() {
      local expected_enabled=$1
      observed=$(observe_provider)
      jq -e --argjson enabled "$expected_enabled" '
        type == "object" and .schemaVersion == 1 and
        .providerEnabled == $enabled and
        .credentialMountPresent == $enabled and
        .credentialMountReadOnly == $enabled and
        .outcome == "observed"
      ' <<<"$observed" >/dev/null
      printf 'provider_observed case=%s enabled=%s\n' \
        "$case_name" "$expected_enabled" >>"$case_log"
    }

    assert_terminal_state() {
      local state_path=$1
      local expected_outcome=$2
      local expected_enabled=$3
      jq -e --arg outcome "$expected_outcome" \
        --argjson enabled "$expected_enabled" \
        --arg run_key "${state_path##*/}" '
        .schemaVersion == 1 and .runKey == ($run_key
          | sub("-(rollback-drill|final-deploy)$"; "")) and
        .outcome == $outcome and .providerEnabled == $enabled and
        (.providerEnabled | type == "boolean")
      ' "$state_path/terminal.json" >/dev/null
      [ -f "$state_path/provider-owner.json" ]
      assert_private_state_snapshots "$state_path"
      timeout 30s python3 "$ROOT_DIR/scripts/test-vps-provider-credential.py" \
        retention-list --state-root "$state_root" >/dev/null
    }

    run_coordinator() {
      local coordinator_status
      assert_internal_network || return 1
      if timeout 1200s env \
        CURL_CA_BUNDLE="$probe_cert" \
        TEST_VPS_STATE_ROOT="$state_root" \
        bash "$ROOT_DIR/scripts/deploy-test-vps-provider-release.sh" \
        --root "$case_root" \
        --base-compose "$case_root/docker-compose.production.yml" \
        --image "$1" --revision "$2" --version "$3" \
        --run-key "$4" --mode "$5" --public-url "$public_url"; then
        coordinator_status=0
      else
        coordinator_status=$?
      fi
      assert_internal_network || return 1
      return "$coordinator_status"
    }

    run_rollback_drill() {
      local current_backend target_seen=false
      capture_command "$rollback_capture" run_coordinator \
        "$target_image" "$target_revision" \
        "$target_version" "$rollback_run_key" rollback-drill \
        &
      coordinator_pid=$!
      for _ in $(seq 1 300); do
        if ! kill -0 "$coordinator_pid" 2>/dev/null; then
          break
        fi
        current_backend=$(compose ps -q backend)
        if [ -n "$current_backend" ] &&
          [ "$(timeout 30s docker inspect "$current_backend" \
            --format '{{.Image}}')" = "$target_id" ]; then
          target_seen=true
          if ! assert_internal_network ||
            ! assert_outbound_blocked "$current_backend"; then
            kill "$coordinator_pid" 2>/dev/null || true
            return 1
          fi
          if ! assert_postgres_image "$postgres" ||
            ! verify_case_runtime "$target_id" "$target_revision" "$target_version"; then
            kill "$coordinator_pid" 2>/dev/null || true
            return 1
          fi
          break
        fi
        sleep 1
      done
      set +e
      wait "$coordinator_pid"
      local coordinator_status=$?
      set -e
      [ "$target_seen" = true ]
      return "$coordinator_status"
    }

    runtime_stage rollback_started
    set +e
    run_rollback_drill
    rollback_status=$?
    set -e
    check_capture_bound "$rollback_capture"
    rollback_output=$(<"$rollback_capture")
    printf 'rollback_capture case=%s bytes=%s status=%s\n' \
      "$case_name" "$(wc -c <"$rollback_capture")" "$rollback_status" >>"$case_log"
    [ "$rollback_status" -eq 86 ]
    grep -Fq 'candidate=ready' <<<"$rollback_output"
    grep -Fq 'rollback=completed previous_image_id=' <<<"$rollback_output"
    previous_state="$state_root/$rollback_run_key-rollback-drill"
    assert_terminal_state "$previous_state" rolled-back "$provider_enabled"
    verify_case_runtime "$previous_id" "$previous_revision" "$previous_version"
    assert_postgres_image "$postgres"
    assert_provider_state "$provider_enabled"
    [ "$(grep '^BACKEND_IMAGE=' "$case_root/.env.production")" = \
      "BACKEND_IMAGE=$previous_image" ]
    legacy_after=$(legacy_digest)
    [ "$legacy_before" = "$legacy_after" ]
    runtime_stage rollback_completed

    runtime_stage deploy_started
    set +e
    capture_command "$deploy_capture" run_coordinator \
      "$target_image" "$target_revision" \
      "$target_version" "$deploy_run_key" deploy
    deploy_status=$?
    set -e
    check_capture_bound "$deploy_capture"
    deploy_output=$(<"$deploy_capture")
    printf 'deploy_capture case=%s bytes=%s status=%s\n' \
      "$case_name" "$(wc -c <"$deploy_capture")" "$deploy_status" >>"$case_log"
    [ "$deploy_status" -eq 0 ]
    grep -Fq 'candidate=ready' <<<"$deploy_output"
    grep -Fq 'deployment=completed image_id=' <<<"$deploy_output"
    target_state="$state_root/$deploy_run_key-final-deploy"
    assert_terminal_state "$target_state" committed "$provider_enabled"
    backend=$(compose ps -q backend)
    [ "$(timeout 30s docker inspect "$backend" --format '{{.Image}}')" = "$target_id" ]
    assert_postgres_image "$postgres"
    assert_internal_network
    assert_outbound_blocked "$backend"
    verify_case_runtime "$target_id" "$target_revision" "$target_version"
    assert_provider_state "$provider_enabled"
    [ "$(grep '^BACKEND_IMAGE=' "$case_root/.env.production")" = \
      "BACKEND_IMAGE=$target_image" ]
    legacy_after=$(legacy_digest)
    [ "$legacy_before" = "$legacy_after" ]
    scan_case_secrets
    runtime_stage deploy_completed
    printf 'image_runtime case=%s previous_id=%s target_id=%s cleanup=pending\n' \
      "$case_name" "$previous_id" "$target_id"
  )

  run_image_case disabled 1 930000001-1 930000002-1 false
  run_image_case enabled 2 930000003-1 930000004-1 true
  set +e
  timeout 30s rm -r -- "$matrix_fixture"
  matrix_status=$?
  transport_cleanup_body "$matrix_status"
  transport_status=$?
  set -e
  trap - EXIT
  [ "$transport_status" -eq 0 ] || exit "$transport_status"
fi

fixture=$(mktemp -d /var/lib/meet-provider-fixture.XXXXXX 2>/dev/null) ||
  prerequisite_missing
if ! chmod 700 "$fixture" 2>/dev/null; then
  timeout 30s rm -r -- "$fixture" >/dev/null 2>&1 || true
  prerequisite_missing
fi
cleanup() {
  local status=$?
  trap - EXIT
  timeout 30s rm -r -- "$fixture"
  exit "$status"
}
trap cleanup EXIT

fixture_log="$fixture/output.log"
fixture_secret=RUNTIME_FIXTURE_PRIVATE_SECRET_9f7d8d
if ! python3 - "$fixture" >"$fixture_log" 2>&1 <<'PY'
import importlib.util
import contextlib
import io
import json
import os
import pathlib
import shutil
import stat
import struct
import sys
import tempfile

fixture = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "provider_helper", pathlib.Path("scripts/test-vps-provider-credential.py")
)
assert spec is not None and spec.loader is not None
helper = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = helper
spec.loader.exec_module(helper)

parent = fixture / "credentials"
parent.mkdir(mode=0o700)
os.chown(parent, 0, 0)
source = fixture / "predecessor.json"
account = {
    "type": "service_account",
    "project_id": helper.EXPECTED_PROJECT,
    "client_email": "runtime-fixture@example.invalid",
    "client_id": "runtime-fixture-id",
    "private_key_id": "runtime-fixture-key",
    "private_key": "-----BEGIN PRIVATE KEY-----\nRUNTIME_FIXTURE_PRIVATE_SECRET_9f7d8d\n-----END PRIVATE KEY-----",
    "token_uri": "https://oauth2.example.invalid/token",
}
source.write_text(json.dumps(account), encoding="utf-8")
os.chown(source, 0, 10001)
os.chmod(source, 0o640)

helper.HOST_CREDENTIAL_PARENT = str(parent)
helper.HOST_CREDENTIAL_PATH = str(parent / "firebase-service-account.json")
helper.CONTAINER_CREDENTIAL_PATH = "/run/secrets/meet-firebase-service-account.json"
state = fixture / "state"
state.mkdir(mode=0o700)
os.chown(state, 0, 0)
marker = state / ".provider-transaction.current"

published_root = fixture / "published-states"
published_root.mkdir(mode=0o700)
os.chown(published_root, 0, 0)
state_publish_output = io.StringIO()
with contextlib.redirect_stdout(state_publish_output):
    helper._state_publish(str(published_root), "123456789-1", "final-deploy")
assert json.loads(state_publish_output.getvalue()) == {
    "schemaVersion": 1,
    "providerEnabled": False,
    "credentialMountPresent": False,
    "credentialMountReadOnly": False,
    "outcome": "published",
}
published_state = published_root / "123456789-1-final-deploy"
assert (published_state / helper.OWNER_MARKER).read_bytes() == helper._state_marker(
    "123456789-1", "final-deploy"
)
expect_collision = published_root / "456-1-final-deploy"
expect_collision.mkdir(mode=0o700)
os.chown(expect_collision, 0, 0)
try:
    helper._state_publish(str(published_root), "456-1", "final-deploy")
except helper.ProviderError as error:
    assert error.category == "RECOVERY_REQUIRED"
else:
    raise AssertionError("state publication accepted an invalid run key")

publication_race_root = fixture / "publication-race-root"
publication_race_root.mkdir(mode=0o700)
os.chown(publication_race_root, 0, 0)
publication_race_moved = fixture / "publication-race-root-moved"
publication_race_name = "123456790-1-final-deploy"
original_lock_directory = helper._lock_directory
publication_swapped = [False]

def swap_publication_root_after_lock(fd):
    original_lock_directory(fd)
    if not publication_swapped[0]:
        os.rename(publication_race_root, publication_race_moved)
        publication_race_root.mkdir(mode=0o700)
        os.chown(publication_race_root, 0, 0)
        publication_swapped[0] = True

helper._lock_directory = swap_publication_root_after_lock
try:
    helper._state_publish(
        str(publication_race_root),
        "123456790-1",
        "final-deploy",
    )
except helper.ProviderError as error:
    assert error.category == "RECOVERY_REQUIRED"
else:
    raise AssertionError("state publication accepted a swapped root")
helper._lock_directory = original_lock_directory
assert not (publication_race_root / publication_race_name).exists()
assert (publication_race_moved / publication_race_name).is_dir()
shutil.rmtree(publication_race_root)
shutil.rmtree(publication_race_moved)

publication_interlock_root = fixture / "publication-interlock-root"
publication_interlock_root.mkdir(mode=0o700)
os.chown(publication_interlock_root, 0, 0)
publication_interlock_name = "123456791-1-final-deploy"
original_publication_interlocks = helper._retention_interlocks_fd
publication_interlock_calls = [0]

def inject_publication_interlock(root, state_root_fd, **kwargs):
    publication_interlock_calls[0] += 1
    if publication_interlock_calls[0] == 2:
        helper._write_private_at(
            state_root_fd,
            ".provider-transaction.current",
            b"publication-interlock-race",
            0o600,
        )
    return original_publication_interlocks(root, state_root_fd, **kwargs)

helper._retention_interlocks_fd = inject_publication_interlock
try:
    helper._state_publish(
        str(publication_interlock_root),
        "123456791-1",
        "final-deploy",
    )
except helper.ProviderError as error:
    assert error.category == "RECOVERY_REQUIRED"
else:
    raise AssertionError("state publication ignored a new interlock")
helper._retention_interlocks_fd = original_publication_interlocks
assert not (publication_interlock_root / publication_interlock_name).exists()
assert (
    publication_interlock_root / ".provider-transaction.current"
).exists()
(publication_interlock_root / ".provider-transaction.current").unlink()
temporary_publication = (
    publication_interlock_root
    / (".provider-state." + publication_interlock_name + ".tmp")
)
if temporary_publication.exists():
    shutil.rmtree(temporary_publication)
shutil.rmtree(publication_interlock_root)

publication_source_race_root = fixture / "publication-source-race-root"
publication_source_race_root.mkdir(mode=0o700)
os.chown(publication_source_race_root, 0, 0)
publication_source_race_name = "123456792-1-final-deploy"
publication_source_race_temporary = (
    ".provider-state." + publication_source_race_name + ".tmp"
)
publication_source_race_displaced = (
    publication_source_race_root / (publication_source_race_temporary + ".displaced")
)
original_publication_boundary = helper._rename_noreplace_boundary

def replace_publication_source_at_boundary(
    directory_fd,
    source_name,
    destination_name,
):
    if (
        source_name == publication_source_race_temporary
        and destination_name == publication_source_race_name
    ):
        os.rename(
            source_name,
            publication_source_race_displaced.name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        os.mkdir(source_name, 0o700, dir_fd=directory_fd)
        replacement_fd = os.open(
            source_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
        try:
            os.fchown(replacement_fd, 0, 0)
            os.fchmod(replacement_fd, 0o700)
            helper._write_private_at(
                replacement_fd,
                helper.OWNER_MARKER,
                helper._state_marker("123456792-1", "final-deploy"),
                0o600,
            )
            os.fsync(replacement_fd)
        finally:
            os.close(replacement_fd)
    return original_publication_boundary(
        directory_fd,
        source_name,
        destination_name,
    )

helper._rename_noreplace_boundary = replace_publication_source_at_boundary
try:
    helper._state_publish(
        str(publication_source_race_root),
        "123456792-1",
        "final-deploy",
    )
except helper.ProviderError as error:
    assert error.category == "RECOVERY_REQUIRED"
else:
    raise AssertionError("state publication accepted a replaced source")
helper._rename_noreplace_boundary = original_publication_boundary
assert publication_source_race_displaced.is_dir()
assert (
    publication_source_race_root / publication_source_race_name
).is_dir()
assert not (publication_source_race_root / publication_source_race_temporary).exists()
shutil.rmtree(publication_source_race_root)

def prepare_marker(run_key: str) -> None:
    helper._write_private(
        str(marker),
        json.dumps(
            {
                "schemaVersion": 1,
                "runKey": run_key,
                "phase": "preparing",
                "providerEnabled": True,
                "durableDisposition": "none",
            },
            separators=(",", ":"),
        ).encode(),
        0o600,
    )

def cleanup_transaction(run_key: str, remove_destination: bool = True) -> None:
    marker.unlink(missing_ok=True)
    shutil.rmtree(parent / f".transaction-{run_key}", ignore_errors=True)
    if remove_destination:
        pathlib.Path(helper.HOST_CREDENTIAL_PATH).unlink(missing_ok=True)

def acl(entries: list[tuple[int, int, int]]) -> bytes:
    return struct.pack("<I", 2) + b"".join(
        struct.pack("<HHI", tag, permission, identifier)
        for tag, permission, identifier in entries
    )

def add_default_acl(path: pathlib.Path) -> None:
    os.setxattr(
        path,
        "system.posix_acl_default",
        acl(
            [
                (1, 7, 0xFFFFFFFF),
                (2, 4, 20002),
                (4, 5, 0xFFFFFFFF),
                (16, 5, 0xFFFFFFFF),
                (32, 5, 0xFFFFFFFF),
            ]
        ),
    )

def add_private_access_acl(path: pathlib.Path) -> None:
    os.setxattr(
        path,
        "system.posix_acl_access",
        acl(
            [
                (1, 0, 0xFFFFFFFF),
                (2, 4, 20002),
                (4, 0, 0xFFFFFFFF),
                (16, 0, 0xFFFFFFFF),
                (32, 0, 0xFFFFFFFF),
            ]
        ),
    )

def remove_acl(path: pathlib.Path, attribute: str) -> None:
    try:
        os.removexattr(path, attribute)
    except OSError as error:
        if error.errno != 61:
            raise

def expect_provider_error(action, category: str) -> None:
    try:
        action()
    except helper.ProviderError as error:
        assert error.category == category, error.category
    else:
        raise AssertionError(f"expected {category}")

def deny_unprivileged_read(path: pathlib.Path) -> None:
    child = os.fork()
    if child == 0:
        try:
            os.setgroups([])
            os.setgid(20002)
            os.setuid(20002)
            with path.open("rb"):
                os._exit(0)
        except OSError:
            os._exit(1)
    _, status = os.waitpid(child, 0)
    assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 1

def inspect(source_path: pathlib.Path) -> dict:
    return {
        "Config": {
            "Env": [
                "APP_PUSH_PROVIDER_ENABLED=true",
                "APP_PUSH_DISCOVERY_ENABLED=false",
                "APP_PUSH_DISPATCH_ENABLED=false",
                "APP_PUSH_DIAGNOSTIC_ENABLED=false",
                "APP_PUSH_MAINTENANCE_ENABLED=false",
                "APP_PUSH_PROJECT_ID=meeting-1d258",
                "APP_PUSH_CREDENTIALS_FILE=/run/secrets/meet-firebase-service-account.json",
            ]
        },
        "Mounts": [
            {"Type": "volume", "Destination": "/data/uploads"},
            {"Type": "tmpfs", "Destination": "/tmp"},
            {
                "Type": "bind",
                "Source": str(source_path),
                "Destination": "/run/secrets/meet-firebase-service-account.json",
                "RW": False,
            },
        ],
    }

predecessor = inspect(source)
add_default_acl(parent)
assert os.getxattr(parent, "system.posix_acl_default")
expect_provider_error(
    lambda: helper._acl_is_safe(str(parent)),
    "CREDENTIAL_INVALID",
)
expect_provider_error(
    lambda: helper._prepare(
        "default-acl-parent", str(state), "", json.dumps(predecessor).encode()
    ),
    "CREDENTIAL_INVALID",
)
remove_acl(parent, "system.posix_acl_default")
assert not (parent / ".transaction-default-acl-parent").exists()

prepare_marker("race-disappearance")
original_read_existing = helper._read_existing
race_removed = False

def remove_destination_before_read(path: str, source: bool = False):
    global race_removed
    if path == helper.HOST_CREDENTIAL_PATH and not source and not race_removed:
        race_removed = True
        pathlib.Path(path).unlink()
    return original_read_existing(path, source=source)

helper._read_existing = remove_destination_before_read
expect_provider_error(
    lambda: helper._prepare(
        "race-disappearance", str(state), "", json.dumps(predecessor).encode()
    ),
    "CREDENTIAL_INVALID",
)
helper._read_existing = original_read_existing
assert not pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
assert (parent / ".transaction-race-disappearance" / "snapshot").exists()
assert json.loads(marker.read_text())["durableDisposition"] == "none"
cleanup_transaction("race-disappearance")

prepare_marker("race-appearance")
original_link = helper.os.link

def create_raced_destination(source_path: str, destination_path: str, **kwargs):
    fd = os.open(destination_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o440)
    try:
        os.write(fd, source.read_bytes())
        os.fchown(fd, 0, 10001)
        os.fchmod(fd, 0o440)
    finally:
        os.close(fd)
    raise FileExistsError(17, "destination appeared", destination_path)

helper.os.link = create_raced_destination
expect_provider_error(
    lambda: helper._prepare(
        "race-appearance", str(state), "", json.dumps(predecessor).encode()
    ),
    "DURABLE_CONFLICT",
)
helper.os.link = original_link
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
assert (parent / ".transaction-race-appearance" / "publication").exists()
assert json.loads(marker.read_text())["durableDisposition"] == "none"
cleanup_transaction("race-appearance")

prepare_marker("source-drift")
helper._prepare("source-drift", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "source-drift",
            "phase": "prepared",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
changed_account = dict(account)
changed_account["client_id"] = "runtime-fixture-changed-id"
source.write_text(json.dumps(changed_account), encoding="utf-8")
os.chown(source, 0, 10001)
os.chmod(source, 0o640)
expect_provider_error(
    lambda: helper._verify(
        "source-drift",
        "",
        json.dumps([predecessor, predecessor]).encode(),
        "predecessor",
        str(state),
    ),
    "CREDENTIAL_CHANGED",
)
source.write_text(json.dumps(account), encoding="utf-8")
os.chown(source, 0, 10001)
os.chmod(source, 0o640)
cleanup_transaction("source-drift")

prepare_marker("witness-removal")
helper._prepare("witness-removal", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "witness-removal",
            "phase": "verifying",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
(parent / ".transaction-witness-removal" / "publication").unlink()
candidate = inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))
expect_provider_error(
    lambda: helper._verify(
        "witness-removal",
        "",
        json.dumps([predecessor, candidate]).encode(),
        "candidate",
        str(state),
    ),
    "RECOVERY_REQUIRED",
)
cleanup_transaction("witness-removal")

prepare_marker("marker-drift")
helper._prepare("marker-drift", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "marker-drift",
            "phase": "prepared",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
expect_provider_error(
    lambda: helper._verify(
        "marker-drift",
        "",
        json.dumps([predecessor, candidate]).encode(),
        "candidate",
        str(state),
    ),
    "RECOVERY_REQUIRED",
)
cleanup_transaction("marker-drift")

prepare_marker("created")
helper._prepare("created", str(state), "", json.dumps(predecessor).encode())
assert json.loads(marker.read_text())["durableDisposition"] == "created"
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "created",
            "phase": "verifying",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
deny_unprivileged_read(parent / ".transaction-created" / "snapshot")
deny_unprivileged_read(parent / ".transaction-created" / "identity.json")
add_default_acl(parent / ".transaction-created")
expect_provider_error(
    lambda: helper._verify(
        "created",
        "",
        json.dumps([predecessor, inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))]).encode(),
        "candidate",
    ),
    "RECOVERY_REQUIRED",
)
remove_acl(parent / ".transaction-created", "system.posix_acl_default")
add_private_access_acl(parent / ".transaction-created" / "snapshot")
expect_provider_error(
    lambda: helper._verify(
        "created",
        "",
        json.dumps([predecessor, inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))]).encode(),
        "candidate",
    ),
    "RECOVERY_REQUIRED",
)
remove_acl(parent / ".transaction-created" / "snapshot", "system.posix_acl_access")
os.chmod(parent / ".transaction-created" / "snapshot", 0o600)
candidate = inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))
helper._verify(
    "created",
    "",
    json.dumps([predecessor, candidate]).encode(),
    "candidate",
)
helper._finish("created", str(state), "", "committed", json.dumps(candidate).encode())
marker.unlink()
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
assert not (parent / ".transaction-created").exists()

prepare_marker("reused")
helper._prepare("reused", str(state), "", json.dumps(predecessor).encode())
assert json.loads(marker.read_text())["durableDisposition"] == "reused"
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "reused",
            "phase": "finalizing",
            "providerEnabled": True,
            "durableDisposition": "reused",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
helper._finish("reused", str(state), "", "committed", json.dumps(candidate).encode())
marker.unlink()
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()

os.unlink(helper.HOST_CREDENTIAL_PATH)
prepare_marker("rollback")
helper._prepare("rollback", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "rollback",
            "phase": "rolling-back",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
helper._finish("rollback", str(state), "", "rolled-back", json.dumps(predecessor).encode())
assert not pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
marker.unlink()

prepare_marker("witness-tamper")
helper._prepare("witness-tamper", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "witness-tamper",
            "phase": "finalizing",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
os.chmod(parent / ".transaction-witness-tamper" / "publication", 0o600)
try:
    helper._finish(
        "witness-tamper",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    )
except helper.ProviderError as error:
    assert error.category == "RECOVERY_REQUIRED"
else:
    raise AssertionError("tampered publication witness was accepted")
cleanup_transaction("witness-tamper")

def prepare_finalizing(run_key: str) -> dict:
    prepare_marker(run_key)
    helper._prepare(run_key, str(state), "", json.dumps(predecessor).encode())
    marker.unlink()
    helper._write_private(
        str(marker),
        json.dumps(
            {
                "schemaVersion": 1,
                "runKey": run_key,
                "phase": "finalizing",
                "providerEnabled": True,
                "durableDisposition": "created",
            },
            separators=(",", ":"),
        ).encode(),
        0o600,
    )
    return inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))

def finish_and_remove(run_key: str, candidate: dict) -> None:
    helper._finish(
        run_key,
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    )
    marker.unlink()
    assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
    cleanup_transaction(run_key)

candidate = prepare_finalizing("cleanup-hard-link")
hard_link = parent / "operator-hard-link"
os.link(helper.HOST_CREDENTIAL_PATH, hard_link)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-hard-link",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
assert hard_link.exists()
hard_link.unlink()
cleanup_transaction("cleanup-hard-link")

candidate = prepare_finalizing("cleanup-metadata")
os.chmod(helper.HOST_CREDENTIAL_PATH, 0o600)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-metadata",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
os.chmod(helper.HOST_CREDENTIAL_PATH, 0o440)
cleanup_transaction("cleanup-metadata")

candidate = prepare_finalizing("cleanup-replacement")
os.unlink(helper.HOST_CREDENTIAL_PATH)
replacement = parent / "operator-replacement"
replacement.write_bytes(b"operator replacement")
os.chown(replacement, 0, 10001)
os.chmod(replacement, 0o440)
os.rename(replacement, helper.HOST_CREDENTIAL_PATH)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-replacement",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).read_bytes() == b"operator replacement"
cleanup_transaction("cleanup-replacement")

candidate = prepare_finalizing("cleanup-symlink")
os.unlink(helper.HOST_CREDENTIAL_PATH)
os.symlink(source, helper.HOST_CREDENTIAL_PATH)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-symlink",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).is_symlink()
cleanup_transaction("cleanup-symlink")

candidate = prepare_finalizing("cleanup-unlink-race")
original_unlink = helper.os.unlink

def reject_descriptor_unlink(path, **kwargs):
    if kwargs.get("dir_fd") is not None:
        raise OSError(11, "operator replacement race")
    return original_unlink(path, **kwargs)

helper.os.unlink = reject_descriptor_unlink
expect_provider_error(
    lambda: helper._finish(
        "cleanup-unlink-race",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
helper.os.unlink = original_unlink
finish_and_remove("cleanup-unlink-race", candidate)

for child in ("identity.json", "snapshot", "publication"):
    run_key = "cleanup-same-metadata-" + child.replace(".", "-")
    candidate = prepare_finalizing(run_key)
    tx = parent / (".transaction-" + run_key)
    original_witness = helper._child_witness
    replaced = [False]

    def replace_transaction_child(directory_fd, name, **kwargs):
        result = original_witness(directory_fd, name, **kwargs)
        if name == child and not replaced[0]:
            replacement = fixture / ("replacement-" + run_key)
            data = (tx / child).read_bytes()
            info = os.stat(tx / child, follow_symlinks=False)
            os.unlink(tx / child)
            replacement.write_bytes(data)
            os.chown(replacement, info.st_uid, info.st_gid)
            os.chmod(replacement, stat.S_IMODE(info.st_mode))
            os.rename(replacement, tx / child)
            replaced[0] = True
        return result

    helper._child_witness = replace_transaction_child
    expect_provider_error(
        lambda: helper._finish(
            run_key,
            str(state),
            "",
            "committed",
            json.dumps(candidate).encode(),
        ),
        "RECOVERY_REQUIRED",
    )
    helper._child_witness = original_witness
    assert (tx / child).exists()
    assert marker.exists()
    shutil.rmtree(tx)
    marker.unlink()
    pathlib.Path(helper.HOST_CREDENTIAL_PATH).unlink(missing_ok=True)

retention_root = fixture / "retention-root"
retention_root.mkdir(mode=0o700)
os.chown(retention_root, 0, 0)
retention_check_output = io.StringIO()
with contextlib.redirect_stdout(retention_check_output):
    helper._retention_check("", str(retention_root))
assert json.loads(retention_check_output.getvalue()) == {
    "schemaVersion": 1,
    "providerEnabled": False,
    "credentialMountPresent": False,
    "credentialMountReadOnly": False,
    "outcome": "retention-safe",
}
retention_list_output = io.BytesIO()
saved_stdout = sys.stdout
sys.stdout = type(
    "BinaryCapture",
    (),
    {"buffer": retention_list_output},
)()
try:
    helper._retention_list("", str(retention_root))
finally:
    sys.stdout = saved_stdout
assert json.loads(retention_list_output.getvalue()) == {
    "schemaVersion": 1,
    "outcome": "retention-safe",
    "ownedStates": [],
}
missing_retention_root = fixture / "missing-retention-root"
expect_provider_error(
    lambda: helper._retention_check("", str(missing_retention_root)),
    "RECOVERY_REQUIRED",
)
unsafe_state_root = fixture / "unsafe-retention-root"
unsafe_state_root.mkdir(mode=0o700)
os.chown(unsafe_state_root, 0, 0)
os.chmod(unsafe_state_root, 0o755)
expect_provider_error(
    lambda: helper._retention_check("", str(unsafe_state_root)),
    "RECOVERY_REQUIRED",
)
os.chmod(unsafe_state_root, 0o700)
os.chown(unsafe_state_root, 65534, 65534)
expect_provider_error(
    lambda: helper._retention_check("", str(unsafe_state_root)),
    "RECOVERY_REQUIRED",
)
os.chown(unsafe_state_root, 0, 0)
shutil.rmtree(unsafe_state_root)
for child in sorted(helper.RETENTION_CHILDREN - {"provider-owner.json", "terminal.json"}):
    retention_state = retention_root / "77-1-final-deploy"
    retention_state.mkdir(mode=0o700)
    os.chown(retention_state, 0, 0)
    for state_child in helper.RETENTION_CHILDREN:
        path = retention_state / state_child
        if state_child == "provider-owner.json":
            path.write_bytes(
                helper._state_marker("77-1", "final-deploy")
            )
        elif state_child == "terminal.json":
            path.write_bytes(
                b'{"schemaVersion":1,"runKey":"77-1","outcome":"committed","providerEnabled":false}'
            )
        else:
            path.write_bytes(("retention-" + state_child).encode())
        os.chown(path, 0, 0)
        os.chmod(path, 0o600)
    original_witness = helper._child_witness
    replaced = [False]

    def replace_retention_child(directory_fd, name, **kwargs):
        result = original_witness(directory_fd, name, **kwargs)
        if name == child and not replaced[0]:
            replacement = fixture / ("retention-replacement-" + child.replace(".", "-"))
            data = (retention_state / child).read_bytes()
            os.unlink(retention_state / child)
            replacement.write_bytes(data)
            os.chown(replacement, 0, 0)
            os.chmod(replacement, 0o600)
            os.rename(replacement, retention_state / child)
            replaced[0] = True
        return result

    helper._child_witness = replace_retention_child
    expect_provider_error(
        lambda: helper._retention_delete(
            str(retention_root),
            str(retention_state),
        ),
        "RECOVERY_REQUIRED",
    )
    helper._child_witness = original_witness
    quarantine = retention_root / ".provider-state.77-1-final-deploy.tmp"
    assert not retention_state.exists()
    assert quarantine.exists()
    shutil.rmtree(quarantine)

def retention_snapshot(path):
    snapshot = []
    for entry in sorted(path.rglob("*")):
        info = os.lstat(entry)
        data = entry.read_bytes() if stat.S_ISREG(info.st_mode) else None
        snapshot.append(
            (
                str(entry.relative_to(path)),
                info.st_mode,
                info.st_uid,
                info.st_gid,
                info.st_nlink,
                info.st_mtime_ns,
                data,
            )
        )
    return snapshot

def valid_retention_state(name):
    path = retention_root / name
    path.mkdir(mode=0o700)
    os.chown(path, 0, 0)
    marker_path = path / "provider-owner.json"
    marker_path.write_bytes(helper._state_marker(*helper._state_parts(name)))
    terminal_path = path / "terminal.json"
    terminal_path.write_bytes(
        (
            (
                '{"schemaVersion":1,"runKey":"%s","outcome":"committed",'
                '"providerEnabled":false}'
            )
            % helper._state_parts(name)[0]
        ).encode()
    )
    for child, mtime_ns in (
        (marker_path, 1_700_000_000_123_456_789),
        (terminal_path, 1_700_000_000_987_654_321),
    ):
        os.chown(child, 0, 0)
        os.chmod(child, 0o600)
        os.utime(child, ns=(mtime_ns, mtime_ns))
    os.utime(path, ns=(1_700_000_001_987_654_321,) * 2)
    return path

def open_fd_count():
    return len(os.listdir("/proc/self/fd"))

def assert_witness_descriptor_cleanup():
    root = fixture / "witness-fd-regression"
    root.mkdir(mode=0o700)
    os.chown(root, 0, 0)
    entry = root / "entry"
    entry.write_bytes(b"witness descriptor regression")
    os.chown(entry, 0, 0)
    os.chmod(entry, 0o600)
    directory_fd = os.open(
        root,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        baseline = open_fd_count()
        identity, data = helper._child_witness(directory_fd, "entry")
        assert open_fd_count() == baseline + 1
        expect_provider_error(
            lambda: helper._witnessed_unlink(
                directory_fd,
                "entry",
                expected_identity=identity,
                expected_data=data,
                uid=0,
                gid=0,
                mode=0o640,
                link_count=1,
            ),
            "RECOVERY_REQUIRED",
        )
        assert open_fd_count() == baseline

        identity, data = helper._child_witness(directory_fd, "entry")
        assert open_fd_count() == baseline + 1
        os.unlink("entry", dir_fd=directory_fd)
        expect_provider_error(
            lambda: helper._witnessed_unlink(
                directory_fd,
                "entry",
                expected_identity=identity,
                expected_data=data,
                uid=0,
                gid=0,
                mode=0o600,
                link_count=1,
            ),
            "RECOVERY_REQUIRED",
        )
        assert open_fd_count() == baseline
    finally:
        os.close(directory_fd)
        shutil.rmtree(root)

assert_witness_descriptor_cleanup()

def assert_direct_retention_refusal(path, **kwargs):
    before = retention_snapshot(path)
    quarantine = retention_root / (".provider-state." + path.name + ".tmp")
    quarantine_before = quarantine.exists()
    expect_provider_error(
        lambda: helper._retention_delete(
            str(retention_root),
            str(path),
            **kwargs,
        ),
        "RECOVERY_REQUIRED",
    )
    assert retention_snapshot(path) == before
    assert quarantine.exists() == quarantine_before

root_swap_state = valid_retention_state("90-1-final-deploy")
root_swap_before = retention_snapshot(root_swap_state)
swapped_root = fixture / "retention-root-swapped-away"
original_interlocks_fd = helper._retention_interlocks_fd

def swap_root_after_interlocks(root, state_root_fd):
    original_interlocks_fd(root, state_root_fd)
    os.rename(retention_root, swapped_root)
    retention_root.mkdir(mode=0o700)
    os.chown(retention_root, 0, 0)

helper._retention_interlocks_fd = swap_root_after_interlocks
expect_provider_error(
    lambda: helper._retention_delete(
        str(retention_root),
        str(root_swap_state),
    ),
    "RECOVERY_REQUIRED",
)
helper._retention_interlocks_fd = original_interlocks_fd
assert retention_snapshot(swapped_root / root_swap_state.name) == root_swap_before
assert not (retention_root / root_swap_state.name).exists()
assert not (retention_root / (".provider-state." + root_swap_state.name + ".tmp")).exists()
shutil.rmtree(retention_root)
os.rename(swapped_root, retention_root)
assert retention_snapshot(root_swap_state) == root_swap_before
shutil.rmtree(root_swap_state)

protected_reference_state = valid_retention_state("91-1-final-deploy")
protected_reference_before = retention_snapshot(protected_reference_state)
protected_reference = fixture / "protected-reference"
protected_reference.write_bytes(b"protected-reference-before-race")
os.chown(protected_reference, 0, 0)
os.chmod(protected_reference, 0o600)
original_revalidate_references = helper._revalidate_protected_references
reference_replaced = [False]

def replace_protected_reference(paths, witnesses):
    if not reference_replaced[0]:
        replacement = fixture / "protected-reference-replacement"
        replacement.write_bytes(b"protected-reference-replacement")
        os.chown(replacement, 0, 0)
        os.chmod(replacement, 0o600)
        os.rename(replacement, protected_reference)
        reference_replaced[0] = True
    return original_revalidate_references(paths, witnesses)

helper._revalidate_protected_references = replace_protected_reference
expect_provider_error(
    lambda: helper._retention_delete(
        str(retention_root),
        str(protected_reference_state),
        protected_paths=[str(protected_reference)],
    ),
    "RECOVERY_REQUIRED",
)
helper._revalidate_protected_references = original_revalidate_references
assert retention_snapshot(protected_reference_state) == protected_reference_before
assert not (
    retention_root
    / (".provider-state." + protected_reference_state.name + ".tmp")
).exists()
protected_reference.unlink()
shutil.rmtree(protected_reference_state)

protected_alias_state = valid_retention_state("94-1-final-deploy")
protected_alias_before = retention_snapshot(protected_alias_state)
protected_alias = fixture / "protected-alias"
protected_alias.write_bytes(b"protected-alias")
os.chown(protected_alias, 0, 0)
os.chmod(protected_alias, 0o600)
original_reference_witness = helper._protected_reference_witness
alias_child_info = os.stat(
    protected_alias_state / "terminal.json",
    follow_symlinks=False,
)

def synthetic_protected_alias(path):
    witness = original_reference_witness(path)
    if path == str(protected_alias):
        assert witness is not None
        return (
            helper._stable_entry_identity(alias_child_info),
            witness[1],
        )
    return witness

helper._protected_reference_witness = synthetic_protected_alias
expect_provider_error(
    lambda: helper._retention_delete(
        str(retention_root),
        str(protected_alias_state),
        protected_paths=[str(protected_alias)],
    ),
    "RECOVERY_REQUIRED",
)
helper._protected_reference_witness = original_reference_witness
assert retention_snapshot(protected_alias_state) == protected_alias_before
protected_alias.unlink()
shutil.rmtree(protected_alias_state)

final_boundary_state = valid_retention_state("95-1-final-deploy")
final_boundary_before = retention_snapshot(final_boundary_state)
final_boundary_reference = fixture / "final-boundary-reference"
final_boundary_reference.write_bytes(b"final-boundary-before-race")
os.chown(final_boundary_reference, 0, 0)
os.chmod(final_boundary_reference, 0o600)
original_final_boundary_revalidate = helper._revalidate_protected_references
final_boundary_calls = [0]

def replace_final_boundary_reference(paths, witnesses):
    final_boundary_calls[0] += 1
    if final_boundary_calls[0] == 5:
        replacement = fixture / "final-boundary-reference-replacement"
        replacement.write_bytes(b"final-boundary-replacement")
        os.chown(replacement, 0, 0)
        os.chmod(replacement, 0o600)
        os.rename(replacement, final_boundary_reference)
    return original_final_boundary_revalidate(paths, witnesses)

helper._revalidate_protected_references = replace_final_boundary_reference
expect_provider_error(
    lambda: helper._retention_delete(
        str(retention_root),
        str(final_boundary_state),
        protected_paths=[str(final_boundary_reference)],
    ),
    "RECOVERY_REQUIRED",
)
helper._revalidate_protected_references = original_final_boundary_revalidate
assert final_boundary_calls[0] == 5
assert retention_snapshot(final_boundary_state) == final_boundary_before
final_boundary_reference.unlink()
shutil.rmtree(final_boundary_state)

semantic_witness_state = valid_retention_state("96-1-final-deploy")
semantic_witness_quarantine = (
    retention_root / ".provider-state.96-1-final-deploy.tmp"
)
original_semantic_witness = helper._child_witness
semantic_witness_replaced = [False]

def replace_terminal_after_witness(directory_fd, name, **kwargs):
    result = original_semantic_witness(directory_fd, name, **kwargs)
    if name == "terminal.json" and not semantic_witness_replaced[0]:
        replacement = (
            '{"schemaVersion":1,"runKey":"96-1","outcome":"rolled-back",'
            '"providerEnabled":true}'
        ).encode()
        helper._write_private_at(
            directory_fd,
            ".terminal-replacement",
            replacement,
            0o600,
        )
        os.rename(
            ".terminal-replacement",
            "terminal.json",
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        semantic_witness_replaced[0] = True
    return result

helper._child_witness = replace_terminal_after_witness
expect_provider_error(
    lambda: helper._retention_delete(
        str(retention_root),
        str(semantic_witness_state),
    ),
    "RECOVERY_REQUIRED",
)
helper._child_witness = original_semantic_witness
assert semantic_witness_replaced[0]
assert not semantic_witness_state.exists()
assert semantic_witness_quarantine.exists()
assert (
    json.loads((semantic_witness_quarantine / "terminal.json").read_text())
    == {
        "schemaVersion": 1,
        "runKey": "96-1",
        "outcome": "rolled-back",
        "providerEnabled": True,
    }
)
shutil.rmtree(semantic_witness_quarantine)

def expect_fault(action):
    try:
        action()
    except (helper.ProviderError, OSError):
        return
    raise AssertionError("fault injection unexpectedly succeeded")

def assert_retention_witness_descriptor_cleanup():
    state = valid_retention_state("103-1-final-deploy")
    baseline = open_fd_count()
    original_interlocks = helper._retention_interlocks_fd
    calls = [0]

    def fail_after_witness_acquisition(root, state_root_fd, **kwargs):
        calls[0] += 1
        if calls[0] == 2:
            raise OSError(5, "retention interlock fault")
        return original_interlocks(root, state_root_fd, **kwargs)

    helper._retention_interlocks_fd = fail_after_witness_acquisition
    try:
        expect_fault(
            lambda: helper._retention_delete(
                str(retention_root),
                str(state),
            )
        )
    finally:
        helper._retention_interlocks_fd = original_interlocks
    assert calls[0] == 2
    assert open_fd_count() == baseline
    assert state.exists()
    shutil.rmtree(state)

assert_retention_witness_descriptor_cleanup()

def cleanup_fault_state(state):
    quarantine = retention_root / (".provider-state." + state.name + ".tmp")
    if state.exists():
        shutil.rmtree(state)
    if quarantine.exists():
        shutil.rmtree(quarantine)

fault_events = []
fault_publication_root = fixture / "fault-publication-root"
fault_publication_root.mkdir(mode=0o700)
os.chown(fault_publication_root, 0, 0)
original_fsync = helper.os.fsync
publication_fsync_failed = [False]

def fail_publication_fsync(fd):
    if not publication_fsync_failed[0]:
        publication_fsync_failed[0] = True
        raise OSError(5, "publication fsync fault")
    return original_fsync(fd)

helper.os.fsync = fail_publication_fsync
expect_fault(
    lambda: helper._state_publish(
        str(fault_publication_root),
        "97-1",
        "final-deploy",
    )
)
helper.os.fsync = original_fsync
fault_events.append("publication-fsync")
shutil.rmtree(fault_publication_root)

def retention_fault(name, fail):
    state = valid_retention_state(name)
    try:
        fail()
    finally:
        cleanup_fault_state(state)

def fail_quarantine_fsync():
    original = helper.os.fsync
    failed = [False]

    def injected(fd):
        if not failed[0]:
            failed[0] = True
            raise OSError(5, "quarantine fsync fault")
        return original(fd)

    helper.os.fsync = injected
    try:
        expect_fault(
            lambda: helper._retention_delete(
                str(retention_root),
                str(retention_root / "98-1-final-deploy"),
            )
        )
    finally:
        helper.os.fsync = original

retention_fault("98-1-final-deploy", fail_quarantine_fsync)
fault_events.append("quarantine-fsync")

def fail_child_unlink():
    original = helper._witnessed_unlink

    def injected(*args, **kwargs):
        raise OSError(5, "child unlink fault")

    helper._witnessed_unlink = injected
    try:
        expect_fault(
            lambda: helper._retention_delete(
                str(retention_root),
                str(retention_root / "99-1-final-deploy"),
            )
        )
    finally:
        helper._witnessed_unlink = original

retention_fault("99-1-final-deploy", fail_child_unlink)
fault_events.append("child-unlink")

def fail_owner_unlink():
    original = helper._witnessed_unlink

    def injected(directory_fd, name, **kwargs):
        if name == helper.OWNER_MARKER:
            raise OSError(5, "owner unlink fault")
        return original(directory_fd, name, **kwargs)

    helper._witnessed_unlink = injected
    try:
        expect_fault(
            lambda: helper._retention_delete(
                str(retention_root),
                str(retention_root / "100-1-final-deploy"),
            )
        )
    finally:
        helper._witnessed_unlink = original

retention_fault("100-1-final-deploy", fail_owner_unlink)
fault_events.append("owner-unlink")

def fail_rmdir():
    original = helper.os.rmdir

    def injected(path, **kwargs):
        if path == ".provider-state.101-1-final-deploy.tmp":
            raise OSError(5, "rmdir fault")
        return original(path, **kwargs)

    helper.os.rmdir = injected
    try:
        expect_fault(
            lambda: helper._retention_delete(
                str(retention_root),
                str(retention_root / "101-1-final-deploy"),
            )
        )
    finally:
        helper.os.rmdir = original

retention_fault("101-1-final-deploy", fail_rmdir)
fault_events.append("rmdir")

def fail_final_fsync():
    original = helper.os.fsync
    calls = [0]

    def injected(fd):
        calls[0] += 1
        if calls[0] == 4:
            raise OSError(5, "final fsync fault")
        return original(fd)

    helper.os.fsync = injected
    try:
        expect_fault(
            lambda: helper._retention_delete(
                str(retention_root),
                str(retention_root / "102-1-final-deploy"),
            )
        )
    finally:
        helper.os.fsync = original

retention_fault("102-1-final-deploy", fail_final_fsync)
fault_events.append("final-fsync")
assert fault_events == [
    "publication-fsync",
    "quarantine-fsync",
    "child-unlink",
    "owner-unlink",
    "rmdir",
    "final-fsync",
]

quarantine_race_state = valid_retention_state("92-1-final-deploy")
quarantine_race_before = retention_snapshot(quarantine_race_state)
quarantine_name = ".provider-state." + quarantine_race_state.name + ".tmp"
quarantine_displaced = retention_root / (quarantine_name + ".displaced")
quarantine_attacker = retention_root / quarantine_name
original_rename_noreplace = helper._rename_noreplace

def replace_quarantine_after_rename(directory_fd, source, destination):
    result = original_rename_noreplace(directory_fd, source, destination)
    if source == quarantine_race_state.name and destination == quarantine_name:
        os.rename(
            destination,
            quarantine_displaced.name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        os.mkdir(destination, 0o700, dir_fd=directory_fd)
        attacker_fd = os.open(
            destination,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
        try:
            os.fchown(attacker_fd, 0, 0)
            os.fchmod(attacker_fd, 0o700)
            for child in quarantine_displaced.iterdir():
                child_info = child.stat()
                helper._write_private_at(
                    attacker_fd,
                    child.name,
                    child.read_bytes(),
                    0o600,
                )
                os.utime(
                    quarantine_attacker / child.name,
                    ns=(child_info.st_atime_ns, child_info.st_mtime_ns),
                    follow_symlinks=False,
                )
            os.fsync(attacker_fd)
        finally:
            os.close(attacker_fd)
    return result

helper._rename_noreplace = replace_quarantine_after_rename
expect_provider_error(
    lambda: helper._retention_delete(
        str(retention_root),
        str(quarantine_race_state),
    ),
    "RECOVERY_REQUIRED",
)
helper._rename_noreplace = original_rename_noreplace
assert retention_snapshot(quarantine_displaced) == quarantine_race_before
assert retention_snapshot(quarantine_attacker) == quarantine_race_before
shutil.rmtree(quarantine_displaced)
shutil.rmtree(quarantine_attacker)

interlock_race_state = valid_retention_state("93-1-final-deploy")
interlock_race_before = retention_snapshot(interlock_race_state)
original_interlocks_fd = helper._retention_interlocks_fd
interlock_calls = [0]

def inject_interlock_before_quarantine(root, state_root_fd):
    interlock_calls[0] += 1
    if interlock_calls[0] == 2:
        helper._write_private_at(
            state_root_fd,
            ".provider-transaction.current",
            b"interlock-race",
            0o600,
        )
    return original_interlocks_fd(root, state_root_fd)

helper._retention_interlocks_fd = inject_interlock_before_quarantine
expect_provider_error(
    lambda: helper._retention_delete(
        str(retention_root),
        str(interlock_race_state),
    ),
    "RECOVERY_REQUIRED",
)
helper._retention_interlocks_fd = original_interlocks_fd
assert retention_snapshot(interlock_race_state) == interlock_race_before
assert not (
    retention_root
    / (".provider-state." + interlock_race_state.name + ".tmp")
).exists()
(retention_root / ".provider-transaction.current").unlink()
shutil.rmtree(interlock_race_state)

protected_state = valid_retention_state("88-1-final-deploy")
assert_direct_retention_refusal(
    protected_state,
    protected_states=[str(protected_state)],
)
shutil.rmtree(protected_state)

interlocked_state = valid_retention_state("89-1-final-deploy")
helper._write_private(
    str(retention_root / ".provider-transaction.current"),
    b"blocking",
    0o600,
)
assert_direct_retention_refusal(interlocked_state)
(retention_root / ".provider-transaction.current").unlink()

reserved = retention_root / ".provider-state.89-1-final-deploy.tmp"
reserved.mkdir(mode=0o700)
os.chown(reserved, 0, 0)
assert_direct_retention_refusal(interlocked_state)
shutil.rmtree(reserved)

parent_transaction = parent / ".transaction-retention-interlock"
parent_transaction.mkdir(mode=0o700)
os.chown(parent_transaction, 0, 0)
assert_direct_retention_refusal(interlocked_state)
shutil.rmtree(parent_transaction)
shutil.rmtree(interlocked_state)

malformed_marker = {
    "schemaVersion": True,
    "runKey": "boolean-marker",
    "phase": "preparing",
    "providerEnabled": True,
    "durableDisposition": "none",
}
helper._write_private(
    str(marker),
    json.dumps(malformed_marker, separators=(",", ":")).encode(),
    0o600,
)
marker_bytes = marker.read_bytes()
expect_provider_error(
    lambda: helper._marker(str(state), "boolean-marker"),
    "RECOVERY_REQUIRED",
)
assert marker.read_bytes() == marker_bytes
marker.unlink()
PY
then
  echo "provider runtime fixture failed" >&2
  sed -n '1,160p' "$fixture_log" >&2
  exit 1
fi
! grep -Fq "$fixture_secret" "$fixture_log" ||
  { echo "provider runtime fixture leaked private credential bytes" >&2; exit 1; }

python3 -B scripts/test-test-vps-provider-credential.py
echo "provider filesystem fixture passed: ACL/default-ACL rejection, unprivileged private-read denial, bounded parsing, no-follow publication, reuse and rollback cleanup; secret scan passed"
