#!/usr/bin/env bash
set -euo pipefail

[ "${BOOTSTRAP_DOCKER_FAIL:-false}" != true ] || exit 91

case "${1:-}" in
  image)
    [ "${2:-}" = inspect ] || exit 92
    cat "${BOOTSTRAP_IMAGE_INSPECT:?BOOTSTRAP_IMAGE_INSPECT is required}"
    ;;
  create)
    printf '%s\n' fixture-container
    ;;
  cp)
    [ "${2:-}" = fixture-container:/app/app.jar ] || exit 93
    cp -- "${BOOTSTRAP_FIXTURE_JAR:?BOOTSTRAP_FIXTURE_JAR is required}" "${3:?destination is required}"
    ;;
  rm)
    [ "${2:-}" = fixture-container ] || exit 94
    ;;
  *) exit 95 ;;
esac
