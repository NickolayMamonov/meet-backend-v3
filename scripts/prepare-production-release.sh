#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
COMPOSE=(scripts/production-compose.sh)
STATE_DIR=/var/lib/meet-production
sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 700 "$STATE_DIR"
umask 077

CONTAINER=$("${COMPOSE[@]}" ps -q backend)
test -n "$CONTAINER" || {
  echo "a running backend is required; fresh installs do not run this script" >&2
  exit 1
}
IMAGE_ID=$(docker inspect --format '{{.Image}}' "$CONTAINER")
REVISION=$(docker image inspect "$IMAGE_ID" \
  --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}')
if [[ ! "$REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  : "${LEGACY_PREVIOUS_REVISION:?export the exact source SHA for the legacy image}"
  [[ "$LEGACY_PREVIOUS_REVISION" =~ ^[0-9a-f]{40}$ ]]
  REVISION=$LEGACY_PREVIOUS_REVISION
fi
ROLLBACK_IMAGE="meet-backend:rollback-$REVISION-${IMAGE_ID#sha256:}"
docker image tag "$IMAGE_ID" "$ROLLBACK_IMAGE"

UID_VALUE=$(docker exec "$CONTAINER" id -u)
GID_VALUE=$(docker exec "$CONTAINER" id -g)
[[ "$UID_VALUE:$GID_VALUE" =~ ^[0-9]+:[0-9]+$ ]]

mapfile -t MOUNTS < <(
  docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s\n" .Type .Name}}{{end}}{{end}}' \
    "$CONTAINER"
)
[ "${#MOUNTS[@]}" -eq 1 ]
IFS='|' read -r MOUNT_TYPE UPLOAD_VOLUME <<< "${MOUNTS[0]}"
[ "$MOUNT_TYPE" = volume ]
[ "$UPLOAD_VOLUME" = meet-production_uploads_data ]

RUNNING_CONFIG_HASH=$(docker inspect --format \
  '{{ index .Config.Labels "com.docker.compose.config-hash" }}' "$CONTAINER")
[[ "$RUNNING_CONFIG_HASH" =~ ^[0-9a-f]{64}$ ]]
[ "$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
  "$CONTAINER")" = meet-production ]
[ "$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' \
  "$CONTAINER")" = backend ]

SOURCE_COMPOSE=docker-compose.production.yml
if [ -s "$STATE_DIR/active-compose.yml" ]; then
  SOURCE_COMPOSE="$STATE_DIR/active-compose.yml"
fi

rm -f "$STATE_DIR/previous-compose-config-hash"
install -m 600 "$SOURCE_COMPOSE" "$STATE_DIR/previous-compose.yml"
umask 077
{
  echo 'services:'
  echo '  backend:'
  printf '    user: "%s:%s"\n' "$UID_VALUE" "$GID_VALUE"
} > "$STATE_DIR/previous-runtime.override.yml"
chmod 600 "$STATE_DIR/previous-runtime.override.yml"

CAPTURED_CONFIG_HASH=$("${COMPOSE[@]}" --captured-runtime config --hash backend |
  awk '$1 == "backend" { print $2 }')
[ "$CAPTURED_CONFIG_HASH" = "$RUNNING_CONFIG_HASH" ] || {
  echo "running backend does not match the captured Compose/runtime definition" >&2
  exit 1
}

printf '%s\n' "$ROLLBACK_IMAGE" > "$STATE_DIR/previous-image"
printf '%s\n' "$IMAGE_ID" > "$STATE_DIR/previous-image-id"
printf '%s\n' "$REVISION" > "$STATE_DIR/previous-revision"
printf '%s\n' "$UID_VALUE" > "$STATE_DIR/previous-uid"
printf '%s\n' "$GID_VALUE" > "$STATE_DIR/previous-gid"
printf '%s\n' "$UPLOAD_VOLUME" > "$STATE_DIR/previous-upload-volume"
sha256sum "$STATE_DIR/previous-compose.yml" | awk '{print $1}' > \
  "$STATE_DIR/previous-compose.sha256"
sha256sum "$STATE_DIR/previous-runtime.override.yml" | awk '{print $1}' > \
  "$STATE_DIR/previous-runtime.sha256"
scripts/production-config-digest.sh > "$STATE_DIR/previous-config.sha256"
chmod 600 "$STATE_DIR"/previous-*
printf '%s\n' "$RUNNING_CONFIG_HASH" > "$STATE_DIR/previous-compose-config-hash"
chmod 600 "$STATE_DIR/previous-compose-config-hash"

echo "captured immediate predecessor image, Compose runtime, volume, and config digest"
