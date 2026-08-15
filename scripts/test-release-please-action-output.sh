#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NORMALIZER=$ROOT_DIR/scripts/normalize-release-please-action-output.sh
TAG=v1.2.0
VERSION=1.2.0
SOURCE=0123456789abcdef0123456789abcdef01234567

assert_output() {
  local expected=$1
  shift
  local actual
  actual=$("$NORMALIZER" "$@")
  [ "$actual" = "$expected" ] || {
    echo "expected '$expected', got '$actual'" >&2
    exit 1
  }
}

assert_rejected() {
  if "$NORMALIZER" "$@" >/dev/null 2>&1; then
    echo "invalid Release Please output shape was accepted: $*" >&2
    exit 1
  fi
}

assert_output false \
  --release-created '' --tag '' --version '' --source-sha ''
assert_output false \
  --release-created false --tag '' --version '' --source-sha ''
assert_output true \
  --release-created true --tag "$TAG" --version "$VERSION" --source-sha "$SOURCE"

assert_rejected \
  --release-created '' --tag "$TAG" --version '' --source-sha ''
assert_rejected \
  --release-created false --tag '' --version "$VERSION" --source-sha ''
assert_rejected \
  --release-created true --tag "$TAG" --version '' --source-sha "$SOURCE"
assert_rejected \
  --release-created yes --tag '' --version '' --source-sha ''
assert_rejected \
  --release-created false --tag '' --version ''

echo "Release Please action output normalization fixtures passed"
