#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SHA=0123456789abcdef0123456789abcdef01234567
if "$ROOT_DIR/scripts/mutate-release-metadata.sh" canonicalize \
  --repository FixtureOwner/repo --release-id 120 --version 1.2.0 \
  --tag v1.2.0 --source-sha "$SHA" >/dev/null 2>&1; then
  echo "retired metadata operation unexpectedly accepted" >&2
  exit 1
fi
if "$ROOT_DIR/scripts/mutate-release-metadata.sh" publish \
  --repository FixtureOwner/repo --release-id 120 --version 1.2.0 \
  --tag v1.2.0 --source-sha "$SHA" --release-file /dev/null \
  >/dev/null 2>&1; then
  echo "publication without the policy reader unexpectedly passed" >&2
  exit 1
fi
echo "publish-only metadata mutation fixtures passed"
