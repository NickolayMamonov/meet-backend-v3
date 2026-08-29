#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

usage() {
  echo "beta recovery host-key materialization failed: invalid arguments" >&2
  exit 2
}

fail() {
  echo "beta recovery host-key materialization failed: $1" >&2
  exit 1
}

host=
port=
expected=
output=
seen_host=false
seen_port=false
seen_expected=false
seen_output=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [ "$seen_host" = false ] && [ "$#" -ge 2 ] || usage
      host=$2
      seen_host=true
      shift 2
      ;;
    --port)
      [ "$seen_port" = false ] && [ "$#" -ge 2 ] || usage
      port=$2
      seen_port=true
      shift 2
      ;;
    --expected-fingerprint)
      [ "$seen_expected" = false ] && [ "$#" -ge 2 ] || usage
      expected=$2
      seen_expected=true
      shift 2
      ;;
    --output)
      [ "$seen_output" = false ] && [ "$#" -ge 2 ] || usage
      output=$2
      seen_output=true
      shift 2
      ;;
    *) usage ;;
  esac
done

[ "$seen_host" = true ] && [ "$seen_port" = true ] &&
  [ "$seen_expected" = true ] && [ "$seen_output" = true ] || usage

[[ "$host" =~ ^[A-Za-z0-9](-?[A-Za-z0-9])*(\.[A-Za-z0-9](-?[A-Za-z0-9])*)*$ ]] ||
  fail "host is invalid"
[ "${#host}" -le 253 ] || fail "host is invalid"
[[ "$port" =~ ^(0|[1-9][0-9]*)$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] ||
  fail "port is invalid"
[[ "$expected" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || fail "fingerprint is invalid"
[[ "$output" != *$'\n'* && "$output" != *$'\r'* && "$output" != *:* ]] ||
  fail "output path is invalid"

for tool in realpath stat id mktemp chmod ln rm ssh-keyscan ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable"
done

runner_temp=${RUNNER_TEMP:-}
[ -n "$runner_temp" ] && [ -d "$runner_temp" ] && [ ! -L "$runner_temp" ] ||
  fail "runner temporary directory is invalid"
runner_temp=$(realpath -- "$runner_temp") || fail "runner temporary directory is invalid"
[ -d "$runner_temp" ] && [ ! -L "$runner_temp" ] || fail "runner temporary directory is invalid"

output_parent=${output%/*}
[ "$output_parent" != "$output" ] || fail "output path is invalid"
output_basename=${output##*/}
[ "$output_basename" = known_hosts ] || fail "output path is invalid"
[ -d "$output_parent" ] && [ ! -L "$output_parent" ] || fail "output path is invalid"
output_parent=$(realpath -- "$output_parent") || fail "output path is invalid"
runner_prefix=$runner_temp/
[[ "$output_parent/" == "$runner_prefix"* ]] && [ "$output_parent" != "$runner_temp" ] ||
  fail "output path is invalid"
[ "$(stat -c '%u' -- "$output_parent")" = "$(id -u)" ] || fail "output directory is unsafe"
[ "$(stat -c '%a' -- "$output_parent")" = 700 ] || fail "output directory is unsafe"
[ "$output" = "$output_parent/known_hosts" ] || fail "output path is invalid"
[ ! -e "$output" ] && [ ! -L "$output" ] || fail "output path is occupied"

scan_file=
fingerprint_file=
candidate_file=
success=false
output_valid=false
published=false
published_identity=

remove_published_output() {
  local current_identity
  [ "$published" = true ] || return 0
  [ -e "$output" ] || [ -L "$output" ] || return 0
  current_identity=$(stat -c '%d:%i' -- "$output") || return 1
  [ "$current_identity" = "$published_identity" ] || return 0
  rm -f -- "$output"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  [ -z "$scan_file" ] || rm -f -- "$scan_file" || status=1
  [ -z "$fingerprint_file" ] || rm -f -- "$fingerprint_file" || status=1
  [ -z "$candidate_file" ] || rm -f -- "$candidate_file" || status=1
  if [ "$status" -ne 0 ] || [ "$success" != true ] || [ "$output_valid" != true ]; then
    remove_published_output || status=1
  fi
  exit "$status"
}

on_signal() {
  local signal=$1
  local status=$((128 + signal))
  trap - EXIT HUP INT TERM
  [ -z "$scan_file" ] || rm -f -- "$scan_file" || status=1
  [ -z "$fingerprint_file" ] || rm -f -- "$fingerprint_file" || status=1
  [ -z "$candidate_file" ] || rm -f -- "$candidate_file" || status=1
  remove_published_output || true
  exit "$status"
}

trap cleanup EXIT
trap 'on_signal 1' HUP
trap 'on_signal 2' INT
trap 'on_signal 15' TERM

scan_file=$(mktemp "$output_parent/.beta-recovery-keyscan.XXXXXX") ||
  fail "staging file creation failed"
fingerprint_file=$(mktemp "$output_parent/.beta-recovery-fingerprint.XXXXXX") ||
  fail "staging file creation failed"
candidate_file=$(mktemp "$output_parent/.beta-recovery-known-hosts.XXXXXX") ||
  fail "staging file creation failed"

endpoint=$host
[ "$port" = 22 ] || endpoint="[$host]:$port"

if ! ssh-keyscan -T 5 -t rsa -p "$port" "$host" >"$scan_file" 2>/dev/null; then
  fail "key scan failed"
fi
[ "$(wc -l <"$scan_file" | tr -d '[:space:]')" = 1 ] || fail "key scan output is ambiguous"
IFS= read -r scan_line <"$scan_file" || fail "key scan output is invalid"
[ -n "$scan_line" ] && [[ "$scan_line" != *$'\r' ]] || fail "key scan output is invalid"
[[ "$scan_line" =~ ^[^[:space:]]+\ ssh-rsa\ [A-Za-z0-9+/=]+$ ]] ||
  fail "key scan output is invalid"
read -r scan_endpoint scan_type scan_key scan_extra <<<"$scan_line"
[ -z "${scan_extra:-}" ] && [ "$scan_endpoint" = "$endpoint" ] &&
  [ "$scan_type" = ssh-rsa ] && [ -n "$scan_key" ] || fail "key scan identity is invalid"

if ! ssh-keygen -lf "$scan_file" -E sha256 >"$fingerprint_file" 2>/dev/null; then
  fail "key fingerprint failed"
fi
[ "$(wc -l <"$fingerprint_file" | tr -d '[:space:]')" = 1 ] ||
  fail "key fingerprint output is invalid"
fingerprint_line=$(<"$fingerprint_file")
[[ "$fingerprint_line" =~ ^[0-9]+\ (SHA256:[A-Za-z0-9+/]{43})\ [^[:space:]]+\ \(RSA\)$ ]] ||
  fail "key fingerprint output is invalid"
observed=${BASH_REMATCH[1]}
[ "$observed" = "$expected" ] || fail "key fingerprint mismatch"

printf '%s\n' "$scan_line" >"$candidate_file"
chmod 600 -- "$candidate_file" || fail "publication preparation failed"
candidate_identity=$(stat -c '%d:%i' -- "$candidate_file") ||
  fail "publication preparation failed"
published_identity=$candidate_identity
published=true
if ! ln -- "$candidate_file" "$output" 2>/dev/null; then
  fail "output publication collision"
fi
success=true
[ -f "$output" ] && [ ! -L "$output" ] || fail "published output is unsafe"
[ "$(stat -c '%a' -- "$output")" = 600 ] || fail "published output is unsafe"
[ "$(wc -l <"$output" | tr -d '[:space:]')" = 1 ] || fail "published output is invalid"
output_valid=true
