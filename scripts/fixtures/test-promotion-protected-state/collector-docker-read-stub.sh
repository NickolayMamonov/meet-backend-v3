#!/usr/bin/env bash
set -euo pipefail

audit=${STUB_AUDIT:?STUB_AUDIT is required}
printf 'docker' >>"$audit"
printf ' %q' "$@" >>"$audit"
printf '\n' >>"$audit"

[ "$#" -eq 5 ] &&
  [ "$1" = buildx ] &&
  [ "$2" = imagetools ] &&
  [ "$3" = inspect ] &&
  [ "$4" = --raw ] ||
  { echo "unexpected docker command" >&2; exit 97; }

reference=$5
digest=${reference##*@}
[ "${STUB_FAIL_DIGEST:-}" != "$digest" ] ||
  { echo "fixture read failure" >&2; exit 91; }
case "$digest" in
  "$STUB_ROOT_DIGEST") cat "${STUB_ROOT_RAW:?STUB_ROOT_RAW is required}" ;;
  "$STUB_PLATFORM_DIGEST") cat "${STUB_PLATFORM_RAW:?STUB_PLATFORM_RAW is required}" ;;
  "$STUB_ARTIFACT_DIGEST") cat "${STUB_ARTIFACT_RAW:?STUB_ARTIFACT_RAW is required}" ;;
  *) echo "unexpected docker digest" >&2; exit 97 ;;
esac
