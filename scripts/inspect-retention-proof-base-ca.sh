#!/usr/bin/env bash
set -euo pipefail

readonly image='ubuntu:24.04@sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b'
readonly container_code='
path=/etc/ssl/certs/ca-certificates.crt
if [[ -L "$path" ]]; then
  printf "CA_BUNDLE_PRESENT_SYMLINK\n"
elif [[ -f "$path" ]]; then
  printf "CA_BUNDLE_PRESENT_REGULAR\n"
elif [[ -e "$path" ]]; then
  printf "CA_BUNDLE_PRESENT_NONREGULAR\n"
else
  printf "CA_BUNDLE_ABSENT\n"
fi
'
container_name="retention-base-ca-${BASHPID}-${RANDOM}"
container_id=''
create_attempted=false

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$create_attempted" == true ]]; then
    timeout 30s docker rm --force "$container_name" >/dev/null || true
    local remaining
    remaining=$(timeout 30s docker ps -aq --no-trunc \
      --filter "name=^/${container_name}$") ||
      status=1
    [[ -z "$remaining" ]] || status=1
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

timeout 240s docker pull "$image" >/dev/null
existing=$(timeout 30s docker ps -aq --no-trunc \
  --filter "name=^/${container_name}$")
[[ -z "$existing" ]] || {
  echo 'RETENTION_BASE_INSPECTION_DENIED: generated container name is already owned' >&2
  exit 1
}
create_attempted=true
container_id=$(
  timeout 30s docker create \
    --name "$container_name" \
    --network none \
    --read-only \
    --entrypoint /bin/bash \
    "$image" -euo pipefail -c "$container_code"
)
[[ "$container_id" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'RETENTION_BASE_INSPECTION_DENIED: invalid owned container identity' >&2
  exit 1
}

classification=$(timeout 30s docker start --attach "$container_id")
case "$classification" in
  CA_BUNDLE_PRESENT_REGULAR|CA_BUNDLE_PRESENT_SYMLINK|CA_BUNDLE_PRESENT_NONREGULAR|CA_BUNDLE_ABSENT) ;;
  *)
    echo 'RETENTION_BASE_INSPECTION_DENIED: unexpected inspection result' >&2
    exit 1
    ;;
esac

timeout 30s docker rm --force "$container_id" >/dev/null
remaining=$(timeout 30s docker ps -aq --no-trunc \
  --filter "name=^/${container_name}$")
[[ -z "$remaining" ]] || {
  echo 'RETENTION_BASE_INSPECTION_DENIED: owned container teardown incomplete' >&2
  exit 1
}
create_attempted=false
container_name=''
container_id=''
printf '%s\n' "$classification"
