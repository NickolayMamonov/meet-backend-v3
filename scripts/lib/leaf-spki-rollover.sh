#!/usr/bin/env bash
#
# Shared implementation for the edge-specific leaf SPKI rollover tool.
# The executable wrapper is intentionally small; all recovery admission and
# mutation boundaries live here so fixture and live execution share code.

[[ "${BASH_SOURCE[0]}" != "$0" ]] || {
  echo "leaf-spki-rollover library must be sourced" >&2
  exit 64
}

set -euo pipefail
IFS=$'\n\t'
umask 077

readonly LEAF_SPKI_HOSTNAME=api.whysoezzy.online
readonly LEAF_SPKI_PRIMARY_LINEAGE=api.whysoezzy.online
readonly LEAF_SPKI_ROLLOVER_LINEAGE=api.whysoezzy.online-rollover
readonly LEAF_SPKI_BACKEND_SOURCE=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
readonly LEAF_SPKI_BACKEND_IMAGE_DIGEST=sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6

LEAF_SPKI_FIXTURE=${LEAF_SPKI_FIXTURE_ROOT:-}
if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
  [[ "$LEAF_SPKI_FIXTURE" = /* && "$LEAF_SPKI_FIXTURE" != / ]] ||
    { echo "fixture root must be a non-root absolute path" >&2; return 65 2>/dev/null || exit 65; }
  ROOT_DIR=$(cd "$LEAF_SPKI_FIXTURE" 2>/dev/null && pwd -P) ||
    { echo "fixture root is unavailable" >&2; return 69 2>/dev/null || exit 69; }
  case "$ROOT_DIR" in
    /|/etc|/etc/*|/run|/run/*|/var|/var/*)
      echo "fixture root overlaps live paths" >&2
      return 65 2>/dev/null || exit 65
      ;;
  esac
  RECOVERY_PARENT=$ROOT_DIR/recovery
  NGINX_SOURCE=$ROOT_DIR/nginx-source.conf
  STATE_DIR=$ROOT_DIR/state
  EFFECT_LOG=${LEAF_SPKI_EFFECT_LOG:-$ROOT_DIR/effects.log}
  case "$EFFECT_LOG" in
    /*) ;;
    *) EFFECT_LOG="$PWD/$EFFECT_LOG" ;;
  esac
  [[ -z "${LEAF_SPKI_EFFECT_LOG:-}" ||
    "$EFFECT_LOG" = "$ROOT_DIR"/* ]] ||
    { echo "fixture effect log escapes fixture root" >&2; return 65 2>/dev/null || exit 65; }
else
  ROOT_DIR=/
  RECOVERY_PARENT=/var/lib/meet-leaf-spki-rollover/recovery
  NGINX_SOURCE=/etc/nginx/sites-available/api.whysoezzy.online
  STATE_DIR=/var/lib/meet-leaf-spki-rollover
  [[ -z "${LEAF_SPKI_EFFECT_LOG:-}" ]] ||
    { echo "fixture variables are forbidden in live mode" >&2; return 65 2>/dev/null || exit 65; }
  EFFECT_LOG=/dev/null
fi
LOCK_FILE=${LEAF_SPKI_FIXTURE_ROOT:+$ROOT_DIR/rollover.lock}
LOCK_FILE=${LOCK_FILE:-/run/lock/meet-leaf-spki-rollover.lock}

die() { printf '%s\n' "$1" >&2; return "${2:-65}"; }
effect() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,63}$ ]] || return 70
  [[ "$EFFECT_LOG" = /dev/null ]] && return 0
  mkdir -p "$(dirname "$EFFECT_LOG")" || return 73
  printf '%s\n' "$1" >>"$EFFECT_LOG" || return 73
}
sha256_file() { sha256sum -- "$1" | awk '{print $1}'; }
is_regular_safe() {
  local path=$1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(stat -c '%a' "$path")" = 600 ]] || return 1
  [[ "$(stat -c '%h' "$path")" = 1 ]] || return 1
  [[ -n "$LEAF_SPKI_FIXTURE" ||
    "$(stat -c '%u:%g' "$path")" = 0:0 ]] || return 1
}
is_directory_safe() {
  local path=$1
  [[ -d "$path" && ! -L "$path" ]] || return 1
  [[ "$(stat -c '%a' "$path")" = 700 ]] || return 1
  [[ -n "$LEAF_SPKI_FIXTURE" ||
    "$(stat -c '%u:%g' "$path")" = 0:0 ]] || return 1
}
manifest_value() {
  local key=$1 file=$2
  awk -F= -v wanted="$key" '
    $1 == wanted { if (++count > 1) exit 2; print substr($0, length($1) + 2) }
    END { if (count != 1) exit 3 }
  ' "$file"
}
valid_digest() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
valid_spki() {
  local value=$1 decoded recoded
  [[ "$value" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  decoded=$(mktemp) || return 1
  if ! printf '%s' "$value" | base64 -d >"$decoded" 2>/dev/null ||
    [[ "$(wc -c <"$decoded")" -ne 32 ]]; then
    rm -f -- "$decoded"
    return 1
  fi
  recoded=$(base64 <"$decoded" | tr -d '\r\n')
  rm -f -- "$decoded"
  [[ "$recoded" = "$value" ]]
}
record_evidence() {
  local mode=$1 outcome=$2 primary=$3 drift=$4 tmp
  [[ "$mode" =~ ^(ACTIVE_RESTORE|COMPLETED_FINALIZATION|INSPECT)$ ]] || return 65
  [[ "$outcome" =~ ^[A-Z0-9_]+$ && "$primary" =~ ^(PROVED_PRIMARY|UNPROVEN)$ ]] || return 65
  [[ "$drift" =~ ^(GREEN|ADVISORY_DRIFT|NOT_APPLICABLE)$ ]] || return 65
  [[ "${LEAF_SPKI_FAIL_EVIDENCE:-}" != 1 ]] || return 73
  mkdir -p "$STATE_DIR" || return 73
  tmp=$STATE_DIR/evidence.kv.tmp
  {
    printf 'schema=1\n'
    printf 'hostname=%s\n' "$LEAF_SPKI_HOSTNAME"
    printf 'restore_mode=%s\n' "$mode"
    printf 'outcome=%s\n' "$outcome"
    printf 'primary_status=%s\n' "$primary"
    printf 'invariant_status=%s\n' "$drift"
  } >"$tmp" || return 73
  chmod 600 "$tmp" || return 73
  mv -f -- "$tmp" "$STATE_DIR/evidence.kv" || return 73
  effect evidence-persist || return 73
}
namespace() {
  local entry name count=0 selected=
  if [[ ! -e "$RECOVERY_PARENT" ]]; then
    printf 'NONE\n'
    return 0
  fi
  is_directory_safe "$RECOVERY_PARENT" || return 65
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    case "$name" in
      preparing|active|completed)
        [[ -d "$entry" && ! -L "$entry" ]] || return 65
        count=$((count + 1))
        selected=$name
        ;;
      *) return 65 ;;
    esac
  done < <(find "$RECOVERY_PARENT" -mindepth 1 -maxdepth 1 -print0)
  if (( count == 0 )); then printf 'NONE\n'
  elif (( count == 1 )); then printf '%s\n' "$selected"
  else printf 'CONFLICT\n'
  fi
}
validate_package() {
  local name=$1 dir="$RECOVERY_PARENT/$1" manifest rollback key value
  local -A seen=()
  [[ "$name" = preparing || "$name" = active || "$name" = completed ]] || return 65
  is_directory_safe "$dir" || return 65
  manifest=$dir/manifest.kv
  rollback=$dir/nginx-source.rollback
  is_regular_safe "$manifest" || return 65
  is_regular_safe "$rollback" || return 65
  [[ "$(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')" = \
    "manifest.kv nginx-source.rollback " ]] || return 65
  while IFS= read -r line; do
    [[ "$line" =~ ^[a-z][a-z0-9_]*=[^[:cntrl:]]*$ ]] || return 65
    key=${line%%=*}; value=${line#*=}
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 65
    [[ ! -v "seen[$key]" ]] || return 65
    seen[$key]=1
  done <"$manifest"
  local source_digest rollback_digest source_path primary_spki hostname schema
  local self_sha256 manifest_without_self
  local tool_revision topology_digest primary_certificate primary_key
  local candidate_digest mixed_certificate_digest mixed_key_digest
  local source_uid source_gid source_mode
  schema=$(manifest_value schema "$manifest") || return 65
  source_digest=$(manifest_value source_digest "$manifest") || return 65
  rollback_digest=$(manifest_value rollback_digest "$manifest") || return 65
  source_path=$(manifest_value source_path "$manifest") || return 65
  primary_spki=$(manifest_value primary_spki "$manifest") || return 65
  hostname=$(manifest_value hostname "$manifest") || return 65
  self_sha256=$(manifest_value self_sha256 "$manifest") || return 65
  tool_revision=$(manifest_value tool_revision "$manifest") || return 65
  topology_digest=$(manifest_value topology_digest "$manifest") || return 65
  primary_certificate=$(manifest_value primary_certificate "$manifest") || return 65
  primary_key=$(manifest_value primary_key "$manifest") || return 65
  candidate_digest=$(manifest_value candidate_digest "$manifest") || return 65
  mixed_certificate_digest=$(manifest_value mixed_certificate_digest "$manifest") || return 65
  mixed_key_digest=$(manifest_value mixed_key_digest "$manifest") || return 65
  source_uid=$(manifest_value source_uid "$manifest") || return 65
  source_gid=$(manifest_value source_gid "$manifest") || return 65
  source_mode=$(manifest_value source_mode "$manifest") || return 65
  for key in "${!seen[@]}"; do
    case "$key" in
      schema|hostname|source_path|source_digest|rollback_digest|primary_spki|\
      source_uid|source_gid|source_mode|self_sha256|tool_revision|topology_digest|\
      primary_certificate|primary_key|candidate_digest|mixed_certificate_digest|\
      mixed_key_digest) ;;
      *) return 65 ;;
    esac
  done
  for key in schema hostname source_path source_digest rollback_digest primary_spki \
    self_sha256 tool_revision topology_digest primary_certificate primary_key \
    candidate_digest mixed_certificate_digest mixed_key_digest; do
    [[ -v "seen[$key]" ]] || return 65
  done
  [[ "$schema" = 1 ]] || return 65
  valid_digest "$source_digest" && valid_digest "$rollback_digest" &&
    valid_digest "$self_sha256" && valid_digest "$topology_digest" &&
    valid_digest "$candidate_digest" && valid_digest "$mixed_certificate_digest" &&
    valid_digest "$mixed_key_digest" || return 65
  valid_spki "$primary_spki" || return 65
  [[ "$source_uid" =~ ^[0-9]+$ && "$source_gid" =~ ^[0-9]+$ &&
    "$source_mode" =~ ^[0-7]{3,4}$ ]] || return 65
  [[ "$hostname" = "$LEAF_SPKI_HOSTNAME" && "$source_path" = "$NGINX_SOURCE" ]] || return 65
  [[ "$tool_revision" = "$LEAF_SPKI_BACKEND_SOURCE" &&
      "$primary_certificate" = /etc/letsencrypt/live/api.whysoezzy.online/fullchain.pem &&
      "$primary_key" = /etc/letsencrypt/live/api.whysoezzy.online/privkey.pem ]] || return 65
  [[ "$(stat -c '%d' "$manifest")" = "$(stat -c '%d' "$dir")" &&
      "$(stat -c '%d' "$rollback")" = "$(stat -c '%d' "$dir")" ]] || return 65
  [[ "$(sha256_file "$rollback")" = "$rollback_digest" ]] || return 65
  [[ "$(tail -n 1 "$manifest")" = "self_sha256=$self_sha256" ]] || return 65
  manifest_without_self=$(mktemp) || return 65
  sed '$d' "$manifest" >"$manifest_without_self"
  [[ "$(sha256_file "$manifest_without_self")" = "$self_sha256" ]] || {
    rm -f -- "$manifest_without_self"
    return 65
  }
  rm -f -- "$manifest_without_self"
  printf '%s\n' "$manifest"
}
validate_package_shape() {
  local name=$1 dir="$RECOVERY_PARENT/$1" manifest rollback
  [[ "$name" = preparing || "$name" = active || "$name" = completed ]] || return 1
  is_directory_safe "$dir" || return 1
  manifest=$dir/manifest.kv
  rollback=$dir/nginx-source.rollback
  is_regular_safe "$manifest" || return 1
  is_regular_safe "$rollback" || return 1
  [[ "$(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')" = \
    "manifest.kv nginx-source.rollback " ]] || return 1
  [[ "$(stat -c '%d' "$manifest")" = "$(stat -c '%d' "$dir")" &&
    "$(stat -c '%d' "$rollback")" = "$(stat -c '%d' "$dir")" ]]
}
validate_original_source() {
  local manifest=$1 source_digest current_digest source_uid source_gid source_mode
  local topology_digest primary_certificate primary_key
  source_digest=$(manifest_value source_digest "$manifest") || return 20
  current_digest=$(sha256_file "$NGINX_SOURCE") || return 20
  [[ "$current_digest" = "$source_digest" ]] || return 20
  source_uid=$(manifest_value source_uid "$manifest" 2>/dev/null || true)
  source_gid=$(manifest_value source_gid "$manifest" 2>/dev/null || true)
  source_mode=$(manifest_value source_mode "$manifest" 2>/dev/null || true)
  topology_digest=$(manifest_value topology_digest "$manifest") || return 20
  primary_certificate=$(manifest_value primary_certificate "$manifest") || return 20
  primary_key=$(manifest_value primary_key "$manifest") || return 20
  if [[ -z "$LEAF_SPKI_FIXTURE" ]]; then
    [[ -z "$source_uid" || "$(stat -c '%u' "$NGINX_SOURCE")" = "$source_uid" ]] || return 20
    [[ -z "$source_gid" || "$(stat -c '%g' "$NGINX_SOURCE")" = "$source_gid" ]] || return 20
    [[ -z "$source_mode" || "$(stat -c '%a' "$NGINX_SOURCE")" = "$source_mode" ]] || return 20
  fi
  grep -Fq "ssl_certificate $primary_certificate;" "$NGINX_SOURCE" || return 20
  grep -Fq "ssl_certificate_key $primary_key;" "$NGINX_SOURCE" || return 20
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    [[ -f "$ROOT_DIR/topology.digest" ]] || return 20
    [[ "$(<"$ROOT_DIR/topology.digest")" = "$topology_digest" ]] || return 20
  else
    command -v nginx >/dev/null 2>&1 || return 69
    [[ "$(nginx -T 2>/dev/null | sha256sum | awk '{print $1}')" = "$topology_digest" ]] ||
      return 20
  fi
  return 0
}
prove_external_primary() {
  local expected=$1
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    local observation="$ROOT_DIR/observations/external-primary.kv"
    local observed_hostname observed_chain observed_spki
    [[ -f "$observation" && ! -L "$observation" ]] || return 69
    observed_hostname=$(manifest_value hostname "$observation") || return 69
    observed_chain=$(manifest_value chain "$observation") || return 69
    observed_spki=$(manifest_value spki "$observation") || return 69
    [[ "$observed_hostname" = "$LEAF_SPKI_HOSTNAME" ]] || return 20
    [[ "$observed_chain" = VERIFIED ]] || return 20
    valid_spki "$observed_spki" || return 69
    [[ "$observed_spki" = "$expected" ]] || return 20
    return 0
  fi
  command -v openssl >/dev/null 2>&1 || return 69
  local actual
  actual=$(openssl s_client -connect "$LEAF_SPKI_HOSTNAME:443" \
    -servername "$LEAF_SPKI_HOSTNAME" -verify_hostname "$LEAF_SPKI_HOSTNAME" \
    -verify_return_error </dev/null 2>/dev/null |
    openssl x509 -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null |
    openssl dgst -sha256 -binary 2>/dev/null |
    base64 | tr -d '\r\n') || return 69
  [[ "$actual" = "$expected" ]] || return 20
}
observe_advisory_status() {
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    local observation="$ROOT_DIR/observations/advisory.kv" status
    [[ -f "$observation" && ! -L "$observation" ]] || return 69
    status=$(manifest_value status "$observation") || return 69
    [[ "$status" = GREEN || "$status" = DRIFT ]] || return 69
    printf '%s\n' "$status"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || return 69
  local app_status actuator_status
  app_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --max-time 15 "https://$LEAF_SPKI_HOSTNAME/api/v1/tags") || return 69
  actuator_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --max-time 15 "https://$LEAF_SPKI_HOSTNAME/actuator") || return 69
  if [[ "$app_status" = 200 &&
    "$actuator_status" =~ ^(401|403|404)$ ]]; then
    printf 'GREEN\n'
  else
    printf 'DRIFT\n'
  fi
}
sync_parent() {
  effect parent-sync || return 73
  [[ -n "$LEAF_SPKI_FIXTURE" && "${LEAF_SPKI_FAIL_SYNC:-}" = 1 ]] && return 73
  [[ -n "$LEAF_SPKI_FIXTURE" ]] || sync -f "$RECOVERY_PARENT" || return 73
}
reopen_completed() {
  [[ -z "$LEAF_SPKI_FIXTURE" || "${LEAF_SPKI_FAIL_REOPEN:-}" != 1 ]] || return 73
  [[ "$(namespace)" = completed ]] || return 73
  local manifest
  manifest=$(validate_package completed) || return 73
  validate_original_source "$manifest" || return 73
  prove_external_primary "$(manifest_value primary_spki "$manifest")" || return 73
}
completed_finalize() {
  local manifest drift rc
  validate_package_shape completed || return 65
  manifest=$(validate_package completed) || return 20
  validate_original_source "$manifest" || {
    rc=$?
    [[ "$rc" = 69 ]] && return 69
    return 20
  }
  prove_external_primary "$(manifest_value primary_spki "$manifest")" || return $?
  drift=$(observe_advisory_status) || return $?
  [[ "$drift" = GREEN ]] || drift=ADVISORY_DRIFT
  sync_parent || return 73
  reopen_completed || return 73
  record_evidence COMPLETED_FINALIZATION PRIMARY_RESTORED PROVED_PRIMARY "$drift" || return 73
  [[ "$drift" = GREEN ]] && return 0 || return 10
}
active_restore() {
  local manifest source_digest current_digest rollback rc
  local candidate_digest mixed_certificate_digest mixed_key_digest
  manifest=$(validate_package active) || return 20
  source_digest=$(manifest_value source_digest "$manifest") || return 20
  candidate_digest=$(manifest_value candidate_digest "$manifest") || return 20
  mixed_certificate_digest=$(manifest_value mixed_certificate_digest "$manifest") || return 20
  mixed_key_digest=$(manifest_value mixed_key_digest "$manifest") || return 20
  rollback="$RECOVERY_PARENT/active/nginx-source.rollback"
  current_digest=$(sha256_file "$NGINX_SOURCE") || return 20
  if [[ "$current_digest" != "$source_digest" ]]; then
    [[ "$current_digest" = "$candidate_digest" ||
      "$current_digest" = "$mixed_certificate_digest" ||
      "$current_digest" = "$mixed_key_digest" ]] || return 20
    if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
      cp -- "$rollback" "$NGINX_SOURCE" || return 20
    else
      install -o "$(manifest_value source_uid "$manifest")" \
        -g "$(manifest_value source_gid "$manifest")" \
        -m "$(manifest_value source_mode "$manifest")" \
        "$rollback" "$NGINX_SOURCE" || return 20
    fi
    effect nginx-install || return 20
    [[ -z "$LEAF_SPKI_FIXTURE" || "${LEAF_SPKI_FAIL_NGINX_TEST:-}" != 1 ]] || return 20
    effect nginx-test || return 20
    if [[ -z "$LEAF_SPKI_FIXTURE" ]]; then
      nginx -t || return 20
    fi
    [[ -z "$LEAF_SPKI_FIXTURE" || "${LEAF_SPKI_FAIL_NGINX_RELOAD:-}" != 1 ]] || return 20
    effect nginx-reload || return 20
    if [[ -z "$LEAF_SPKI_FIXTURE" ]]; then
      systemctl reload nginx || return 20
    fi
  fi
  validate_original_source "$manifest" || {
    rc=$?
    [[ "$rc" = 69 ]] && return 69
    return 20
  }
  prove_external_primary "$(manifest_value primary_spki "$manifest")" || return $?
  local active_identity
  active_identity=$(stat -c '%d:%i' "$RECOVERY_PARENT/active") || return 73
  [[ ! -e "$RECOVERY_PARENT/completed" && ! -L "$RECOVERY_PARENT/completed" ]] || return 73
  mv -T -n --no-copy "$RECOVERY_PARENT/active" "$RECOVERY_PARENT/completed" || return 73
  [[ ! -e "$RECOVERY_PARENT/active" && ! -L "$RECOVERY_PARENT/active" &&
    -d "$RECOVERY_PARENT/completed" && ! -L "$RECOVERY_PARENT/completed" &&
    "$(stat -c '%d:%i' "$RECOVERY_PARENT/completed")" = "$active_identity" ]] || return 73
  effect active-to-completed || return 73
  sync_parent || return 73
  completed_finalize
}
inspect_mode() {
  local state
  state=$(namespace) || return 65
  record_evidence INSPECT INSPECT_COMPLETE UNPROVEN NOT_APPLICABLE || return 73
  printf 'namespace=%s\n' "$state"
}
dispatch_phase() {
  local phase=$1
  case "$phase" in
    inspect) inspect_mode ;;
    configure-primary|ensure-rollover|configure-rollover|\
    verify-primary-renewal|verify-rollover-renewal)
      # Forward Certbot operations are intentionally not part of this bounded
      # recovery core. Never report synthetic success or emit an effect.
      return 65
      ;;
    drill)
      [[ "$(namespace)" = NONE ]] || return 65
      return 65
      ;;
    restore)
      local state
      state=$(namespace) || return 65
      case "$state" in
        active) active_restore ;;
        completed) completed_finalize ;;
        *) return 65 ;;
      esac
      ;;
    *) return 64 ;;
  esac
}
run_rollover() {
  local phase=$1 fd lock_dir=
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    mkdir -p "$(dirname "$LOCK_FILE")"
  else
    [[ -d "$(dirname "$LOCK_FILE")" && ! -L "$(dirname "$LOCK_FILE")" ]] || return 65
  fi
  if command -v flock >/dev/null 2>&1; then
    exec {fd}>"$LOCK_FILE" || return 75
    flock -n "$fd" || return 75
  else
    [[ -n "$LEAF_SPKI_FIXTURE" ]] || return 75
    lock_dir="${LOCK_FILE}.d"
    mkdir "$lock_dir" 2>/dev/null || return 75
    LEAF_SPKI_FIXTURE_LOCK_DIR=$lock_dir
    trap 'rmdir -- "${LEAF_SPKI_FIXTURE_LOCK_DIR:?}" 2>/dev/null || true' EXIT
  fi
  dispatch_phase "$phase"
}
