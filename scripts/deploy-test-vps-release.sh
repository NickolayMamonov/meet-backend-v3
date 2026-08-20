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
    --root) [ "$#" -ge 2 ] && [ -z "$root" ] || usage; root=$2; shift 2 ;;
    --base-compose) [ "$#" -ge 2 ] && [ -z "$base_compose" ] || usage; base_compose=$2; shift 2 ;;
    --image) [ "$#" -ge 2 ] && [ -z "$image" ] || usage; image=$2; shift 2 ;;
    --revision) [ "$#" -ge 2 ] && [ -z "$revision" ] || usage; revision=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] && [ -z "$version" ] || usage; version=$2; shift 2 ;;
    --run-key) [ "$#" -ge 2 ] && [ -z "$run_key" ] || usage; run_key=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] && [ -z "$mode" ] || usage; mode=$2; shift 2 ;;
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
[[ "$run_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
case "$mode" in deploy|rollback-drill) ;; *) usage ;; esac

for command_name in docker curl jq flock; do
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
[ -x "$compose_script" ] || fail "reviewed Compose wrapper is unavailable"
[ -x "$update_script" ] || fail "reviewed release updater is unavailable"
[ -r "$runtime_helper" ] || fail "runtime invariant helper is unavailable"
# shellcheck source=/dev/null
source "$runtime_helper"

state_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
active_compose=/var/lib/meet-production/active-compose.yml
active_runtime=/var/lib/meet-production/active-runtime.override.yml
smtp_pointer=$state_root/.smtp-transaction.current
state=$state_root/$run_key-$mode
install -d -m 700 "$state_root"
exec 9>"$state_root/.deploy.lock"
flock -n 9 || fail "another test VPS deployment is active"

# This is intentionally an existence/type-only interlock.  SMTP tooling owns
# parsing, recovery, terminal publication, and cleanup of every object class.
if [ -e "$smtp_pointer" ] || [ -L "$smtp_pointer" ]; then
  fail "SMTP transaction is active; reconcile it with the SMTP tooling first"
fi

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
previous_id=$(runtime_image_id "$root" "$compose_script")
[ "$(docker image inspect "$previous_image" --format '{{.Id}}')" = "$previous_id" ]
previous_runtime_hash=$(docker inspect "$(compose ps -q backend)" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
[[ "$previous_runtime_hash" =~ ^[0-9a-f]{64}$ ]]
verify_runtime_invariants "$root" "$compose_script" "$previous_id" \
  "$previous_revision" "$previous_version" "$previous_runtime_hash"
verify_environment_matches_container "$root" "$compose_script" ||
  fail "running container does not match the current production environment"

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
  verify_runtime_invariants "$root" "$compose_script" "$previous_id" \
    "$previous_revision" "$previous_version" "$previous_runtime_hash"
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
[[ "$target_hash" =~ ^[0-9a-f]{64}$ ]] || fail "candidate runtime hash unavailable"
verify_runtime_invariants "$root" "$compose_script" "$target_id" \
  "$revision" "$version" "$target_hash"
echo "candidate=ready image_id=$target_id version=$version revision=$revision"

if [ "$mode" = rollback-drill ]; then
  echo "rollback_drill=triggered"
  exit 86
fi

mutation_started=false
echo "deployment=completed image_id=$target_id version=$version revision=$revision"
