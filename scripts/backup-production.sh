#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=${PRODUCTION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
cd "$ROOT_DIR"
SCRIPTS_DIR=${PRODUCTION_SCRIPTS_DIR:-"$ROOT_DIR/scripts"}
COMPOSE=("$SCRIPTS_DIR/production-compose.sh")

restart_current() {
  local container=$1
  docker start "$container" >/dev/null
  for _ in $(seq 1 90); do
    local health
    health=$(docker inspect "$container" --format \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}')
    if [ "$health" = healthy ] || [ "$health" = running ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

validate_upload_archive() {
  local volume=$1 image=$2 list=$3 types=$4 entry
  docker run --rm --read-only --entrypoint tar \
    --mount "type=volume,source=$volume,target=/source,readonly" \
    "$image" -C /source -czf - . | tar --list --gzip >"$list"
  while IFS= read -r entry; do
    case "$entry" in
      ./|./avatars|./avatars/|./meetings|./meetings/|./communities|./communities/) ;;
      ./avatars/*|./meetings/*|./communities/*) ;;
      *) echo "unsafe or unexpected uploads archive entry" >&2; return 1 ;;
    esac
  done <"$list"
  for directory in avatars meetings communities; do
    grep -Eq "^\\./${directory}/?$" "$list" || return 1
  done
  docker run --rm --read-only --entrypoint tar \
    --mount "type=volume,source=$volume,target=/source,readonly" \
    "$image" -C /source -czf - . | tar --list --gzip --verbose >"$types"
  while IFS= read -r entry; do
    case "${entry:0:1}" in d|-) ;; *) echo "unsafe uploads archive type" >&2; return 1 ;; esac
  done <"$types"
}

decimal() { [[ "$1" =~ ^[0-9]+$ ]]; }
normalize_decimal() { local value=${1#0*}; printf '%s\n' "${value:-0}"; }
decimal_ge() {
  local left right
  decimal "$1" && decimal "$2" || return 1
  left=$(normalize_decimal "$1")
  right=$(normalize_decimal "$2")
  [ "${#left}" -gt "${#right}" ] ||
    { [ "${#left}" -eq "${#right}" ] && [[ "$left" > "$right" || "$left" = "$right" ]]; }
}
decimal_add() {
  local left=$1 right=$2 carry=0 result='' ld rd digit
  decimal "$left" && decimal "$right" || return 1
  while [ -n "$left" ] || [ -n "$right" ] || [ "$carry" -gt 0 ]; do
    ld=0; rd=0; [ -z "$left" ] || ld=${left: -1}; [ -z "$right" ] || rd=${right: -1}
    digit=$((10#$ld + 10#$rd + carry)); result=$((digit % 10))$result; carry=$((digit / 10))
    [ -z "$left" ] || left=${left:0:${#left}-1}; [ -z "$right" ] || right=${right:0:${#right}-1}
  done
  normalize_decimal "$result"
}
decimal_mul_small() {
  local value=$1 multiplier=$2 carry=0 result='' digit last
  decimal "$value" && [[ "$multiplier" =~ ^[0-9]+$ ]] || return 1
  value=$(normalize_decimal "$value")
  while [ -n "$value" ] || [ "$carry" -gt 0 ]; do
    last=0; [ -z "$value" ] || last=${value: -1}
    digit=$((10#$last * 10#$multiplier + carry))
    result=$((digit % 10))$result; carry=$((digit / 10))
    [ -z "$value" ] || value=${value:0:${#value}-1}
  done
  normalize_decimal "$result"
}
capacity_ok() {
  decimal_ge "$1" "$2" &&
    decimal_ge "$(decimal_mul_small "$1" 4)" "$(decimal_mul_small "$2" 5)"
}

write_media_reference_list() {
  local output=$1
  "${COMPOSE[@]}" exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -c \
    "SELECT regexp_replace(image_url, '^https://api[.]whysoezzy[.]online/demo-assets/v1/', '')
       FROM (
         SELECT avatar_url AS image_url FROM users WHERE avatar_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%'
         UNION ALL SELECT image_url FROM communities WHERE image_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%'
         UNION ALL SELECT image_url FROM meetings WHERE image_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%'
       ) media_refs
       ORDER BY 1" >"$output"
}

if [ "${1:-}" = "--beta" ]; then
  shift
  recovery_id='' beta_dir=${BACKUP_DIR:-/var/backups/meet-production}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --recovery-id) recovery_id=$2; shift 2 ;;
      --output-dir) beta_dir=$2; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [[ "$recovery_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || exit 2
  : "${AGE_RECIPIENT:?AGE_RECIPIENT is required}"
  database_sql=${BETA_DATABASE_PROOF_SCRIPT:-"$SCRIPTS_DIR/beta-recovery-database-proof.sql"}
  media_script=${BETA_MEDIA_PROOF_SCRIPT:-"$SCRIPTS_DIR/beta-recovery-media-proof.sh"}
  [ -f "$database_sql" ] && [ -x "$media_script" ] || exit 1
  backend=$("${COMPOSE[@]}" ps -q backend)
  postgres=$("${COMPOSE[@]}" ps -q postgres)
  [ -n "$backend" ] && [ -n "$postgres" ] || exit 1
  image=$(docker inspect "$backend" --format '{{.Image}}')
  upload_mount=$(docker inspect "$backend" --format \
    '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s" .Type .Name}}{{end}}{{end}}')
  [ "$upload_mount" = "volume|meet-production_uploads_data" ] || exit 1
  upload_volume=meet-production_uploads_data
  upload_root=$(docker volume inspect --format '{{.Mountpoint}}' "$upload_volume")
  [ -d "$upload_root" ] && [ ! -L "$upload_root" ] || exit 1
  install -d -m 700 "$beta_dir"; [ ! -L "$beta_dir" ] || exit 1
  for file in postgres.dump.age uploads.tar.gz.age capture-database-proof.json \
    capture-media-proof.json capture-result.json; do
    [ ! -e "$beta_dir/$file" ] || exit 1
  done
  temp=$(mktemp -d "$beta_dir/.capture.XXXXXX")
  db_file=$beta_dir/postgres.dump.age
  media_file=$beta_dir/uploads.tar.gz.age
  cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    rm -r -- "$temp" 2>/dev/null || status=1
    restart_current "$backend" || status=1
    if [ "$status" -ne 0 ]; then
      rm -f -- "$db_file" "$media_file" "$beta_dir"/capture-{database-proof,media-proof,result}.json
    fi
    exit "$status"
  }
  trap cleanup EXIT HUP INT TERM
  docker stop --time 30 "$backend" >/dev/null
  trap 'cleanup' EXIT HUP INT TERM
  db_bytes=$("${COMPOSE[@]}" exec -T postgres sh -c \
    'psql -X -Atqc "SELECT pg_database_size(current_database())"' | tr -d '[:space:]')
  [[ "$db_bytes" =~ ^[1-9][0-9]*$ ]] || exit 1
  write_media_reference_list "$temp/reference-list"
  "$media_script" --root "$upload_root" --reference-list "$temp/reference-list" \
    --output "$temp/media-proof.json"
  jq -e '.schema=="meet-backend/beta-recovery-media-proof/v1" and
    .referencesResolved==true' "$temp/media-proof.json" >/dev/null
  postgres_root=$(docker volume inspect --format '{{.Mountpoint}}' meet-production_postgres_data)
  docker_root=$(docker info --format '{{.DockerRootDir}}')
  [ -d "$postgres_root" ] && [ -d "$docker_root" ] || exit 1
  db_capacity=$(df -Pk -- "$postgres_root" | awk 'NR==2{print $1 "\t" $4}')
  upload_capacity=$(df -Pk -- "$upload_root" | awk 'NR==2{print $1 "\t" $4}')
  [ -n "$db_capacity" ] && [ -n "$upload_capacity" ] || exit 1
  db_device=${db_capacity%%$'\t'*}; db_free=$(decimal_mul_small "${db_capacity#*$'\t'}" 1024)
  upload_device=${upload_capacity%%$'\t'*}; upload_free=$(decimal_mul_small "${upload_capacity#*$'\t'}" 1024)
  projected=$(decimal_add "$db_bytes" "$(jq -er '.bytes' "$temp/media-proof.json")")
  required=$(decimal_add "$(decimal_mul_small "$projected" 2)" 2147483648)
  if [ "$db_device" = "$upload_device" ]; then
    capacity_ok "$db_free" "$required" || exit 1
  else
    capacity_ok "$db_free" "$required" || exit 1
    capacity_ok "$upload_free" "$required" || exit 1
  fi
  "${COMPOSE[@]}" exec -T postgres sh -c \
    'pg_dump --format=custom -U "$POSTGRES_USER" -d "$POSTGRES_DB"' |
    age -r "$AGE_RECIPIENT" -o "$db_file"
  validate_upload_archive "$upload_volume" "$image" "$temp/archive.list" "$temp/archive.types"
  docker run --rm --read-only --entrypoint tar \
    --mount "type=volume,source=$upload_volume,target=/source,readonly" \
    "$image" -C /source -czf - . | age -r "$AGE_RECIPIENT" -o "$media_file"
  [ -s "$db_file" ] && [ -s "$media_file" ] || exit 1
  cat "$database_sql" | "${COMPOSE[@]}" exec -T postgres sh -c 'psql -X -qAt -f -' |
    jq -cS 'if type=="object" and .schema=="meet-backend/closed-beta-database-proof/v1" then . else error("database proof schema") end' \
      >"$temp/database-proof.json"
  cp -- "$temp/database-proof.json" "$beta_dir/capture-database-proof.json"
  cp -- "$temp/media-proof.json" "$beta_dir/capture-media-proof.json"
  db_sha=$(sha256sum "$db_file" | awk '{print $1}')
  media_sha=$(sha256sum "$media_file" | awk '{print $1}')
  db_size=$(wc -c <"$db_file" | tr -d '[:space:]')
  media_size=$(wc -c <"$media_file" | tr -d '[:space:]')
  jq -cnS --arg id "$recovery_id" --arg dbsha "$db_sha" --arg mediasha "$media_sha" \
    --arg dbproof "$(sha256sum "$beta_dir/capture-database-proof.json" | awk '{print $1}')" \
    --arg mediaproof "$(sha256sum "$beta_dir/capture-media-proof.json" | awk '{print $1}')" \
    --argjson dbsize "$db_size" --argjson mediasize "$media_size" --argjson db "$db_bytes" \
    --argjson files "$(jq -er '.files' "$beta_dir/capture-media-proof.json")" \
    --argjson bytes "$(jq -er '.bytes' "$beta_dir/capture-media-proof.json")" \
    --arg digest "$(jq -er '.canonicalDigest' "$beta_dir/capture-media-proof.json")" \
    '{schema:"meet-backend/beta-recovery-capture/v1",recoveryId:$id,databaseBytes:$db,
      uploads:{files:$files,bytes:$bytes,digest:$digest},
      ciphertexts:{database:{name:"postgres.dump.age",size:$dbsize,sha256:$dbsha},
        uploads:{name:"uploads.tar.gz.age",size:$mediasize,sha256:$mediasha}},
      proofs:{database:{name:"capture-database-proof.json",sha256:$dbproof},
        media:{name:"capture-media-proof.json",sha256:$mediaproof}}}' \
    >"$beta_dir/capture-result.json"
  chmod 600 "$beta_dir"/*.age "$beta_dir"/capture-*.json
  exit 0
fi

: "${AGE_RECIPIENT:?AGE_RECIPIENT is required}"
BACKUP_DIR=${BACKUP_DIR:-/var/backups/meet-production}
sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 700 "$BACKUP_DIR"
umask 077
stamp=$(date -u +%Y%m%dT%H%M%SZ)
db_backup="$BACKUP_DIR/postgres-$stamp.dump.age"
upload_backup="$BACKUP_DIR/uploads-$stamp.tar.gz.age"
backend=$("${COMPOSE[@]}" ps -q backend)
[ -n "$backend" ] || { echo "a running backend is required" >&2; exit 1; }
upload_mount=$(docker inspect "$backend" --format \
  '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s" .Type .Name}}{{end}}{{end}}')
[ "$upload_mount" = "volume|meet-production_uploads_data" ] || exit 1
docker stop --time 30 "$backend" >/dev/null
trap 'restart_current "$backend"' EXIT
validate_upload_archive meet-production_uploads_data \
  "$(docker inspect "$backend" --format '{{.Image}}')" \
  "$BACKUP_DIR/.archive.list" "$BACKUP_DIR/.archive.types"
"${COMPOSE[@]}" exec -T postgres sh -c \
  'pg_dump --format=custom -U "$POSTGRES_USER" -d "$POSTGRES_DB"' |
  age -r "$AGE_RECIPIENT" -o "$db_backup"
docker run --rm --read-only --entrypoint tar \
  --mount "type=volume,source=meet-production_uploads_data,target=/source,readonly" \
  "$(docker inspect "$backend" --format '{{.Image}}')" -C /source -czf - . |
  age -r "$AGE_RECIPIENT" -o "$upload_backup"
[ -s "$db_backup" ] && [ -s "$upload_backup" ]
restart_current "$backend"
trap - EXIT
printf 'database=%s\nuploads=%s\n' "$db_backup" "$upload_backup"
