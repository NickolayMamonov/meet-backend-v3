#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 4 ]
[ "$1" = "ghcr.io/nickolaymamonov/meet-backend-v3" ] || exit 1
[ "$2" = "test-sha-$3" ] || exit 1
[ "$4" = "1.2.3" ] || exit 1

fixture_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cat "$fixture_dir/reusable.json"
