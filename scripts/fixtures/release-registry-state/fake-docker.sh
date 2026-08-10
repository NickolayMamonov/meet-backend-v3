#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = buildx ] && [ "${2:-}" = imagetools ] &&
  [ "${3:-}" = inspect ] || {
    echo "unsupported fake docker operation" >&2
    exit 2
  }

ref=${!#}
case "$ref" in
  *:latest)
    case "${FAKE_LATEST_STATE:-absent}" in
      absent)
        echo "manifest unknown" >&2
        exit 1
        ;;
      present)
        printf 'Name: %s\nDigest: sha256:%064d\n' "$ref" 1
        exit 0
        ;;
      error)
        echo "permission denied while inspecting registry" >&2
        exit 2
        ;;
      *)
        echo "unknown fake latest state" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "manifest unknown" >&2
    exit 1
    ;;
esac
