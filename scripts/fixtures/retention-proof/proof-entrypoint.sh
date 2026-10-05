#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != --run-fixture ] || [ "$#" -ne 1 ]; then
  echo "RETENTION_PROOF_DENIED" >&2
  exit 1
fi
[[ -d /src && ! -L /src && -d /fixture && ! -L /fixture ]] || exit 1
[ "$(stat -c '%u:%a' /fixture)" = 0:700 ] || exit 1
[ "$(findmnt -n -o TARGET,FSTYPE --target /fixture)" = '/fixture tmpfs' ] ||
  exit 1
[ "$(findmnt -R -n -o TARGET /fixture)" = /fixture ] || exit 1

exec timeout 300s bash /src/scripts/test-test-vps-retention.sh \
  --fixture-parent /fixture
