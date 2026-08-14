#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
POLICY=$ROOT_DIR/scripts/release-mutation-policy.sh
SHA=0123456789abcdef0123456789abcdef01234567
"$POLICY" check --repository FixtureOwner/repo --release-id 120 \
  --version 1.2.0 --tag v1.2.0 --source-sha "$SHA" >/dev/null
for args in \
  "--release-id 368531227 --version 1.1.0 --tag v1.1.0" \
  "--release-id 120 --version 1.1.0 --tag v1.1.0" \
  "--release-id 120 --version 1.2.0 --tag v1.1.0"; do
  if "$POLICY" check --repository FixtureOwner/repo \
    --source-sha "$SHA" $args >/dev/null 2>&1; then
    echo "blocked mutation tuple passed: $args" >&2
    exit 1
  fi
done
echo "release mutation policy fixtures passed"
