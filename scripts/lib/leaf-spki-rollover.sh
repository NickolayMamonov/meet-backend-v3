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
readonly LEAF_SPKI_PRIMARY_CERT=/etc/letsencrypt/live/api.whysoezzy.online/fullchain.pem
readonly LEAF_SPKI_PRIMARY_KEY=/etc/letsencrypt/live/api.whysoezzy.online/privkey.pem
readonly LEAF_SPKI_ROLLOVER_CERT=/etc/letsencrypt/live/api.whysoezzy.online-rollover/fullchain.pem
readonly LEAF_SPKI_ROLLOVER_KEY=/etc/letsencrypt/live/api.whysoezzy.online-rollover/privkey.pem

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
effect_detail() {
  [[ "$EFFECT_LOG" = /dev/null ]] && return 0
  mkdir -p "$(dirname "$EFFECT_LOG")" || return 73
  printf '%s' "$1" >>"$EFFECT_LOG" || return 73
  shift
  printf '\t%s' "$@" >>"$EFFECT_LOG" || return 73
  printf '\n' >>"$EFFECT_LOG" || return 73
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
valid_spki() { [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
ensure_state_dir() {
  local parent
  if [[ -L "$STATE_DIR" ]]; then
    return 65
  fi
  if [[ -e "$STATE_DIR" ]]; then
    is_directory_safe "$STATE_DIR" || return 65
    return 0
  fi
  parent=${STATE_DIR%/*}
  [[ -d "$parent" && ! -L "$parent" ]] || return 73
  if [[ -z "$LEAF_SPKI_FIXTURE" ]]; then
    [[ "$(stat -c '%u:%g' "$parent")" = 0:0 ]] || return 65
    [[ $((8#$(stat -c '%a' "$parent") & 8#022)) -eq 0 ]] || return 65
  fi
  mkdir -- "$STATE_DIR" || return 73
  chmod 700 "$STATE_DIR" || return 73
  is_directory_safe "$STATE_DIR" || return 73
}
atomic_state_file() {
  local destination=$1 tmp=$2
  [[ "$destination" = "$STATE_DIR"/* && "$tmp" = "$STATE_DIR"/* ]] || return 70
  if [[ -L "$destination" || (-e "$destination" && ! -f "$destination") ]]; then
    return 65
  fi
  if [[ -e "$destination" ]]; then
    is_regular_safe "$destination" || return 65
  fi
  is_regular_safe "$tmp" || return 65
  chmod 600 "$tmp" || return 73
  mv -f -- "$tmp" "$destination" || return 73
}
new_state_temp() {
  local stem=$1 tmp
  [[ "$stem" =~ ^[a-z][a-z0-9.-]+$ ]] || return 70
  tmp=$(mktemp "$STATE_DIR/$stem.XXXXXXXX") || return 73
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 73; }
  is_regular_safe "$tmp" || { rm -f -- "$tmp"; return 65; }
  printf '%s\n' "$tmp"
}
fixture_observation() {
  local key=$1 file=$ROOT_DIR/observations/leaf-spki.kv
  [[ -n "$LEAF_SPKI_FIXTURE" ]] || return 70
  [[ -f "$file" && ! -L "$file" ]] || return 69
  manifest_value "$key" "$file" || return 69
}
certbot_account() {
  local environment=$1 root value
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    value=$(fixture_observation "${environment}_account") || return $?
    [[ "$value" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || return 69
    printf '%s\n' "$value"
    return 0
  fi
  case "$environment" in
    production) root=/etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory ;;
    staging) root=/etc/letsencrypt/accounts/acme-staging-v02.api.letsencrypt.org/directory ;;
    *) return 70 ;;
  esac
  [[ -d "$root" && ! -L "$root" ]] || return 69
  mapfile -t accounts < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
  [[ "${#accounts[@]}" = 1 && "${accounts[0]}" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || return 65
  printf '%s\n' "${accounts[0]}"
}
certbot_webroot() {
  local value file=/etc/letsencrypt/renewal/$LEAF_SPKI_PRIMARY_LINEAGE.conf
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    value=$(fixture_observation webroot) || return $?
  else
    [[ -f "$file" && ! -L "$file" ]] || return 69
    value=$(awk -F' = ' '/^webroot_path = / { print $2 }' "$file")
  fi
  [[ "$value" = /* && "$value" != / && "$value" != *$'\n'* ]] || return 65
  printf '%s\n' "$value"
}
lineage_spki() {
  local lineage=$1 value certificate
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    case "$lineage" in
      "$LEAF_SPKI_PRIMARY_LINEAGE") value=$(fixture_observation primary_spki) || return $? ;;
      "$LEAF_SPKI_ROLLOVER_LINEAGE") value=$(fixture_observation rollover_spki) || return $? ;;
      *) return 70 ;;
    esac
  else
    case "$lineage" in
      "$LEAF_SPKI_PRIMARY_LINEAGE") certificate=$LEAF_SPKI_PRIMARY_CERT ;;
      "$LEAF_SPKI_ROLLOVER_LINEAGE") certificate=$LEAF_SPKI_ROLLOVER_CERT ;;
      *) return 70 ;;
    esac
    [[ -r "$certificate" ]] || return 69
    command -v openssl >/dev/null 2>&1 || return 69
    value=$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null |
      openssl pkey -pubin -outform DER 2>/dev/null |
      openssl dgst -sha256 -binary 2>/dev/null |
      base64 | tr -d '\r\n') || return 69
  fi
  valid_spki "$value" || return 69
  printf '%s\n' "$value"
}
rollover_presence() {
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    local value
    value=$(fixture_observation rollover_present) || return $?
    [[ "$value" = YES || "$value" = NO ]] || return 69
    printf '%s\n' "$value"
    return 0
  fi
  local live=/etc/letsencrypt/live/$LEAF_SPKI_ROLLOVER_LINEAGE
  local archive=/etc/letsencrypt/archive/$LEAF_SPKI_ROLLOVER_LINEAGE
  local renewal=/etc/letsencrypt/renewal/$LEAF_SPKI_ROLLOVER_LINEAGE.conf
  if [[ ! -e "$live" && ! -L "$live" && ! -e "$archive" && ! -L "$archive" &&
    ! -e "$renewal" && ! -L "$renewal" ]]; then
    printf 'NO\n'
  elif [[ -d "$live" && ! -L "$live" && -d "$archive" && ! -L "$archive" &&
    -f "$renewal" && ! -L "$renewal" ]]; then
    printf 'YES\n'
  else
    return 65
  fi
}
prove_rollover_dormant() {
  local source=$NGINX_SOURCE
  [[ -f "$source" && ! -L "$source" ]] || return 69
  ! grep -Fq "$LEAF_SPKI_ROLLOVER_LINEAGE" "$source" || return 65
}
validate_rollover_configuration() {
  local file=/etc/letsencrypt/renewal/$LEAF_SPKI_ROLLOVER_LINEAGE.conf
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    [[ "$(fixture_observation rollover_configuration)" = VALID ]] || return 65
    return 0
  fi
  [[ -f "$file" && ! -L "$file" ]] || return 65
  grep -Eq '^authenticator = webroot$' "$file" || return 65
  grep -Eq '^key_type = ecdsa$' "$file" || return 65
  grep -Eq '^elliptic_curve = secp256r1$' "$file" || return 65
  grep -Eq '^reuse_key = True$' "$file" || return 65
  [[ "$(awk -F' = ' '/^webroot_path = / { print $2 }' "$file")" = "$(certbot_webroot)" ]] ||
    return 65
  ! grep -Eq '^(pre_hook|post_hook|renew_hook|deploy_hook) = ' "$file" || return 65
}
run_certbot() {
  local operation=$1 rc=0
  shift
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    effect certbot-"$operation" || return 73
    effect_detail certbot-argv /usr/bin/certbot "$@" || return 73
    [[ "${LEAF_SPKI_FAIL_CERTBOT:-}" != 1 &&
      "${LEAF_SPKI_FAIL_CERTBOT_OPERATION:-}" != "$operation" ]] || return 74
    return 0
  fi
  command -v /usr/bin/certbot >/dev/null 2>&1 || return 69
  /usr/bin/certbot "$@" || rc=$?
  [[ "$rc" = 0 ]] || return 74
}
record_evidence() {
  local mode=$1 outcome=$2 primary=$3 drift=$4 tmp
  [[ "$mode" =~ ^(ACTIVE_RESTORE|COMPLETED_FINALIZATION|INSPECT|FORWARD|DRILL)$ ]] || return 65
  [[ "$outcome" =~ ^[A-Z0-9_]+$ && "$primary" =~ ^(PROVED_PRIMARY|UNPROVEN)$ ]] || return 65
  [[ "$drift" =~ ^(GREEN|ADVISORY_DRIFT|NOT_APPLICABLE)$ ]] || return 65
  [[ "${LEAF_SPKI_FAIL_EVIDENCE:-}" != 1 ]] || return 73
  ensure_state_dir || return $?
  tmp=$(new_state_temp evidence.kv.tmp) || return $?
  {
    printf 'schema=1\n'
    printf 'hostname=%s\n' "$LEAF_SPKI_HOSTNAME"
    printf 'restore_mode=%s\n' "$mode"
    printf 'outcome=%s\n' "$outcome"
    printf 'primary_status=%s\n' "$primary"
    printf 'invariant_status=%s\n' "$drift"
  } >"$tmp" || return 73
  atomic_state_file "$STATE_DIR/evidence.kv" "$tmp" || return $?
  effect evidence-persist || return 73
}
namespace() {
  local entry name count=0 selected=
  local -a entries=()
  [[ ! -L "$RECOVERY_PARENT" ]] || return 65
  if [[ ! -e "$RECOVERY_PARENT" ]]; then
    printf 'NONE\n'
    return 0
  fi
  is_directory_safe "$RECOVERY_PARENT" || return 65
  shopt -s nullglob
  entries=("$RECOVERY_PARENT"/*)
  shopt -u nullglob
  for entry in "${entries[@]}"; do
    name=${entry##*/}
    case "$name" in
      preparing|active|completed)
        [[ -d "$entry" && ! -L "$entry" ]] || return 65
        count=$((count + 1))
        selected=$name
        ;;
      *) return 65 ;;
    esac
  done
  if (( count == 0 )); then printf 'NONE\n'
  elif (( count == 1 )); then printf '%s\n' "$selected"
  else printf 'CONFLICT\n'
  fi
}
validate_package() {
  local name=$1 dir="$RECOVERY_PARENT/$1" manifest rollback key value
  local -A seen=()
  local entry entry_count=0 has_manifest=0 has_rollback=0
  [[ "$name" = preparing || "$name" = active || "$name" = completed ]] || return 65
  is_directory_safe "$dir" || return 65
  manifest=$dir/manifest.kv
  rollback=$dir/nginx-source.rollback
  is_regular_safe "$manifest" || return 65
  is_regular_safe "$rollback" || return 65
  shopt -s nullglob
  for entry in "$dir"/*; do
    entry_count=$((entry_count + 1))
    case "${entry##*/}" in
      manifest.kv) has_manifest=1 ;;
      nginx-source.rollback) has_rollback=1 ;;
      *) return 65 ;;
    esac
  done
  shopt -u nullglob
  [[ "$entry_count" = 2 && "$has_manifest" = 1 && "$has_rollback" = 1 ]] || return 65
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
  local entry entry_count=0 has_manifest=0 has_rollback=0
  [[ "$name" = preparing || "$name" = active || "$name" = completed ]] || return 1
  is_directory_safe "$dir" || return 1
  manifest=$dir/manifest.kv
  rollback=$dir/nginx-source.rollback
  is_regular_safe "$manifest" || return 1
  is_regular_safe "$rollback" || return 1
  shopt -s nullglob
  for entry in "$dir"/*; do
    entry_count=$((entry_count + 1))
    case "${entry##*/}" in
      manifest.kv) has_manifest=1 ;;
      nginx-source.rollback) has_rollback=1 ;;
      *) return 1 ;;
    esac
  done
  shopt -u nullglob
  [[ "$entry_count" = 2 && "$has_manifest" = 1 && "$has_rollback" = 1 ]] || return 1
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
    case "${LEAF_SPKI_FIXTURE_EXTERNAL_ROLE:-primary}" in
      primary) ;;
      rollover) observed_spki=$(fixture_observation external_rollover_spki) || return $? ;;
      unavailable) return 69 ;;
      *) return 65 ;;
    esac
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
prove_external_rollover() {
  local expected=$1
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    local observation=$ROOT_DIR/observations/external-rollover.kv
    local observed_hostname observed_chain observed_spki
    [[ -f "$observation" && ! -L "$observation" ]] || return 69
    observed_hostname=$(manifest_value hostname "$observation") || return 69
    observed_chain=$(manifest_value chain "$observation") || return 69
    observed_spki=$(manifest_value spki "$observation") || return 69
    [[ "$observed_hostname" = "$LEAF_SPKI_HOSTNAME" && "$observed_chain" = VERIFIED ]] ||
      return 20
    valid_spki "$observed_spki" || return 69
    [[ "$observed_spki" = "$expected" ]] || return 20
    return 0
  fi
  prove_external_primary "$expected"
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
  [[ ! -e "$RECOVERY_PARENT/completed" && ! -L "$RECOVERY_PARENT/completed" ]] || return 73
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    mv -T -n "$RECOVERY_PARENT/active" "$RECOVERY_PARENT/completed" || return 73
  else
    mv -T -n --no-copy "$RECOVERY_PARENT/active" "$RECOVERY_PARENT/completed" || return 73
  fi
  [[ ! -e "$RECOVERY_PARENT/active" && ! -L "$RECOVERY_PARENT/active" &&
    -d "$RECOVERY_PARENT/completed" && ! -L "$RECOVERY_PARENT/completed" ]] || return 73
  effect active-to-completed || return 73
  sync_parent || return 73
  completed_finalize
}
render_rollover_candidate() {
  local source=$1 destination=$2 cert_count key_count normalized_source normalized_destination
  cert_count=$(awk -v expected="$LEAF_SPKI_PRIMARY_CERT" '
    $1 == "ssl_certificate" && $2 == expected ";" && NF == 2 { count++ }
    END { print count + 0 }
  ' "$source")
  key_count=$(awk -v expected="$LEAF_SPKI_PRIMARY_KEY" '
    $1 == "ssl_certificate_key" && $2 == expected ";" && NF == 2 { count++ }
    END { print count + 0 }
  ' "$source")
  [[ "$cert_count" = 1 && "$key_count" = 1 ]] || return 65
  awk -v cert="$LEAF_SPKI_ROLLOVER_CERT" -v key="$LEAF_SPKI_ROLLOVER_KEY" '
    $1 == "ssl_certificate" { sub($2, cert ";") }
    $1 == "ssl_certificate_key" { sub($2, key ";") }
    { print }
  ' "$source" >"$destination" || return 73
  normalized_source=$(mktemp) || return 73
  normalized_destination=$(mktemp) || { rm -f -- "$normalized_source"; return 73; }
  awk '$1 == "ssl_certificate" { $2 = "<CERT>;" }
       $1 == "ssl_certificate_key" { $2 = "<KEY>;" }
       { print }' "$source" >"$normalized_source" || return 73
  awk '$1 == "ssl_certificate" { $2 = "<CERT>;" }
       $1 == "ssl_certificate_key" { $2 = "<KEY>;" }
       { print }' "$destination" >"$normalized_destination" || return 73
  cmp -s "$normalized_source" "$normalized_destination" || {
    rm -f -- "$normalized_source" "$normalized_destination"
    return 65
  }
  rm -f -- "$normalized_source" "$normalized_destination"
}
render_mixed_candidate() {
  local source=$1 destination=$2 kind=$3
  case "$kind" in
    certificate)
      sed "s#^\([[:space:]]*ssl_certificate[[:space:]]\+\)$LEAF_SPKI_PRIMARY_CERT;\([[:space:]]*\)\$#\1$LEAF_SPKI_ROLLOVER_CERT;\2#" \
        "$source" >"$destination" || return 73
      ;;
    key)
      sed "s#^\([[:space:]]*ssl_certificate_key[[:space:]]\+\)$LEAF_SPKI_PRIMARY_KEY;\([[:space:]]*\)\$#\1$LEAF_SPKI_ROLLOVER_KEY;\2#" \
        "$source" >"$destination" || return 73
      ;;
    *) return 70 ;;
  esac
}
install_nginx_source() {
  local source=$1
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    cp -- "$source" "$NGINX_SOURCE" || return 20
  else
    install -o "$(stat -c '%u' "$NGINX_SOURCE")" \
      -g "$(stat -c '%g' "$NGINX_SOURCE")" \
      -m "$(stat -c '%a' "$NGINX_SOURCE")" \
      "$source" "$NGINX_SOURCE" || return 20
  fi
  effect nginx-install || return 20
}
nginx_test_reload() {
  [[ -z "$LEAF_SPKI_FIXTURE" || "${LEAF_SPKI_FAIL_NGINX_TEST:-}" != 1 ]] || return 20
  effect nginx-test || return 20
  [[ -n "$LEAF_SPKI_FIXTURE" ]] || nginx -t || return 20
  [[ -z "$LEAF_SPKI_FIXTURE" || "${LEAF_SPKI_FAIL_NGINX_RELOAD:-}" != 1 ]] || return 20
  effect nginx-reload || return 20
  [[ -n "$LEAF_SPKI_FIXTURE" ]] || systemctl reload nginx || return 20
}
prepare_recovery_package() {
  local primary=$1 candidate=$2 mixed_certificate=$3 mixed_key=$4
  local preparing=$RECOVERY_PARENT/preparing manifest rollback source_digest rollback_digest
  local source_uid source_gid source_mode topology_digest self_sha256 active_identity
  [[ "$(namespace)" = NONE ]] || return 65
  mkdir -- "$RECOVERY_PARENT" || return 73
  chmod 700 "$RECOVERY_PARENT" || return 73
  is_directory_safe "$RECOVERY_PARENT" || return 73
  mkdir -- "$preparing" || return 73
  chmod 700 "$preparing" || return 73
  rollback=$preparing/nginx-source.rollback
  cp -- "$NGINX_SOURCE" "$rollback" || return 73
  chmod 600 "$rollback" || return 73
  source_digest=$(sha256_file "$NGINX_SOURCE") || return 73
  rollback_digest=$(sha256_file "$rollback") || return 73
  source_uid=$(stat -c '%u' "$NGINX_SOURCE") || return 73
  source_gid=$(stat -c '%g' "$NGINX_SOURCE") || return 73
  source_mode=$(stat -c '%a' "$NGINX_SOURCE") || return 73
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    [[ -f "$ROOT_DIR/topology.digest" && ! -L "$ROOT_DIR/topology.digest" ]] || return 69
    topology_digest=$(<"$ROOT_DIR/topology.digest")
  else
    topology_digest=$(nginx -T 2>/dev/null | sha256sum | awk '{print $1}') || return 69
  fi
  valid_digest "$topology_digest" || return 69
  manifest=$preparing/manifest.kv
  {
    printf 'schema=1\nhostname=%s\nsource_path=%s\n' "$LEAF_SPKI_HOSTNAME" "$NGINX_SOURCE"
    printf 'source_digest=%s\nrollback_digest=%s\nprimary_spki=%s\n' \
      "$source_digest" "$rollback_digest" "$primary"
    printf 'source_uid=%s\nsource_gid=%s\nsource_mode=%s\n' \
      "$source_uid" "$source_gid" "$source_mode"
    printf 'tool_revision=%s\ntopology_digest=%s\n' "$LEAF_SPKI_BACKEND_SOURCE" "$topology_digest"
    printf 'primary_certificate=%s\nprimary_key=%s\n' \
      "$LEAF_SPKI_PRIMARY_CERT" "$LEAF_SPKI_PRIMARY_KEY"
    printf 'candidate_digest=%s\nmixed_certificate_digest=%s\nmixed_key_digest=%s\n' \
      "$(sha256_file "$candidate")" "$(sha256_file "$mixed_certificate")" "$(sha256_file "$mixed_key")"
  } >"$manifest" || return 73
  self_sha256=$(sha256_file "$manifest") || return 73
  printf 'self_sha256=%s\n' "$self_sha256" >>"$manifest" || return 73
  chmod 600 "$manifest" || return 73
  validate_package preparing >/dev/null || return 73
  active_identity=$(stat -c '%d:%i' "$preparing") || return 73
  if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    mv -T -n "$preparing" "$RECOVERY_PARENT/active" || return 73
  else
    mv -T -n --no-copy "$preparing" "$RECOVERY_PARENT/active" || return 73
  fi
  [[ "$(stat -c '%d:%i' "$RECOVERY_PARENT/active")" = "$active_identity" ]] || return 73
  effect preparing-to-active || return 73
  [[ "${LEAF_SPKI_FAIL_ACTIVE_PERSIST:-}" != 1 ]] || return 73
}
drill_mode() {
  local primary rollover work candidate mixed_certificate mixed_key rc=0 restored_rc
  [[ "$(namespace)" = NONE ]] || return 65
  primary=$(lineage_spki "$LEAF_SPKI_PRIMARY_LINEAGE") || return $?
  rollover=$(lineage_spki "$LEAF_SPKI_ROLLOVER_LINEAGE") || return $?
  [[ "$primary" != "$rollover" ]] || return 65
  prove_external_primary "$primary" || return $?
  prove_rollover_dormant || return $?
  run_certbot primary-renew-dry-run renew \
    --non-interactive --cert-name "$LEAF_SPKI_PRIMARY_LINEAGE" \
    --dry-run --no-directory-hooks || return $?
  run_certbot rollover-renew-dry-run renew \
    --non-interactive --cert-name "$LEAF_SPKI_ROLLOVER_LINEAGE" \
    --dry-run --no-directory-hooks || return $?
  work=$(mktemp -d) || return 73
  candidate=$work/candidate
  mixed_certificate=$work/mixed-certificate
  mixed_key=$work/mixed-key
  render_rollover_candidate "$NGINX_SOURCE" "$candidate" || { rm -r -- "$work"; return $?; }
  render_mixed_candidate "$NGINX_SOURCE" "$mixed_certificate" certificate ||
    { rm -r -- "$work"; return $?; }
  render_mixed_candidate "$NGINX_SOURCE" "$mixed_key" key || { rm -r -- "$work"; return $?; }
  prepare_recovery_package "$primary" "$candidate" "$mixed_certificate" "$mixed_key" ||
    { rc=$?; rm -r -- "$work"; return "$rc"; }
  if ! install_nginx_source "$candidate"; then
    rc=1
  elif ! nginx_test_reload; then
    rc=1
  elif [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
    [[ "${LEAF_SPKI_FAIL_ROLLOVER_PROOF:-}" != 1 ]] || rc=1
    prove_external_rollover "$rollover" || rc=1
  else
    prove_external_rollover "$rollover" || rc=1
  fi
  rm -r -- "$work"
  if active_restore; then
    restored_rc=0
  else
    restored_rc=$?
  fi
  [[ "$restored_rc" = 0 || "$restored_rc" = 10 ]] || return 20
  if [[ "$rc" = 0 && "$restored_rc" = 0 ]]; then
    record_evidence DRILL PRIMARY_RESTORED PROVED_PRIMARY GREEN || return 73
    return 0
  fi
  record_evidence DRILL DRILL_FAILED_PRIMARY_RESTORED PROVED_PRIMARY ADVISORY_DRIFT || return 73
  return 10
}
inspect_mode() {
  local recovery primary rollover=
  recovery=$(namespace) || return 65
  primary=$(lineage_spki "$LEAF_SPKI_PRIMARY_LINEAGE") || return $?
  prove_external_primary "$primary" || return $?
  if [[ "$recovery" = active || "$recovery" = preparing || "$recovery" = CONFLICT ]]; then
    return 65
  fi
  if [[ "$(rollover_presence)" = YES ]]; then
    rollover=$(lineage_spki "$LEAF_SPKI_ROLLOVER_LINEAGE") || return $?
    [[ "$primary" != "$rollover" ]] || return 65
    prove_rollover_dormant || return $?
  fi
  record_evidence INSPECT INSPECT_COMPLETE UNPROVEN NOT_APPLICABLE || return $?
  printf 'namespace=%s\nprimary_spki=%s\n' "$recovery" "$primary"
  [[ -z "$rollover" ]] || printf 'rollover_spki=%s\n' "$rollover"
}
configure_primary() {
  local primary webroot
  primary=$(lineage_spki "$LEAF_SPKI_PRIMARY_LINEAGE") || return $?
  prove_external_primary "$primary" || return $?
  webroot=$(certbot_webroot) || return $?
  run_certbot primary-reconfigure reconfigure \
    --non-interactive \
    --cert-name "$LEAF_SPKI_PRIMARY_LINEAGE" \
    --webroot \
    --webroot-path "$webroot" \
    --key-type ecdsa \
    --elliptic-curve secp256r1 \
    --reuse-key \
    --no-directory-hooks || return $?
  [[ "$(lineage_spki "$LEAF_SPKI_PRIMARY_LINEAGE")" = "$primary" ]] || return 65
  prove_external_primary "$primary" || return $?
  record_evidence FORWARD PRIMARY_REUSE_VERIFIED PROVED_PRIMARY GREEN || return $?
  printf 'primary_spki=%s\n' "$primary"
}
ensure_rollover() {
  local primary rollover presence webroot production_account
  primary=$(lineage_spki "$LEAF_SPKI_PRIMARY_LINEAGE") || return $?
  prove_external_primary "$primary" || return $?
  webroot=$(certbot_webroot) || return $?
  production_account=$(certbot_account production) || return $?
  presence=$(rollover_presence) || return $?
  if [[ "$presence" = NO ]]; then
    run_certbot rollover-certonly certonly \
      --non-interactive \
      --server https://acme-v02.api.letsencrypt.org/directory \
      --account "$production_account" \
      --webroot \
      --webroot-path "$webroot" \
      --domains "$LEAF_SPKI_HOSTNAME" \
      --cert-name "$LEAF_SPKI_ROLLOVER_LINEAGE" \
      --key-type ecdsa \
      --elliptic-curve secp256r1 \
      --new-key \
      --reuse-key \
      --no-directory-hooks || return $?
    if [[ -n "$LEAF_SPKI_FIXTURE" ]]; then
      [[ "$(fixture_observation rollover_present_after_certbot)" = YES ]] || return 65
    else
      [[ "$(rollover_presence)" = YES ]] || return 65
    fi
  else
    run_certbot rollover-reconfigure reconfigure \
      --non-interactive \
      --cert-name "$LEAF_SPKI_ROLLOVER_LINEAGE" \
      --webroot \
      --webroot-path "$webroot" \
      --key-type ecdsa \
      --elliptic-curve secp256r1 \
      --reuse-key \
      --no-directory-hooks || return $?
    validate_rollover_configuration || return $?
  fi
  rollover=$(lineage_spki "$LEAF_SPKI_ROLLOVER_LINEAGE") || return $?
  [[ "$primary" != "$rollover" ]] || return 65
  prove_rollover_dormant || return $?
  prove_external_primary "$primary" || return $?
  record_evidence FORWARD ROLLOVER_VERIFIED PROVED_PRIMARY GREEN || return $?
  printf 'primary_spki=%s\nrollover_spki=%s\n' "$primary" "$rollover"
}
configure_rollover() {
  local primary rollover
  [[ "$(rollover_presence)" = YES ]] || return 65
  validate_rollover_configuration || return $?
  primary=$(lineage_spki "$LEAF_SPKI_PRIMARY_LINEAGE") || return $?
  rollover=$(lineage_spki "$LEAF_SPKI_ROLLOVER_LINEAGE") || return $?
  [[ "$primary" != "$rollover" ]] || return 65
  prove_rollover_dormant || return $?
  prove_external_primary "$primary" || return $?
  record_evidence FORWARD ROLLOVER_VERIFIED PROVED_PRIMARY GREEN || return $?
  printf 'primary_spki=%s\nrollover_spki=%s\n' "$primary" "$rollover"
}
verify_renewal() {
  local lineage=$1 operation primary rollover staging_account
  primary=$(lineage_spki "$LEAF_SPKI_PRIMARY_LINEAGE") || return $?
  rollover=$(lineage_spki "$LEAF_SPKI_ROLLOVER_LINEAGE") || return $?
  [[ "$primary" != "$rollover" ]] || return 65
  prove_rollover_dormant || return $?
  prove_external_primary "$primary" || return $?
  staging_account=$(certbot_account staging) || return $?
  [[ "$lineage" = "$LEAF_SPKI_PRIMARY_LINEAGE" ]] &&
    operation=primary-renew-dry-run || operation=rollover-renew-dry-run
  run_certbot "$operation" renew \
    --non-interactive \
    --cert-name "$lineage" \
    --dry-run \
    --server https://acme-staging-v02.api.letsencrypt.org/directory \
    --account "$staging_account" \
    --no-directory-hooks || return $?
  [[ "$(lineage_spki "$LEAF_SPKI_PRIMARY_LINEAGE")" = "$primary" &&
    "$(lineage_spki "$LEAF_SPKI_ROLLOVER_LINEAGE")" = "$rollover" ]] || return 65
  prove_rollover_dormant || return $?
  prove_external_primary "$primary" || return $?
  record_evidence FORWARD RENEWAL_VERIFIED PROVED_PRIMARY GREEN || return $?
  printf 'primary_spki=%s\nrollover_spki=%s\n' "$primary" "$rollover"
}
dispatch_phase() {
  local phase=$1
  case "$phase" in
    inspect) inspect_mode ;;
    configure-primary) configure_primary ;;
    ensure-rollover) ensure_rollover ;;
    configure-rollover) configure_rollover ;;
    verify-primary-renewal) verify_renewal "$LEAF_SPKI_PRIMARY_LINEAGE" ;;
    verify-rollover-renewal) verify_renewal "$LEAF_SPKI_ROLLOVER_LINEAGE" ;;
    drill) drill_mode ;;
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
  local phase=$1 fd lock_dir= rc
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
  fi
  if [[ -n "$lock_dir" ]]; then
    dispatch_phase "$phase" || rc=$?
    rc=${rc:-0}
    rmdir -- "$lock_dir" 2>/dev/null || true
    return "$rc"
  fi
  dispatch_phase "$phase"
}
