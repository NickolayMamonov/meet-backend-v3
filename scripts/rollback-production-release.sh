#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
COMPOSE=(scripts/production-compose.sh)
STATE_DIR=/var/lib/meet-production

for name in previous-image previous-image-id previous-revision previous-uid previous-gid previous-upload-volume previous-config.sha256 previous-compose.yml previous-runtime.override.yml previous-compose.sha256 previous-runtime.sha256 previous-compose-config-hash; do
  test -s "$STATE_DIR/$name" || { echo "missing rollback state: $name" >&2; exit 1; }
done
[ "$(scripts/production-config-digest.sh)" = "$(< "$STATE_DIR/previous-config.sha256")" ] || {
  echo "non-release configuration changed; automatic rollback is prohibited" >&2
  echo "preserve rotated credentials and roll forward, or explicitly validate prior-image compatibility" >&2
  exit 1
}

IMAGE=$(< "$STATE_DIR/previous-image")
IMAGE_ID=$(< "$STATE_DIR/previous-image-id")
REVISION=$(< "$STATE_DIR/previous-revision")
UID_VALUE=$(< "$STATE_DIR/previous-uid")
GID_VALUE=$(< "$STATE_DIR/previous-gid")
UPLOAD_VOLUME=$(< "$STATE_DIR/previous-upload-volume")
[[ "$IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]]
[[ "$UID_VALUE:$GID_VALUE" =~ ^[0-9]+:[0-9]+$ ]]
[ "$UPLOAD_VOLUME" = meet-production_uploads_data ]
[ "$(docker image inspect "$IMAGE" --format '{{.Id}}')" = "$IMAGE_ID" ]
LABEL_REVISION=$(docker image inspect "$IMAGE" --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}')
[ -z "$LABEL_REVISION" ] || [ "$LABEL_REVISION" = "$REVISION" ]
[ "$(sha256sum "$STATE_DIR/previous-compose.yml" | awk '{print $1}')" = "$(< "$STATE_DIR/previous-compose.sha256")" ]
[ "$(sha256sum "$STATE_DIR/previous-runtime.override.yml" | awk '{print $1}')" = "$(< "$STATE_DIR/previous-runtime.sha256")" ]
docker volume inspect "$UPLOAD_VOLUME" >/dev/null

HELPER_IMAGE=$(sed -n 's/^BACKEND_IMAGE=//p' .env.production)
test -n "$HELPER_IMAGE"
"${COMPOSE[@]}" stop backend
docker run --rm --user 0:0 --entrypoint chown \
  --mount "type=volume,source=$UPLOAD_VOLUME,target=/data/uploads" \
  "$HELPER_IMAGE" -R "$UID_VALUE:$GID_VALUE" /data/uploads
docker run --rm --user "$UID_VALUE:$GID_VALUE" --entrypoint sh \
  --mount "type=volume,source=$UPLOAD_VOLUME,target=/data/uploads" \
  "$IMAGE" -ec 'test -w /data/uploads'

install -m 600 "$STATE_DIR/previous-compose.yml" "$STATE_DIR/active-compose.yml"
install -m 600 "$STATE_DIR/previous-runtime.override.yml" \
  "$STATE_DIR/active-runtime.override.yml"
scripts/update-production-release.sh "$IMAGE" "$REVISION"

"${COMPOSE[@]}" up -d --no-deps --no-build --pull never --wait --wait-timeout 180 backend
CONTAINER=$("${COMPOSE[@]}" ps -q backend)
test -n "$CONTAINER"
[ "$(docker inspect --format '{{.Image}}' "$CONTAINER")" = "$IMAGE_ID" ]
[ "$(docker exec "$CONTAINER" id -u)" = "$UID_VALUE" ]
[ "$(docker exec "$CONTAINER" id -g)" = "$GID_VALUE" ]
mapfile -t ROLLBACK_MOUNTS < <(
  docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s\n" .Type .Name}}{{end}}{{end}}' \
    "$CONTAINER"
)
[ "${#ROLLBACK_MOUNTS[@]}" -eq 1 ]
[ "${ROLLBACK_MOUNTS[0]}" = "volume|$UPLOAD_VOLUME" ]
ADDRESS=$("${COMPOSE[@]}" port backend 8080)
curl --fail "http://$ADDRESS/actuator/health/readiness"
