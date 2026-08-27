#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=${PRODUCTION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
cd "$ROOT_DIR"

if [ "${1:-}" = "--beta" ]; then
  shift
  recovery_id=
  beta_dir=${BACKUP_DIR:-/var/backups/meet-production}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --recovery-id) [ "$#" -ge 2 ] && [ -z "$recovery_id" ] || exit 2; recovery_id=$2; shift 2 ;;
      --output-dir) [ "$#" -ge 2 ] || exit 2; beta_dir=$2; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [[ "$recovery_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || exit 2
  : "${AGE_RECIPIENT:?AGE_RECIPIENT is required}"
  SCRIPTS_DIR=${PRODUCTION_SCRIPTS_DIR:-"$ROOT_DIR/scripts"}
  COMPOSE=("$SCRIPTS_DIR/production-compose.sh")
  CURRENT_CONTAINER=$("${COMPOSE[@]}" ps -q backend)
  test -n "$CURRENT_CONTAINER" || exit 1
  CURRENT_IMAGE_ID=$(docker inspect --format '{{.Image}}' "$CURRENT_CONTAINER")
  mapfile -t UPLOAD_MOUNTS < <(
    docker inspect --format \
      '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s\n" .Type .Name}}{{end}}{{end}}' \
      "$CURRENT_CONTAINER"
  )
  [ "${#UPLOAD_MOUNTS[@]}" -eq 1 ] || exit 1
  IFS='|' read -r UPLOAD_MOUNT_TYPE UPLOAD_VOLUME <<<"${UPLOAD_MOUNTS[0]}"
  [ "$UPLOAD_MOUNT_TYPE" = volume ] && [ "$UPLOAD_VOLUME" = meet-production_uploads_data ] || exit 1
  docker volume inspect "$UPLOAD_VOLUME" >/dev/null
  [ -d "$beta_dir" ] || install -d -m 700 "$beta_dir"
  db_backup=$beta_dir/postgres.dump.age
  uploads_backup=$beta_dir/uploads.tar.gz.age
  [ ! -e "$db_backup" ] && [ ! -e "$uploads_backup" ] || exit 1
  restart_beta() {
    docker start "$CURRENT_CONTAINER" >/dev/null
    for _ in $(seq 1 90); do
      health=$(docker inspect --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}stopped{{end}}{{end}}' \
        "$CURRENT_CONTAINER")
      case "$health" in healthy|running) return 0;; unhealthy|stopped) return 1;; esac
      sleep 2
    done
    return 1
  }
  # shellcheck disable=SC2329
  beta_cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    restart_beta || status=1
    exit "$status"
  }
  trap beta_cleanup EXIT HUP INT TERM
  docker stop --time 30 "$CURRENT_CONTAINER" >/dev/null
  # shellcheck disable=SC2016
  "${COMPOSE[@]}" exec -T postgres sh -c \
    'pg_dump --format=custom -U "$POSTGRES_USER" -d "$POSTGRES_DB"' |
    age -r "$AGE_RECIPIENT" -o "$db_backup"
  docker run --rm --read-only --entrypoint tar \
    --mount "type=volume,source=$UPLOAD_VOLUME,target=/source,readonly" \
    "$CURRENT_IMAGE_ID" -C /source -czf - . |
    age -r "$AGE_RECIPIENT" -o "$uploads_backup"
  [ -s "$db_backup" ] && [ -s "$uploads_backup" ] || exit 1
  chmod 600 "$db_backup" "$uploads_backup"
  restart_beta
  trap - EXIT HUP INT TERM
  printf 'database=%s\nuploads=%s\n' "$db_backup" "$uploads_backup"
  exit 0
fi

: "${AGE_RECIPIENT:?AGE_RECIPIENT is required}"
BACKUP_DIR=${BACKUP_DIR:-/var/backups/meet-production}
SCRIPTS_DIR=${PRODUCTION_SCRIPTS_DIR:-"$ROOT_DIR/scripts"}
COMPOSE=("$SCRIPTS_DIR/production-compose.sh")
CURRENT_CONTAINER=$("${COMPOSE[@]}" ps -q backend)
test -n "$CURRENT_CONTAINER" || {
  echo "a running backend is required for a coordinated backup" >&2
  exit 1
}
CURRENT_IMAGE_ID=$(docker inspect --format '{{.Image}}' "$CURRENT_CONTAINER")

mapfile -t UPLOAD_MOUNTS < <(
  docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s\n" .Type .Name}}{{end}}{{end}}' \
    "$CURRENT_CONTAINER"
)
[ "${#UPLOAD_MOUNTS[@]}" -eq 1 ] || {
  echo "expected exactly one /data/uploads mount" >&2
  exit 1
}
IFS='|' read -r UPLOAD_MOUNT_TYPE UPLOAD_VOLUME <<< "${UPLOAD_MOUNTS[0]}"
[ "$UPLOAD_MOUNT_TYPE" = volume ]
[ "$UPLOAD_VOLUME" = meet-production_uploads_data ] || {
  echo "unexpected uploads volume: $UPLOAD_VOLUME" >&2
  exit 1
}
docker volume inspect "$UPLOAD_VOLUME" >/dev/null

sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 700 "$BACKUP_DIR"
umask 077
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DB_BACKUP="$BACKUP_DIR/postgres-$STAMP.dump.age"
UPLOAD_BACKUP="$BACKUP_DIR/uploads-$STAMP.tar.gz.age"
UPLOAD_MANIFEST=$(mktemp)

restart_current() {
  docker start "$CURRENT_CONTAINER" >/dev/null
  for _ in $(seq 1 90); do
    HEALTH=$(docker inspect --format \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}stopped{{end}}{{end}}' \
      "$CURRENT_CONTAINER")
    case "$HEALTH" in
      healthy|running) return 0 ;;
      unhealthy|stopped) return 1 ;;
    esac
    sleep 2
  done
  return 1
}
cleanup() {
  rm -f "$UPLOAD_MANIFEST"
  restart_current
}
trap cleanup EXIT

docker stop --time 30 "$CURRENT_CONTAINER" >/dev/null
"${COMPOSE[@]}" exec -T postgres \
  sh -c 'pg_dump --format=custom -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | age -r "$AGE_RECIPIENT" -o "$DB_BACKUP"

# Validate the exact mounted volume and its expected storage layout before
# encrypting it. An accidentally created empty volume must not pass this gate.
docker run --rm --read-only --entrypoint tar \
  --mount "type=volume,source=$UPLOAD_VOLUME,target=/source,readonly" \
  "$CURRENT_IMAGE_ID" -C /source -czf - . | tar -tzf - > "$UPLOAD_MANIFEST"
for directory in avatars meetings communities; do
  grep -Eq "^\./${directory}/?$" "$UPLOAD_MANIFEST" || {
    echo "uploads archive is missing the $directory directory" >&2
    exit 1
  }
done
if grep -Evq '^\./?$|^\./(avatars|meetings|communities)(/.*)?$' "$UPLOAD_MANIFEST"; then
  echo "uploads archive contains an unexpected top-level path" >&2
  exit 1
fi

docker run --rm --read-only --entrypoint tar \
  --mount "type=volume,source=$UPLOAD_VOLUME,target=/source,readonly" \
  "$CURRENT_IMAGE_ID" -C /source -czf - . \
  | age -r "$AGE_RECIPIENT" -o "$UPLOAD_BACKUP"

test -s "$DB_BACKUP"
test -s "$UPLOAD_BACKUP"
chmod 600 "$DB_BACKUP" "$UPLOAD_BACKUP"
restart_current
rm -f "$UPLOAD_MANIFEST"
trap - EXIT

printf 'database=%s\nuploads=%s\n' "$DB_BACKUP" "$UPLOAD_BACKUP"
