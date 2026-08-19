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
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" = true ]; then
    if [ -n "${MEE_SMTP_FAKE_COMPOSE_LOG:-}" ]; then
      printf '%s|%s\n' "${RUNTIME_BASE_COMPOSE:-}" "$*" \
        >>"$MEE_SMTP_FAKE_COMPOSE_LOG"
    fi
    case "$*" in
      "ps -q backend") printf 'backend-container\n' ;;
      "ps -q postgres") printf 'postgres-container\n' ;;
      "port backend 8080") printf '127.0.0.1:18080\n' ;;
      *) ;;
    esac
    return
  fi
  PRODUCTION_ROOT=$root \
    PRODUCTION_BASE_COMPOSE="${RUNTIME_BASE_COMPOSE:-"$root/docker-compose.production.yml"}" \
    PRODUCTION_USE_REVIEWED_COMPOSE="${RUNTIME_USE_REVIEWED_COMPOSE:-false}" \
    "$compose_script" "$@"
}

runtime_image_id() {
  local root=$1
  local compose_script=$2
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" = true ]; then
    printf 'sha256:%064d\n' 0
    return
  fi
  local container
  container=$(runtime_compose "$root" "$compose_script" ps -q backend)
  [ -n "$container" ] || return 1
  docker inspect "$container" --format '{{.Image}}'
}

runtime_non_email_config_digest() {
  local root=$1
  awk '
    /^(APP_EMAIL_PROVIDER|APP_EMAIL_FROM|APP_EMAIL_FROM_NAME|SPRING_MAIL_HOST|SPRING_MAIL_PORT|SPRING_MAIL_USERNAME|SPRING_MAIL_PASSWORD|APP_EMAIL_CONNECT_TIMEOUT_MS|APP_EMAIL_READ_TIMEOUT_MS|APP_EMAIL_WRITE_TIMEOUT_MS)=/ { next }
    { print }
  ' "$root/.env.production" | sha256sum | awk '{print $1}'
}

runtime_email_key_pattern='^(APP_EMAIL_PROVIDER|APP_EMAIL_FROM|APP_EMAIL_FROM_NAME|SPRING_MAIL_HOST|SPRING_MAIL_PORT|SPRING_MAIL_USERNAME|SPRING_MAIL_PASSWORD|APP_EMAIL_CONNECT_TIMEOUT_MS|APP_EMAIL_READ_TIMEOUT_MS|APP_EMAIL_WRITE_TIMEOUT_MS)='

runtime_environment_digest() {
  local container=$1
  local exclude_email=${2:-false}
  docker inspect "$container" --format '{{json .Config.Env}}' |
    jq -r '.[]' |
    if [ "$exclude_email" = true ]; then
      awk -v pattern="$runtime_email_key_pattern" '$0 !~ pattern'
    else
      cat
    fi |
    LC_ALL=C sort |
    sha256sum | awk '{print $1}'
}

runtime_normalized_mounts() {
  local container=$1
  docker inspect "$container" --format '{{json .Mounts}}' |
    jq -cS '
      map({
        type: (.Type // ""),
        source: (.Name // .Source // ""),
        destination: (.Destination // ""),
        read_only: (.RW == false),
        propagation: (.Propagation // "")
      })
      | sort_by(.destination, .type, .source)
    '
}

runtime_normalized_ports() {
  local container=$1
  docker inspect "$container" --format '{{json .NetworkSettings.Ports}}' |
    jq -cS '
      (. // {})
      | to_entries
      | map({
          container_port: .key,
          bindings: ((.value // [])
            | map({
                host_ip: (.HostIp // ""),
                host_port: (.HostPort // "")
              })
            | sort_by([.host_ip, .host_port]))
        })
      | sort_by(.container_port)
    '
}

runtime_normalized_networks() {
  local container=$1
  docker inspect "$container" --format '{{json .NetworkSettings.Networks}}' |
    jq -cS '
      (. // {})
      | to_entries
      | map({
          network: .key,
          aliases: ((.value.Aliases // []) | sort),
          driver_opts: (.value.DriverOpts // {}),
          ip_address: (.value.IPAddress // ""),
          ip_prefix_len: (.value.IPPrefixLen // 0),
          gateway: (.value.Gateway // ""),
          global_ipv6_address: (.value.GlobalIPv6Address // ""),
          global_ipv6_prefix_len: (.value.GlobalIPv6PrefixLen // 0),
          ipv6_gateway: (.value.IPv6Gateway // ""),
          links: ((.value.Links // []) | sort)
        })
      | sort_by(.network)
    '
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
  local digest
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    if [ "${MEE_SMTP_FAKE_REMOTE:-false}" = true ]; then
      printf 'present:fake'
      return
    fi
    digest=$(sha256sum "$file" | awk '{print $1}') || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'present:%s' "$digest"
  else
    printf 'absent'
  fi
}

runtime_container_material() {
  local container=$1
  local include_config_hash=${2:-true}
  local include_email_environment=${3:-true}
  local config_hash=
  if [ "$include_config_hash" = true ]; then
    config_hash=$(docker inspect "$container" --format \
      '{{index .Config.Labels "com.docker.compose.config-hash"}}')
  fi
  {
    printf 'image=%s\n' "$(docker inspect "$container" --format '{{.Image}}')"
    printf 'image_config=%s\n' "$(docker inspect "$container" --format '{{.Config.Image}}')"
    printf 'entrypoint=%s\n' "$(docker inspect "$container" --format '{{json .Config.Entrypoint}}')"
    printf 'command=%s\n' "$(docker inspect "$container" --format '{{json .Config.Cmd}}')"
    printf 'running=%s\n' "$(docker inspect "$container" --format '{{.State.Running}}')"
    printf 'health=%s\n' "$(docker inspect "$container" --format '{{.State.Health.Status}}')"
    printf 'user=%s\n' "$(docker exec "$container" id -u)"
    printf 'group=%s\n' "$(docker exec "$container" id -g)"
    printf 'project=%s\n' "$(docker inspect "$container" \
      --format '{{index .Config.Labels "com.docker.compose.project"}}')"
    printf 'service=%s\n' "$(docker inspect "$container" \
      --format '{{index .Config.Labels "com.docker.compose.service"}}')"
    printf 'image_source=%s\n' "$(docker inspect "$container" \
      --format '{{index .Config.Labels "org.opencontainers.image.source"}}')"
    printf 'image_revision=%s\n' "$(docker inspect "$container" \
      --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
    printf 'image_version=%s\n' "$(docker inspect "$container" \
      --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
    printf 'image_user=%s\n' "$(docker inspect "$container" --format '{{.Config.User}}')"
    if [ "$include_email_environment" = true ]; then
      printf 'environment_hash=%s\n' "$(runtime_environment_digest "$container")"
    fi
    printf 'non_email_environment_hash=%s\n' \
      "$(runtime_environment_digest "$container" true)"
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
    printf 'mounts=%s\n' "$(runtime_normalized_mounts "$container")"
    printf 'ports=%s\n' "$(runtime_normalized_ports "$container")"
    printf 'networks=%s\n' "$(runtime_normalized_networks "$container")"
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
  local backend postgres production_state_dir
  local active_compose_record active_runtime_record
  backend=$(runtime_compose "$root" "$compose_script" ps -q backend)
  postgres=$(runtime_compose "$root" "$compose_script" ps -q postgres)
  [ -n "$backend" ] && [ -n "$postgres" ] || return 1
  production_state_dir=${PRODUCTION_STATE_DIR:-/var/lib/meet-production}
  active_compose_record=$(runtime_file_record \
    "$production_state_dir/active-compose.yml") || return 1
  active_runtime_record=$(runtime_file_record \
    "$production_state_dir/active-runtime.override.yml") || return 1
  {
    printf 'non_email_config=%s\n' "$(runtime_non_email_config_digest "$root")"
    printf 'release_image=%s\n' "$(runtime_release_field "$root" BACKEND_IMAGE)"
    printf 'release_version=%s\n' "$(runtime_release_field "$root" BACKEND_VERSION)"
    printf 'release_revision=%s\n' "$(runtime_release_field "$root" BACKEND_REVISION)"
    printf 'active_compose=%s\n' "$active_compose_record"
    printf 'active_runtime=%s\n' "$active_runtime_record"
    runtime_container_material "$backend" false false
    printf 'postgres:\n'
    runtime_container_material "$postgres" false false
  }
}

runtime_active_file_records() {
  local production_state_dir=${PRODUCTION_STATE_DIR:-/var/lib/meet-production}
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" = true ]; then
    [ -f "$production_state_dir/active-compose.yml" ] &&
      [ ! -L "$production_state_dir/active-compose.yml" ] &&
      [ -f "$production_state_dir/active-runtime.override.yml" ] &&
      [ ! -L "$production_state_dir/active-runtime.override.yml" ]
    return
  fi
  runtime_file_record "$production_state_dir/active-compose.yml" >/dev/null ||
    return 1
  runtime_file_record "$production_state_dir/active-runtime.override.yml" \
    >/dev/null || return 1
}

runtime_non_email_fingerprint() {
  local root=$1
  local compose_script=$2
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" = true ]; then
    runtime_active_file_records || return 1
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    return
  fi
  runtime_non_email_material "$root" "$compose_script" |
    sha256sum | awk '{print $1}'
}

runtime_safe_fingerprint() {
  local root=$1
  local compose_script=$2
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" = true ]; then
    runtime_active_file_records || return 1
    printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
    return
  fi
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
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" = true ]; then
    return 0
  fi

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
  [ "$(docker inspect "$backend" --format '{{.Config.User}}')" = 10001:10001 ]
  [ "$(docker inspect "$backend" \
    --format '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
    "https://github.com/NickolayMamonov/meet-backend-v3" ]
  verify_environment_matches_container "$root" "$compose_script"
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
