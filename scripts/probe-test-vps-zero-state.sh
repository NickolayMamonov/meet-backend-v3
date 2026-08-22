#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: probe-test-vps-zero-state.sh
  --phase predecessor|candidate|rollback|final
  --root PATH --compose-script PATH --state-dir PATH
  --expected-image IMAGE@sha256:DIGEST --expected-image-id sha256:DIGEST
  --expected-revision SHA --expected-version X.Y.Z --expected-runtime-hash HEX64
  --public-url https://HOST --output PATH
EOF
  exit 2
}

fail() {
  echo "test VPS zero-state probe failed: $*" >&2
  exit 1
}

phase=
root=
compose_script=
state_dir=
expected_image=
expected_image_id=
expected_revision=
expected_version=
expected_runtime_hash=
public_url=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase) [ "$#" -ge 2 ] || usage; phase=$2; shift 2 ;;
    --root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
    --compose-script) [ "$#" -ge 2 ] || usage; compose_script=$2; shift 2 ;;
    --state-dir) [ "$#" -ge 2 ] || usage; state_dir=$2; shift 2 ;;
    --expected-image) [ "$#" -ge 2 ] || usage; expected_image=$2; shift 2 ;;
    --expected-image-id) [ "$#" -ge 2 ] || usage; expected_image_id=$2; shift 2 ;;
    --expected-revision) [ "$#" -ge 2 ] || usage; expected_revision=$2; shift 2 ;;
    --expected-version) [ "$#" -ge 2 ] || usage; expected_version=$2; shift 2 ;;
    --expected-runtime-hash) [ "$#" -ge 2 ] || usage; expected_runtime_hash=$2; shift 2 ;;
    --public-url) [ "$#" -ge 2 ] || usage; public_url=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done

case "$phase" in predecessor|candidate|rollback|final) ;; *) usage ;; esac
[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$root" != *..* ]] || usage
[[ "$compose_script" =~ ^/[A-Za-z0-9._/-]+$ ]] &&
  [[ "$compose_script" != *..* ]] || usage
[[ "$state_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$state_dir" != *..* ]] || usage
[[ "$expected_image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
  usage
[[ "$expected_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$expected_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  usage
[[ "$expected_runtime_hash" =~ ^[0-9a-f]{64}$ ]] || usage
[[ "$public_url" =~ ^https://[^/]+$ ]] || usage
[ -n "$output" ] || usage
[ -d "$root" ] && [ -s "$root/.env.production" ] || fail "production root is incomplete"
[ -x "$compose_script" ] || fail "Compose wrapper is unavailable"
[ -d "$state_dir" ] && [ ! -L "$state_dir" ] || fail "state directory is unsafe"
[ ! -L "$output" ] || fail "output path is unsafe"
[ -d "$(dirname -- "$output")" ] || fail "output directory is unavailable"
for command_name in docker curl jq sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name is required"
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$script_dir/test-vps-runtime-invariants.sh"

backend=$(runtime_compose "$root" "$compose_script" ps -q backend) ||
  fail "backend lookup failed"
postgres=$(runtime_compose "$root" "$compose_script" ps -q postgres) ||
  fail "postgres lookup failed"
[ -n "$backend" ] && [ -n "$postgres" ] ||
  fail "backend or PostgreSQL container is unavailable"

actual_id=$(docker inspect "$backend" --format '{{.Image}}') ||
  fail "backend image identity unavailable"
reference=$(docker inspect "$backend" --format '{{.Config.Image}}') ||
  fail "backend image reference unavailable"
runtime_hash=$(docker inspect "$backend" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') ||
  fail "backend runtime hash unavailable"
[ "$actual_id" = "$expected_image_id" ] || fail "backend image identity differs"
[ "$reference" = "$expected_image" ] || fail "backend image reference differs"
[ "$runtime_hash" = "$expected_runtime_hash" ] ||
  fail "backend runtime hash differs"

container_running=$(docker inspect "$backend" --format '{{.State.Running}}') ||
  fail "backend running state unavailable"
health_status=$(docker inspect "$backend" --format '{{.State.Health.Status}}') ||
  fail "backend health state unavailable"
container_healthy=false
[ "$container_running" = true ] && [ "$health_status" = healthy ] &&
  container_healthy=true

source_label=$(docker inspect "$backend" \
  --format '{{index .Config.Labels "org.opencontainers.image.source"}}')
revision_label=$(docker inspect "$backend" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
version_label=$(docker inspect "$backend" \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}')
[ "$source_label" = "https://github.com/NickolayMamonov/meet-backend-v3" ] ||
  fail "backend source label differs"
[ "$revision_label" = "$expected_revision" ] || fail "backend revision label differs"
[ "$version_label" = "$expected_version" ] || fail "backend version label differs"

volumes=$(runtime_normalized_mounts "$backend")
postgres_volumes=$(runtime_normalized_mounts "$postgres")
volumes_verified=false
if jq -e '
  length == 1 and .[0].type == "volume" and
  .[0].source == "meet-production_uploads_data" and
  .[0].destination == "/data/uploads" and .[0].read_only == false
' <<<"$volumes" >/dev/null &&
  jq -e '
  length == 1 and .[0].type == "volume" and
  .[0].source == "meet-production_postgres_data" and
  .[0].destination == "/var/lib/postgresql/data" and .[0].read_only == false
' <<<"$postgres_volumes" >/dev/null; then
  docker volume inspect meet-production_uploads_data >/dev/null
  docker volume inspect meet-production_postgres_data >/dev/null
  volumes_verified=true
fi

topology_verified=false
ports=$(runtime_normalized_ports "$backend")
networks=$(runtime_normalized_networks "$backend")
binding=$(docker inspect "$backend" --format \
  '{{range $port, $bindings := .NetworkSettings.Ports}}{{if eq $port "8080/tcp"}}{{range $bindings}}{{.HostIp}}:{{.HostPort}}{{println}}{{end}}{{end}}{{end}}')
postgres_binding=$(docker port "$postgres")
compose_address=$(runtime_compose "$root" "$compose_script" port backend 8080)
if [ "$(wc -l <<<"$binding")" -eq 1 ] &&
  [[ "$binding" =~ ^127\.0\.0\.1:[0-9]+$ ]] &&
  [ -z "$postgres_binding" ] &&
  [[ "$compose_address" =~ ^127\.0\.0\.1:[0-9]+$ ]]; then
  topology_verified=true
fi

hardening_verified=false
memory=$(docker inspect "$backend" --format '{{.HostConfig.Memory}}')
if [ "$(docker inspect "$backend" --format '{{.HostConfig.ReadonlyRootfs}}')" = true ] &&
  [ "$(docker inspect "$backend" --format '{{.HostConfig.RestartPolicy.Name}}')" = unless-stopped &&
  [ "$(docker inspect "$backend" --format '{{.HostConfig.LogConfig.Type}}')" = local &&
  docker inspect "$backend" --format '{{json .HostConfig.CapDrop}}' |
    jq -e 'index("ALL") != null' >/dev/null &&
  docker inspect "$backend" --format '{{json .HostConfig.SecurityOpt}}' |
    jq -e 'index("no-new-privileges:true") != null' >/dev/null &&
  docker inspect "$backend" --format '{{json .HostConfig.Tmpfs}}' |
    jq -e 'has("/tmp")' >/dev/null &&
  [[ "$memory" =~ ^[1-9][0-9]*$ ]] &&
  [ "$(docker exec "$backend" id -u)" = 10001 ] &&
  [ "$(docker exec "$backend" id -g)" = 10001 ]; then
  hardening_verified=true
fi

database_json=$(
  docker exec "$postgres" psql -Atqc "
    SELECT json_build_object(
      'tags',(SELECT count(*) FROM tags),
      'users',(SELECT count(*) FROM users),
      'communities',(SELECT count(*) FROM communities),
      'meetings',(SELECT count(*) FROM meetings),
      'ad_blocks',(SELECT count(*) FROM ad_blocks),
      'user_interests',(SELECT count(*) FROM user_interests),
      'user_social_media',(SELECT count(*) FROM user_social_media),
      'community_tags',(SELECT count(*) FROM community_tags),
      'community_subscribers',(SELECT count(*) FROM community_subscribers),
      'meeting_tags',(SELECT count(*) FROM meeting_tags),
      'meeting_participants',(SELECT count(*) FROM meeting_participants),
      'ad_block_communities',(SELECT count(*) FROM ad_block_communities),
      'ad_block_users',(SELECT count(*) FROM ad_block_users),
      'demo_catalog_state',(SELECT count(*) FROM demo_catalog_state)
    )::text
  " 2>/dev/null
) || fail "database aggregate query failed"
echo "$database_json" | jq -e 'type == "object" and all(values[]; type == "number" and . >= 0)' \
  >/dev/null || fail "database aggregate query was not canonical"
total_rows=$(jq -n --argjson tables "$database_json" '$tables | add')

query_metric() {
  local sql=$1
  docker exec "$postgres" psql -Atqc "$sql" 2>/dev/null |
    tr -d '[:space:]'
}
non_idle_transactions=$(query_metric \
  "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend' AND state <> 'idle'") ||
  fail "transaction probe failed"
[[ "$non_idle_transactions" =~ ^[0-9]+$ ]] ||
  fail "transaction probe was not numeric"
smtp_sample_one=$(query_metric \
  "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND backend_type = 'client backend' AND state <> 'idle' AND application_name ILIKE '%smtp%'") ||
  fail "SMTP probe failed"
sleep 1
smtp_sample_two=$(query_metric \
  "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND backend_type = 'client backend' AND state <> 'idle' AND application_name ILIKE '%smtp%'") ||
  fail "SMTP probe failed"
[[ "$smtp_sample_one" =~ ^[0-9]+$ ]] && [[ "$smtp_sample_two" =~ ^[0-9]+$ ]] ||
  fail "SMTP probe was not numeric"
postgres_writable_primary=$(query_metric \
  "SELECT CASE WHEN pg_is_in_recovery() THEN 0 ELSE 1 END") ||
  fail "PostgreSQL primary probe failed"
[ "$postgres_writable_primary" = 1 ] ||
  fail "PostgreSQL is not a writable primary"

meetings_body=$(mktemp)
trap 'rm -f -- "$meetings_body" "$headers"' EXIT HUP INT TERM
meetings_status=$(curl --silent --show-error --output "$meetings_body" \
  --write-out '%{http_code}' --proto '=https' --tlsv1.2 "$public_url/meetings") ||
  fail "meetings HTTP probe failed"
[ "$meetings_status" = 200 ] || fail "meetings HTTP status was not 200"
meetings_json=$(jq -c 'if type == "array" then . else error("not an array") end' \
  "$meetings_body") || fail "meetings response was not a JSON array"
meetings_json_valid=true
meetings_count=$(jq 'length' <<<"$meetings_json")
actuator_status=$(curl --silent --show-error --output /dev/null \
  --write-out '%{http_code}' --proto '=https' --tlsv1.2 "$public_url/actuator")
headers=$(mktemp)
curl --silent --show-error --proto '=http' --max-time 10 \
  -D "$headers" -o /dev/null "${public_url/https:\/\//http://}/meetings" ||
  fail "HTTP redirect probe failed"
http_redirect_https=false
grep -Eiq '^location: https://' "$headers" && http_redirect_https=true
missing_admin=$(curl --silent --show-error --output /dev/null \
  --write-out '%{http_code}' -X POST "$public_url/admin/demo-catalog/bootstrap" \
  -H 'Content-Type: application/json' --data '{}')
wrong_admin=$(curl --silent --show-error --output /dev/null \
  --write-out '%{http_code}' -X POST "$public_url/admin/demo-catalog/bootstrap" \
  -H 'X-Admin-Key: wrong' -H 'Content-Type: application/json' --data '{}')
admin_key_configured=false
admin_authenticated_disabled_404=false
admin_blank_disabled_403=false
[ "$(grep -c '^ADMIN_API_KEY=' "$root/.env.production")" -eq 1 ] ||
  fail "admin key setting is unavailable"
admin_key=$(sed -n 's/^ADMIN_API_KEY=//p' "$root/.env.production")
case "$admin_key" in *[[:space:]]*) fail "configured admin key is malformed" ;; esac
if [ -n "$admin_key" ]; then
  admin_config=$(mktemp)
  chmod 600 "$admin_config"
  printf 'header = "X-Admin-Key: %s"\n' "$admin_key" >"$admin_config"
  unset admin_key
  authenticated_admin=$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}' -X POST --config "$admin_config" \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'Content-Type: application/json' --data '{}')
  rm -f -- "$admin_config"
  [ "$authenticated_admin" = 404 ] ||
    fail "authenticated disabled admin endpoint is not absent"
  admin_key_configured=true
  admin_authenticated_disabled_404=true
else
  admin_blank_disabled_403=true
fi

assets_file="$state_dir/zero-state-assets-$phase.json"
"$script_dir/verify-test-vps-assets.sh" --public-url "$public_url" \
  --output "$assets_file" >/dev/null || fail "frozen assets probe failed"
assets_count=$(jq -r '.assets | length // .count // 0' "$assets_file" 2>/dev/null ||
  jq -r '.count // 0' "$assets_file")
assets_verified=$(jq -er '.verified | select(type == "boolean")' "$assets_file")
[ "$assets_count" = 13 ] || fail "frozen asset count differs"

zero_state=unknown
if [ "$total_rows" -gt 0 ] || [ "$meetings_count" -gt 0 ]; then
  zero_state=populated
elif [ "$container_healthy" = true ] &&
  [ "$topology_verified" = true ] &&
  [ "$hardening_verified" = true ] &&
  [ "$volumes_verified" = true ] &&
  [ "$non_idle_transactions" = 0 ] &&
  [ "$smtp_sample_one" = 0 ] && [ "$smtp_sample_two" = 0 ] &&
  [ "$meetings_status" = 200 ] && [ "$meetings_count" = 0 ] &&
  [ "$actuator_status" = 404 ] && [ "$http_redirect_https" = true ] &&
  [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] &&
  [ "$postgres_writable_primary" = 1 ] &&
  [ "$assets_verified" = true ]; then
  zero_state=closed
fi

temporary="$output.tmp.$$"
trap 'rm -f -- "$temporary" "$meetings_body" "$headers"' EXIT HUP INT TERM
jq -cnS \
  --arg schema "meet-backend/test-vps-zero-state-probe/v1" \
  --arg phase "$phase" --arg image "$expected_image" --arg imageId "$expected_image_id" \
  --arg sourceSha "$expected_revision" --arg version "$expected_version" \
  --arg runtimeHash "$expected_runtime_hash" --arg zeroState "$zero_state" \
  --argjson containerHealthy "$container_healthy" \
  --argjson topologyVerified "$topology_verified" \
  --argjson hardeningVerified "$hardening_verified" \
  --argjson volumesVerified "$volumes_verified" \
  --argjson postgresWritablePrimary "$([ "$postgres_writable_primary" = 1 ] && echo true || echo false)" \
  --argjson nonIdle "$non_idle_transactions" \
  --argjson smtpSamples "[$smtp_sample_one,$smtp_sample_two]" \
  --argjson database "$database_json" --argjson totalRows "$total_rows" \
  --argjson meetingsStatus "$meetings_status" --argjson meetingsCount "$meetings_count" \
  --argjson meetingsJson "$meetings_json_valid" \
  --argjson actuatorStatus "$actuator_status" --argjson httpRedirectHttps "$http_redirect_https" \
  --argjson missingAdmin "$missing_admin" --argjson wrongAdmin "$wrong_admin" \
  --argjson adminKeyConfigured "$admin_key_configured" \
  --argjson adminAuthenticatedDisabled404 "$admin_authenticated_disabled_404" \
  --argjson adminBlankDisabled403 "$admin_blank_disabled_403" \
  --argjson assetsCount "$assets_count" --argjson assetsVerified "$assets_verified" \
  --argjson volumes "$volumes" --argjson postgresVolumes "$postgres_volumes" \
  --argjson ports "$ports" --argjson networks "$networks" '
  {
    schema:$schema,phase:$phase,image:$image,imageId:$imageId,
    sourceSha:$sourceSha,version:$version,runtimeConfigHash:$runtimeHash,
    runtime:{
      containerHealthy:$containerHealthy,topologyVerified:$topologyVerified,
      hardeningVerified:$hardeningVerified,volumesVerified:$volumesVerified,
      volumes:$volumes,postgresVolumes:$postgresVolumes,
      ports:$ports,networks:$networks,
      postgresWritablePrimary:$postgresWritablePrimary,
      nonIdleApplicationTransactions:$nonIdle,
      smtpIdleSamples:$smtpSamples
    },
    database:{tables:$database,totalRows:$totalRows},
    http:{
      meetingsStatus:$meetingsStatus,meetingsJson:$meetingsJson,meetingsCount:$meetingsCount,
      actuatorStatus:$actuatorStatus,httpRedirectHttps:$httpRedirectHttps,
      adminMissingStatus:$missingAdmin,adminWrongStatus:$wrongAdmin,
      adminKeyConfigured:$adminKeyConfigured,
      adminAuthenticatedDisabled404:$adminAuthenticatedDisabled404,
      adminBlankDisabled403:$adminBlankDisabled403,
      assetsCount:$assetsCount,assetsVerified:$assetsVerified
    },
    zeroStateObserved:true,zeroState:$zeroState
  }
' >"$temporary" || fail "zero-state evidence construction failed"
chmod 600 "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || fail "zero-state evidence publication failed"

[ "$zero_state" = closed ] ||
  fail "zero-state probe observed populated or unsafe state"
