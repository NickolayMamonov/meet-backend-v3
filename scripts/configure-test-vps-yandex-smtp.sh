#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --root PATH --base-compose PATH --run-key KEY --mode apply|rollback_last --payload-file PATH" >&2
  exit 2
}

RESULT_CATEGORY=
RESULT_STATUS=
result() {
  RESULT_CATEGORY=$1
  RESULT_STATUS=$2
  printf 'MEE_SMTP_RESULT=%s\n' "$RESULT_CATEGORY"
  return 0
}

fail_result() {
  local category=$1
  local status=$2
  result "$category" "$status"
  exit "$status"
}

root=
base_compose=
run_key=
mode=
payload_file=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] && [ -z "$root" ] || usage; root=$2; shift 2 ;;
    --base-compose) [ "$#" -ge 2 ] && [ -z "$base_compose" ] || usage; base_compose=$2; shift 2 ;;
    --run-key) [ "$#" -ge 2 ] && [ -z "$run_key" ] || usage; run_key=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] && [ -z "$mode" ] || usage; mode=$2; shift 2 ;;
    --payload-file) [ "$#" -ge 2 ] && [ -z "$payload_file" ] || usage; payload_file=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$root" != *..* ]] || usage
[[ "$base_compose" =~ ^/[A-Za-z0-9._/-]+$ ]] &&
  [[ "$base_compose" != *..* ]] || usage
[[ "$run_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
case "$mode" in apply|rollback_last) ;; *) usage ;; esac
if [ "$mode" = apply ]; then
  [ -n "$payload_file" ] || usage
  [[ "$payload_file" =~ ^/[A-Za-z0-9._/-]+$ ]] || usage
fi

for command_name in awk cp curl date docker find flock grep install mktemp mv sha256sum stat sync wc; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail_result precheck_failed 20
done
[ "$(id -u)" -eq 0 ] || fail_result precheck_failed 20
[ -d "$root" ] && [ -s "$root/.env.production" ] ||
  fail_result precheck_failed 20
[ -s "$base_compose" ] || fail_result precheck_failed 20
[ -x "$(dirname -- "${BASH_SOURCE[0]}")/production-compose.sh" ] ||
  fail_result precheck_failed 20
[ -x "$(dirname -- "${BASH_SOURCE[0]}")/production-config-digest.sh" ] ||
  fail_result precheck_failed 20
if [ "$mode" = apply ]; then
  [ -f "$payload_file" ] && [ ! -L "$payload_file" ] ||
    fail_result precheck_failed 20
  [ "$(stat -c '%a' "$payload_file" 2>/dev/null)" = 600 ] ||
    fail_result precheck_failed 20
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compose_script=$script_dir/production-compose.sh
runtime_helper=$script_dir/test-vps-runtime-invariants.sh
# shellcheck source=/dev/null
source "$runtime_helper"

state_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
transactions=$state_root/.smtp-transactions
generations=$state_root/.smtp-last-good-generations
pointer=$state_root/.smtp-transaction.current
selector=$state_root/.smtp-last-good.current
active_compose=/var/lib/meet-production/active-compose.yml
active_runtime=/var/lib/meet-production/active-runtime.override.yml
mkdir -p "$transactions" "$generations"
chmod 700 "$state_root" "$transactions" "$generations"
exec 9>"$state_root/.deploy.lock"
if ! flock -n 9; then
  fail_result lock_busy 21
fi

sync_probe=$(mktemp "$state_root/.smtp-sync-probe.XXXXXX")
chmod 600 "$sync_probe"
if ! sync -f "$sync_probe" || ! sync -f "$state_root"; then
  rm -f -- "$sync_probe"
  fail_result precheck_failed 20
fi
rm -f -- "$sync_probe"

interrupt_boundary() {
  local name=$1
  case "${MEE_SMTP_INTERRUPT_BOUNDARY:-}" in
    "$name"|"$name:before"|"$name:after")
      kill -TERM "$$"
      ;;
  esac
  [ "${MEE_SMTP_FAIL_AT:-}" != "$name" ] ||
    return 1
  return 0
}

sync_file() {
  local file=$1
  interrupt_boundary "$2:before"
  sync -f "$file"
  interrupt_boundary "$2:after"
}

sync_directory() {
  local directory=$1
  interrupt_boundary "$2:before"
  sync -f "$directory"
  interrupt_boundary "$2:after"
}

atomic_copy() {
  local source=$1
  local target=$2
  local mode_bits=$3
  local boundary_name=${4:-atomic_file}
  local temporary
  temporary=$(mktemp "$target.tmp.XXXXXX")
  chmod "$mode_bits" "$temporary"
  interrupt_boundary "${boundary_name}_temp_write"
  cp -- "$source" "$temporary"
  chmod "$mode_bits" "$temporary"
  sync_file "$temporary" "${boundary_name}_file_sync"
  interrupt_boundary "${boundary_name}_rename"
  mv -f -- "$temporary" "$target"
  sync_directory "$(dirname -- "$target")" "${boundary_name}_directory_sync"
}

atomic_text() {
  local text=$1
  local target=$2
  local mode_bits=$3
  local boundary_name=${4:-atomic_file}
  local temporary
  temporary=$(mktemp "$target.tmp.XXXXXX")
  chmod "$mode_bits" "$temporary"
  interrupt_boundary "${boundary_name}_temp_write"
  printf '%s' "$text" >"$temporary"
  chmod "$mode_bits" "$temporary"
  sync_file "$temporary" "${boundary_name}_file_sync"
  interrupt_boundary "${boundary_name}_rename"
  mv -f -- "$temporary" "$target"
  sync_directory "$(dirname -- "$target")" "${boundary_name}_directory_sync"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

safe_selector_value() {
  [ -f "$selector" ] && [ ! -L "$selector" ] || return 1
  [ "$(wc -l <"$selector")" -eq 1 ] || return 1
  local value
  value=$(<"$selector")
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s' "$value"
}

validate_generation() {
  local generation=$1
  local directory=$generations/$generation
  local key value
  [[ "$generation" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  [ -f "$directory/env" ] && [ ! -L "$directory/env" ] || return 1
  [ -f "$directory/manifest" ] && [ ! -L "$directory/manifest" ] || return 1
  [ "$(stat -c '%a' "$directory/env" 2>/dev/null)" = 600 ] || return 1
  [ "$(stat -c '%a' "$directory/manifest" 2>/dev/null)" = 600 ] || return 1
  declare -A manifest=()
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ "$key" =~ ^[a-z_]+$ ]] || return 1
    [ -z "${manifest[$key]+present}" ] || return 1
    manifest[$key]=$value
  done <"$directory/manifest"
  [ "${manifest[schema]:-}" = 1 ] || return 1
  [ "${manifest[generation]:-}" = "$generation" ] || return 1
  [[ "${manifest[env_sha256]:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ "$(sha256_file "$directory/env")" = "${manifest[env_sha256]}" ]
}

declare -A journal=()
journal_required=(
  version transaction_id phase critical
  pre_config_sha256 pre_runtime_fingerprint prior_selector
  prior_selector_value prior_generation_sha256 candidate_generation
  terminal_category terminal_status terminal_fingerprint
)

load_journal() {
  local file=$1 key value
  journal=()
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ "$key" =~ ^[a-z_]+$ ]] || return 1
    [ -z "${journal[$key]+present}" ] || return 1
    journal[$key]=$value
  done <"$file"
  for key in "${journal_required[@]}"; do
    [ -n "${journal[$key]+present}" ] || return 1
  done
  [ "${journal[version]}" = 1 ] || return 1
  [[ "${journal[transaction_id]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [ "${journal[transaction_id]}" = "$(basename -- "$(dirname -- "$file")")" ] ||
    return 1
  [[ "${journal[critical]}" =~ ^(true|false)$ ]] || return 1
  [[ "${journal[pre_config_sha256]}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "${journal[pre_runtime_fingerprint]}" =~ ^[0-9a-f]{64}$ ]] || return 1
  case "${journal[prior_selector]}" in
    absent) [ -z "${journal[prior_selector_value]}" ] &&
      [ -z "${journal[prior_generation_sha256]}" ] ;;
    present)
      [[ "${journal[prior_selector_value]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] &&
        [[ "${journal[prior_generation_sha256]}" =~ ^[0-9a-f]{64}$ ]] &&
        validate_generation "${journal[prior_selector_value]}" ;;
    *) return 1 ;;
  esac
  case "${journal[phase]}" in
    SNAPSHOTTED) [ "${journal[critical]}" = false ] ;;
    CANDIDATE_INSTALL_PENDING|CANDIDATE_INSTALLED|BACKEND_RECREATE_PENDING|\
      BACKEND_RECREATED|VERIFIED|LAST_GOOD_COMMIT_PENDING)
      [ "${journal[critical]}" = true ] ;;
    COMMITTED)
      [ "${journal[critical]}" = false ] &&
        [ "${journal[terminal_category]}" = deploy_succeeded ] &&
        [ "${journal[terminal_status]}" = 0 ] &&
        [[ "${journal[terminal_fingerprint]}" =~ ^[0-9a-f]{64}$ ]] ;;
    RECOVERED)
      [ "${journal[critical]}" = false ] &&
        [ "${journal[terminal_category]}" = deploy_failed_rollback_succeeded ] &&
        [ "${journal[terminal_status]}" = 22 ] &&
        [[ "${journal[terminal_fingerprint]}" =~ ^[0-9a-f]{64}$ ]] ;;
    *) return 1 ;;
  esac
}

journal_text() {
  local phase=$1 critical=$2 category=$3 status=$4 fingerprint=$5
  printf 'version=1\n'
  printf 'transaction_id=%s\n' "${journal[transaction_id]}"
  printf 'phase=%s\ncritical=%s\n' "$phase" "$critical"
  printf 'pre_config_sha256=%s\npre_runtime_fingerprint=%s\n' \
    "${journal[pre_config_sha256]}" "${journal[pre_runtime_fingerprint]}"
  printf 'prior_selector=%s\nprior_selector_value=%s\n' \
    "${journal[prior_selector]}" "${journal[prior_selector_value]}"
  printf 'prior_generation_sha256=%s\ncandidate_generation=%s\n' \
    "${journal[prior_generation_sha256]}" "${journal[candidate_generation]}"
  printf 'terminal_category=%s\nterminal_status=%s\nterminal_fingerprint=%s\n' \
    "$category" "$status" "$fingerprint"
}

write_journal() {
  local phase=$1 critical=$2 category=$3 status=$4 fingerprint=$5
  atomic_text "$(journal_text "$phase" "$critical" "$category" "$status" "$fingerprint")" \
    "$transaction_dir/journal" 600 journal
  journal[phase]=$phase
  journal[critical]=$critical
  journal[terminal_category]=$category
  journal[terminal_status]=$status
  journal[terminal_fingerprint]=$fingerprint
}

# A critical transition is persisted as the complete tuple critical=true plus
# its pending phase.  COMMITTED/RECOVERED are complete terminal tuples with
# critical=false, category, status, and the expected fingerprint together.

publish_pointer() {
  atomic_text "${journal[transaction_id]}"$'\n' "$pointer" 600 transaction_pointer
}

clear_pointer_then_delete() {
  local transaction=$1
  [ -f "$pointer" ] && [ ! -L "$pointer" ] || return 1
  atomic_text '' "$pointer.clear" 600 pointer_clear_temp
  interrupt_boundary pointer_unlink
  rm -f -- "$pointer.clear" "$pointer"
  sync_directory "$state_root" pointer_root_sync
  interrupt_boundary transaction_delete
  if [ -d "$transaction" ] && [ ! -L "$transaction" ]; then
    find "$transaction" -xdev -type f -delete
    find "$transaction" -xdev -depth -type d -empty -delete
  fi
  sync_directory "$transactions" transaction_directory_sync
}

selector_matches_prior() {
  case "${journal[prior_selector]}" in
    absent) [ ! -e "$selector" ] && [ ! -L "$selector" ] ;;
    present)
      [ "$(safe_selector_value)" = "${journal[prior_selector_value]}" ] || return 1
      [ "$(sha256_file "$generations/${journal[prior_selector_value]}/manifest")" =
        "${journal[prior_generation_sha256]}" ] ;;
  esac
}

restore_selector_prior() {
  case "${journal[prior_selector]}" in
    present)
      atomic_text "${journal[prior_selector_value]}"$'\n' "$selector" 600 last_good_pointer
      ;;
    absent)
      if [ -e "$selector" ] || [ -L "$selector" ]; then
        [ -f "$selector" ] && [ ! -L "$selector" ] ||
          return 1
        [ "$(safe_selector_value)" = "${journal[candidate_generation]}" ] ||
          return 1
        rm -f -- "$selector"
        sync_directory "$state_root" last_good_pointer_unlink
      fi
      ;;
  esac
  selector_matches_prior
}

restore_files() {
  atomic_copy "$transaction_dir/env.before" "$root/.env.production" 600 live_config
  if [ -e "$transaction_dir/had-active-compose" ]; then
    atomic_copy "$transaction_dir/active-compose.before" "$active_compose" 600 live_compose
  else
    rm -f -- "$active_compose"
    sync_directory "$(dirname -- "$active_compose")" live_compose_unlink
  fi
  if [ -e "$transaction_dir/had-active-runtime" ]; then
    atomic_copy "$transaction_dir/active-runtime.before" "$active_runtime" 600 live_runtime
  else
    rm -f -- "$active_runtime"
    sync_directory "$(dirname -- "$active_runtime")" live_runtime_unlink
  fi
}

verify_pre_state() {
  [ "$(sha256_file "$root/.env.production")" = "${journal[pre_config_sha256]}" ] || return 1
  selector_matches_prior || return 1
  local fingerprint
  fingerprint=$(runtime_safe_fingerprint "$root" "$compose_script")
  [ "$fingerprint" = "${journal[pre_runtime_fingerprint]}" ]
}

recover_transaction() {
  restore_files || return 1
  restore_selector_prior || return 1
  runtime_compose "$root" "$compose_script" config -q >/dev/null
  runtime_compose "$root" "$compose_script" up -d --no-deps --no-build \
    --pull never --force-recreate --wait --wait-timeout 180 backend >/dev/null
  verify_pre_state
}

finalize_terminal() {
  local status=${journal[terminal_status]}
  local category=${journal[terminal_category]}
  local fingerprint=${journal[terminal_fingerprint]}
  case "${journal[phase]}" in
    COMMITTED)
      [ "$(safe_selector_value)" = "${journal[candidate_generation]}" ] || return 1
      validate_generation "${journal[candidate_generation]}" || return 1
      [ "$(runtime_safe_fingerprint "$root" "$compose_script")" = "$fingerprint" ] ||
        return 1
      ;;
    RECOVERED)
      [ "$fingerprint" = "${journal[pre_runtime_fingerprint]}" ] || return 1
      verify_pre_state || return 1
      ;;
    *) return 1 ;;
  esac
  clear_pointer_then_delete "$transaction_dir"
  result "$category" "$status"
  exit "$status"
}

reconcile_current() {
  if ! { [ -e "$pointer" ] || [ -L "$pointer" ]; }; then
    return 0
  fi
  [ -f "$pointer" ] && [ ! -L "$pointer" ] || fail_result deploy_failed_rollback_failed 23
  [ "$(wc -l <"$pointer")" -eq 1 ] || fail_result deploy_failed_rollback_failed 23
  local txid
  txid=$(<"$pointer")
  [[ "$txid" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    fail_result deploy_failed_rollback_failed 23
  transaction_dir=$transactions/$txid
  [ -d "$transaction_dir" ] && [ ! -L "$transaction_dir" ] ||
    fail_result deploy_failed_rollback_failed 23
  load_journal "$transaction_dir/journal" ||
    fail_result deploy_failed_rollback_failed 23
  case "${journal[phase]}" in
    SNAPSHOTTED)
      [ "$(sha256_file "$root/.env.production")" = "${journal[pre_config_sha256]}" ] ||
        fail_result deploy_failed_rollback_failed 23
      selector_matches_prior ||
        fail_result deploy_failed_rollback_failed 23
      clear_pointer_then_delete "$transaction_dir" ||
        fail_result deploy_failed_rollback_failed 23
      transaction_dir=
      ;;
    CANDIDATE_INSTALL_PENDING|CANDIDATE_INSTALLED|BACKEND_RECREATE_PENDING|\
      BACKEND_RECREATED|VERIFIED|LAST_GOOD_COMMIT_PENDING)
      if recover_transaction; then
        fingerprint=${journal[pre_runtime_fingerprint]}
        write_journal RECOVERED false deploy_failed_rollback_succeeded 22 "$fingerprint"
        finalize_terminal || fail_result deploy_failed_rollback_failed 23
      else
        fail_result deploy_failed_rollback_failed 23
      fi
      ;;
    COMMITTED|RECOVERED)
      finalize_terminal || fail_result deploy_failed_rollback_failed 23
      ;;
  esac
}

reconcile_current

if [ "$mode" = rollback_last ] && ! { [ -e "$selector" ] || [ -L "$selector" ]; }; then
  fail_result precheck_failed 20
fi

pre_config_sha256=$(sha256_file "$root/.env.production")
pre_runtime_fingerprint=$(runtime_safe_fingerprint "$root" "$compose_script") ||
  fail_result precheck_failed 20
runtime_compose "$root" "$compose_script" config -q >/dev/null ||
  fail_result precheck_failed 20

prior_selector=absent
prior_selector_value=
prior_generation_sha256=
if [ -e "$selector" ] || [ -L "$selector" ]; then
  prior_selector=present
  prior_selector_value=$(safe_selector_value) ||
    fail_result precheck_failed 20
  [ -f "$generations/$prior_selector_value/env" ] &&
    [ -f "$generations/$prior_selector_value/manifest" ] ||
    fail_result precheck_failed 20
  validate_generation "$prior_selector_value" ||
    fail_result precheck_failed 20
  prior_generation_sha256=$(sha256_file "$generations/$prior_selector_value/manifest")
fi

if [ "$mode" = rollback_last ]; then
  selected_env=$generations/$prior_selector_value/env
  [ -f "$selected_env" ] && [ ! -L "$selected_env" ] ||
    fail_result precheck_failed 20
  transaction_id="$run_key-rollback-$(date +%s%N)"
else
  [ -f "$payload_file" ] && [ ! -L "$payload_file" ] ||
    fail_result precheck_failed 20
  transaction_id="$run_key-apply-$(date +%s%N)"
fi

transaction_dir=$transactions/$transaction_id
[ ! -e "$transaction_dir" ] || fail_result precheck_failed 20
install -d -m 700 "$transaction_dir"
install -m 600 "$root/.env.production" "$transaction_dir/env.before"
printf '%s\n' "$pre_config_sha256" >"$transaction_dir/pre-config.sha256"
chmod 600 "$transaction_dir/pre-config.sha256"
if [ -e "$active_compose" ]; then
  [ -s "$active_compose" ] || fail_result precheck_failed 20
  install -m 600 "$active_compose" "$transaction_dir/active-compose.before"
  : >"$transaction_dir/had-active-compose"
  chmod 600 "$transaction_dir/had-active-compose"
fi
if [ -e "$active_runtime" ]; then
  [ -s "$active_runtime" ] || fail_result precheck_failed 20
  install -m 600 "$active_runtime" "$transaction_dir/active-runtime.before"
  : >"$transaction_dir/had-active-runtime"
  chmod 600 "$transaction_dir/had-active-runtime"
fi

if [ "$mode" = apply ]; then
  declare -A payload=()
  payload_count=0
  while IFS= read -r -d '' record; do
    [[ "$record" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] ||
      fail_result precheck_failed 20
    name=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    case "$name" in
      APP_EMAIL_PROVIDER|APP_EMAIL_FROM|APP_EMAIL_FROM_NAME|SPRING_MAIL_HOST|\
      SPRING_MAIL_PORT|SPRING_MAIL_USERNAME|SPRING_MAIL_PASSWORD|\
      APP_EMAIL_CONNECT_TIMEOUT_MS|APP_EMAIL_READ_TIMEOUT_MS|APP_EMAIL_WRITE_TIMEOUT_MS) ;;
      *) fail_result precheck_failed 20 ;;
    esac
    [ -z "${payload[$name]+present}" ] || fail_result precheck_failed 20
    [[ "$value" != *$'\n'* ]] && [[ "$value" != *$'\r'* ]] || fail_result precheck_failed 20
    payload[$name]=$value
    payload_count=$((payload_count + 1))
  done <"$payload_file"
  [ "$payload_count" -eq 10 ] || fail_result precheck_failed 20
  [ "${payload[APP_EMAIL_PROVIDER]}" = smtp ] ||
    fail_result precheck_failed 20
  [ "${payload[SPRING_MAIL_HOST]}" = smtp.yandex.ru ] ||
    fail_result precheck_failed 20
  [ "${payload[SPRING_MAIL_PORT]}" = 587 ] ||
    fail_result precheck_failed 20
  for required_name in APP_EMAIL_FROM APP_EMAIL_FROM_NAME SPRING_MAIL_USERNAME \
    SPRING_MAIL_PASSWORD APP_EMAIL_CONNECT_TIMEOUT_MS APP_EMAIL_READ_TIMEOUT_MS \
    APP_EMAIL_WRITE_TIMEOUT_MS; do
    [ -n "${payload[$required_name]}" ] || fail_result precheck_failed 20
  done
  for timeout_name in APP_EMAIL_CONNECT_TIMEOUT_MS APP_EMAIL_READ_TIMEOUT_MS \
    APP_EMAIL_WRITE_TIMEOUT_MS; do
    [[ "${payload[$timeout_name]}" =~ ^[1-9][0-9]*$ ]] &&
      [ "${payload[$timeout_name]}" -ge 1000 ] &&
      [ "${payload[$timeout_name]}" -le 30000 ] ||
      fail_result precheck_failed 20
  done
  candidate_env="$transaction_dir/env.candidate"
  : >"$candidate_env"
  declare -A seen_env=()
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      APP_EMAIL_PROVIDER=*) key=APP_EMAIL_PROVIDER ;;
      APP_EMAIL_FROM=*) key=APP_EMAIL_FROM ;;
      APP_EMAIL_FROM_NAME=*) key=APP_EMAIL_FROM_NAME ;;
      SPRING_MAIL_HOST=*) key=SPRING_MAIL_HOST ;;
      SPRING_MAIL_PORT=*) key=SPRING_MAIL_PORT ;;
      SPRING_MAIL_USERNAME=*) key=SPRING_MAIL_USERNAME ;;
      SPRING_MAIL_PASSWORD=*) key=SPRING_MAIL_PASSWORD ;;
      APP_EMAIL_CONNECT_TIMEOUT_MS=*) key=APP_EMAIL_CONNECT_TIMEOUT_MS ;;
      APP_EMAIL_READ_TIMEOUT_MS=*) key=APP_EMAIL_READ_TIMEOUT_MS ;;
      APP_EMAIL_WRITE_TIMEOUT_MS=*) key=APP_EMAIL_WRITE_TIMEOUT_MS ;;
      *) printf '%s\n' "$line" >>"$candidate_env"; continue ;;
    esac
    [ -z "${seen_env[$key]+present}" ] || fail_result precheck_failed 20
    seen_env[$key]=1
    printf '%s=%s\n' "$key" "${payload[$key]}" >>"$candidate_env"
  done <"$root/.env.production"
  for required_name in APP_EMAIL_PROVIDER APP_EMAIL_FROM APP_EMAIL_FROM_NAME \
    SPRING_MAIL_HOST SPRING_MAIL_PORT SPRING_MAIL_USERNAME SPRING_MAIL_PASSWORD \
    APP_EMAIL_CONNECT_TIMEOUT_MS APP_EMAIL_READ_TIMEOUT_MS APP_EMAIL_WRITE_TIMEOUT_MS; do
    [ -n "${seen_env[$required_name]+present}" ] || fail_result precheck_failed 20
  done
  chmod 600 "$candidate_env"
else
  candidate_env=$selected_env
fi

if [ "$mode" = rollback_last ]; then
  candidate_generation=$prior_selector_value
  candidate_generation_dir=$generations/$candidate_generation
  validate_generation "$candidate_generation" ||
    fail_result precheck_failed 20
  atomic_copy "$candidate_generation_dir/env" "$transaction_dir/candidate.env" \
    600 candidate_env
else
  candidate_generation=$transaction_id
  candidate_generation_dir=$generations/$candidate_generation
  install -d -m 700 "$candidate_generation_dir"
  atomic_copy "$candidate_env" "$transaction_dir/candidate.env" 600 candidate_env
  candidate_env_hash=$(sha256_file "$transaction_dir/candidate.env")
  atomic_text $'schema=1\ngeneration='"$candidate_generation"$'\nenv_sha256='"$candidate_env_hash"$'\n' \
    "$candidate_generation_dir/manifest" 600 generation_manifest
  atomic_copy "$transaction_dir/candidate.env" "$candidate_generation_dir/env" \
    600 generation_env
  sync_directory "$candidate_generation_dir" generation_directory_sync
fi

journal=()
journal[version]=1
journal[transaction_id]=$transaction_id
journal[pre_config_sha256]=$pre_config_sha256
journal[pre_runtime_fingerprint]=$pre_runtime_fingerprint
journal[prior_selector]=$prior_selector
journal[prior_selector_value]=$prior_selector_value
journal[prior_generation_sha256]=$prior_generation_sha256
journal[candidate_generation]=$candidate_generation
journal[terminal_category]=
journal[terminal_status]=
journal[terminal_fingerprint]=
journal[phase]=SNAPSHOTTED
journal[critical]=false
write_journal SNAPSHOTTED false '' '' ''
publish_pointer

on_exit() {
  local exit_status=$?
  trap - EXIT TERM INT HUP
  [ "$exit_status" -ne 0 ] || exit 0
  [ -n "${transaction_dir:-}" ] &&
    [ -f "$transaction_dir/journal" ] &&
    load_journal "$transaction_dir/journal" || {
    result deploy_failed_rollback_failed 23
    exit 23
  }
  case "${journal[phase]}" in
    SNAPSHOTTED)
      clear_pointer_then_delete "$transaction_dir" || {
        result deploy_failed_rollback_failed 23
        exit 23
      }
      result precheck_failed 20
      exit 20
      ;;
    COMMITTED|RECOVERED)
      finalize_terminal || {
        result deploy_failed_rollback_failed 23
        exit 23
      }
      ;;
    CANDIDATE_INSTALL_PENDING|CANDIDATE_INSTALLED|BACKEND_RECREATE_PENDING|\
      BACKEND_RECREATED|VERIFIED|LAST_GOOD_COMMIT_PENDING)
      if recover_transaction; then
        write_journal RECOVERED false deploy_failed_rollback_succeeded 22 \
          "${journal[pre_runtime_fingerprint]}"
        finalize_terminal || {
          result deploy_failed_rollback_failed 23
          exit 23
        }
      else
        result deploy_failed_rollback_failed 23
        exit 23
      fi
      ;;
    *)
      result deploy_failed_rollback_failed 23
      exit 23
      ;;
  esac
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

if [ "$mode" = rollback_last ]; then
  # The EXIT path reloads this durable record, so a signal at any publication
  # boundary cannot downgrade a record whose atomic replacement is visible.
  write_journal CANDIDATE_INSTALL_PENDING true '' '' ''
  atomic_copy "$candidate_env" "$root/.env.production" 600 live_config
else
  write_journal CANDIDATE_INSTALL_PENDING true '' '' ''
  atomic_copy "$candidate_env" "$root/.env.production" 600 live_config
fi
write_journal CANDIDATE_INSTALLED true '' '' ''
runtime_compose "$root" "$compose_script" config -q >/dev/null
write_journal BACKEND_RECREATE_PENDING true '' '' ''
runtime_compose "$root" "$compose_script" up -d --no-deps --no-build \
  --pull never --force-recreate --wait --wait-timeout 180 backend >/dev/null
write_journal BACKEND_RECREATED true '' '' ''
runtime_compose "$root" "$compose_script" ps -q backend >/dev/null
candidate_runtime_fingerprint=$(runtime_safe_fingerprint "$root" "$compose_script")
write_journal VERIFIED true '' '' "$candidate_runtime_fingerprint"
write_journal LAST_GOOD_COMMIT_PENDING true '' '' "$candidate_runtime_fingerprint"
atomic_text "${candidate_generation}"$'\n' "$selector" 600 last_good_pointer
sync_directory "$state_root" last_good_selector_root_sync
write_journal COMMITTED false deploy_succeeded 0 "$candidate_runtime_fingerprint"
finalize_terminal
