#!/usr/bin/env bash
set -euo pipefail

username=${GHCR_USERNAME:-${GITHUB_ACTOR:-}}
if [ -z "$username" ]; then
  username=$(gh api user --jq .login 2>/dev/null) || {
    echo "GHCR username resolution failed" >&2
    exit 1
  }
fi

case "$username" in
  ""|*[[:space:]]*)
    echo "GHCR username is empty or contains whitespace" >&2
    exit 1
    ;;
esac

printf '%s\n' "$username"
