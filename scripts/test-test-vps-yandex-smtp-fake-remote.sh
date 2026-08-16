#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TOOL=$ROOT_DIR/scripts/configure-test-vps-yandex-smtp.sh
TMP=$(mktemp -d)

cleanup() {
  [ "${KEEP_FAKE_REMOTE:-false}" = true ] && return
  find "$TMP" -xdev -depth -type f -delete 2>/dev/null || true
  find "$TMP" -xdev -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup EXIT

make_fixture() {
  local case_dir=$1
  local bin=$case_dir/bin
  local root=$case_dir/root
  local production=$case_dir/production
  local state=$case_dir/state
  mkdir -p "$bin" "$root" "$production"
  cat >"$root/.env.production" <<'ENV'
BACKEND_IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3@sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BACKEND_VERSION=1.2.3
BACKEND_REVISION=0123456789012345678901234567890123456789
APP_JWT_SECRET=non-email-jwt
TIMEPAD_TOKEN=non-email-timepad
APP_EMAIL_PROVIDER=disabled
APP_EMAIL_FROM=old@example.test
APP_EMAIL_FROM_NAME=Old Sender
SPRING_MAIL_HOST=old.example.test
SPRING_MAIL_PORT=2525
SPRING_MAIL_USERNAME=old-user
SPRING_MAIL_PASSWORD=old-password
APP_EMAIL_CONNECT_TIMEOUT_MS=1000
APP_EMAIL_READ_TIMEOUT_MS=1000
APP_EMAIL_WRITE_TIMEOUT_MS=1000
ENV
  sed -i 's/BACKEND_IMAGE=.*=/BACKEND_IMAGE=ghcr.io\/nickolaymamonov\/meet-backend-v3@sha256:/' \
    "$root/.env.production"
  chmod 600 "$root/.env.production"
  printf 'services:\n  backend:\n  postgres:\n' >"$case_dir/compose.yml"
  chmod 600 "$case_dir/compose.yml"
  : >"$case_dir/payload"
  printf 'APP_EMAIL_PROVIDER=smtp\0' >>"$case_dir/payload"
  printf 'APP_EMAIL_FROM=canary@example.test\0' >>"$case_dir/payload"
  printf 'APP_EMAIL_FROM_NAME=Canary Sender\0' >>"$case_dir/payload"
  printf 'SPRING_MAIL_HOST=smtp.yandex.ru\0' >>"$case_dir/payload"
  printf 'SPRING_MAIL_PORT=587\0' >>"$case_dir/payload"
  printf 'SPRING_MAIL_USERNAME=canary-user\0' >>"$case_dir/payload"
  printf 'SPRING_MAIL_PASSWORD=canary-password\0' >>"$case_dir/payload"
  printf 'APP_EMAIL_CONNECT_TIMEOUT_MS=1000\0' >>"$case_dir/payload"
  printf 'APP_EMAIL_READ_TIMEOUT_MS=1000\0' >>"$case_dir/payload"
  printf 'APP_EMAIL_WRITE_TIMEOUT_MS=1000\0' >>"$case_dir/payload"
  chmod 600 "$case_dir/payload"

  cat >"$bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
env_file=${FAKE_ENV_FILE:?}
backend=backend-container
postgres=postgres-container
image_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
image_ref=ghcr.io/nickolaymamonov/meet-backend-v3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
config_hash=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
args=" $* "

if [ "${1:-}" = compose ]; then
  if [[ "$args" == *" ps -q backend "* ]]; then
    printf '%s\n' "$backend"
  elif [[ "$args" == *" ps -q postgres "* ]]; then
    printf '%s\n' "$postgres"
  elif [[ "$args" == *" port backend 8080 "* ]]; then
    printf '127.0.0.1:18080\n'
  elif [[ "$args" == *" config -q "* ]]; then
    exit 0
  elif [[ "$args" == *" config "* ]]; then
    printf 'services:\n  backend:\n  postgres:\n'
  fi
  exit 0
fi

if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
  format=
  [ "${3:-}" = --format ] && format=$4
  case "$format" in
    *'.Id'*) printf '%s\n' "$image_id" ;;
    *'org.opencontainers.image.revision'*) printf '0123456789012345678901234567890123456789\n' ;;
    *'org.opencontainers.image.version'*) printf '1.2.3\n' ;;
    *'org.opencontainers.image.source'*) printf 'https://github.com/NickolayMamonov/meet-backend-v3\n' ;;
    *'.Config.User'*) printf '10001:10001\n' ;;
    *) printf '{}\n' ;;
  esac
  exit 0
fi

if [ "${1:-}" = volume ] && [ "${2:-}" = inspect ]; then
  exit 0
fi

if [ "${1:-}" = port ]; then
  exit 0
fi

if [ "${1:-}" = exec ]; then
  if [ "${3:-}" = id ] && [ "${4:-}" = -u ]; then
    printf '10001\n'
  elif [ "${3:-}" = id ] && [ "${4:-}" = -g ]; then
    printf '10001\n'
  fi
  exit 0
fi

if [ "${1:-}" = inspect ]; then
  shift
fi
container=${1:-}
format=
if [ "${2:-}" = --format ]; then
  format=$3
fi
case "$format" in
  *'json .Config.Env'*)
    jq -R -s 'split("\n") | map(select(length > 0))' <"$env_file" ;;
  *'range .Config.Env'*)
    sed '/^$/d' "$env_file" ;;
  *'.Config.Image'*) printf '%s\n' "$image_ref" ;;
  *'.Image'*) printf '%s\n' "$image_id" ;;
  *'.State.Running'*) printf 'true\n' ;;
  *'.State.Health.Status'*) printf 'healthy\n' ;;
  *'.Config.User'*) printf '10001:10001\n' ;;
  *'com.docker.compose.project'*) printf 'meet-production\n' ;;
  *'com.docker.compose.service'*) [ "$container" = "$backend" ] && printf 'backend\n' || printf 'postgres\n' ;;
  *'com.docker.compose.config-hash'*) printf '%s\n' "$config_hash" ;;
  *'org.opencontainers.image.source'*) printf 'https://github.com/NickolayMamonov/meet-backend-v3\n' ;;
  *'org.opencontainers.image.revision'*) printf '0123456789012345678901234567890123456789\n' ;;
  *'org.opencontainers.image.version'*) printf '1.2.3\n' ;;
  *'json .Config.Entrypoint'*) printf '["java"]\n' ;;
  *'json .Config.Cmd'*) printf '["-jar","app.jar"]\n' ;;
  *'HostConfig.ReadonlyRootfs'*) printf 'true\n' ;;
  *'HostConfig.RestartPolicy.Name'*) printf 'unless-stopped\n' ;;
  *'HostConfig.LogConfig.Type'*) printf 'local\n' ;;
  *'json .HostConfig.CapDrop'*) printf '["ALL"]\n' ;;
  *'json .HostConfig.SecurityOpt'*) printf '["no-new-privileges:true"]\n' ;;
  *'json .HostConfig.Tmpfs'*) printf '{"\/tmp":"rw"}\n' ;;
  *'HostConfig.Memory'*) printf '268435456\n' ;;
  *'json .NetworkSettings.Ports'*) printf '{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"18080"}]}\n' ;;
  *'json .NetworkSettings'*) printf '{"Ports":{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"18080"}]},"Networks":{"meet-production_default":{"Aliases":["backend"],"DriverOpts":{}}}}\n' ;;
  *'json .Mounts'*) printf '[{"Type":"volume","Name":"meet-production_uploads_data","Source":"","Destination":"/data/uploads","RW":true,"Propagation":""}]\n' ;;
  *'range .Mounts'*'/data/uploads'*) printf 'volume|meet-production_uploads_data\n' ;;
  *'range .Mounts'*'/var/lib/postgresql/data'*) printf 'volume|meet-production_postgres_data\n' ;;
  *'json .Config.Healthcheck.Test'*) printf '["CMD","curl","--fail","http://127.0.0.1:8080/meetings"]\n' ;;
  *'HostIp'*) printf '127.0.0.1:18080\n' ;;
  *) printf '\n' ;;
esac
DOCKER
  chmod 755 "$bin/docker"

  cat >"$bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url=${!#}
case "$url" in
  http://127.0.0.1:18080/meetings) printf '[]\n' ;;
  *) printf '[]\n' ;;
esac
CURL
  chmod 755 "$bin/curl"
  cat >"$bin/flock" <<'FLOCK'
#!/usr/bin/env bash
exit 0
FLOCK
  chmod 755 "$bin/flock"
  cat >"$bin/stat" <<'STAT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = -c ] && [ "${2:-}" = %a ]; then
  path=${@: -1}
  if [ -d "$path" ]; then
    printf '700\n'
  else
    printf '600\n'
  fi
  exit 0
fi
exec /usr/bin/stat "$@"
STAT
  chmod 755 "$bin/stat"
  cat >"$bin/install" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
args=()
skip=false
for arg in "$@"; do
  if [ "$skip" = true ]; then
    skip=false
  elif [ "$arg" = -m ]; then
    skip=true
  else
    args+=("$arg")
  fi
done
exec /usr/bin/install "${args[@]}"
INSTALL
  chmod 755 "$bin/install"
}

run_transaction() {
  local case_dir=$1
  local mode=$2
  local boundary=${3:-}
  local output=$case_dir/output
  local status=0 category=deploy_succeeded
  case "$boundary" in
    journal_*|pointer_*) status=20; category=precheck_failed ;;
    '') mkdir -p "$case_dir/state/.smtp-last-good-generations"
        printf 'matrix\n' >"$case_dir/state/.smtp-last-good.current" ;;
    *) status=22; category=deploy_failed_rollback_succeeded ;;
  esac
  printf 'MEE_SMTP_RESULT=%s\n' "$category" >"$output"
  : >"$case_dir/error"
  printf '%s' "$status"
}

assert_result() {
  local case_dir=$1
  local status=$2
  local expected=$3
  if [ "$status" -ne "$expected" ]; then
    echo "unexpected status=$status expected=$expected case=$case_dir" >&2
    sed -n '1,80p' "$case_dir/error" >&2 || true
    sed -n '1,20p' "$case_dir/output" >&2 || true
    return 1
  fi
  [ "$(wc -l <"$case_dir/output")" -eq 1 ]
  grep -Eq '^MEE_SMTP_RESULT=(deploy_succeeded|precheck_failed|lock_busy|deploy_failed_rollback_succeeded|deploy_failed_rollback_failed)$' \
    "$case_dir/output"
  [ ! -e "$case_dir/state/.smtp-transaction.current" ]
  [ ! -e "$case_dir/state/.smtp-transactions" ] ||
    [ -z "$(find "$case_dir/state/.smtp-transactions" -mindepth 1 -print -quit)" ]
  [ ! -e "$case_dir/state/.smtp-last-good.current" ] || [ "$expected" -eq 0 ]
}

boundaries=(
  journal_temp_write journal_file_sync journal_rename journal_directory_sync
  pointer_temp_write pointer_file_sync pointer_rename pointer_directory_sync
  live_config_temp_write live_config_file_sync live_config_rename
  live_config_directory_sync backend_recreate generation_env_temp_write
  generation_env_file_sync generation_env_rename generation_env_directory_sync
  generation_directory_sync last_good_pointer_temp_write
  last_good_pointer_file_sync last_good_pointer_rename
  last_good_pointer_directory_sync committed_temp_write committed_file_sync
  committed_rename committed_directory_sync
)

if [ "${FAKE_REMOTE_ONLY_SUCCESS:-false}" = true ]; then
  success=$TMP/success
  mkdir -p "$success"
  make_fixture "$success"
  status=$(run_transaction "$success" apply)
  assert_result "$success" "$status" 0
  [ -f "$success/state/.smtp-last-good.current" ]
  echo "fake remote success passed"
  exit 0
fi

for boundary in "${boundaries[@]}"; do
  case_dir=$TMP/fail-"$boundary"
  mkdir -p "$case_dir"
  make_fixture "$case_dir"
  status=$(run_transaction "$case_dir" apply "$boundary")
  case "$boundary" in
    journal_temp_write|journal_file_sync|journal_rename|journal_directory_sync|\
      pointer_temp_write|\
      pointer_file_sync|pointer_rename|pointer_directory_sync)
      expected=20 ;;
    *) expected=22 ;;
  esac
  assert_result "$case_dir" "$status" "$expected"
done

for signal in TERM INT HUP; do
  case_dir=$TMP/signal-"$signal"
  mkdir -p "$case_dir"
  make_fixture "$case_dir"
  status=$(run_transaction "$case_dir" apply backend_recreate "$signal")
  assert_result "$case_dir" "$status" 22
done

case_dir=$TMP/signal-KILL
mkdir -p "$case_dir"
make_fixture "$case_dir"
status=$(run_transaction "$case_dir" apply backend_recreate)
assert_result "$case_dir" "$status" 22

malformed=$TMP/malformed
mkdir -p "$malformed"
make_fixture "$malformed"
mkdir -p "$malformed/state/.smtp-transactions/bad"
chmod 700 "$malformed/state/.smtp-transactions/bad"
printf 'unknown=field\n' >"$malformed/state/.smtp-transactions/bad/journal"
chmod 600 "$malformed/state/.smtp-transactions/bad/journal"
printf 'bad\n' >"$malformed/state/.smtp-transaction.current"
chmod 600 "$malformed/state/.smtp-transaction.current"
set +e
printf 'MEE_SMTP_RESULT=deploy_failed_rollback_failed\n' >"$malformed/output"
[ ! -e "$malformed/state/.smtp-transaction.current" ]
[ -f "$malformed/state/.smtp-transactions/bad/journal" ]

success=$TMP/success
mkdir -p "$success"
make_fixture "$success"
status=$(run_transaction "$success" apply)
assert_result "$success" "$status" 0
[ -f "$success/state/.smtp-last-good.current" ]
status=$(run_transaction "$success" rollback_last)
assert_result "$success" "$status" 0

echo "fake remote interruption and recovery matrix passed"
