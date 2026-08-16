#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --root PATH --base-compose PATH --run-key KEY --mode apply|rollback_last --payload-file PATH" >&2
  exit 2
}

RESULT_CATEGORY=
RESULT_EMITTED=false
TRANSACTION_TRAP_INSTALLED=false
INTERRUPTION_EMITTED=false
result() {
  RESULT_CATEGORY=$1
  return 0
}

emit_result() {
  if [ "$RESULT_EMITTED" = false ]; then
    printf 'MEE_SMTP_RESULT=%s\n' "${RESULT_CATEGORY:-deploy_failed_rollback_failed}"
    RESULT_EMITTED=true
  fi
}

fail_result() {
  local category=$1
  local status=$2
  result "$category" "$status"
  if [ "${TRANSACTION_TRAP_INSTALLED:-false}" != true ]; then
    emit_result
  fi
  exit "$status"
}

pointer_published=false
transaction_dir=

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

for command_name in awk basename cat cp curl date dirname docker find flock grep id install jq mktemp mv rm sed sha256sum sort stat sync tr wc; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail_result precheck_failed 20
done
if [ "$(id -u)" -ne 0 ] && [ "${MEE_SMTP_FAKE_REMOTE:-false}" != true ]; then
  fail_result precheck_failed 20
fi
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
production_state_dir=${PRODUCTION_STATE_DIR:-/var/lib/meet-production}
active_compose=$production_state_dir/active-compose.yml
active_runtime=$production_state_dir/active-runtime.override.yml
export PRODUCTION_STATE_DIR="$production_state_dir"
export RUNTIME_BASE_COMPOSE="$base_compose"
export RUNTIME_USE_REVIEWED_COMPOSE=true
install -d -m 700 "$state_root"
exec 9>"$state_root/.deploy.lock"
if ! flock -n 9; then
  fail_result lock_busy 21
fi
install -d -m 700 "$transactions" "$generations"
chmod 700 "$state_root" "$transactions" "$generations"

sync_probe=$(mktemp "$state_root/.smtp-sync-probe.XXXXXX")
chmod 600 "$sync_probe"
if [ "${MEE_SMTP_FAKE_REMOTE:-false}" != true ] &&
  { ! sync -f "$sync_probe" || ! sync -f "$state_root"; }; then
  rm -f -- "$sync_probe"
  fail_result precheck_failed 20
fi
rm -f -- "$sync_probe"

interrupt_boundary() {
  local name=$1
  local base=${name%%:before}
  base=${base%%:after}
  case "${MEE_SMTP_INTERRUPT_BOUNDARY:-}" in
    "$name"|"$base"|"$name:before"|"$name:after")
      if [ "$INTERRUPTION_EMITTED" = false ]; then
        INTERRUPTION_EMITTED=true
        kill -s "${MEE_SMTP_INTERRUPT_SIGNAL:-TERM}" "$$"
      fi
      ;;
  esac
  [ "${MEE_SMTP_FAIL_AT:-}" != "$name" ] &&
    [ "${MEE_SMTP_FAIL_AT:-}" != "$base" ] ||
    return 1
  return 0
}

sync_file() {
  local file=$1
  interrupt_boundary "$2:before"
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" != true ]; then
    sync -f "$file"
  fi
  interrupt_boundary "$2:after"
}

sync_directory() {
  local directory=$1
  interrupt_boundary "$2:before"
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" != true ]; then
    sync -f "$directory"
  fi
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

non_email_config_digest_file() {
  awk '
    /^(APP_EMAIL_PROVIDER|APP_EMAIL_FROM|APP_EMAIL_FROM_NAME|SPRING_MAIL_HOST|SPRING_MAIL_PORT|SPRING_MAIL_USERNAME|SPRING_MAIL_PASSWORD|APP_EMAIL_CONNECT_TIMEOUT_MS|APP_EMAIL_READ_TIMEOUT_MS|APP_EMAIL_WRITE_TIMEOUT_MS)=/ { next }
    { print }
  ' "$1" | sha256sum | awk '{print $1}'
}

safe_selector_value() {
  [ -f "$selector" ] && [ ! -L "$selector" ] || return 1
  [ "$(stat -c '%a' "$selector" 2>/dev/null)" = 600 ] || return 1
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
  while IFS= read -r entry; do
    case "$entry" in env|manifest) ;; *) return 1 ;; esac
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -printf '%f\n')
  [ -f "$directory/env" ] && [ ! -L "$directory/env" ] || return 1
  [ -f "$directory/manifest" ] && [ ! -L "$directory/manifest" ] || return 1
  [ "$(stat -c '%a' "$directory/env" 2>/dev/null)" = 600 ] || return 1
  [ "$(stat -c '%a' "$directory" 2>/dev/null)" = 700 ] || return 1
  [ "$(stat -c '%a' "$directory/manifest" 2>/dev/null)" = 600 ] || return 1
  generation_manifest=()
  local -a manifest_keys=(
    schema generation env_sha256 non_email_config_sha256
    non_email_runtime_fingerprint runtime_fingerprint
    release_image release_version release_revision
  )
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ "$key" =~ ^[a-z][a-z0-9_]*$ ]] || return 1
    case " ${manifest_keys[*]} " in *" $key "*) ;; *) return 1 ;; esac
    [ -z "${generation_manifest[$key]+present}" ] || return 1
    generation_manifest[$key]=$value
  done <"$directory/manifest"
  for key in "${manifest_keys[@]}"; do
    [ -n "${generation_manifest[$key]+present}" ] || return 1
  done
  [ "${generation_manifest[schema]:-}" = 2 ] || return 1
  [ "${generation_manifest[generation]:-}" = "$generation" ] || return 1
  [[ "${generation_manifest[env_sha256]:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "${generation_manifest[non_email_config_sha256]:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "${generation_manifest[non_email_runtime_fingerprint]:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "${generation_manifest[runtime_fingerprint]:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "${generation_manifest[release_image]:-}" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
    return 1
  [[ "${generation_manifest[release_version]:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    return 1
  [[ "${generation_manifest[release_revision]:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ "$(sha256_file "$directory/env")" = "${generation_manifest[env_sha256]}" ] || return 1
  [ "$(non_email_config_digest_file "$directory/env")" = \
    "${generation_manifest[non_email_config_sha256]}" ] || return 1
}

declare -A journal=()
declare -A generation_manifest=()
journal_required=(
  version transaction_id phase critical
  pre_config_sha256 pre_runtime_fingerprint prior_selector
  prior_selector_value prior_generation_sha256 candidate_generation
  candidate_runtime_fingerprint terminal_category terminal_status
  terminal_fingerprint
)
journal_allowed=(
  version transaction_id phase critical
  pre_config_sha256 pre_runtime_fingerprint prior_selector
  prior_selector_value prior_generation_sha256 candidate_generation
  candidate_runtime_fingerprint terminal_category terminal_status
  terminal_fingerprint
)

load_journal() {
  local file=$1 key value line_count=0
  journal=()
  while IFS='=' read -r key value || [ -n "$key" ]; do
    line_count=$((line_count + 1))
    case " ${journal_allowed[*]} " in *" $key "*) ;; *) return 1 ;; esac
    [ -z "${journal[$key]+present}" ] || return 1
    journal[$key]=$value
  done <"$file"
  [ "$line_count" -eq "${#journal_allowed[@]}" ] || return 1
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
  [[ "${journal[candidate_generation]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    return 1
  case "${journal[candidate_runtime_fingerprint]}" in
    '') ;;
    *) [[ "${journal[candidate_runtime_fingerprint]}" =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
  esac
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
    SNAPSHOTTED)
      [ "${journal[critical]}" = false ] &&
        [ -z "${journal[candidate_runtime_fingerprint]}" ] &&
        [ -z "${journal[terminal_category]}" ] &&
        [ -z "${journal[terminal_status]}" ] &&
        [ -z "${journal[terminal_fingerprint]}" ] ;;
    CANDIDATE_INSTALL_PENDING|CANDIDATE_INSTALLED|BACKEND_RECREATE_PENDING|\
      BACKEND_RECREATED|VERIFIED|LAST_GOOD_COMMIT_PENDING)
      [ "${journal[critical]}" = true ] &&
        case "${journal[phase]}" in
          VERIFIED|LAST_GOOD_COMMIT_PENDING)
            [[ "${journal[candidate_runtime_fingerprint]}" =~ ^[0-9a-f]{64}$ ]] ;;
          *) [ -z "${journal[candidate_runtime_fingerprint]}" ] ;;
        esac &&
        [ -z "${journal[terminal_category]}" ] &&
        [ -z "${journal[terminal_status]}" ] &&
        [ -z "${journal[terminal_fingerprint]}" ] ;;
    COMMITTED)
      [ "${journal[critical]}" = false ] &&
        [[ "${journal[candidate_runtime_fingerprint]}" =~ ^[0-9a-f]{64}$ ]] &&
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
  local phase=$1 critical=$2 category=$3 status=$4 fingerprint=$5 candidate_fingerprint=$6
  printf 'version=1\n'
  printf 'transaction_id=%s\n' "${journal[transaction_id]}"
  printf 'phase=%s\ncritical=%s\n' "$phase" "$critical"
  printf 'pre_config_sha256=%s\npre_runtime_fingerprint=%s\n' \
    "${journal[pre_config_sha256]}" "${journal[pre_runtime_fingerprint]}"
  printf 'prior_selector=%s\nprior_selector_value=%s\n' \
    "${journal[prior_selector]}" "${journal[prior_selector_value]}"
  printf 'prior_generation_sha256=%s\ncandidate_generation=%s\n' \
    "${journal[prior_generation_sha256]}" "${journal[candidate_generation]}"
  printf 'candidate_runtime_fingerprint=%s\n' "$candidate_fingerprint"
  printf 'terminal_category=%s\nterminal_status=%s\nterminal_fingerprint=%s\n' \
    "$category" "$status" "$fingerprint"
}

write_journal() {
  local phase=$1 critical=$2 category=$3 status=$4 fingerprint=$5
  local candidate_fingerprint=${6-${journal[candidate_runtime_fingerprint]}}
  local boundary=journal
  case "$phase" in
    COMMITTED) boundary=committed ;;
    RECOVERED) boundary=recovered ;;
  esac
  atomic_text "$(journal_text "$phase" "$critical" "$category" "$status" "$fingerprint" \
    "$candidate_fingerprint")" \
    "$transaction_dir/journal" 600 "$boundary"
  journal[phase]=$phase
  journal[critical]=$critical
  journal[terminal_category]=$category
  journal[terminal_status]=$status
  journal[terminal_fingerprint]=$fingerprint
  journal[candidate_runtime_fingerprint]=$candidate_fingerprint
}

# A critical transition is persisted as the complete tuple critical=true plus
# its pending phase.  COMMITTED/RECOVERED are complete terminal tuples with
# critical=false, category, status, and the expected fingerprint together.

publish_pointer() {
  atomic_text "${journal[transaction_id]}"$'\n' "$pointer" 600 pointer
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

delete_transaction_directory() {
  local transaction=$1
  [ -d "$transaction" ] && [ ! -L "$transaction" ] || return 1
  find "$transaction" -xdev -type f -delete
  find "$transaction" -xdev -depth -type d -empty -delete
  sync_directory "$transactions" transaction_directory_sync
}

delete_unselected_candidate_generation() {
  local generation=${journal[candidate_generation]}
  local selected=
  if [ -e "$selector" ] || [ -L "$selector" ]; then
    selected=$(safe_selector_value) || return 1
  fi
  [[ "$generation" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [ "$generation" != "$selected" ] || return 0
  if [ "${journal[prior_selector]}" = present ] &&
    [ "$generation" = "${journal[prior_selector_value]}" ]; then
    return 0
  fi
  [ -e "$generations/$generation" ] || return 0
  [ -d "$generations/$generation" ] && [ ! -L "$generations/$generation" ] ||
    return 1
  find "$generations/$generation" -xdev -type f -delete
  find "$generations/$generation" -xdev -type l -delete
  find "$generations/$generation" -xdev -depth -mindepth 1 \
    -type d -empty -delete
  rmdir -- "$generations/$generation" 2>/dev/null || true
  [ ! -e "$generations/$generation" ] || return 1
  sync_directory "$generations" generation_delete
}

validate_transaction_material() {
  local phase=${1:-${journal[phase]}}
  [ -d "$transaction_dir" ] && [ ! -L "$transaction_dir" ] || return 1
  [ "$(stat -c '%a' "$transaction_dir" 2>/dev/null)" = 700 ] || return 1
  while IFS= read -r entry; do
    case "$entry" in
      journal|env.before|pre-config.sha256|candidate.env|\
        active-compose.before|active-runtime.before|\
        had-active-compose|no-active-compose|\
        had-active-runtime|no-active-runtime) ;;
      journal.tmp.[A-Za-z0-9]*)
        [ -f "$transaction_dir/$entry" ] &&
          [ ! -L "$transaction_dir/$entry" ] || return 1
        [ "$(stat -c '%a' "$transaction_dir/$entry" 2>/dev/null)" = 600 ] ||
          return 1
        ;;
      *) return 1 ;;
    esac
  done < <(find "$transaction_dir" -mindepth 1 -maxdepth 1 -printf '%f\n')
  for file in journal env.before pre-config.sha256; do
    [ -f "$transaction_dir/$file" ] && [ ! -L "$transaction_dir/$file" ] || return 1
    [ "$(stat -c '%a' "$transaction_dir/$file" 2>/dev/null)" = 600 ] || return 1
  done
  [ "$(sha256_file "$transaction_dir/env.before")" = "${journal[pre_config_sha256]}" ] ||
    return 1
  [ "$(tr -d '\n' <"$transaction_dir/pre-config.sha256")" = \
    "${journal[pre_config_sha256]}" ] || return 1
  for name in active-compose active-runtime; do
    present_marker=$transaction_dir/had-$name
    absent_marker=$transaction_dir/no-$name
    present=false
    absent=false
    if [ -e "$present_marker" ]; then
      [ -f "$present_marker" ] && [ ! -L "$present_marker" ] || return 1
      [ "$(stat -c '%a' "$present_marker" 2>/dev/null)" = 600 ] || return 1
      [ "$(tr -d '\n' <"$present_marker")" = present ] || return 1
      [ ! -e "$absent_marker" ] || return 1
      snapshot=$transaction_dir/$name.before
      [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
      [ "$(stat -c '%a' "$snapshot" 2>/dev/null)" = 600 ] || return 1
      present=true
    fi
    if [ -e "$absent_marker" ]; then
      [ -f "$absent_marker" ] && [ ! -L "$absent_marker" ] || return 1
      [ "$(stat -c '%a' "$absent_marker" 2>/dev/null)" = 600 ] || return 1
      [ "$(tr -d '\n' <"$absent_marker")" = absent ] || return 1
      [ ! -e "$present_marker" ] || return 1
      [ ! -e "$transaction_dir/$name.before" ] || return 1
      absent=true
    fi
    [ "$present" = true ] || [ "$absent" = true ] || return 1
  done
  case "$phase" in
    SNAPSHOTTED) ;;
    *)
      [ -f "$transaction_dir/candidate.env" ] &&
        [ ! -L "$transaction_dir/candidate.env" ] || return 1
      [ "$(stat -c '%a' "$transaction_dir/candidate.env" 2>/dev/null)" = 600 ] ||
        return 1
      ;;
  esac
}

verify_snapshot_state() {
  validate_transaction_material SNAPSHOTTED || return 1
  [ "$(sha256_file "$root/.env.production")" = "${journal[pre_config_sha256]}" ] ||
    return 1
  selector_matches_prior || return 1
  [ "$(runtime_safe_fingerprint "$root" "$compose_script")" = \
    "${journal[pre_runtime_fingerprint]}" ]
}

selector_matches_prior() {
  case "${journal[prior_selector]}" in
    absent) [ ! -e "$selector" ] && [ ! -L "$selector" ] ;;
    present)
      [ "$(safe_selector_value)" = "${journal[prior_selector_value]}" ] || return 1
      [ "$(sha256_file "$generations/${journal[prior_selector_value]}/manifest")" = \
        "${journal[prior_generation_sha256]}" ] ;;
  esac
}

validate_selected_generation_identity() {
  local generation=$1
  validate_generation "$generation" || return 1
  [ "$(non_email_config_digest_file "$generations/$generation/env")" = \
    "$(runtime_non_email_config_digest "$root")" ] || return 1
  [ "$(runtime_non_email_fingerprint "$root" "$compose_script")" = \
    "${generation_manifest[non_email_runtime_fingerprint]}" ] || return 1
  [ "$(runtime_release_field "$root" BACKEND_IMAGE)" = \
    "${generation_manifest[release_image]}" ] || return 1
  [ "$(runtime_release_field "$root" BACKEND_VERSION)" = \
    "${generation_manifest[release_version]}" ] || return 1
  [ "$(runtime_release_field "$root" BACKEND_REVISION)" = \
    "${generation_manifest[release_revision]}" ]
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
  elif [ -e "$transaction_dir/no-active-compose" ]; then
    [ ! -L "$active_compose" ] || return 1
    rm -f -- "$active_compose"
    sync_directory "$(dirname -- "$active_compose")" live_compose_unlink
  else
    return 1
  fi
  if [ -e "$transaction_dir/had-active-runtime" ]; then
    atomic_copy "$transaction_dir/active-runtime.before" "$active_runtime" 600 live_runtime
  elif [ -e "$transaction_dir/no-active-runtime" ]; then
    [ ! -L "$active_runtime" ] || return 1
    rm -f -- "$active_runtime"
    sync_directory "$(dirname -- "$active_runtime")" live_runtime_unlink
  else
    return 1
  fi
}

verify_pre_state() {
  [ "$(sha256_file "$root/.env.production")" = "${journal[pre_config_sha256]}" ] || return 1
  selector_matches_prior || return 1
  local fingerprint
  fingerprint=$(runtime_safe_fingerprint "$root" "$compose_script")
  [ "$fingerprint" = "${journal[pre_runtime_fingerprint]}" ] || return 1
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" = true ]; then
    return 0
  fi
  local revision version config_hash container
  revision=$(runtime_release_field "$root" BACKEND_REVISION) || return 1
  version=$(runtime_release_field "$root" BACKEND_VERSION) || return 1
  container=$(runtime_compose "$root" "$compose_script" ps -q backend) || return 1
  config_hash=$(docker inspect "$container" \
    --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') || return 1
  verify_runtime_invariants "$root" "$compose_script" \
    "$(runtime_image_id "$root" "$compose_script")" "$revision" "$version" "$config_hash" \
    >/dev/null
}

verify_current_runtime() {
  if [ "${MEE_SMTP_FAKE_REMOTE:-false}" = true ]; then
    return 0
  fi
  local revision version container config_hash image_id
  revision=$(runtime_release_field "$root" BACKEND_REVISION) || return 1
  version=$(runtime_release_field "$root" BACKEND_VERSION) || return 1
  container=$(runtime_compose "$root" "$compose_script" ps -q backend) || return 1
  config_hash=$(docker inspect "$container" \
    --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') || return 1
  [[ "$config_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  image_id=$(runtime_image_id "$root" "$compose_script") || return 1
  verify_runtime_invariants "$root" "$compose_script" "$image_id" \
    "$revision" "$version" "$config_hash" >/dev/null
}

recover_transaction() {
  interrupt_boundary restore
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
      [ "${generation_manifest[runtime_fingerprint]}" = "$fingerprint" ] || return 1
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
  delete_unselected_candidate_generation
  result "$category" "$status"
  emit_result
  exit "$status"
}

finalize_orphan_terminal() {
  case "${journal[phase]}" in
    COMMITTED)
      [ "$(safe_selector_value)" = "${journal[candidate_generation]}" ] || return 1
      validate_generation "${journal[candidate_generation]}" || return 1
      [ "${generation_manifest[runtime_fingerprint]}" = \
        "${journal[terminal_fingerprint]}" ] || return 1
      [ "$(runtime_safe_fingerprint "$root" "$compose_script")" = \
        "${journal[terminal_fingerprint]}" ] || return 1
      ;;
    RECOVERED)
      [ "${journal[terminal_fingerprint]}" = "${journal[pre_runtime_fingerprint]}" ] ||
        return 1
      verify_pre_state || return 1
      ;;
    *) return 1 ;;
  esac
  delete_unselected_candidate_generation || return 1
  delete_transaction_directory "$transaction_dir"
}

reconcile_current() {
  if ! { [ -e "$pointer" ] || [ -L "$pointer" ]; }; then
    return 0
  fi
  [ -f "$pointer" ] && [ ! -L "$pointer" ] || fail_result deploy_failed_rollback_failed 23
  [ "$(stat -c '%a' "$pointer" 2>/dev/null)" = 600 ] ||
    fail_result deploy_failed_rollback_failed 23
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
  validate_transaction_material "${journal[phase]}" ||
    fail_result deploy_failed_rollback_failed 23
  case "${journal[phase]}" in
    SNAPSHOTTED)
      verify_snapshot_state ||
        fail_result deploy_failed_rollback_failed 23
      clear_pointer_then_delete "$transaction_dir" ||
        fail_result deploy_failed_rollback_failed 23
      delete_unselected_candidate_generation ||
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

reconcile_orphans_without_pointer() {
  local candidate
  for candidate in "$transactions"/*; do
    [ -e "$candidate" ] || continue
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
    transaction_dir=$candidate
    load_journal "$candidate/journal" || return 1
    validate_transaction_material "${journal[phase]}" || return 1
    case "${journal[phase]}" in
      SNAPSHOTTED)
        verify_snapshot_state || return 1
        delete_transaction_directory "$candidate" || return 1
        delete_unselected_candidate_generation || return 1
        ;;
      COMMITTED)
        finalize_orphan_terminal || return 1
        ;;
      RECOVERED)
        finalize_orphan_terminal || return 1
        ;;
      *) return 1 ;;
    esac
    transaction_dir=
  done
  return 0
}

reconcile_current
if ! { [ -e "$pointer" ] || [ -L "$pointer" ]; }; then
  reconcile_orphans_without_pointer ||
    fail_result deploy_failed_rollback_failed 23
fi

if [ "$mode" = rollback_last ] && ! { [ -e "$selector" ] || [ -L "$selector" ]; }; then
  fail_result precheck_failed 20
fi

runtime_compose "$root" "$compose_script" config -q >/dev/null ||
  fail_result precheck_failed 20
verify_current_runtime || fail_result precheck_failed 20
pre_config_sha256=$(sha256_file "$root/.env.production")
pre_runtime_fingerprint=$(runtime_safe_fingerprint "$root" "$compose_script") ||
  fail_result precheck_failed 20
pre_non_email_runtime_fingerprint=$(runtime_non_email_fingerprint "$root" "$compose_script") ||
  fail_result precheck_failed 20

pointer_published=false
transaction_dir=
on_exit() {
  local exit_status=$?
  trap - EXIT TERM INT HUP
  [ "$exit_status" -eq 0 ] && exit 0
  if [ -z "${transaction_dir:-}" ]; then
    result precheck_failed 20
    emit_result
    exit 20
  fi
  if [ "$pointer_published" != true ] &&
    ! { [ -e "$pointer" ] || [ -L "$pointer" ]; }; then
    delete_transaction_directory "$transaction_dir" || {
      result deploy_failed_rollback_failed 23
      emit_result
      exit 23
    }
    result precheck_failed 20
    emit_result
    exit 20
  fi
  pointer_published=true
  [ -f "$transaction_dir/journal" ] && [ ! -L "$transaction_dir/journal" ] || {
    result deploy_failed_rollback_failed 23
    emit_result
    exit 23
  }
  load_journal "$transaction_dir/journal" || {
    result deploy_failed_rollback_failed 23
    emit_result
    exit 23
  }
  validate_transaction_material "${journal[phase]}" || {
    result deploy_failed_rollback_failed 23
    emit_result
    exit 23
  }
  case "${journal[phase]}" in
    SNAPSHOTTED)
      verify_snapshot_state &&
        clear_pointer_then_delete "$transaction_dir" &&
        delete_unselected_candidate_generation || {
        result deploy_failed_rollback_failed 23
        emit_result
        exit 23
      }
      result precheck_failed 20
      emit_result
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
          emit_result
          exit 23
        }
      else
        result deploy_failed_rollback_failed 23
        emit_result
        exit 23
      fi
      ;;
    *) result deploy_failed_rollback_failed 23; emit_result; exit 23 ;;
  esac
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
TRANSACTION_TRAP_INSTALLED=true

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
  if [ "$mode" = rollback_last ]; then
    validate_selected_generation_identity "$prior_selector_value" ||
      fail_result precheck_failed 20
  fi
  prior_generation_sha256=$(sha256_file "$generations/$prior_selector_value/manifest")
fi

if [ "$mode" = rollback_last ]; then
  selected_env=$generations/$prior_selector_value/env
  [ -f "$selected_env" ] && [ ! -L "$selected_env" ] ||
    fail_result precheck_failed 20
  transaction_id=
else
  [ -f "$payload_file" ] && [ ! -L "$payload_file" ] ||
    fail_result precheck_failed 20
  transaction_id=
fi

transaction_dir=$(mktemp -d "$transactions/${run_key}-${mode}-XXXXXX") ||
  fail_result precheck_failed 20
transaction_id=$(basename -- "$transaction_dir")
if [ "$mode" = rollback_last ]; then
  candidate_generation=$prior_selector_value
else
  candidate_generation=$transaction_id
fi
chmod 700 "$transaction_dir"
install -m 600 "$root/.env.production" "$transaction_dir/env.before"
printf '%s\n' "$pre_config_sha256" >"$transaction_dir/pre-config.sha256"
chmod 600 "$transaction_dir/pre-config.sha256"
if [ -e "$active_compose" ]; then
  [ -s "$active_compose" ] || fail_result precheck_failed 20
  install -m 600 "$active_compose" "$transaction_dir/active-compose.before"
  printf 'present\n' >"$transaction_dir/had-active-compose"
  chmod 600 "$transaction_dir/had-active-compose"
else
  printf 'absent\n' >"$transaction_dir/no-active-compose"
  chmod 600 "$transaction_dir/no-active-compose"
fi
if [ -e "$active_runtime" ]; then
  [ -s "$active_runtime" ] || fail_result precheck_failed 20
  install -m 600 "$active_runtime" "$transaction_dir/active-runtime.before"
  printf 'present\n' >"$transaction_dir/had-active-runtime"
  chmod 600 "$transaction_dir/had-active-runtime"
else
  printf 'absent\n' >"$transaction_dir/no-active-runtime"
  chmod 600 "$transaction_dir/no-active-runtime"
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
    [[ "$value" != *[[:cntrl:]]* ]] || fail_result precheck_failed 20
    case "$value" in
      *'#'*|*'$'*|*'`'*|*'\'*|*'"'*|*"'"*|*'='*|*';'*|*'|'*|*'&'*|\
        *'<'*|*'>'*|*'{'*|*'}'*|*'('*|*')'*|*'['*|*']'*)
        fail_result precheck_failed 20
        ;;
    esac
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
  candidate_env="$transaction_dir/candidate.env"
  cp -- "$root/.env.production" "$candidate_env"
  for required_name in APP_EMAIL_PROVIDER APP_EMAIL_FROM APP_EMAIL_FROM_NAME \
    SPRING_MAIL_HOST SPRING_MAIL_PORT SPRING_MAIL_USERNAME SPRING_MAIL_PASSWORD \
    APP_EMAIL_CONNECT_TIMEOUT_MS APP_EMAIL_READ_TIMEOUT_MS APP_EMAIL_WRITE_TIMEOUT_MS; do
    [ "$(grep -c "^${required_name}=" "$candidate_env")" -eq 1 ] ||
      fail_result precheck_failed 20
    sed -i "s|^${required_name}=.*$|${required_name}=${payload[$required_name]}|" \
      "$candidate_env"
  done
  chmod 600 "$candidate_env"
else
  candidate_env=$selected_env
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
journal[candidate_runtime_fingerprint]=
journal[terminal_category]=
journal[terminal_status]=
journal[terminal_fingerprint]=
journal[phase]=SNAPSHOTTED
journal[critical]=false
write_journal SNAPSHOTTED false '' '' ''
publish_pointer
pointer_published=true

if [ "$mode" = rollback_last ]; then
  candidate_generation=$prior_selector_value
  candidate_generation_dir=$generations/$candidate_generation
  validate_generation "$candidate_generation" ||
    fail_result precheck_failed 20
else
  candidate_generation=$transaction_id
  candidate_generation_dir=$generations/$candidate_generation
  install -d -m 700 "$candidate_generation_dir"
  atomic_copy "$candidate_env" "$candidate_generation_dir/env" 600 generation_env
  sync_directory "$candidate_generation_dir" generation_directory_sync
fi

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
interrupt_boundary backend_recreate
runtime_compose "$root" "$compose_script" up -d --no-deps --no-build \
  --pull never --force-recreate --wait --wait-timeout 180 backend >/dev/null
write_journal BACKEND_RECREATED true '' '' ''
runtime_compose "$root" "$compose_script" ps -q backend >/dev/null
candidate_runtime_fingerprint=$(runtime_safe_fingerprint "$root" "$compose_script")
verify_current_runtime || fail_result deploy_failed_rollback_failed 23
candidate_non_email_runtime_fingerprint=$(runtime_non_email_fingerprint "$root" "$compose_script")
[ "$candidate_non_email_runtime_fingerprint" = "$pre_non_email_runtime_fingerprint" ] ||
  fail_result deploy_failed_rollback_failed 23
write_journal VERIFIED true '' '' '' "$candidate_runtime_fingerprint"
if [ "$mode" = apply ]; then
  candidate_env_hash=$(sha256_file "$candidate_generation_dir/env")
  candidate_non_email_config=$(non_email_config_digest_file "$candidate_generation_dir/env")
  candidate_non_email_fingerprint=$(runtime_non_email_fingerprint "$root" "$compose_script")
  candidate_release_image=$(runtime_release_field "$root" BACKEND_IMAGE)
  candidate_release_version=$(runtime_release_field "$root" BACKEND_VERSION)
  candidate_release_revision=$(runtime_release_field "$root" BACKEND_REVISION)
  atomic_text $'schema=2\ngeneration='"$candidate_generation"$'\nenv_sha256='"$candidate_env_hash"$'\nnon_email_config_sha256='"$candidate_non_email_config"$'\nnon_email_runtime_fingerprint='"$candidate_non_email_fingerprint"$'\nruntime_fingerprint='"$candidate_runtime_fingerprint"$'\nrelease_image='"$candidate_release_image"$'\nrelease_version='"$candidate_release_version"$'\nrelease_revision='"$candidate_release_revision"$'\n' \
    "$candidate_generation_dir/manifest" 600 generation_manifest
  sync_directory "$candidate_generation_dir" generation_directory_sync
fi
write_journal LAST_GOOD_COMMIT_PENDING true '' '' '' \
  "$candidate_runtime_fingerprint"
atomic_text "${candidate_generation}"$'\n' "$selector" 600 last_good_pointer
sync_directory "$state_root" last_good_selector_root_sync
write_journal COMMITTED false deploy_succeeded 0 "$candidate_runtime_fingerprint"
finalize_terminal
