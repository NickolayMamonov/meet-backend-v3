#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --root PATH --base-compose PATH --image IMAGE@sha256:DIGEST --revision SHA --version VERSION --run-key KEY --mode deploy|rollback-drill" >&2
  exit 2
}

fail() {
  echo "test VPS deployment failed: $1" >&2
  exit 1
}

root=
base_compose=
image=
revision=
version=
run_key=
mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] && [ -z "$root" ] || usage
      root=$2
      shift 2
      ;;
    --base-compose)
      [ "$#" -ge 2 ] && [ -z "$base_compose" ] || usage
      base_compose=$2
      shift 2
      ;;
    --image)
      [ "$#" -ge 2 ] && [ -z "$image" ] || usage
      image=$2
      shift 2
      ;;
    --revision)
      [ "$#" -ge 2 ] && [ -z "$revision" ] || usage
      revision=$2
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] && [ -z "$version" ] || usage
      version=$2
      shift 2
      ;;
    --run-key)
      [ "$#" -ge 2 ] && [ -z "$run_key" ] || usage
      run_key=$2
      shift 2
      ;;
    --mode)
      [ "$#" -ge 2 ] && [ -z "$mode" ] || usage
      mode=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$root" != *..* ]] || usage
[[ "$base_compose" =~ ^/[A-Za-z0-9._/-]+$ ]] &&
  [[ "$base_compose" != *..* ]] || usage
[[ "$image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
  usage
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  usage
[[ "$run_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
case "$mode" in deploy|rollback-drill) ;; *) usage ;; esac

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v flock >/dev/null 2>&1 || fail "flock is required"
[ "$(id -u)" -eq 0 ] || fail "the test VPS deploy must run as root"
[ -d "$root" ] || fail "deployment root is unavailable"
[ -s "$root/.env.production" ] || fail "existing production environment is unavailable"
[ -s "$root/docker-compose.production.yml" ] ||
  fail "existing production Compose file is unavailable"
[ -s "$base_compose" ] || fail "reviewed target Compose file is unavailable"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compose_script=$script_dir/production-compose.sh
update_script=$script_dir/update-production-release.sh
[ -x "$compose_script" ] || fail "reviewed Compose wrapper is unavailable"
[ -x "$update_script" ] || fail "reviewed release updater is unavailable"

state_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
active_compose=/var/lib/meet-production/active-compose.yml
active_runtime=/var/lib/meet-production/active-runtime.override.yml
state=$state_root/$run_key-$mode
install -d -m 700 "$state_root"
[ ! -e "$state" ] || fail "run state already exists"
install -d -m 700 "$state"
exec 9>"$state_root/.deploy.lock"
flock -n 9 || fail "another test VPS deployment is active"

compose() {
  PRODUCTION_ROOT=$root \
    PRODUCTION_BASE_COMPOSE=$root/docker-compose.production.yml \
    "$compose_script" "$@"
}

release_field() {
  local name=$1
  local value
  [ "$(grep -c "^$name=" "$root/.env.production")" -eq 1 ] ||
    fail "release identity field is missing or duplicated: $name"
  value=$(sed -n "s/^$name=//p" "$root/.env.production")
  [ -n "$value" ] || fail "release identity field is blank: $name"
  case "$value" in *[[:space:]]*) fail "release identity field contains whitespace: $name" ;; esac
  printf '%s' "$value"
}

runtime_image_id() {
  local container
  container=$(compose ps -q backend)
  [ -n "$container" ] || fail "backend container is unavailable"
  docker inspect "$container" --format '{{.Image}}'
}

verify_runtime() {
  local expected_id=$1
  local expected_revision=$2
  local expected_version=$3
  local expected_hash=$4
  local backend postgres binding address memory
  local -a mounts postgres_mounts

  backend=$(compose ps -q backend)
  postgres=$(compose ps -q postgres)
  [ -n "$backend" ] && [ -n "$postgres" ] ||
    fail "backend or PostgreSQL container is unavailable"
  [ "$(docker inspect "$backend" --format '{{.State.Running}}')" = true ]
  [ "$(docker inspect "$backend" --format '{{.State.Health.Status}}')" = healthy ]
  [ "$(docker inspect "$backend" --format '{{.Image}}')" = "$expected_id" ]
  [ "$(docker inspect "$backend" \
    --format '{{index .Config.Labels "com.docker.compose.project"}}')" = meet-production ]
  [ "$(docker inspect "$backend" \
    --format '{{index .Config.Labels "com.docker.compose.service"}}')" = backend ]
  [ "$(docker inspect "$backend" \
    --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')" = "$expected_hash" ]
  echo "runtime_check=identity image_id=$expected_id config_hash=$expected_hash"
  [ "$(docker inspect "$backend" --format '{{.HostConfig.ReadonlyRootfs}}')" = true ]
  [ "$(docker inspect "$backend" \
    --format '{{.HostConfig.RestartPolicy.Name}}')" = unless-stopped ]
  [ "$(docker inspect "$backend" --format '{{.HostConfig.LogConfig.Type}}')" = local ]
  docker inspect "$backend" --format '{{json .HostConfig.CapDrop}}' |
    jq -e 'index("ALL") != null' >/dev/null
  docker inspect "$backend" --format '{{json .HostConfig.SecurityOpt}}' |
    jq -e 'index("no-new-privileges:true") != null' >/dev/null
  docker inspect "$backend" --format '{{json .HostConfig.Tmpfs}}' |
    jq -e 'has("/tmp")' >/dev/null
  docker inspect "$backend" --format '{{json .Config.Healthcheck.Test}}' |
    jq -e 'index("http://127.0.0.1:8080/meetings") != null' >/dev/null
  memory=$(docker inspect "$backend" --format '{{.HostConfig.Memory}}')
  [[ "$memory" =~ ^[1-9][0-9]*$ ]]
  echo "runtime_check=hardening image_id=$expected_id"
  [ "$(docker image inspect "$expected_id" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$expected_revision" ]
  [ "$(docker image inspect "$expected_id" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$expected_version" ]
  [ "$(docker image inspect "$expected_id" \
    --format '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
    "https://github.com/NickolayMamonov/meet-backend-v3" ]
  [ "$(docker image inspect "$expected_id" --format '{{.Config.User}}')" = 10001:10001 ]
  [ "$(docker exec "$backend" id -u)" = 10001 ]
  [ "$(docker exec "$backend" id -g)" = 10001 ]
  docker exec "$backend" sh -ec 'test -w /data/uploads'
  echo "runtime_check=image image_id=$expected_id runtime_user=10001:10001"

  mapfile -t mounts < <(
    docker inspect "$backend" --format \
      '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s\n" .Type .Name}}{{end}}{{end}}' |
      sed '/^$/d'
  )
  [ "${#mounts[@]}" -eq 1 ]
  [ "${mounts[0]}" = "volume|meet-production_uploads_data" ]
  docker volume inspect meet-production_uploads_data >/dev/null
  docker volume inspect meet-production_postgres_data >/dev/null
  mapfile -t postgres_mounts < <(
    docker inspect "$postgres" --format \
      '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{printf "%s|%s\n" .Type .Name}}{{end}}{{end}}' |
      sed '/^$/d'
  )
  [ "${#postgres_mounts[@]}" -eq 1 ]
  [ "${postgres_mounts[0]}" = "volume|meet-production_postgres_data" ]
  echo "runtime_check=volumes image_id=$expected_id"

  binding=$(docker inspect "$backend" --format \
    '{{range $port, $bindings := .NetworkSettings.Ports}}{{if eq $port "8080/tcp"}}{{range $bindings}}{{.HostIp}}:{{.HostPort}}{{println}}{{end}}{{end}}{{end}}')
  [ "$(wc -l <<<"$binding")" -eq 1 ]
  [[ "$binding" =~ ^127\.0\.0\.1:[0-9]+$ ]]
  [ -z "$(docker port "$postgres")" ] ||
    fail "PostgreSQL unexpectedly publishes a host port"

  address=$(compose port backend 8080)
  [[ "$address" =~ ^127\.0\.0\.1:[0-9]+$ ]]
  curl --fail --silent --show-error "http://$address/meetings" |
    jq -e 'type == "array"' >/dev/null
  echo "runtime_check=network image_id=$expected_id binding=$binding"
}

verify_environment_matches_container() {
  local container line name
  declare -A runtime_environment=()
  container=$(compose ps -q backend)
  [ -n "$container" ] || fail "backend container is unavailable"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    name=${line%%=*}
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      fail "running container environment is malformed"
    [ -z "${runtime_environment[$name]+present}" ] ||
      fail "running container environment contains a duplicate name"
    runtime_environment[$name]=$line
  done < <(
    docker inspect "$container" \
      --format '{{range .Config.Env}}{{println .}}{{end}}'
  )
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ""|\#*) continue ;; esac
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] ||
      fail "production environment contains a malformed record"
    name=${line%%=*}
    [ "${runtime_environment[$name]:-}" = "$line" ] ||
      fail "running container does not match the current production environment"
  done <"$root/.env.production"
  unset runtime_environment
}

previous_image=$(release_field BACKEND_IMAGE)
previous_version=$(release_field BACKEND_VERSION)
previous_revision=$(release_field BACKEND_REVISION)
[[ "$previous_revision" =~ ^[0-9a-f]{40}$ ]] ||
  fail "running revision is malformed"
[[ "$previous_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "running version is malformed"
previous_id=$(runtime_image_id)
[ "$(docker image inspect "$previous_image" --format '{{.Id}}')" = "$previous_id" ]
previous_runtime_hash=$(docker inspect "$(compose ps -q backend)" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
[[ "$previous_runtime_hash" =~ ^[0-9a-f]{64}$ ]]
verify_runtime "$previous_id" "$previous_revision" "$previous_version" \
  "$previous_runtime_hash"
verify_environment_matches_container

printf '%s\n' "$previous_image" >"$state/previous-image"
printf '%s\n' "$previous_id" >"$state/previous-image-id"
printf '%s\n' "$previous_revision" >"$state/previous-revision"
printf '%s\n' "$previous_version" >"$state/previous-version"
printf '%s\n' "$previous_runtime_hash" >"$state/previous-runtime-config-hash"
if [ -e "$active_compose" ]; then
  [ -s "$active_compose" ] || fail "active Compose file is empty"
  install -m 600 "$active_compose" "$state/previous-active-compose.yml"
  : >"$state/had-active-compose"
fi
if [ -e "$active_runtime" ]; then
  [ -s "$active_runtime" ] || fail "active runtime override is empty"
  install -m 600 "$active_runtime" "$state/previous-active-runtime.yml"
  : >"$state/had-active-runtime"
fi

target_id=$(docker image inspect "$image" --format '{{.Id}}')
[ "$(docker image inspect "$image" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$revision" ]
[ "$(docker image inspect "$image" \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$version" ]
[ "$(docker image inspect "$image" \
  --format '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
  "https://github.com/NickolayMamonov/meet-backend-v3" ]
[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 10001:10001 ]
if [ "$mode" = rollback-drill ] && [ "$target_id" = "$previous_id" ]; then
  fail "rollback drill requires a target image distinct from the predecessor"
fi

cat >"$state/target-runtime.override.yml" <<'YAML'
services:
  backend:
    # SecurityConfig intentionally keeps Actuator private. This test-only
    # health probe exercises the HTTP server and PostgreSQL through /meetings.
    healthcheck:
      test:
        - CMD
        - curl
        - --fail
        - --silent
        - --show-error
        - http://127.0.0.1:8080/meetings
YAML
chmod 600 "$state/target-runtime.override.yml"

restore_previous_active_files() {
  if [ -e "$state/had-active-compose" ]; then
    install -m 600 "$state/previous-active-compose.yml" "$active_compose"
  else
    rm -f "$active_compose"
  fi
  if [ -e "$state/had-active-runtime" ]; then
    install -m 600 "$state/previous-active-runtime.yml" "$active_runtime"
  else
    rm -f "$active_runtime"
  fi
}

rollback() {
  restore_previous_active_files
  PRODUCTION_ROOT=$root PRODUCTION_SCRIPTS_DIR=$script_dir \
    "$update_script" "$previous_image" "$previous_revision" "$previous_version" \
    >/dev/null
  compose up -d --no-deps --no-build --pull never --force-recreate \
    --wait --wait-timeout 180 backend >/dev/null
  restored_hash=$(docker inspect "$(compose ps -q backend)" \
    --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
  [ "$restored_hash" = "$previous_runtime_hash" ] ||
    fail "rollback did not restore the exact predecessor Compose runtime"
  verify_runtime "$previous_id" "$previous_revision" "$previous_version" \
    "$previous_runtime_hash"
  echo "rollback=completed previous_image_id=$previous_id"
}

mutation_started=false
on_exit() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ "$mutation_started" = true ]; then
    rollback
  fi
  exit "$status"
}
trap on_exit EXIT

mutation_started=true
install -m 600 "$base_compose" "$active_compose"
install -m 600 "$state/target-runtime.override.yml" "$active_runtime"
PRODUCTION_ROOT=$root PRODUCTION_SCRIPTS_DIR=$script_dir \
  "$update_script" "$image" "$revision" "$version" >/dev/null

compose up -d --no-deps --no-build --pull never --force-recreate \
  --wait --wait-timeout 180 backend >/dev/null
target_hash=$(docker inspect "$(compose ps -q backend)" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
[[ "$target_hash" =~ ^[0-9a-f]{64}$ ]] ||
  fail "candidate Compose runtime hash is unavailable"
verify_runtime "$target_id" "$revision" "$version" "$target_hash"
echo "candidate=ready image_id=$target_id version=$version revision=$revision"

if [ "$mode" = rollback-drill ]; then
  echo "rollback_drill=triggered"
  exit 86
fi

mutation_started=false
echo "deployment=completed image_id=$target_id version=$version revision=$revision"
