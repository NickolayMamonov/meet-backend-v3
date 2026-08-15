#!/usr/bin/env bash
set -euo pipefail

# This file is sourced by deployment tooling.  It deliberately returns only
# hashes, identifiers, and booleans; container environment values are never
# written to logs or durable state.

runtime_release_field() {
  local root=$1
  local name=$2
  local value
  [ "$(grep -c "^${name}=" "$root/.env.production")" -eq 1 ] ||
    return 1
  value=$(sed -n "s/^${name}=//p" "$root/.env.production")
  [ -n "$value" ] || return 1
  case "$value" in *[[:space:]]*) return 1 ;; esac
  printf '%s' "$value"
}

runtime_compose() {
  local root=$1
  local compose_script=$2
  shift 2
  PRODUCTION_ROOT=$root \
    PRODUCTION_BASE_COMPOSE="$root/docker-compose.production.yml" \
    "$compose_script" "$@"
}

runtime_image_id() {
  local root=$1
  local compose_script=$2
  local container
  container=$(runtime_compose "$root" "$compose_script" ps -q backend)
  [ -n "$container" ] || return 1
  docker inspect "$container" --format '{{.Image}}'
}

runtime_non_email_config_digest() {
  local root=$1
  awk '
    /^APP_EMAIL_/ { next }
    /^SPRING_MAIL_/ { next }
    { print }
  ' "$root/.env.production" | sha256sum | awk '{print $1}'
}

verify_environment_matches_container() {
  local root=$1
  local compose_script=$2
  local container line name
  declare -A runtime_environment=()
  container=$(runtime_compose "$root" "$compose_script" ps -q backend)
  [ -n "$container" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    name=${line%%=*}
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [ -z "${runtime_environment[$name]+present}" ] || return 1
    runtime_environment[$name]=$line
  done < <(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}')
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ""|\#*) continue ;; esac
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || return 1
    name=${line%%=*}
    [ "${runtime_environment[$name]:-}" = "$line" ] || return 1
  done <"$root/.env.production"
}

runtime_safe_fingerprint() {
  local root=$1
  local compose_script=$2
  local backend postgres image_id release_image release_version release_revision
  local config_hash non_email_config health user group binding upload_volume postgres_volume
  backend=$(runtime_compose "$root" "$compose_script" ps -q backend)
  postgres=$(runtime_compose "$root" "$compose_script" ps -q postgres)
  [ -n "$backend" ] && [ -n "$postgres" ] || return 1
  image_id=$(docker inspect "$backend" --format '{{.Image}}')
  release_image=$(runtime_release_field "$root" BACKEND_IMAGE)
  release_version=$(runtime_release_field "$root" BACKEND_VERSION)
  release_revision=$(runtime_release_field "$root" BACKEND_REVISION)
  non_email_config=$(runtime_non_email_config_digest "$root")
  config_hash=$(docker inspect "$backend" \
    --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
  health=$(docker inspect "$backend" --format '{{.State.Health.Status}}')
  user=$(docker exec "$backend" id -u)
  group=$(docker exec "$backend" id -g)
  binding=$(docker inspect "$backend" --format \
    '{{range $port, $bindings := .NetworkSettings.Ports}}{{if eq $port "8080/tcp"}}{{range $bindings}}{{.HostIp}}:{{.HostPort}}{{println}}{{end}}{{end}}{{end}}')
  upload_volume=$(docker inspect "$backend" --format \
    '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{.Name}}{{end}}{{end}}')
  postgres_volume=$(docker inspect "$postgres" --format \
    '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}')
  {
    printf 'image_id=%s\n' "$image_id"
    printf 'release_image=%s\n' "$release_image"
    printf 'release_version=%s\n' "$release_version"
    printf 'release_revision=%s\n' "$release_revision"
    printf 'config_hash=%s\n' "$config_hash"
    printf 'non_email_config=%s\n' "$non_email_config"
    printf 'health=%s\n' "$health"
    printf 'user=%s:%s\n' "$user" "$group"
    printf 'binding=%s' "$binding"
    printf 'upload_volume=%s\n' "$upload_volume"
    printf 'postgres_volume=%s\n' "$postgres_volume"
  } | sha256sum | awk '{print $1}'
}

verify_runtime_invariants() {
  local root=$1
  local compose_script=$2
  local expected_id=$3
  local expected_revision=$4
  local expected_version=$5
  local expected_hash=$6
  local backend postgres binding address memory
  local -a mounts postgres_mounts

  backend=$(runtime_compose "$root" "$compose_script" ps -q backend)
  postgres=$(runtime_compose "$root" "$compose_script" ps -q postgres)
  [ -n "$backend" ] && [ -n "$postgres" ]
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
  [ -z "$(docker port "$postgres")" ]
  address=$(runtime_compose "$root" "$compose_script" port backend 8080)
  [[ "$address" =~ ^127\.0\.0\.1:[0-9]+$ ]]
  curl --fail --silent --show-error "http://$address/meetings" |
    jq -e 'type == "array"' >/dev/null
  echo "runtime_check=network image_id=$expected_id binding=$binding"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "runtime invariant helper must be sourced" >&2
  exit 2
fi
