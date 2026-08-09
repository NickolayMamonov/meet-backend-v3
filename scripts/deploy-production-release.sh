#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=${PRODUCTION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
cd "$ROOT_DIR"
SCRIPTS_DIR=${PRODUCTION_SCRIPTS_DIR:-"$ROOT_DIR/scripts"}
COMPOSE=("$SCRIPTS_DIR/production-compose.sh")
STATE_DIR=/var/lib/meet-production
ACTIVE_COMPOSE="$STATE_DIR/active-compose.yml"
RUNTIME_OVERRIDE="$STATE_DIR/active-runtime.override.yml"
IMAGE=$(sed -n 's/^BACKEND_IMAGE=//p' .env.production)
VERSION=$(sed -n 's/^BACKEND_VERSION=//p' .env.production)
REVISION=$(sed -n 's/^BACKEND_REVISION=//p' .env.production)
[ "$(grep -c "^BACKEND_IMAGE=" .env.production)" -eq 1 ]
[ "$(grep -c "^BACKEND_VERSION=" .env.production)" -eq 1 ]
[ "$(grep -c "^BACKEND_REVISION=" .env.production)" -eq 1 ]
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]]
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
test -n "$IMAGE"
case "$IMAGE" in *[[:space:]]*|*:latest) echo "BACKEND_IMAGE must be a non-latest immutable release reference" >&2; exit 1;; esac
test "$(docker image inspect "$IMAGE" --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}')" = "$REVISION"
test "$(docker image inspect "$IMAGE" --format '{{ index .Config.Labels "org.opencontainers.image.version" }}')" = "$VERSION"
test "$(docker image inspect "$IMAGE" --format '{{ index .Config.Labels "org.opencontainers.image.source" }}')" = "https://github.com/NickolayMamonov/meet-backend-v3"
test "$(docker image inspect "$IMAGE" --format '{{.Config.User}}')" = "10001:10001"

STATE_NAMES=(previous-image previous-image-id previous-version previous-revision previous-uid
  previous-gid previous-upload-volume previous-config.sha256
  previous-compose.yml previous-runtime.override.yml previous-compose.sha256
  previous-runtime.sha256 previous-compose-config-hash)
mapfile -t EXISTING_STATE < <(compgen -G "$STATE_DIR/previous-*" || true)
if [ "${#EXISTING_STATE[@]}" -gt 0 ]; then
  for name in "${STATE_NAMES[@]}"; do
    test -s "$STATE_DIR/$name" || {
      echo "incomplete rollback state: $name" >&2
      exit 1
    }
  done
  [ "$("$SCRIPTS_DIR/production-config-digest.sh")" = "$(< "$STATE_DIR/previous-config.sha256")" ] || {
    echo "non-release configuration changed; mixed release/config deployment is prohibited" >&2
    exit 1
  }
  [ "$(sha256sum "$STATE_DIR/previous-compose.yml" | awk '{print $1}')" = "$(< "$STATE_DIR/previous-compose.sha256")" ]
  [ "$(sha256sum "$STATE_DIR/previous-runtime.override.yml" | awk '{print $1}')" = "$(< "$STATE_DIR/previous-runtime.sha256")" ]
  PREVIOUS_IMAGE_ID=$(< "$STATE_DIR/previous-image-id")
  PREVIOUS_VERSION=$(< "$STATE_DIR/previous-version")
  PREVIOUS_REVISION=$(< "$STATE_DIR/previous-revision")
  PREVIOUS_UID=$(< "$STATE_DIR/previous-uid")
  PREVIOUS_GID=$(< "$STATE_DIR/previous-gid")
  EXPECTED_CONFIG_HASH=$(< "$STATE_DIR/previous-compose-config-hash")
  [[ "$PREVIOUS_REVISION" =~ ^[0-9a-f]{40}$ ]]
  [[ "$PREVIOUS_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
  [[ "$PREVIOUS_UID:$PREVIOUS_GID" =~ ^[0-9]+:[0-9]+$ ]]
  [[ "$EXPECTED_CONFIG_HASH" =~ ^[0-9a-f]{64}$ ]]
  UPLOAD_VOLUME=$(< "$STATE_DIR/previous-upload-volume")
  [ "$UPLOAD_VOLUME" = meet-production_uploads_data ]
  docker volume inspect meet-production_postgres_data >/dev/null
  docker volume inspect "$UPLOAD_VOLUME" >/dev/null
  CURRENT_CONTAINER=$("${COMPOSE[@]}" ps -q backend)
  test -n "$CURRENT_CONTAINER" || {
    echo "captured predecessor is no longer running" >&2
    exit 1
  }
  [ "$(docker inspect --format '{{.Image}}' "$CURRENT_CONTAINER")" = "$PREVIOUS_IMAGE_ID" ]
  [ "$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.config-hash" }}' \
    "$CURRENT_CONTAINER")" = "$EXPECTED_CONFIG_HASH" ]
  [ "$(docker exec "$CURRENT_CONTAINER" id -u)" = "$PREVIOUS_UID" ]
  [ "$(docker exec "$CURRENT_CONTAINER" id -g)" = "$PREVIOUS_GID" ]
  mapfile -t CURRENT_MOUNTS < <(
    docker inspect --format \
      '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s\n" .Type .Name}}{{end}}{{end}}' \
      "$CURRENT_CONTAINER"
  )
  [ "${#CURRENT_MOUNTS[@]}" -eq 1 ]
  IFS='|' read -r CURRENT_MOUNT_TYPE CURRENT_UPLOAD_VOLUME <<< "${CURRENT_MOUNTS[0]}"
  [ "$CURRENT_MOUNT_TYPE" = volume ]
  [ "$CURRENT_UPLOAD_VOLUME" = "$UPLOAD_VOLUME" ]
  "${COMPOSE[@]}" stop backend
  docker run --rm --user 0:0 --entrypoint chown \
    --mount "type=volume,source=$UPLOAD_VOLUME,target=/data/uploads" \
    "$IMAGE" -R 10001:10001 /data/uploads
  docker run --rm --user 10001:10001 --entrypoint sh \
    --mount "type=volume,source=$UPLOAD_VOLUME,target=/data/uploads" \
    "$IMAGE" -ec 'test -w /data/uploads'
else
  if [ -e "$STATE_DIR/active-compose.yml" ] || \
     [ -e "$STATE_DIR/active-runtime.override.yml" ] || \
     docker volume inspect meet-production_postgres_data >/dev/null 2>&1 || \
     docker volume inspect meet-production_uploads_data >/dev/null 2>&1; then
    echo "existing production state requires a complete predecessor capture" >&2
    exit 1
  fi
fi

rm -f "$ACTIVE_COMPOSE" "$RUNTIME_OVERRIDE"
"${COMPOSE[@]}" up -d --no-build --pull never --wait --wait-timeout 180
CONTAINER=$("${COMPOSE[@]}" ps -q backend)
test -n "$CONTAINER"
[ "$(docker exec "$CONTAINER" id -u)" = 10001 ]
[ "$(docker exec "$CONTAINER" id -g)" = 10001 ]
docker exec "$CONTAINER" sh -ec 'test -w /data/uploads'
mapfile -t DEPLOYED_MOUNTS < <(
  docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s\n" .Type .Name}}{{end}}{{end}}' \
    "$CONTAINER"
)
[ "${#DEPLOYED_MOUNTS[@]}" -eq 1 ]
[ "${DEPLOYED_MOUNTS[0]}" = "volume|meet-production_uploads_data" ]
ADDRESS=$("${COMPOSE[@]}" port backend 8080)
curl --fail "http://$ADDRESS/actuator/health/readiness"
