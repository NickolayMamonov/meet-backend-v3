#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TOOL=$ROOT_DIR/scripts/configure-test-vps-yandex-smtp.sh
TIMEOUT=$(command -v timeout)
TIMEOUT_SECONDS=${FAKE_REMOTE_CASE_TIMEOUT_SECONDS:-180}
WAIT_SECONDS=${FAKE_REMOTE_WAIT_SECONDS:-240}
TMP=$(mktemp -d)
active_pids=()

descendant_pids() {
  local parent=$1 proc pid ppid
  for proc in /proc/[0-9]*/stat; do
    pid=${proc#/proc/}
    pid=${pid%/stat}
    [ -r "$proc" ] || continue
    read -r _ _ _ ppid _ <"$proc" || continue
    if [ "$ppid" = "$parent" ]; then
      descendant_pids "$pid"
      printf '%s\n' "$pid"
    fi
  done
}

terminate_case_pid() {
  local pid=$1
  local -a descendants=()
  mapfile -t descendants < <(descendant_pids "$pid")
  kill -TERM "$pid" "${descendants[@]}" 2>/dev/null || true
  kill -TERM -- "-$pid" 2>/dev/null || true
  sleep 0.1
  mapfile -t descendants < <(descendant_pids "$pid")
  kill -KILL "$pid" "${descendants[@]}" 2>/dev/null || true
  kill -KILL -- "-$pid" 2>/dev/null || true
}

reap_active_cases() {
  local pid
  for pid in "${active_pids[@]}"; do
    terminate_case_pid "$pid"
  done
  for pid in "${active_pids[@]}"; do
    wait_case_pid "$pid" || true
  done
  active_pids=()
}

reap_task_processes() {
  local proc pid command_line
  for proc in /proc/[0-9]*/cmdline; do
    pid=${proc#/proc/}
    pid=${pid%/cmdline}
    [ "$pid" -ne "$$" ] || continue
    command_line=
    if [ -r "$proc" ]; then
      command_line=$(tr '\0' ' ' "$proc" 2>/dev/null || true)
    fi
    case "$command_line" in *"$TMP/"*) terminate_case_pid "$pid" ;; esac
  done
}

cleanup() {
  reap_active_cases
  reap_task_processes
  [ "${KEEP_FAKE_REMOTE:-false}" = true ] && return
  find "$TMP" -xdev -depth -type f -delete 2>/dev/null || true
  find "$TMP" -xdev -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup EXIT

assert_no_task_processes() {
  local proc pid command_line
  for proc in /proc/[0-9]*/cmdline; do
    pid=${proc#/proc/}
    pid=${pid%/cmdline}
    [ "$pid" -ne "$$" ] || continue
    command_line=
    if [ -r "$proc" ]; then
      command_line=$(tr '\0' ' ' "$proc" 2>/dev/null || true)
    fi
    case "$command_line" in
      *"$TMP/"*)
        echo "task-owned case process survived matrix: pid=$pid command=$command_line" >&2
        return 1
        ;;
    esac
  done
  echo "zero_survivors=0"
}

write_payload() {
  local payload_file=$1
  : >"$payload_file"
  printf 'APP_EMAIL_PROVIDER=smtp\0' >>"$payload_file"
  printf 'APP_EMAIL_FROM=canary@example.test\0' >>"$payload_file"
  printf 'APP_EMAIL_FROM_NAME=Canary Sender\0' >>"$payload_file"
  printf 'SPRING_MAIL_HOST=smtp.yandex.ru\0' >>"$payload_file"
  printf 'SPRING_MAIL_PORT=587\0' >>"$payload_file"
  printf 'SPRING_MAIL_USERNAME=canary-user\0' >>"$payload_file"
  printf 'SPRING_MAIL_PASSWORD=canary-password\0' >>"$payload_file"
  printf 'APP_EMAIL_CONNECT_TIMEOUT_MS=1000\0' >>"$payload_file"
  printf 'APP_EMAIL_READ_TIMEOUT_MS=1000\0' >>"$payload_file"
  printf 'APP_EMAIL_WRITE_TIMEOUT_MS=1000\0' >>"$payload_file"
  chmod 600 "$payload_file"
}

make_fixture() {
  local case_dir=$1
  local bin=$case_dir/bin
  local root=$case_dir/root
  local production=$case_dir/production
  local state=$case_dir/state
  mkdir -p "$bin" "$root" "$production" "$state"
  printf '%s\n' \
    'BACKEND_IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'BACKEND_VERSION=1.2.3' \
    'BACKEND_REVISION=0123456789012345678901234567890123456789' \
    'APP_JWT_SECRET=non-email-jwt' \
    'TIMEPAD_TOKEN=non-email-timepad' \
    'APP_EMAIL_PROVIDER=disabled' \
    'APP_EMAIL_FROM=old@example.test' \
    'APP_EMAIL_FROM_NAME=Old Sender' \
    'SPRING_MAIL_HOST=old.example.test' \
    'SPRING_MAIL_PORT=2525' \
    'SPRING_MAIL_USERNAME=old-user' \
    'SPRING_MAIL_PASSWORD=old-password' \
    'APP_EMAIL_CONNECT_TIMEOUT_MS=1000' \
    'APP_EMAIL_READ_TIMEOUT_MS=1000' \
    'APP_EMAIL_WRITE_TIMEOUT_MS=1000' \
    >"$root/.env.production"
  chmod 600 "$root/.env.production"
  printf '%s\n' 'services:' '  backend:' '  postgres:' >"$case_dir/compose.yml"
  chmod 600 "$case_dir/compose.yml"
  if [ "${FAKE_REMOTE_ABSENT_ACTIVE:-false}" != true ]; then
    printf '%s\n' 'services:' '  backend:' '  postgres:' \
      >"$production/active-compose.yml"
    printf '%s\n' 'services:' '  backend:' \
      >"$production/active-runtime.override.yml"
    chmod 600 "$production/active-compose.yml" \
      "$production/active-runtime.override.yml"
  fi
  write_payload "$case_dir/payload"

  printf '%s\n' '#!/usr/bin/bash' 'exit 0' >"$bin/docker"
  chmod 755 "$bin/docker"
  printf '%s\n' '#!/usr/bin/bash' 'exit 0' >"$bin/jq"
  chmod 755 "$bin/jq"
  printf '%s\n' \
    '#!/usr/bin/bash' \
    '[ "${MEE_SMTP_FAKE_LOCK_FILE:-}" != "" ] &&' \
    '  [ -e "$MEE_SMTP_FAKE_LOCK_FILE" ] &&' \
    '  exit 1' \
    'exit 0' >"$bin/flock"
  chmod 755 "$bin/flock"
  printf '%s\n' \
    '#!/usr/bin/bash' \
    'if [ "${1:-}" = -c ] && [ "${2:-}" = %a ]; then' \
    '  path=${@: -1}' \
    '  [ -d "$path" ] && printf "700\n" || printf "600\n"' \
    '  exit 0' \
    'fi' \
    'exec /usr/bin/stat "$@"' >"$bin/stat"
  chmod 755 "$bin/stat"
  printf '%s\n' \
    '#!/usr/bin/bash' \
    'args=()' \
    'skip=false' \
    'for arg in "$@"; do' \
    '  if [ "$skip" = true ]; then' \
    '    skip=false' \
    '  elif [ "$arg" = -m ]; then' \
    '    skip=true' \
    '  else' \
    '    args+=("$arg")' \
    '  fi' \
    'done' \
    'exec /usr/bin/install "${args[@]}"' >"$bin/install"
  chmod 755 "$bin/install"
}

run_tool() {
  local case_dir=$1
  local boundary=${2:-}
  local signal=${3:-TERM}
  local fail_at=${4:-}
  local mode=${5:-apply}
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
    MEE_SMTP_FAKE_COMPOSE_LOG="$case_dir/compose.log" \
    "$TIMEOUT" -k 1 "$TIMEOUT_SECONDS" \
    "$TOOL" --root "$case_dir/root" \
      --base-compose "$case_dir/compose.yml" \
      --run-key fake-remote \
      --mode "$mode" \
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
  case "$boundary" in
    env_before_file_sync|pre_config_file_sync|active_compose_before_file_sync|\
      had_active_compose_file_sync|no_active_compose_file_sync|\
      active_runtime_before_file_sync|had_active_runtime_file_sync|\
      no_active_runtime_file_sync|candidate_env_file_sync|snapshot_directory|\
      transaction_directory|journal_file_sync|journal_rename|\
      journal_directory_sync|pointer_temp_write|pointer_file_sync|pointer_rename|\
      generation_env_temp_write|generation_env_file_sync|generation_env_rename|\
      generation_directory_sync)
      expected=20
      ;;
    pointer_directory_sync)
      expected=23
      ;;
    live_config_temp_write|live_config_file_sync|live_config_rename|\
      live_config_directory_sync|backend_recreate)
      expected=23
      ;;
    journal_temp_write)
      expected=23
      ;;
    committed_temp_write)
      expected=23
      ;;
    committed_directory_sync)
      expected=0
      ;;
    committed_rename)
      expected=22
      ;;
    *)
      expected=22
      ;;
  esac
  case "$status" in
    "$expected") ;;
    *)
      echo "unexpected interruption status=$status expected=$expected boundary=$boundary" >&2
      sed -n '1,80p' "$case_dir/error" >&2 || true
      sed -n '1,20p' "$case_dir/output" >&2 || true
      return 1
      ;;
  esac
  case "$expected" in
    20) assert_result_line "$case_dir" precheck_failed ;;
    23) assert_result_line "$case_dir" deploy_failed_rollback_failed ;;
    0) assert_result_line "$case_dir" deploy_succeeded ;;
    *) assert_result_line "$case_dir" deploy_failed_rollback_succeeded ;;
  esac
  if [ "$expected" -ne 23 ]; then
    [ ! -e "$case_dir/state/.smtp-transaction.current" ]
  fi
  [ ! -e "$case_dir/payload" ]
}

pre_pointer_boundaries=(
  env_before_file_sync pre_config_file_sync
  active_compose_before_file_sync had_active_compose_file_sync
  no_active_compose_file_sync active_runtime_before_file_sync
  had_active_runtime_file_sync no_active_runtime_file_sync
  candidate_env_file_sync snapshot_directory transaction_directory
  journal_temp_write journal_file_sync journal_rename journal_directory_sync
  pointer_temp_write pointer_file_sync pointer_rename pointer_directory_sync
)
post_pointer_boundaries=(
  live_config_temp_write live_config_file_sync
  live_config_rename live_config_directory_sync backend_recreate
  last_good_pointer_temp_write last_good_pointer_file_sync
  last_good_pointer_rename last_good_pointer_directory_sync
  committed_temp_write committed_file_sync committed_rename
  committed_directory_sync
)
cleanup_boundaries=(
  pointer_clear_temp_temp_write pointer_clear_temp_file_sync
  pointer_clear_temp_rename pointer_clear_temp_directory_sync
  pointer_unlink pointer_root_sync transaction_delete
  transaction_directory_sync
)
recovery_boundaries=(
  recovered_temp_write recovered_file_sync recovered_rename
  recovered_directory_sync
)
parallelism=${FAKE_REMOTE_PARALLELISM:-2}
[[ "$parallelism" =~ ^[1-9][0-9]*$ ]] || exit 2

wait_batch() {
  local pid
  local batch_status=0
  local child_status
  for pid in "$@"; do
    if wait_case_pid "$pid"; then
      continue
    else
      child_status=$?
      [ "$batch_status" -ne 0 ] || batch_status=$child_status
    fi
  done
  active_pids=()
  return "$batch_status"
}

wait_case_pid() {
  local pid=$1
  local deadline=$((SECONDS + WAIT_SECONDS))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      terminate_case_pid "$pid"
      reap_task_processes
      break
    fi
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
}

run_interrupt_case() {
  local boundary=$1
  case_dir=$TMP/interrupt-"$boundary"
  mkdir -p "$case_dir"
  if [[ "$boundary" == no_active_* ]]; then
    FAKE_REMOTE_ABSENT_ACTIVE=true make_fixture "$case_dir"
  else
    make_fixture "$case_dir"
  fi
  assert_interrupted "$case_dir" "$boundary" || {
    echo "interruption case failed boundary=$boundary" >&2
    return 1
  }
}

pids=()
for boundary in "${pre_pointer_boundaries[@]}" "${post_pointer_boundaries[@]}"; do
  [ -z "${FAKE_REMOTE_FAIL_ONLY:-}" ] || continue
  [ -z "${FAKE_REMOTE_BOUNDARY_ONLY:-}" ] ||
    [ "$boundary" = "$FAKE_REMOTE_BOUNDARY_ONLY" ] || continue
  run_interrupt_case "$boundary" &
  pids+=("$!")
  active_pids=("${pids[@]}")
  if [ "${#pids[@]}" -ge "$parallelism" ]; then
    wait_batch "${pids[@]}"
    assert_no_task_processes
    pids=()
  fi
done
wait_batch "${pids[@]}"
assert_no_task_processes

[ -n "${FAKE_REMOTE_BOUNDARY_ONLY:-}" ] &&
  [ "${FAKE_REMOTE_RUN_SPECIALS:-false}" != true ] && exit 0

run_failure_case() {
  local boundary=$1
  case_dir=$TMP/failure-"$boundary"
  mkdir -p "$case_dir"
  if [[ "$boundary" == no_active_* ]]; then
    FAKE_REMOTE_ABSENT_ACTIVE=true make_fixture "$case_dir"
  else
    make_fixture "$case_dir"
  fi
  if [[ "$boundary" == recovered_* ]]; then
    status=$(run_tool "$case_dir" backend_recreate KILL)
    [ "$status" -eq 137 ] || exit 1
    status=$(run_tool "$case_dir" '' TERM "$boundary")
  else
    status=$(run_tool "$case_dir" '' TERM "$boundary")
  fi
  case "$boundary:$status" in
    committed_directory_sync:0|\
      pointer_clear_temp_temp_write:0|pointer_clear_temp_file_sync:0|\
      pointer_clear_temp_rename:0|pointer_clear_temp_directory_sync:0|\
      pointer_unlink:0|pointer_root_sync:0|transaction_delete:0|\
      transaction_directory_sync:0)
      assert_result_line "$case_dir" deploy_succeeded
      return 0
      ;;
    *:20|*:22|*:23) ;;
    *)
      echo "unexpected injected-failure status=$status boundary=$boundary" >&2
      sed -n '1,80p' "$case_dir/error" >&2 || true
      sed -n '1,20p' "$case_dir/output" >&2 || true
      exit 1
      ;;
  esac
  grep -Eq \
    '^MEE_SMTP_RESULT=(deploy_succeeded|precheck_failed|deploy_failed_rollback_succeeded|deploy_failed_rollback_failed)$' \
    "$case_dir/output" || {
      echo "unexpected injected-failure result boundary=$boundary status=$status" >&2
      sed -n '1,80p' "$case_dir/error" >&2 || true
      sed -n '1,20p' "$case_dir/output" >&2 || true
      exit 1
    }
}

pids=()
for boundary in "${pre_pointer_boundaries[@]}" "${post_pointer_boundaries[@]}" \
  "${cleanup_boundaries[@]}" "${recovery_boundaries[@]}"; do
  [ -z "${FAKE_REMOTE_FAIL_ONLY:-}" ] ||
    [ "$boundary" = "${FAKE_REMOTE_FAIL_ONLY}" ] || continue
  run_failure_case "$boundary" &
  pids+=("$!")
  active_pids=("${pids[@]}")
  if [ "${#pids[@]}" -ge "$parallelism" ]; then
    wait_batch "${pids[@]}"
    assert_no_task_processes
    pids=()
  fi
done
wait_batch "${pids[@]}"
assert_no_task_processes

[ -n "${FAKE_REMOTE_FAIL_ONLY:-}" ] &&
  [ "${FAKE_REMOTE_RUN_SPECIALS:-false}" != true ] && exit 0

case_dir=$TMP/sigkill
mkdir -p "$case_dir"
make_fixture "$case_dir"
status=$(run_tool "$case_dir" backend_recreate KILL)
[ "$status" -eq 137 ] || {
  echo "expected SIGKILL status 137, got $status" >&2
  sed -n '1,80p' "$case_dir/error" >&2 || true
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}
status=$(run_tool "$case_dir")
[ "$status" -eq 22 ] || {
  echo "unexpected SIGKILL recovery status=$status" >&2
  sed -n '1,80p' "$case_dir/error" >&2 || true
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}
assert_result_line "$case_dir" deploy_failed_rollback_succeeded || {
  echo "unexpected SIGKILL recovery result" >&2
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}

for signal in INT HUP; do
  case_dir=$TMP/signal-"$signal"
  mkdir -p "$case_dir"
  make_fixture "$case_dir"
  status=$(run_tool "$case_dir" backend_recreate "$signal")
  [ "$status" -eq 22 ] || {
    echo "unexpected signal status=$status signal=$signal" >&2
    sed -n '1,80p' "$case_dir/error" >&2 || true
    sed -n '1,20p' "$case_dir/output" >&2 || true
    exit 1
  }
  assert_result_line "$case_dir" deploy_failed_rollback_succeeded
done

for boundary in "${recovery_boundaries[@]}"; do
  case_dir=$TMP/recovery-"$boundary"
  mkdir -p "$case_dir"
  make_fixture "$case_dir"
  status=$(run_tool "$case_dir" backend_recreate KILL)
  [ "$status" -eq 137 ] || exit 1
  status=$(run_tool "$case_dir" "$boundary" TERM)
  case "$status" in
    129|130|143|22) ;;
    *)
      echo "unexpected recovery publication status=$status boundary=$boundary" >&2
      exit 1
      ;;
  esac
  status=$(run_tool "$case_dir")
  expected_recovery_status=22
  expected_recovery_result=deploy_failed_rollback_succeeded
  if [ "$boundary" = recovered_temp_write ]; then
    expected_recovery_status=23
    expected_recovery_result=deploy_failed_rollback_failed
  fi
  [ "$status" -eq "$expected_recovery_status" ] || {
    echo "unexpected recovery cleanup status=$status boundary=$boundary" >&2
    sed -n '1,80p' "$case_dir/error" >&2 || true
    sed -n '1,20p' "$case_dir/output" >&2 || true
    exit 1
  }
  assert_result_line "$case_dir" "$expected_recovery_result" || {
    echo "unexpected recovery cleanup result boundary=$boundary" >&2
    sed -n '1,20p' "$case_dir/output" >&2 || true
    exit 1
  }
done

case_dir=$TMP/success
mkdir -p "$case_dir"
make_fixture "$case_dir"
assert_success "$case_dir" || {
  echo "clean success case failed" >&2
  sed -n '1,80p' "$case_dir/error" >&2 || true
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}

case_dir=$TMP/rollback-last
mkdir -p "$case_dir"
make_fixture "$case_dir"
assert_success "$case_dir"
selected_env="$case_dir/state/.smtp-last-good-generations/$(<"$case_dir/state/.smtp-last-good.current")/env"
cp -- "$case_dir/root/.env.production" "$case_dir/rollback-live.env"
sed -i 's/^APP_EMAIL_FROM=.*/APP_EMAIL_FROM=changed@example.test/' \
  "$case_dir/root/.env.production"
status=$(run_tool "$case_dir" '' TERM '' rollback_last)
[ "$status" -eq 0 ] || {
  echo "unexpected rollback_last status=$status" >&2
  sed -n '1,80p' "$case_dir/error" >&2 || true
  exit 1
}
assert_result_line "$case_dir" deploy_succeeded
cmp --silent "$selected_env" "$case_dir/root/.env.production"
status=$(run_tool "$case_dir" '' TERM '' rollback_last)
[ "$status" -eq 0 ] || exit 1
assert_result_line "$case_dir" deploy_succeeded
cmp --silent "$selected_env" "$case_dir/root/.env.production"

case_dir=$TMP/rollback-last-missing
mkdir -p "$case_dir"
make_fixture "$case_dir"
status=$(run_tool "$case_dir" '' TERM '' rollback_last)
[ "$status" -eq 20 ] || exit 1
assert_result_line "$case_dir" precheck_failed
[ ! -e "$case_dir/state/.smtp-transaction.current" ]

case_dir=$TMP/malformed-selector
mkdir -p "$case_dir"
make_fixture "$case_dir"
assert_success "$case_dir"
printf '%s\n' 'not-a-valid-generation!' >"$case_dir/state/.smtp-last-good.current"
chmod 600 "$case_dir/state/.smtp-last-good.current"
status=$(run_tool "$case_dir")
[ "$status" -eq 20 ] || exit 1
assert_result_line "$case_dir" precheck_failed

case_dir=$TMP/malformed-transaction-pointer
mkdir -p "$case_dir"
make_fixture "$case_dir"
printf '%s\n' 'malformed-pointer' >"$case_dir/state/.smtp-transaction.current"
chmod 600 "$case_dir/state/.smtp-transaction.current"
status=$(run_tool "$case_dir")
[ "$status" -eq 23 ] || exit 1
assert_result_line "$case_dir" deploy_failed_rollback_failed

case_dir=$TMP/active-compose-rollback
mkdir -p "$case_dir"
make_fixture "$case_dir"
status=$(run_tool "$case_dir" backend_recreate TERM)
case "$status" in 22|23) ;;
  *) exit 1 ;;
esac
assert_result_line "$case_dir" deploy_failed_rollback_succeeded
grep -Fq 'active-compose.before|config -q' "$case_dir/compose.log"
grep -Fq 'active-compose.before|up -d --no-deps --no-build --pull never --force-recreate --wait --wait-timeout 180 backend' \
  "$case_dir/compose.log"

case_dir=$TMP/lock
mkdir -p "$case_dir"
make_fixture "$case_dir"
: >"$case_dir/lock-busy"
status=$(run_tool "$case_dir")
[ "$status" -eq 21 ] || {
  echo "unexpected lock status=$status" >&2
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}
assert_result_line "$case_dir" lock_busy || {
  echo "unexpected lock result" >&2
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}

case_dir=$TMP/malformed-active
mkdir -p "$case_dir"
make_fixture "$case_dir"
rm -f "$case_dir/production/active-compose.yml"
mkdir "$case_dir/production/active-compose.yml"
status=$(run_tool "$case_dir")
[ "$status" -eq 20 ] || {
  echo "unexpected malformed-active status=$status" >&2
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}
assert_result_line "$case_dir" precheck_failed || {
  echo "unexpected malformed-active result" >&2
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}

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
write_payload "$case_dir/payload"
status=$(run_tool "$case_dir")
[ "$status" -eq 0 ] || {
  echo "unexpected orphan cleanup status=$status" >&2
  sed -n '1,80p' "$case_dir/error" >&2 || true
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}
assert_result_line "$case_dir" deploy_succeeded || {
  echo "unexpected orphan cleanup result" >&2
  sed -n '1,20p' "$case_dir/output" >&2 || true
  exit 1
}
[ ! -e "$generations/$orphan_generation" ] || {
  echo "orphan generation was not removed" >&2
  exit 1
}

assert_no_task_processes
echo "fake remote configure transaction matrix passed"
