#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --input PATH" >&2
  exit 2
}

fail() {
  echo "test promotion environment policy validation failed: $*" >&2
  exit 1
}

input=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)
      [ "$#" -ge 2 ] && [ -z "$input" ] || usage
      input=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$input" ] && [ -f "$input" ] || usage
[ ! -L "$input" ] || fail "input path is unsafe"
command -v jq >/dev/null 2>&1 || fail "jq is required"

jq -e '
  type == "object" and
  (keys | sort) == ["branch_policies", "total_count"] and
  (.total_count |
    type == "number" and floor == . and . == 1) and
  (.branch_policies |
    type == "array" and length == 1) and
  (.branch_policies[0] |
    type == "object" and
    (.name | type) == "string" and .name == "dev" and
    (.type | type) == "string" and .type == "branch")
' "$input" >/dev/null || fail "expected exactly one dev branch policy in the live object shape"

echo "deployment_branch=dev"
