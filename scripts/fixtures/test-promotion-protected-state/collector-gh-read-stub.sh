#!/usr/bin/env bash
set -euo pipefail

audit=${STUB_AUDIT:?STUB_AUDIT is required}
{
  printf 'gh'
  printf ' %s' "$@"
  printf '\n'
} >>"$audit"

[ "$#" -eq 4 ] &&
  [ "$1" = api ] &&
  [ "$2" = --paginate ] &&
  [ "$3" = --slurp ] ||
  { echo "unexpected gh command" >&2; exit 97; }

case "$4" in
  *'releases?per_page=100')
    printf '[[]]\n'
    ;;
  *'versions?per_page=100')
    cat "${STUB_PACKAGES:?STUB_PACKAGES is required}"
    ;;
  *)
    echo "unexpected gh command" >&2
    exit 97
    ;;
esac
