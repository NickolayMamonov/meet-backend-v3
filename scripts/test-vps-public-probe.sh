#!/usr/bin/env bash
set -euo pipefail

public_url=${1:-}
[[ "$public_url" =~ ^https://[^/]+$ ]] || {
  echo "public_probe_failed=invalid_url" >&2
  exit 1
}

meetings_probe=$(
  timeout 30s curl --silent --show-error --connect-timeout 5 \
    --max-time 15 --write-out $'\n%{http_code}' \
    "$public_url/meetings" 2>/dev/null |
    timeout 5s python3 -c '
import json
import sys

data = sys.stdin.buffer.read(8 * 1024 * 1024 + 64)
body, separator, status = data.rpartition(b"\n")
if not separator or len(body) > 8 * 1024 * 1024:
    raise SystemExit(21)
if status != b"200":
    raise SystemExit(22)
try:
    value = json.loads(body.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(23)
if not isinstance(value, list):
    raise SystemExit(24)
print("meetings_status=200")
print("meetings_array=true")
'
) || {
  echo "public_probe_failed=meetings_response" >&2
  exit 1
}

actuator_status=$(
  timeout 30s curl --silent --show-error --connect-timeout 5 \
    --max-time 15 --output /dev/null --write-out '%{http_code}' \
    "$public_url/actuator" 2>/dev/null
) || {
  echo "public_probe_failed=actuator_transport" >&2
  exit 1
}
[ "$actuator_status" = 404 ] || {
  echo "public_probe_failed=actuator_status" >&2
  exit 1
}

redirect_headers=$(
  timeout 30s curl --silent --show-error --connect-timeout 5 \
    --max-time 15 --dump-header - --output /dev/null \
    --write-out '%{http_code}' \
    "${public_url/https:\/\//http://}/meetings" 2>/dev/null
) || {
  echo "public_probe_failed=redirect_transport" >&2
  exit 1
}
redirect_status=${redirect_headers: -3}
case "$redirect_status" in
  301|302|307|308) ;;
  *)
    echo "public_probe_failed=redirect_status" >&2
    exit 1
    ;;
esac
grep -Eiq '^location:[[:space:]]+https://' <<<"$redirect_headers" || {
  echo "public_probe_failed=redirect_location" >&2
  exit 1
}

printf '%s\n' "$meetings_probe"
printf 'actuator_status=%s\n' "$actuator_status"
printf 'redirect_status=%s\n' "$redirect_status"
