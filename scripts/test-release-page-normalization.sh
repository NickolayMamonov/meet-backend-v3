#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NORMALIZER=$ROOT_DIR/scripts/normalize-release-pages.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

assert_output() {
  local expected=$1
  local input=$2
  local actual

  actual=$(printf '%s' "$input" | "$NORMALIZER")
  if [ "$actual" != "$expected" ]; then
    echo "expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

assert_rejected() {
  local name=$1
  local input=$2
  local stdout=$TMP/stdout
  local stderr=$TMP/stderr

  if printf '%s' "$input" | "$NORMALIZER" >"$stdout" 2>"$stderr"; then
    echo "expected rejection: $name" >&2
    exit 1
  fi
  if [ -s "$stdout" ]; then
    echo "rejection wrote to stdout: $name" >&2
    exit 1
  fi
}

assert_output \
  '[{"id":1,"tag_name":"v1.0.0"},{"id":2,"draft":false},{"id":3,"assets":[]}]' \
  '[[{"id":1,"tag_name":"v1.0.0"},{"id":2,"draft":false}],[{"id":3,"assets":[]}]]'
assert_output '[]' '[]'
assert_output '[]' '[[],[]]'

assert_rejected "null page" '[null]'
assert_rejected "object root" '{"id":1}'
assert_rejected "null root" 'null'
assert_rejected "scalar root" '"release"'
assert_rejected "non-array page object" '[[{"id":1}],{"id":2}]'
assert_rejected "non-array page scalar" '[[{"id":1}],7]'
assert_rejected "non-object release null" '[[null]]'
assert_rejected "non-object release array" '[[[]]]'
assert_rejected "non-object release scalar" '[[{"id":1},"v2.0.0"]]'
assert_rejected "malformed JSON" '[[{"id":1}]] trailing'
assert_rejected "multiple JSON roots" '[[{"id":1}]][[{"id":2}]]'

echo "Release page normalization tests passed"
