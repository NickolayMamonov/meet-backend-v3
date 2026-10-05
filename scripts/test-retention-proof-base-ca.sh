#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INSPECTOR=$ROOT_DIR/scripts/inspect-retention-proof-base-ca.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

mkdir "$TMP/bin" "$TMP/state"
cat >"$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$FAKE_DOCKER_LOG"
case "$1" in
  pull)
    [[ "$2" == ubuntu:24.04@sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b ]]
    ;;
  create)
    [[ "$2" == --name ]]
    [[ "$3" =~ ^retention-base-ca-[0-9]+-[0-9]+$ ]]
    [[ " $* " == *" --network none "* ]]
    [[ " $* " == *" --read-only "* ]]
    [[ " $* " == *" --entrypoint /bin/bash "* ]]
    [[ " $* " == *" ubuntu:24.04@sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b "* ]]
    touch "$FAKE_STATE_DIR/created"
    [[ "${FAKE_CREATE_FAIL:-false}" != true ]] || exit 23
    printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    ;;
  start)
    [[ "$2" == --attach ]]
    [[ "$3" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
    [[ "${FAKE_START_FAIL:-false}" != true ]] || exit 23
    printf '%s\n' "${FAKE_CA_CLASSIFICATION:-CA_BUNDLE_ABSENT}"
    ;;
  rm)
    [[ "$2" == --force ]]
    [[ "$3" =~ ^(retention-base-ca-[0-9]+-[0-9]+|a{64})$ ]]
    if [[ "${FAKE_PERSIST_CONTAINER:-false}" != true ]]; then
      touch "$FAKE_STATE_DIR/removed"
    fi
    ;;
  ps)
    [[ "$2" == -aq ]]
    [[ "$3" == --no-trunc ]]
    [[ "$4" == --filter ]]
    [[ "$5" =~ ^name=\^/retention-base-ca-[0-9]+-[0-9]+\$$ ]]
    if [[ "${FAKE_EXISTING_CONTAINER:-false}" == true ]] ||
      [[ -e "$FAKE_STATE_DIR/created" && ! -e "$FAKE_STATE_DIR/removed" ]]; then
      printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    fi
    ;;
  *)
    exit 97
    ;;
esac
DOCKER
chmod +x "$TMP/bin/docker"

run_case() {
  local classification=$1
  local output
  rm -f "$TMP/state/created"
  rm -f "$TMP/state/removed"
  : >"$TMP/docker.log"
  output=$(
    PATH="$TMP/bin:$PATH" \
      FAKE_CA_CLASSIFICATION="$classification" \
      FAKE_DOCKER_LOG="$TMP/docker.log" \
      FAKE_STATE_DIR="$TMP/state" \
      timeout 120s bash "$INSPECTOR"
  )
  [[ "$output" == "$classification" ]]
  [[ "$(wc -l <"$TMP/docker.log" | tr -d '[:space:]')" == 6 ]]
  [[ "$(sed -n '1,6p' "$TMP/docker.log" | paste -sd ' ' -)" == 'pull ps create start rm ps' ]]
}

run_case CA_BUNDLE_PRESENT_REGULAR
run_case CA_BUNDLE_PRESENT_SYMLINK
run_case CA_BUNDLE_PRESENT_NONREGULAR
run_case CA_BUNDLE_ABSENT

: >"$TMP/docker.log"
rm -f "$TMP/state/created"
rm -f "$TMP/state/removed"
if PATH="$TMP/bin:$PATH" \
  FAKE_CA_CLASSIFICATION=CA_BUNDLE_ABSENT \
  FAKE_START_FAIL=true \
  FAKE_DOCKER_LOG="$TMP/docker.log" \
  FAKE_STATE_DIR="$TMP/state" \
  timeout 120s bash "$INSPECTOR"; then
  echo 'expected start failure to be rejected' >&2
  exit 1
fi
grep -Fxq rm "$TMP/docker.log"
grep -Fxq ps "$TMP/docker.log"

: >"$TMP/docker.log"
rm -f "$TMP/state/created"
rm -f "$TMP/state/removed"
if PATH="$TMP/bin:$PATH" \
  FAKE_CA_CLASSIFICATION=CA_BUNDLE_ABSENT \
  FAKE_PERSIST_CONTAINER=true \
  FAKE_DOCKER_LOG="$TMP/docker.log" \
  FAKE_STATE_DIR="$TMP/state" \
  timeout 120s bash "$INSPECTOR"; then
  echo 'expected incomplete teardown to be rejected' >&2
  exit 1
fi
[[ "$(grep -Fc rm "$TMP/docker.log")" == 2 ]]

: >"$TMP/docker.log"
rm -f "$TMP/state/created"
rm -f "$TMP/state/removed"
if PATH="$TMP/bin:$PATH" \
  FAKE_CREATE_FAIL=true \
  FAKE_DOCKER_LOG="$TMP/docker.log" \
  FAKE_STATE_DIR="$TMP/state" \
  timeout 120s bash "$INSPECTOR"; then
  echo 'expected ambiguous create failure to be rejected' >&2
  exit 1
fi
[[ "$(sed -n '1,5p' "$TMP/docker.log" | paste -sd ' ' -)" == 'pull ps create rm ps' ]]

: >"$TMP/docker.log"
rm -f "$TMP/state/created"
rm -f "$TMP/state/removed"
if PATH="$TMP/bin:$PATH" \
  FAKE_EXISTING_CONTAINER=true \
  FAKE_DOCKER_LOG="$TMP/docker.log" \
  FAKE_STATE_DIR="$TMP/state" \
  timeout 120s bash "$INSPECTOR"; then
  echo 'expected a pre-existing generated name to be rejected' >&2
  exit 1
fi
[[ "$(sed -n '1,2p' "$TMP/docker.log" | paste -sd ' ' -)" == 'pull ps' ]]
! grep -Fxq rm "$TMP/docker.log"
echo 'retention proof base CA inspection tests passed'
