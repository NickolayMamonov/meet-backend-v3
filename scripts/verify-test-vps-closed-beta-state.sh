#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: verify-test-vps-closed-beta-state.sh --phase predecessor|candidate|rollback|final
  --root PATH --compose-script PATH --state-dir PATH
  --expected-image IMAGE@sha256:DIGEST --expected-image-id sha256:DIGEST
  --expected-revision SHA --expected-version X.Y.Z --expected-runtime-hash HEX64
  --output PATH [--public-url https://HOST]
EOF
  exit 2
}
fail() { echo "closed-beta host-state verification failed: $*" >&2; exit 1; }

phase='' root='' compose_script='' state_dir='' expected_image='' expected_image_id=''
expected_revision='' expected_version='' expected_runtime_hash='' output=''
public_url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase) [ "$#" -ge 2 ] || usage; phase=$2; shift 2 ;;
    --root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
    --compose-script) [ "$#" -ge 2 ] || usage; compose_script=$2; shift 2 ;;
    --state-dir) [ "$#" -ge 2 ] || usage; state_dir=$2; shift 2 ;;
    --expected-image) [ "$#" -ge 2 ] || usage; expected_image=$2; shift 2 ;;
    --expected-image-id) [ "$#" -ge 2 ] || usage; expected_image_id=$2; shift 2 ;;
    --expected-revision) [ "$#" -ge 2 ] || usage; expected_revision=$2; shift 2 ;;
    --expected-version) [ "$#" -ge 2 ] || usage; expected_version=$2; shift 2 ;;
    --expected-runtime-hash) [ "$#" -ge 2 ] || usage; expected_runtime_hash=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    --public-url) [ "$#" -ge 2 ] || usage; public_url=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$phase" in predecessor|candidate|rollback|final) ;; *) usage ;; esac
[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$root" != *..* ]] || usage
[[ "$compose_script" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$compose_script" != *..* ]] || usage
[[ "$state_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$state_dir" != *..* ]] || usage
[[ "$expected_image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] || usage
[[ "$expected_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$expected_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
[[ "$expected_runtime_hash" =~ ^[0-9a-f]{64}$ ]] || usage
[ -n "$output" ] || usage
if [ -n "$public_url" ]; then
  [[ "$public_url" =~ ^https://[^/]+$ ]] || usage
fi
for command_name in docker jq sha256sum; do command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"; done
[ -z "$public_url" ] || command -v curl >/dev/null 2>&1 || fail "curl is required"
[ -d "$root" ] && [ -s "$root/.env.production" ] && [ -s "$root/docker-compose.production.yml" ] || fail "production root is incomplete"
[ -x "$compose_script" ] || fail "Compose wrapper is unavailable"
[ -d "$state_dir" ] && [ ! -L "$state_dir" ] || fail "state directory is unsafe"
[ ! -L "$output" ] || fail "output path is unsafe"
[ ! -e "$output" ] || [ -f "$output" ] || fail "output path is not a regular file"
[ -d "$(dirname -- "$output")" ] || fail "output directory is unavailable"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
runtime_helper=$script_dir/test-vps-runtime-invariants.sh
[ -r "$runtime_helper" ] || fail "runtime invariant helper is unavailable"
# shellcheck source=/dev/null
source "$runtime_helper"
actual_id=$(docker image inspect "$expected_image" --format '{{.Id}}') || fail "expected image cannot be inspected"
[ "$actual_id" = "$expected_image_id" ] || fail "image identity differs"
source_label=$(docker image inspect "$expected_image" --format '{{index .Config.Labels "org.opencontainers.image.source"}}') || fail "source label unavailable"
[ "$source_label" = "https://github.com/NickolayMamonov/meet-backend-v3" ] || fail "source label differs"
revision_label=$(docker image inspect "$expected_image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}') || fail "revision label unavailable"
[ "$revision_label" = "$expected_revision" ] || fail "revision label differs"
version_label=$(docker image inspect "$expected_image" --format '{{index .Config.Labels "org.opencontainers.image.version"}}') || fail "version label unavailable"
[ "$version_label" = "$expected_version" ] || fail "version label differs"
image_user=$(docker image inspect "$expected_image" --format '{{.Config.User}}') || fail "image user unavailable"
[ "$image_user" = "10001:10001" ] || fail "image user differs"
container=$(runtime_compose "$root" "$compose_script" ps -q backend) || fail "backend container lookup failed"
[ -n "$container" ] || fail "backend container unavailable"
container_image=$(docker inspect "$container" --format '{{.Image}}') || fail "container image unavailable"
[ "$container_image" = "$expected_image_id" ] || fail "container image differs"
container_reference=$(docker inspect "$container" --format '{{.Config.Image}}') || fail "container reference unavailable"
[ "$container_reference" = "$expected_image" ] || fail "container reference differs"
container_hash=$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') || fail "runtime hash unavailable"
[ "$container_hash" = "$expected_runtime_hash" ] || fail "runtime hash differs"
[ "$(runtime_release_field "$root" BACKEND_IMAGE)" = "$expected_image" ] || fail "release image differs"
[ "$(runtime_release_field "$root" BACKEND_REVISION)" = "$expected_revision" ] || fail "release revision differs"
[ "$(runtime_release_field "$root" BACKEND_VERSION)" = "$expected_version" ] || fail "release version differs"
verify_environment_matches_container "$root" "$compose_script" || fail "container environment differs"

if [ "$phase" = final ] && [ -n "$public_url" ]; then
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  "$script_dir/verify-test-vps-assets.sh" \
    --public-url "$public_url" \
    --output "$state_dir/frozen-assets.json" >/dev/null ||
    fail "frozen public assets do not match"
  curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
    "$public_url/meetings" | jq -e 'type == "array"' >/dev/null ||
    fail "meetings probe failed"
  [ "$(curl --silent --show-error --proto '=https' --tlsv1.2 \
    -o /dev/null -w '%{http_code}' "$public_url/actuator")" = 404 ] ||
    fail "Actuator is not private"
  headers=$(mktemp)
  trap 'rm -f -- "$headers"' RETURN
  curl --silent --show-error --proto '=http' --max-time 10 \
    -D "$headers" -o /dev/null \
    "${public_url/https:\/\//http://}/meetings"
  grep -Eiq '^location: https://' "$headers" ||
    fail "HTTP does not redirect to HTTPS"
  rm -f -- "$headers"
  missing_admin=$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}' -X POST \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'Content-Type: application/json' --data '{}')
  wrong_admin=$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}' -X POST \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'X-Admin-Key: wrong' -H 'Content-Type: application/json' --data '{}')
  [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] ||
    fail "admin endpoint is not protected"
  [ "$(grep -c '^ADMIN_API_KEY=' "$root/.env.production")" -eq 1 ] ||
    fail "configured admin key is unavailable"
  admin_key=$(sed -n 's/^ADMIN_API_KEY=//p' "$root/.env.production")
  [ -n "$admin_key" ] || fail "configured admin key is empty"
  case "$admin_key" in *[[:space:]]*) fail "configured admin key is malformed" ;; esac
  authenticated_admin=$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}' -X POST \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H "X-Admin-Key: $admin_key" -H 'Content-Type: application/json' --data '{}')
  unset admin_key
  [ "$authenticated_admin" = 404 ] ||
    fail "authenticated disabled admin endpoint is not absent"
fi

temporary=$output.tmp.$$
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
jq -cnS --arg phase "$phase" --arg image "$expected_image" --arg imageId "$expected_image_id" \
  --arg revision "$expected_revision" --arg version "$expected_version" --arg runtimeHash "$expected_runtime_hash" \
  --argjson assetsCount "$(if [ "$phase" = final ] && [ -n "$public_url" ]; then echo 13; else echo 0; fi)" \
  --argjson assetsVerified "$(if [ "$phase" = final ] && [ -n "$public_url" ]; then echo true; else echo false; fi)" \
  --argjson adminAuthenticatedDisabled404 "$(if [ "$phase" = final ] && [ -n "$public_url" ]; then echo true; else echo false; fi)" \
  '{schema:"meet-backend/test-vps-closed-beta-state/v1",phase:$phase,image:$image,imageId:$imageId,
    revision:$revision,version:$version,runtimeConfigHash:$runtimeHash,
    containerHealthy:true,environmentMatched:true,assetsCount:$assetsCount,
    assetsVerified:$assetsVerified,adminAuthenticatedDisabled404:$adminAuthenticatedDisabled404}' \
  >"$temporary" || fail "evidence construction failed"
chmod 600 "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || fail "evidence publication failed"
trap - EXIT HUP INT TERM
