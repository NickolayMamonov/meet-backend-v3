#!/usr/bin/env bash
set -euo pipefail

FILE=${1:-.env.production}
test -f "$FILE" || {
  echo "$FILE does not exist" >&2
  exit 1
}

sed -E '/^BACKEND_(IMAGE|VERSION|REVISION)=/d' "$FILE" | sha256sum | awk '{print $1}'
