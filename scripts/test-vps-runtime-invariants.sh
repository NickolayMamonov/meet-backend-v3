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

runtime_file_record() {
  local file=$1
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    printf 'present:%s' "$(sha256sum "$file" | awk '{print $1}')"
  else
    printf 'absent'
  fi
}

runtime_container_material() {
  local container=$1
  local include_config_hash=${2:-true}
  local config_hash=
  if [ "$include_config_hash" = true ]; then
    config_hash=$(docker inspect "$container" --format \
      '{{index .Config.Labels "com.docker.compose.config-hash"}}')
  fi
  {
    printf 'image=%s\n' "$(docker inspect "$container" --format '{{.Image}}')"
    printf 'running=%s\n' "$(docker inspect "$container" --format '{{.State.Running}}')"
    printf 'health=%s\n' "$(docker inspect "$container" --format '{{.State.Health.Status}}')"
    printf 'user=%s\n' "$(docker exec "$container" id -u)"
    printf 'group=%s\n' "$(docker exec "$container" id -g)"
    printf 'project=%s\n' "$(docker inspect "$container" \
      --format '{{index .Config.Labels "com.docker.compose.project"}}')"
    printf 'service=%s\n' "$(docker inspect "$container" \
      --format '{{index .Config.Labels "com.docker.compose.service"}}')"
    printf 'config_hash=%s\n' "$config_hash"
    printf 'readonly=%s\n' "$(docker inspect "$container" \
      --format '{{.HostConfig.ReadonlyRootfs}}')"
    printf 'restart=%s\n' "$(docker inspect "$container" \
      --format '{{.HostConfig.RestartPolicy.Name}}')"
    printf 'logging=%s\n' "$(docker inspect "$container" \
      --format '{{.HostConfig.LogConfig.Type}}')"
    printf 'cap_drop=%s\n' "$(docker inspect "$container" \
      --format '{{json .HostConfig.CapDrop}}')"
    printf 'security_opt=%s\n' "$(docker inspect "$container" \
      --format '{{json .HostConfig.SecurityOpt}}')"
    printf 'tmpfs=%s\n' "$(docker inspect "$container" \
      --format '{{json .HostConfig.Tmpfs}}')"
    printf 'memory=%s\n' "$(docker inspect "$container" \
      --format '{{.HostConfig.Memory}}')"
    printf 'ports=%s\n' "$(docker inspect "$container" \
      --format '{{json .NetworkSettings.Ports}}')"
    printf 'networks=%s\n' "$(docker inspect "$container" \
      --format '{{json .NetworkSettings.Networks}}')"
    printf 'mounts=%s\n' "$(docker inspect "$container" \
      --format '{{json .Mounts}}')"
    printf 'healthcheck=%s\n' "$(docker inspect "$container" \
      --format '{{json .Config.Healthcheck.Test}}')"
  } | {
    if [ "$include_config_hash" = true ]; then
      cat
    else
      sed '/^config_hash=/d'
    fi
  }
}

runtime_non_email_material() {
  local root=$1
  local compose_script=$2
  local backend postgres
  backend=$(runtime_compose "$root" "$compose_script" ps -q backend)
  postgres=$(runtime_compose "$root" "$compose_script" ps -q postgres)
  [ -n "$backend" ] && [ -n "$postgres" ] || return 1
  {
    printf 'non_email_config=%s\n' "$(runtime_non_email_config_digest "$root")"
    printf 'release_image=%s\n' "$(runtime_release_field "$root" BACKEND_IMAGE)"
    printf 'release_version=%s\n' "$(runtime_release_field "$root" BACKEND_VERSION)"
    printf 'release_revision=%s\n' "$(runtime_release_field "$root" BACKEND_REVISION)"
    printf 'active_compose=%s\n' "$(runtime_file_record /var/lib/meet-production/active-compose.yml)"
    printf 'active_runtime=%s\n' \
      "$(runtime_file_record /var/lib/meet-production/active-runtime.override.yml)"
    runtime_container_material "$backend" false
    printf 'postgres:\n'
    runtime_container_material "$postgres" false
  }
}

runtime_non_email_fingerprint() {
  local root=$1
  local compose_script=$2
  runtime_non_email_material "$root" "$compose_script" |
    sha256sum | awk '{print $1}'
}

runtime_safe_fingerprint() {
  local root=$1
  local compose_script=$2
  local backend postgres compose_digest
  backend=$(runtime_compose "$root" "$compose_script" ps -q backend)
  postgres=$(runtime_compose "$root" "$compose_script" ps -q postgres)
  [ -n "$backend" ] && [ -n "$postgres" ] || return 1
  compose_digest=$(
    runtime_compose "$root" "$compose_script" config |
      sha256sum | awk '{print $1}'
  )
  {
    runtime_non_email_material "$root" "$compose_script"
    printf 'env=%s\n' "$(sha256sum "$root/.env.production" | awk '{print $1}')"
    printf 'compose_config=%s\n' "$compose_digest"
    runtime_container_material "$backend" true
    printf 'postgres:\n'
    runtime_container_material "$postgres" true
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
