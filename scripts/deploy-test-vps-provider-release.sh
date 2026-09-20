#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

is_supported_test_vps_version() {
  local version=${1:-}
  local major minor patch
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    return 1
  IFS=. read -r major minor patch <<<"$version"
  (( major > 1 ||
    (major == 1 && (minor > 2 || (minor == 2 && patch >= 0))) ))
}

usage() {
  echo "usage: $0 --root PATH --base-compose PATH --image IMAGE@sha256:DIGEST --revision SHA --version VERSION --run-key KEY --mode deploy|rollback-drill [--closed-beta-safety --state-mode empty-closed|closed-beta-demo] [--public-url https://HOST]" >&2
  exit 2
}

fail() {
  echo "test VPS deployment failed: $1" >&2
  exit 1
}

provider_release_main() {
root=
base_compose=
image=
revision=
version=
run_key=
mode=
closed_beta_safety=false
public_url=
state_mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] && [ -z "$root" ] || usage; root=$2; shift 2 ;;
    --base-compose) [ "$#" -ge 2 ] && [ -z "$base_compose" ] || usage; base_compose=$2; shift 2 ;;
    --image) [ "$#" -ge 2 ] && [ -z "$image" ] || usage; image=$2; shift 2 ;;
    --revision) [ "$#" -ge 2 ] && [ -z "$revision" ] || usage; revision=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] && [ -z "$version" ] || usage; version=$2; shift 2 ;;
    --run-key) [ "$#" -ge 2 ] && [ -z "$run_key" ] || usage; run_key=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] && [ -z "$mode" ] || usage; mode=$2; shift 2 ;;
    --closed-beta-safety)
      [ "$closed_beta_safety" = false ] || usage
      closed_beta_safety=true
      shift
      ;;
    --state-mode)
      [ "$#" -ge 2 ] && [ -z "$state_mode" ] || usage
      state_mode=$2
      shift 2
      ;;
    --public-url)
      [ "$#" -ge 2 ] && [ -z "$public_url" ] || usage
      public_url=$2
      shift 2
      ;;
    *) usage ;;
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
is_supported_test_vps_version "$version" ||
  fail "target version must be at least v1.2.0"
[[ "$run_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
case "$mode" in deploy|rollback-drill) ;; *) usage ;; esac
if [ -n "$public_url" ]; then
  [[ "$public_url" =~ ^https://[^/]+$ ]] || usage
fi
if [ "$closed_beta_safety" = true ]; then
  case "$state_mode" in empty-closed|closed-beta-demo) ;; *) usage ;; esac
elif [ -n "$state_mode" ]; then
  usage
fi

for command_name in docker curl jq flock python3 timeout; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name is required"
done
[ "$(id -u)" -eq 0 ] || fail "the test VPS deploy must run as root"
[ -d "$root" ] || fail "deployment root is unavailable"
[ -s "$root/.env.production" ] || fail "existing production environment is unavailable"
[ -s "$root/docker-compose.production.yml" ] ||
  fail "existing production Compose file is unavailable"
[ -s "$base_compose" ] || fail "reviewed target Compose file is unavailable"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compose_script=$script_dir/production-compose.sh
update_script=$script_dir/update-production-release.sh
runtime_helper=$script_dir/test-vps-runtime-invariants.sh
safety_hook=$script_dir/verify-test-vps-closed-beta-state.sh
provider_helper=$script_dir/test-vps-provider-credential.py
[ -x "$compose_script" ] || fail "reviewed Compose wrapper is unavailable"
[ -x "$update_script" ] || fail "reviewed release updater is unavailable"
[ -r "$runtime_helper" ] || fail "runtime invariant helper is unavailable"
[ -f "$provider_helper" ] && [ ! -L "$provider_helper" ] && [ -r "$provider_helper" ] ||
  fail "provider credential helper is unavailable"
timeout 30s python3 "$provider_helper" check >/dev/null ||
  fail "PREREQUISITE_MISSING"
# shellcheck source=/dev/null
source "$runtime_helper"

state_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
active_compose=/var/lib/meet-production/active-compose.yml
active_runtime=/var/lib/meet-production/active-runtime.override.yml
smtp_pointer=$state_root/.smtp-transaction.current
provider_pointer=$state_root/.provider-transaction.current
state=$state_root/$run_key-$mode
install -d -m 700 "$state_root"
exec 9>"$state_root/.deploy.lock"
flock -n 9 || fail "another test VPS deployment is active"
if [ "$closed_beta_safety" = true ]; then
  [ -f "$safety_hook" ] && [ ! -L "$safety_hook" ] && [ -x "$safety_hook" ] ||
    fail "closed-beta safety hook is unavailable"
fi

# This is intentionally an existence/type-only interlock.  SMTP tooling owns
# parsing, recovery, terminal publication, and cleanup of every object class.
if [ -e "$smtp_pointer" ] || [ -L "$smtp_pointer" ]; then
  fail "SMTP transaction is active; reconcile it with the SMTP tooling first"
fi
if [ -e "$provider_pointer" ] || [ -L "$provider_pointer" ]; then
  fail "RECOVERY_REQUIRED"
fi
timeout 30s python3 "$provider_helper" retention-check \
  --state-root "$state_root" >/dev/null ||
  fail "RECOVERY_REQUIRED"

[ ! -e "$state" ] || fail "run state already exists"
install -d -m 700 "$state"

compose() {
  runtime_compose "$root" "$compose_script" "$@"
}

previous_image=$(runtime_release_field "$root" BACKEND_IMAGE)
previous_version=$(runtime_release_field "$root" BACKEND_VERSION)
previous_revision=$(runtime_release_field "$root" BACKEND_REVISION)
[[ "$previous_revision" =~ ^[0-9a-f]{40}$ ]] ||
  fail "running revision is malformed"
[[ "$previous_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "running version is malformed"
is_supported_test_vps_version "$previous_version" ||
  fail "predecessor version must be at least v1.2.0"
previous_id=$(runtime_image_id "$root" "$compose_script")
[ "$(docker image inspect "$previous_image" --format '{{.Id}}')" = "$previous_id" ]
previous_container=$(compose ps -q backend)
[ -n "$previous_container" ] || fail "predecessor backend is unavailable"
previous_runtime_hash=$(docker inspect "$previous_container" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
[[ "$previous_runtime_hash" =~ ^[0-9a-f]{64}$ ]]
verify_runtime_invariants "$root" "$compose_script" "$previous_id" \
  "$previous_revision" "$previous_version" "$previous_runtime_hash"
verify_environment_matches_container "$root" "$compose_script" ||
  fail "running container does not match the current production environment"
previous_inspect=$(docker inspect "$previous_container" 2>/dev/null) ||
  fail "PROVIDER_STATE_INVALID"
provider_observed=$(printf '%s' "$previous_inspect" |
  timeout 30s python3 "$provider_helper" observe) ||
  fail "PROVIDER_STATE_INVALID"
jq -e '
  type == "object" and .schemaVersion == 1 and
  (.providerEnabled | type == "boolean") and
  (.credentialMountPresent | type == "boolean") and
  (.credentialMountReadOnly | type == "boolean") and
  (.outcome == "observed")
' <<<"$provider_observed" >/dev/null || fail "PROVIDER_STATE_INVALID"
provider_enabled=$(jq -r '.providerEnabled' <<<"$provider_observed")

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

run_safety_hook() {
  local phase=$1
  local expected_image=$2
  local expected_id=$3
  local expected_revision=$4
  local expected_version=$5
  local expected_runtime_hash=$6
  local output=$state/$phase.json
  [ "$closed_beta_safety" = true ] || return 0
  [ ! -e "$output" ] && [ ! -L "$output" ] ||
    fail "closed-beta $phase evidence already exists"
  safety_args=(
    --phase "$phase"
    --root "$root"
    --compose-script "$compose_script"
    --state-dir "$state"
    --expected-image "$expected_image"
    --expected-image-id "$expected_id"
    --expected-revision "$expected_revision"
    --expected-version "$expected_version"
    --expected-runtime-hash "$expected_runtime_hash"
    --state-mode "$state_mode"
  )
  if [ -n "$public_url" ]; then
    safety_args+=(--public-url "$public_url")
  fi
  "$safety_hook" "${safety_args[@]}" \
    --output "$output" >/dev/null
  [ -f "$output" ] && [ ! -L "$output" ] && [ -s "$output" ] ||
    fail "closed-beta $phase evidence is unavailable"
  chmod 600 "$output"
  if [ "$phase" = final ] && [ -n "$public_url" ]; then
    "$script_dir/verify-test-vps-assets.sh" \
      --public-url "$public_url" \
      --output "$state/frozen-assets.json" >/dev/null
    curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
      "$public_url/meetings" | jq -e 'type == "array"' >/dev/null
    [ "$(curl --silent --show-error --proto '=https' --tlsv1.2 \
      -o /dev/null -w '%{http_code}' "$public_url/actuator")" = 404 ] ||
      fail "Actuator is not private"
    headers=$(mktemp)
    trap 'rm -f -- "$headers"' RETURN
    curl --silent --show-error --proto '=http' --max-time 10 \
      -D "$headers" -o /dev/null "${public_url/https:\/\//http://}/meetings"
    grep -Eiq '^location: https://' "$headers" ||
      fail "HTTP does not redirect to HTTPS"
    rm -f -- "$headers"
    missing_admin=$(curl --silent --show-error --output /dev/null \
      --write-out '%{http_code}' -X POST \
      "$public_url/admin/demo-catalog/bootstrap" \
      -H 'Content-Type: application/json' --data '{}')
    wrong_admin=$(curl --silent --show-error --output /dev/null \
      --write-out '%{http_code}' -X POST \
      "$public_url/admin/demo-catalog/bootstrap" \
      -H 'X-Admin-Key: wrong' -H 'Content-Type: application/json' --data '{}')
    [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] ||
      fail "admin guard did not reject unauthenticated requests"
  fi
}

write_provider_marker() {
  local phase=$1
  local disposition=$2
  local temporary="$state_root/.provider-transaction.$run_key.tmp"
  case "$phase" in preparing|prepared|applying|verifying|rolling-back|finalizing) ;; *)
    fail "RECOVERY_REQUIRED"
    ;;
  esac
  case "$disposition" in none|created|reused) ;; *) fail "RECOVERY_REQUIRED" ;; esac
  if [ "$phase" = preparing ]; then
    [ ! -e "$provider_pointer" ] && [ ! -L "$provider_pointer" ] ||
      fail "RECOVERY_REQUIRED"
  fi
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || fail "RECOVERY_REQUIRED"
  umask 077
  printf '{"schemaVersion":1,"runKey":"%s","phase":"%s","providerEnabled":%s,"durableDisposition":"%s"}\n' \
    "$run_key" "$phase" "$provider_enabled" "$disposition" >"$temporary"
  chmod 600 "$temporary"
  python3 - "$temporary" "$state_root" <<'PY'
import os
import sys

for path, directory in ((sys.argv[1], False), (sys.argv[2], True)):
    flags = os.O_RDONLY | (os.O_DIRECTORY if directory else 0)
    fd = os.open(path, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
  mv -f -- "$temporary" "$provider_pointer"
  python3 - "$state_root" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

write_terminal_record() {
  local outcome=$1
  local terminal="$state/terminal.json"
  [ "$outcome" = committed ] || [ "$outcome" = rolled-back ] ||
    fail "RECOVERY_REQUIRED"
  umask 077
  jq -cn --arg run_key "$run_key" --arg outcome "$outcome" \
    --argjson enabled "$provider_enabled" \
    '{schemaVersion:1,runKey:$run_key,outcome:$outcome,providerEnabled:$enabled}' \
    >"$terminal"
  chmod 600 "$terminal"
  python3 - "$terminal" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

provider_finish() {
  local outcome=$1
  local inspection=$2
  write_provider_marker finalizing \
    "${durable_disposition:-none}"
  printf '%s' "$inspection" |
    timeout 30s python3 "$provider_helper" finish \
      --run-key "$run_key" --state-root "$state_root" \
      --outcome "$outcome" >/dev/null ||
    fail "RECOVERY_REQUIRED"
  write_terminal_record "$outcome"
  rm -f -- "$provider_pointer"
  jq -cn --argjson enabled "$provider_enabled" --arg outcome "$outcome" \
    '{schemaVersion:1,providerEnabled:$enabled,credentialMountPresent:$enabled,
      credentialMountReadOnly:$enabled,outcome:$outcome}'
}

verify_public_contract() {
  [ -n "$public_url" ] || return 0
  local meetings_probe actuator_status redirect_headers redirect_status
  meetings_probe=$(timeout 30s curl --silent --connect-timeout 5 \
    --max-time 15 --write-out $'\n%{http_code}' \
    "$public_url/meetings" 2>/dev/null |
    timeout 5s python3 -c '
import json
import sys

data = sys.stdin.buffer.read(8 * 1024 * 1024 + 64)
body, separator, status = data.rpartition(b"\n")
if not separator or len(body) > 8 * 1024 * 1024 or status != b"200":
    raise SystemExit(1)
try:
    value = json.loads(body.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, list):
    raise SystemExit(1)
print("meetings_status=200 meetings_array=true")
') || fail "public meetings probe failed"
  [ "$meetings_probe" = "meetings_status=200 meetings_array=true" ] ||
    fail "public meetings probe failed"
  actuator_status=$(curl --silent --show-error --connect-timeout 5 \
    --max-time 15 --output /dev/null --write-out '%{http_code}' \
    "$public_url/actuator" 2>/dev/null) || fail "public actuator probe failed"
  [ "$actuator_status" = 404 ] || fail "public actuator probe failed"
  redirect_headers=$(curl --silent --connect-timeout 5 --max-time 15 \
    --dump-header - --output /dev/null --write-out '%{http_code}' \
    "${public_url/https:\/\//http://}/meetings" 2>/dev/null) ||
    fail "public redirect probe failed"
  redirect_status=${redirect_headers: -3}
  case "$redirect_status" in 301|302|307|308) ;; *)
    fail "public redirect probe failed"
    ;;
  esac
  grep -Eiq '^location:[[:space:]]+https://' <<<"$redirect_headers" ||
    fail "public redirect probe failed"
  local missing_admin wrong_admin
  missing_admin=$(curl --silent --connect-timeout 5 --max-time 15 \
    --output /dev/null --write-out '%{http_code}' -X POST \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'Content-Type: application/json' --data '{}' 2>/dev/null) ||
    fail "admin guard probe failed"
  wrong_admin=$(curl --silent --connect-timeout 5 --max-time 15 \
    --output /dev/null --write-out '%{http_code}' -X POST \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'X-Admin-Key: wrong' -H 'Content-Type: application/json' \
    --data '{}' 2>/dev/null) || fail "admin guard probe failed"
  [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] ||
    fail "admin guard probe failed"
}

mutation_started=false
credential_prepared=false
rollback_complete=false
on_exit() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ "$rollback_complete" = false ]; then
    if [ "$mutation_started" = true ]; then
      rollback || status=1
    elif [ "$credential_prepared" = true ]; then
      verify_runtime_invariants "$root" "$compose_script" "$previous_id" \
        "$previous_revision" "$previous_version" "$previous_runtime_hash" \
        >/dev/null 2>&1 || status=1
      if [ "$status" -eq 0 ]; then
        provider_finish rolled-back "$previous_inspect" || status=1
      fi
    fi
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 143' TERM INT HUP

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
run_safety_hook predecessor "$previous_image" "$previous_id" \
  "$previous_revision" "$previous_version" "$previous_runtime_hash"

if [ "$provider_enabled" = true ]; then
  cat >"$state/target-runtime.override.yml" <<'YAML'
services:
  backend:
    healthcheck:
      test:
        - CMD
        - curl
        - --fail
        - --silent
        - --show-error
        - http://127.0.0.1:8080/meetings
    volumes:
      - type: bind
        source: /var/lib/meet-production/credentials/firebase-service-account.json
        target: /run/secrets/meet-firebase-service-account.json
        read_only: true
        bind:
          create_host_path: false
YAML
else
  cat >"$state/target-runtime.override.yml" <<'YAML'
services:
  backend:
    healthcheck:
      test:
        - CMD
        - curl
        - --fail
        - --silent
        - --show-error
        - http://127.0.0.1:8080/meetings
YAML
fi
chmod 600 "$state/target-runtime.override.yml"

target_config=$(
  env -i PATH="$PATH" HOME=/root COMPOSE_PROJECT_NAME=meet-production \
    BACKEND_IMAGE="$image" BACKEND_VERSION="$version" BACKEND_REVISION="$revision" \
    docker compose --project-directory "$root" --env-file "$root/.env.production" \
    -f "$base_compose" -f "$state/target-runtime.override.yml" \
    config --format json 2>/dev/null
) || fail "PROVIDER_STATE_INVALID"
target_image_inspect=$(docker image inspect "$image" 2>/dev/null) ||
  fail "PROVIDER_STATE_INVALID"
printf '%s\n%s\n%s\n' "$previous_inspect" "$target_image_inspect" "$target_config" |
  jq -s -e '
    def envmap:
      if type == "array" then
        reduce .[] as $entry ({};
          if ($entry | type) != "string" or ($entry | contains("=") | not)
          then error("invalid environment")
          else ($entry | index("=")) as $i |
            . + {($entry[0:$i]): $entry[($i + 1):]}
          end)
      elif type == "object" then
        reduce to_entries[] as $entry ({};
          if ($entry.value | type) != "string"
          then error("unresolved environment")
          else . + {($entry.key):$entry.value}
          end)
      else {}
      end;
    def effective($imageEnv; $targetEnv):
      ($imageEnv | envmap) + ($targetEnv | envmap);
    def tuple($env):
      {
        APP_PUSH_PROVIDER_ENABLED: ($env.APP_PUSH_PROVIDER_ENABLED // "false" | ascii_downcase),
        APP_PUSH_DISCOVERY_ENABLED: ($env.APP_PUSH_DISCOVERY_ENABLED // "false" | ascii_downcase),
        APP_PUSH_DISPATCH_ENABLED: ($env.APP_PUSH_DISPATCH_ENABLED // "false" | ascii_downcase),
        APP_PUSH_DIAGNOSTIC_ENABLED: ($env.APP_PUSH_DIAGNOSTIC_ENABLED // "false" | ascii_downcase),
        APP_PUSH_MAINTENANCE_ENABLED: ($env.APP_PUSH_MAINTENANCE_ENABLED // "false" | ascii_downcase),
        APP_PUSH_PROJECT_ID: ($env.APP_PUSH_PROJECT_ID // "meeting-1d258"),
        APP_PUSH_CREDENTIALS_FILE: ($env.APP_PUSH_CREDENTIALS_FILE // "")
      };
    (.[0][0].Config.Env | envmap) as $previous |
    (.[1][0].Config.Env | envmap) as $image |
    (.[2].services.backend.environment // {}) as $target |
    (effective($image; $target) | tuple(.)) == (tuple($previous)) and
    (tuple($previous).APP_PUSH_PROVIDER_ENABLED == "true" or
      tuple($previous).APP_PUSH_PROVIDER_ENABLED == "false") and
    (tuple($previous).APP_PUSH_DISCOVERY_ENABLED == "true" or
      tuple($previous).APP_PUSH_DISCOVERY_ENABLED == "false") and
    (tuple($previous).APP_PUSH_DISPATCH_ENABLED == "true" or
      tuple($previous).APP_PUSH_DISPATCH_ENABLED == "false") and
    (tuple($previous).APP_PUSH_DIAGNOSTIC_ENABLED == "true" or
      tuple($previous).APP_PUSH_DIAGNOSTIC_ENABLED == "false") and
    (tuple($previous).APP_PUSH_MAINTENANCE_ENABLED == "true" or
      tuple($previous).APP_PUSH_MAINTENANCE_ENABLED == "false")
  ' >/dev/null 2>&1 || fail "PROVIDER_STATE_INVALID"

write_provider_marker preparing none
durable_existed=false
if [ -e /var/lib/meet-production/credentials/firebase-service-account.json ] ||
  [ -L /var/lib/meet-production/credentials/firebase-service-account.json ]; then
  durable_existed=true
fi
printf '%s' "$previous_inspect" |
  timeout 30s python3 "$provider_helper" prepare \
    --run-key "$run_key" --state-root "$state_root" >/dev/null ||
  fail "CREDENTIAL_INVALID"
durable_disposition=none
if [ "$provider_enabled" = true ]; then
  if [ "$durable_existed" = true ]; then
    durable_disposition=reused
  else
    durable_disposition=created
  fi
fi
case "$durable_disposition" in none|created|reused) ;; *) fail "RECOVERY_REQUIRED" ;; esac
write_provider_marker prepared "$durable_disposition"
credential_prepared=true

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
  write_provider_marker rolling-back "${durable_disposition:-none}"
  restore_previous_active_files
  PRODUCTION_ROOT=$root PRODUCTION_SCRIPTS_DIR=$script_dir \
    "$update_script" "$previous_image" "$previous_revision" "$previous_version" \
    >/dev/null
  timeout 240s compose up -d --no-deps --no-build --pull never --force-recreate \
    --wait --wait-timeout 180 backend >/dev/null
  restored_container=$(compose ps -q backend)
  restored_inspect=$(docker inspect "$restored_container" 2>/dev/null) ||
    fail "RECOVERY_REQUIRED"
  restored_hash=$(docker inspect "$restored_container" \
    --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
  [ "$restored_hash" = "$previous_runtime_hash" ] ||
    fail "rollback did not restore the exact predecessor Compose runtime"
  verify_runtime_invariants "$root" "$compose_script" "$previous_id" \
    "$previous_revision" "$previous_version" "$previous_runtime_hash"
  printf '[%s,%s]' "$previous_inspect" "$restored_inspect" |
    timeout 30s python3 "$provider_helper" verify \
      --run-key "$run_key" --phase rollback >/dev/null ||
    fail "RECOVERY_REQUIRED"
  verify_public_contract
  run_safety_hook rollback "$previous_image" "$previous_id" \
    "$previous_revision" "$previous_version" "$previous_runtime_hash"
  provider_finish rolled-back "$restored_inspect"
  rollback_complete=true
  echo "rollback=completed previous_image_id=$previous_id"
}

write_provider_marker applying "$durable_disposition"
mutation_started=true
install -m 600 "$base_compose" "$active_compose"
install -m 600 "$state/target-runtime.override.yml" "$active_runtime"
PRODUCTION_ROOT=$root PRODUCTION_SCRIPTS_DIR=$script_dir \
  "$update_script" "$image" "$revision" "$version" >/dev/null
timeout 240s compose up -d --no-deps --no-build --pull never --force-recreate \
  --wait --wait-timeout 180 backend >/dev/null
candidate_container=$(compose ps -q backend)
candidate_inspect=$(docker inspect "$candidate_container" 2>/dev/null) ||
  fail "RECOVERY_REQUIRED"
target_hash=$(docker inspect "$candidate_container" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
[[ "$target_hash" =~ ^[0-9a-f]{64}$ ]] || fail "candidate runtime hash unavailable"
write_provider_marker verifying "$durable_disposition"
printf '[%s,%s]' "$previous_inspect" "$candidate_inspect" |
  timeout 30s python3 "$provider_helper" verify \
    --run-key "$run_key" --phase candidate >/dev/null ||
  fail "PROVIDER_STATE_INVALID"
verify_runtime_invariants "$root" "$compose_script" "$target_id" \
  "$revision" "$version" "$target_hash"
verify_public_contract
run_safety_hook candidate "$image" "$target_id" \
  "$revision" "$version" "$target_hash"
echo "candidate=ready image_id=$target_id version=$version revision=$revision"

if [ "$mode" = rollback-drill ]; then
  echo "rollback_drill=triggered"
  exit 86
fi

run_safety_hook final "$image" "$target_id" \
  "$revision" "$version" "$target_hash"
provider_finish committed "$candidate_inspect"
mutation_started=false
rollback_complete=true
echo "deployment=completed image_id=$target_id version=$version revision=$revision"

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  provider_release_main "$@"
fi
