#!/usr/bin/env bash
set -euo pipefail

event_log=${FAKE_RECOVERY_EVENT_LOG:-}
log_event() {
  [ -n "$event_log" ] || return 0
  printf '%s\n' "$1" >>"$event_log"
}
identity_value() {
  local path=$1
  [ -f "$path" ] || return 1
  tr -d '\r\n' <"$path"
}

program=$(basename -- "$0")
if [ "$program" = age-keygen ]; then
  case "${1:-}" in
    --version)
      printf '1.3.1\n'
      exit 0
      ;;
    -y)
      [ "$#" -eq 2 ] || exit 2
      identity=$2
      value=$(identity_value "$identity") || exit 1
      case "$value" in
        identity|wrong-identity)
          log_event identity-parse
          printf '%s\n' age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m
          exit 0
          ;;
        *)
          exit 1
          ;;
      esac
      ;;
    -o)
      [ "$#" -eq 2 ] || exit 2
      printf '%s\n' identity >"$2"
      exit 0
      ;;
    *)
      exit 2
      ;;
  esac
fi

output=''
input=''
decrypt=0
identity=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      printf '1.3.1\n'
      exit 0
      ;;
    -o)
      output=$2
      shift 2
      ;;
    -d)
      decrypt=1
      shift
      ;;
    -i)
      identity=$2
      shift 2
      ;;
    -r)
      shift 2
      ;;
    *)
      input=$1
      shift
      ;;
  esac
done
[ "$decrypt" -eq 1 ] && [ -n "$output" ] && [ -n "$input" ] && [ -n "$identity" ]
value=$(identity_value "$identity") || exit 1
case "$input" in
  *postgres.dump.age)
    log_event database-decrypt
    [ "$value" = identity ] || exit 1
    cp -- "$FAKE_DATABASE_DUMP" "$output"
    ;;
  *uploads.tar.gz.age)
    log_event uploads-decrypt
    [ "$value" = identity ] || exit 1
    [ "${FAKE_AGE_FAIL_UPLOADS:-0}" != 1 ] || exit 1
    cp -- "$FAKE_UPLOADS_ARCHIVE" "$output"
    ;;
  *)
    exit 1
    ;;
esac
