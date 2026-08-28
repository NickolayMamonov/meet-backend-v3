#!/usr/bin/env bash
set -euo pipefail

output=''
input=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -d) shift ;;
    -i|-r) shift 2 ;;
    *) input=$1; shift ;;
  esac
done
[ -n "$output" ] && [ -n "$input" ]
if [[ "$input" == *postgres.dump.age ]]; then
  cp "$FAKE_DATABASE_DUMP" "$output"
else
  cp "$FAKE_UPLOADS_ARCHIVE" "$output"
fi
