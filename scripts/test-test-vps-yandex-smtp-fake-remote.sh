#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TOOL=$ROOT_DIR/scripts/configure-test-vps-yandex-smtp.sh
TIMEOUT=$(command -v timeout)
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
  mkdir -p "$bin" "$root" "$production" "$state"
  cat >"$root/.env.production" <<'ENV'
BACKEND_IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
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
exit 0
DOCKER
  chmod 755 "$bin/docker"
  cat >"$bin/jq" <<'JQ'
#!/usr/bin/env bash
exit 0
JQ
  chmod 755 "$bin/jq"
  cat >"$bin/flock" <<'FLOCK'
#!/usr/bin/env bash
[ "${MEE_SMTP_FAKE_LOCK_FILE:-}" != "" ] &&
  [ -e "$MEE_SMTP_FAKE_LOCK_FILE" ] &&
  exit 1
exit 0
FLOCK
  chmod 755 "$bin/flock"
  cat >"$bin/stat" <<'STAT'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %a ]; then
  path=${@: -1}
  [ -d "$path" ] && printf '700\n' || printf '600\n'
  exit 0
fi
exec /usr/bin/stat "$@"
STAT
  chmod 755 "$bin/stat"
  cat >"$bin/install" <<'INSTALL'
#!/usr/bin/env bash
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

run_tool() {
  local case_dir=$1
  local boundary=${2:-}
  local signal=${3:-TERM}
  local fail_at=${4:-}
  local output=$case_dir/output
  local error=$case_dir/error
  local status
  if env \
    PATH="$case_dir/bin:$PATH" \
    TEST_VPS_STATE_ROOT="$case_dir/state" \
    PRODUCTION_STATE_DIR="$case_dir/production" \
    MEE_SMTP_FAKE_LOCK_FILE="$case_dir/lock-busy" \
    MEE_SMTP_FAKE_REMOTE=true \
    MEE_SMTP_INTERRUPT_BOUNDARY="$boundary" \
    MEE_SMTP_INTERRUPT_SIGNAL="$signal" \
    MEE_SMTP_FAIL_AT="$fail_at" \
    "$TIMEOUT" 120 \
    "$TOOL" --root "$case_dir/root" \
      --base-compose "$case_dir/compose.yml" \
      --run-key fake-remote \
      --mode apply \
      --payload-file "$case_dir/payload" \
      >"$output" 2>"$error"; then
    status=0
  else
    status=$?
  fi
  printf '%s' "$status"
}

assert_result_line() {
  local case_dir=$1
  local expected=$2
  [ "$(wc -l <"$case_dir/output")" -eq 1 ]
  grep -Fxq "MEE_SMTP_RESULT=$expected" "$case_dir/output"
}

assert_success() {
  local case_dir=$1
  local status
  status=$(run_tool "$case_dir")
  [ "$status" -eq 0 ] || {
    echo "unexpected clean status=$status case=$case_dir" >&2
    sed -n '1,80p' "$case_dir/error" >&2 || true
    sed -n '1,20p' "$case_dir/output" >&2 || true
    return 1
  }
  assert_result_line "$case_dir" deploy_succeeded
  [ -f "$case_dir/state/.smtp-last-good.current" ]
  [ ! -e "$case_dir/state/.smtp-transaction.current" ]
  [ -z "$(find "$case_dir/state/.smtp-transactions" -mindepth 1 -print -quit)" ]
}

assert_interrupted() {
  local case_dir=$1
  local boundary=$2
  local status
  status=$(run_tool "$case_dir" "$boundary" TERM)
  case "$status" in
    20|22) ;;
    *)
      echo "unexpected interruption status=$status boundary=$boundary" >&2
      sed -n '1,80p' "$case_dir/error" >&2 || true
      sed -n '1,20p' "$case_dir/output" >&2 || true
      return 1
      ;;
  esac
  grep -Eq \
    '^MEE_SMTP_RESULT=(precheck_failed|deploy_failed_rollback_succeeded)$' \
    "$case_dir/output"
  assert_success "$case_dir"
}

boundaries=(
  journal_rename pointer_rename generation_env_rename
  live_config_rename last_good_pointer_rename
  committed_rename
)

for boundary in "${boundaries[@]}"; do
  [ -z "${FAKE_REMOTE_BOUNDARY_ONLY:-}" ] ||
    [ "$boundary" = "$FAKE_REMOTE_BOUNDARY_ONLY" ] || continue
  case_dir=$TMP/interrupt-"$boundary"
  mkdir -p "$case_dir"
  make_fixture "$case_dir"
  assert_interrupted "$case_dir" "$boundary"
done

[ -n "${FAKE_REMOTE_BOUNDARY_ONLY:-}" ] &&
  [ "${FAKE_REMOTE_RUN_SPECIALS:-false}" != true ] && exit 0

case_dir=$TMP/sigkill
mkdir -p "$case_dir"
make_fixture "$case_dir"
status=$(run_tool "$case_dir" backend_recreate KILL)
[ "$status" -eq 137 ] || {
  echo "expected SIGKILL status 137, got $status" >&2
  exit 1
}
status=$(run_tool "$case_dir")
[ "$status" -eq 22 ]
assert_result_line "$case_dir" deploy_failed_rollback_succeeded
assert_success "$case_dir"

case_dir=$TMP/lock
mkdir -p "$case_dir"
make_fixture "$case_dir"
: >"$case_dir/lock-busy"
status=$(run_tool "$case_dir")
[ "$status" -eq 21 ]
assert_result_line "$case_dir" lock_busy

case_dir=$TMP/malformed-active
mkdir -p "$case_dir"
make_fixture "$case_dir"
mkdir "$case_dir/production/active-compose.yml"
status=$(run_tool "$case_dir")
[ "$status" -eq 20 ]
assert_result_line "$case_dir" precheck_failed

case_dir=$TMP/orphan
mkdir -p "$case_dir"
make_fixture "$case_dir"
assert_success "$case_dir"
selected=$(<"$case_dir/state/.smtp-last-good.current")
generations=$case_dir/state/.smtp-last-good-generations
orphan_generation=orphan-candidate
cp -a "$generations/$selected" "$generations/$orphan_generation"
sed -i "s/^generation=.*/generation=$orphan_generation/" \
  "$generations/$orphan_generation/manifest"
chmod 700 "$generations/$orphan_generation"
chmod 600 "$generations/$orphan_generation/env" \
  "$generations/$orphan_generation/manifest"
tx=$case_dir/state/.smtp-transactions/orphan
mkdir -p "$tx"
chmod 700 "$tx"
cp "$case_dir/root/.env.production" "$tx/env.before"
cp "$case_dir/root/.env.production" "$tx/candidate.env"
printf '%s\n' "$(sha256sum "$case_dir/root/.env.production" | awk '{print $1}')" \
  >"$tx/pre-config.sha256"
printf 'absent\n' >"$tx/no-active-compose"
printf 'absent\n' >"$tx/no-active-runtime"
chmod 600 "$tx/env.before" "$tx/candidate.env" "$tx/pre-config.sha256" \
  "$tx/no-active-compose" "$tx/no-active-runtime"
prior_generation_sha256=$(sha256sum "$generations/$selected/manifest" | awk '{print $1}')
pre_config_sha256=$(sha256sum "$case_dir/root/.env.production" | awk '{print $1}')
cat >"$tx/journal" <<JOURNAL
version=1
transaction_id=orphan
phase=RECOVERED
critical=false
pre_config_sha256=$pre_config_sha256
pre_runtime_fingerprint=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
prior_selector=present
prior_selector_value=$selected
prior_generation_sha256=$prior_generation_sha256
candidate_generation=$orphan_generation
candidate_runtime_fingerprint=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
terminal_category=deploy_failed_rollback_succeeded
terminal_status=22
terminal_fingerprint=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
JOURNAL
chmod 600 "$tx/journal"
status=$(run_tool "$case_dir")
[ "$status" -eq 0 ]
assert_result_line "$case_dir" deploy_succeeded
[ ! -e "$generations/$orphan_generation" ]

echo "fake remote configure transaction matrix passed"
