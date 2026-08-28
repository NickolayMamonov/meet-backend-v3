#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 3 ] && [ "$1" = -c ] && [ "$2" = %a ] || exit 2
[ -n "${FAKE_IDENTITY_MODE:-}" ] || exit 1
printf '%s\n' "$FAKE_IDENTITY_MODE"
