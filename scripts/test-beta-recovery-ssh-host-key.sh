#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
umask 077

fail() {
  echo "beta recovery SSH host-key fixture failed: $* (fixture root: ${temporary_root:-unknown})" >&2
  exit 1
}

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
materializer=$root/scripts/materialize-beta-recovery-known-hosts.sh
[ -x "$materializer" ] || fail "materializer is missing or not executable"

for tool in awk basename chmod env find grep mkdir mktemp rm scp seq sleep ssh ssh-keygen stat tr wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

original_path=$PATH
real_ssh_keygen=$(command -v ssh-keygen)
real_rm=$(command -v rm)
temporary_root=$(mktemp -d)
chmod 700 -- "$temporary_root"
if [ "$(stat -c '%a' -- "$temporary_root")" != 700 ]; then
  echo "beta recovery SSH host-key fixture skipped: POSIX mode checks unavailable"
  exit 0
fi

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "${KEEP_BETA_RECOVERY_FIXTURE:-0}" != 1 ]; then
    rm -r -- "$temporary_root" || status=1
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

fixture_bin=$temporary_root/bin
key_dir=$temporary_root/key
mkdir -p "$fixture_bin" "$key_dir"

key_file=$key_dir/fixture-rsa
"$real_ssh_keygen" -q -t rsa -b 2048 -N '' -f "$key_file" >/dev/null
chmod 600 -- "$key_file"
[ -f "$key_file.pub" ] || fail "real ssh-keygen did not create a public key"

key_type=$(awk 'NR == 1 { print $1; exit }' "$key_file.pub")
key_data=$(awk 'NR == 1 { print $2; exit }' "$key_file.pub")
[ "$key_type" = ssh-rsa ] || fail "fixture key is not RSA"
[ -n "$key_data" ] || fail "fixture public key is empty"
scan_host=beta-recovery.example.test
scan_line="$scan_host $key_type $key_data"
expected_fingerprint=$("$real_ssh_keygen" -lf "$key_file.pub" -E sha256 |
  awk 'NR == 1 { print $2; exit }')
[[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] ||
  fail "real ssh-keygen did not produce a SHA256 fingerprint"
wrong_fingerprint=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

write_wrapper() {
  local path=$1
  shift
  printf '%s\n' "$@" >"$path"
  chmod 700 -- "$path"
}

write_wrapper "$fixture_bin/ssh-keyscan" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  ': "${BETA_RECOVERY_BOUNDARY_LOG:?}"' \
  'printf "ssh-keyscan args:" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'for arg in "$@"; do printf " <%s>" "$arg" >>"$BETA_RECOVERY_BOUNDARY_LOG"; done' \
  'printf "\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'case "${BETA_RECOVERY_SCAN_MODE:-valid}" in' \
  '  valid|mismatch) printf "%s\n" "${BETA_RECOVERY_SCAN_LINE:?}" ;;' \
  '  timeout) exit 124 ;;' \
  '  empty) : ;;' \
  '  comment) printf "# hostile comment\n" ;;' \
  '  extra-field) printf "%s extra\n" "${BETA_RECOVERY_SCAN_LINE:?}" ;;' \
  '  duplicate) printf "%s\n%s\n" "${BETA_RECOVERY_SCAN_LINE:?}" "${BETA_RECOVERY_SCAN_LINE:?}" ;;' \
  '  ambiguous|multiple) printf "%s\n%s\n" "${BETA_RECOVERY_SCAN_LINE:?}" "${BETA_RECOVERY_SCAN_ALT_LINE:?}" ;;' \
  '  unexpected-host) printf "%s\n" "${BETA_RECOVERY_SCAN_UNEXPECTED_LINE:?}" ;;' \
  '  wrong-type) printf "%s\n" "${BETA_RECOVERY_SCAN_WRONG_TYPE_LINE:?}" ;;' \
  '  malformed-key) printf "%s ssh-rsa not-a-public-key\n" "${BETA_RECOVERY_SCAN_ENDPOINT:?}" ;;' \
  '  malformed) printf "not-a-valid-keyscan-line\n" ;;' \
  '  failure) exit 42 ;;' \
  '  *) echo "unknown fixture keyscan mode" >&2; exit 43 ;;' \
  'esac'

write_wrapper "$fixture_bin/ssh-keygen" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  ': "${BETA_RECOVERY_BOUNDARY_LOG:?}"' \
  'printf "ssh-keygen args:" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'for arg in "$@"; do printf " <%s>" "$arg" >>"$BETA_RECOVERY_BOUNDARY_LOG"; done' \
  'printf "\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '[ "${BETA_RECOVERY_KEYGEN_MODE:-delegate}" = fail ] && exit 44' \
  '[ "${BETA_RECOVERY_KEYGEN_MODE:-delegate}" = malformed ] && { printf "malformed fingerprint\n"; exit 0; }' \
  'exec "${BETA_RECOVERY_REAL_SSH_KEYGEN:?}" "$@"'

write_wrapper "$fixture_bin/ln" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [ -n "${BETA_RECOVERY_LN_BARRIER_DIR:-}" ]; then' \
  '  ready="$BETA_RECOVERY_LN_BARRIER_DIR/$BASHPID.ready"' \
  '  : >"$ready"' \
  '  for attempt in $(seq 1 500); do' \
  '    [ "$(find "$BETA_RECOVERY_LN_BARRIER_DIR" -maxdepth 1 -name "*.ready" | wc -l | tr -d "[:space:]")" -ge 2 ] && break' \
  '    sleep 0.01' \
  '  done' \
  '  [ "$(find "$BETA_RECOVERY_LN_BARRIER_DIR" -maxdepth 1 -name "*.ready" | wc -l | tr -d "[:space:]")" -ge 2 ]' \
  'fi' \
  '"${BETA_RECOVERY_REAL_LN:?}" "$@"' \
  'if [ "${BETA_RECOVERY_SIGNAL_AFTER_PUBLICATION:-0}" = 1 ]; then' \
  '  helper_pid=$PPID' \
  '  printf "%s\n" "$helper_pid" >"$BETA_RECOVERY_HELPER_PID_FILE"' \
  '  kill -STOP "$helper_pid"' \
  '  (sleep 0.1; kill -CONT "$helper_pid" 2>/dev/null || true) &' \
  'fi'

write_wrapper "$fixture_bin/stat" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'args=("$@")' \
  '"${BETA_RECOVERY_REAL_STAT:?}" "${args[@]}"' \
  'if [ "${BETA_RECOVERY_SIGNAL_AFTER_PUBLICATION:-0}" = 1 ] &&' \
  '  [ "${args[0]:-}" = -c ] && [ "${args[1]:-}" = %a ] &&' \
  '  [ "${args[3]:-}" = "${BETA_RECOVERY_OUTPUT:?}" ]; then' \
  '  kill -"${BETA_RECOVERY_PUBLICATION_SIGNAL:-TERM}" "$(cat "$BETA_RECOVERY_HELPER_PID_FILE")"' \
  '  sleep 1' \
  'fi'

write_wrapper "$fixture_bin/rm" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'exec "${BETA_RECOVERY_REAL_RM:?}" "$@"'

write_wrapper "$fixture_bin/ssh" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  ': "${BETA_RECOVERY_BOUNDARY_LOG:?}"' \
  'printf "ssh fake boundary argc=%s\n" "$#" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'exit 0'

write_wrapper "$fixture_bin/scp" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  ': "${BETA_RECOVERY_BOUNDARY_LOG:?}"' \
  'printf "scp fake boundary argc=%s\n" "$#" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'exit 0'

make_case() {
  local name=$1
  local case_dir=$temporary_root/cases/$name
  mkdir -p "$case_dir/runner/output" "$case_dir/home/.ssh"
  chmod 700 "$case_dir/runner" "$case_dir/runner/output" "$case_dir/home" \
    "$case_dir/home/.ssh"
  printf '%s\n' \
    'Host *' \
    '  UserKnownHostsFile /tmp/hostile-known-hosts' \
    '  GlobalKnownHostsFile /tmp/hostile-global-known-hosts' \
    '  KnownHostsCommand /bin/false' \
    '  ProxyCommand /bin/false' \
    >"$case_dir/home/.ssh/config"
  chmod 600 "$case_dir/home/.ssh/config"
  printf '%s\n' "$case_dir"
}

run_materializer() {
  local case_dir=$1 host=$2 port=$3 expected=$4 mode=$5 keygen_mode=${6:-delegate}
  local output_override=${7:-} ln_barrier=${8:-}
  local path_prefix=${9:-$fixture_bin}
  local rm_marker=${10:-}
  local staging_log=${11:-}
  local output=$case_dir/runner/output/known_hosts scan_line_for_case=$scan_line
  [ "$port" = 22 ] || scan_line_for_case="[$host]:$port $key_type $key_data"
  [ -n "$output_override" ] && output=$output_override
  local scan_endpoint_for_case=${scan_line_for_case%% *}
  env \
    PATH="$path_prefix:$original_path" \
    HOME="$case_dir/home" \
    RUNNER_TEMP="$case_dir/runner" \
    BETA_RECOVERY_BOUNDARY_LOG="$case_dir/boundary.log" \
    BETA_RECOVERY_REAL_SSH_KEYGEN="$real_ssh_keygen" \
    BETA_RECOVERY_REAL_LN="$(command -v ln)" \
    BETA_RECOVERY_REAL_STAT="$(command -v stat)" \
    BETA_RECOVERY_REAL_RM="$real_rm" \
    BETA_RECOVERY_REAL_MKTEMP="$(command -v mktemp)" \
    BETA_RECOVERY_REAL_CHMOD="$(command -v chmod)" \
    BETA_RECOVERY_RM_MARKER="$rm_marker" \
    BETA_RECOVERY_STAGING_LOG="$staging_log" \
    BETA_RECOVERY_SCAN_MODE="$mode" \
    BETA_RECOVERY_SCAN_LINE="$scan_line_for_case" \
    BETA_RECOVERY_SCAN_ALT_LINE="$scan_line_for_case" \
    BETA_RECOVERY_SCAN_ENDPOINT="$scan_endpoint_for_case" \
    BETA_RECOVERY_SCAN_UNEXPECTED_LINE="unexpected.example.test ssh-rsa $key_data" \
    BETA_RECOVERY_SCAN_WRONG_TYPE_LINE="$scan_endpoint_for_case ssh-ed25519 $key_data" \
    BETA_RECOVERY_KEYGEN_MODE="$keygen_mode" \
    BETA_RECOVERY_LN_BARRIER_DIR="$ln_barrier" \
    "$materializer" \
    --host "$host" \
    --port "$port" \
    --expected-fingerprint "$expected" \
    --output "$output" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
}

assert_no_staging() {
  local case_dir=$1
  local leftovers
  leftovers=$(find "$case_dir/runner/output" -maxdepth 1 -type f \
    -name '.beta-recovery-*' -print)
  [ -z "$leftovers" ] || fail "staging residue remained in $case_dir"
}

assert_no_private_output() {
  local case_dir=$1
  if grep -Eiq 'BEGIN[[:space:]]+[^ ]*PRIVATE KEY|OPENSSH PRIVATE KEY' \
    "$case_dir/stdout" "$case_dir/stderr" "$case_dir/boundary.log" 2>/dev/null; then
    fail "private key material reached fixture output for $(basename "$case_dir")"
  fi
}

assert_success_output() {
  local case_dir=$1 expected_line=$2
  local output=$case_dir/runner/output/known_hosts
  [ -f "$output" ] && [ ! -L "$output" ] || fail "success output is not a regular file"
  [ "$(stat -c '%a' -- "$output")" = 600 ] ||
    fail "success output mode is not 0600"
  [ "$(wc -l <"$output" | tr -d '[:space:]')" = 1 ] ||
    fail "success output does not contain exactly one line"
  [ "$(<"$output")" = "$expected_line" ] ||
    fail "success output key line differs from the real fixture key"
  assert_no_staging "$case_dir"
  assert_no_private_output "$case_dir"
}

assert_failure_case() {
  local case_dir=$1
  local output=${2:-$case_dir/runner/output/known_hosts}
  if [ -e "$output" ] || [ -L "$output" ]; then
    fail "failed case published output: $(basename "$case_dir")"
  fi
  assert_no_staging "$case_dir"
  assert_no_private_output "$case_dir"
}

assert_sanitized_failure() {
  local case_dir=$1
  shift
  for value in "$@"; do
    ! grep -Fq -- "$value" "$case_dir/stderr" 2>/dev/null ||
      fail "failure diagnostics disclosed sensitive value for $(basename "$case_dir")"
  done
}

assert_no_boundary_crossing() {
  local case_dir=$1
  [ ! -s "$case_dir/boundary.log" ] ||
    fail "invalid helper case crossed a boundary: $(basename "$case_dir")"
}

run_no_scan_failure_case() {
  local name=$1 host=$2 port=$3 expected=$4 output_override=${5:-}
  local case_dir output=$output_override
  case_dir=$(make_case "$name")
  [ -n "$output" ] || output=$case_dir/runner/output/known_hosts
  if run_materializer "$case_dir" "$host" "$port" "$expected" valid delegate "$output"; then
    fail "invalid pre-scan case unexpectedly succeeded: $name"
  fi
  assert_failure_case "$case_dir" "$output"
  assert_no_boundary_crossing "$case_dir"
  assert_sanitized_failure "$case_dir" "$host" "$expected" "$output"
}

assert_keyscan_invocation() {
  local case_dir=$1 port=$2
  grep -Fq \
    "ssh-keyscan args: <-T> <5> <-t> <rsa> <-p> <$port> <$scan_host>" \
    "$case_dir/boundary.log" ||
    fail "keyscan boundary did not receive the expected host and port"
  [ "$(grep -c '^ssh-keyscan args:' "$case_dir/boundary.log")" -eq 1 ] ||
    fail "keyscan boundary was called more than once"
  [ "$(grep -c '^ssh-keygen args:' "$case_dir/boundary.log")" -eq 1 ] ||
    fail "keygen boundary was not called exactly once"
  ! grep -q '^ssh fake boundary' "$case_dir/boundary.log" ||
    fail "materializer crossed the SSH boundary"
  ! grep -q '^scp fake boundary' "$case_dir/boundary.log" ||
    fail "materializer crossed the SCP boundary"
}

run_success_case() {
  local name=$1 port=$2 expected_line=$3
  local case_dir
  case_dir=$(make_case "$name")
  run_materializer "$case_dir" "$scan_host" "$port" "$expected_fingerprint" valid
  assert_success_output "$case_dir" "$expected_line"
  assert_keyscan_invocation "$case_dir" "$port"
}

run_failure_case() {
  local name=$1 mode=$2 expected=${3:-$expected_fingerprint} keygen_mode=${4:-delegate}
  local case_dir
  case_dir=$(make_case "$name")
  if run_materializer "$case_dir" "$scan_host" 22 "$expected" "$mode" "$keygen_mode"; then
    fail "invalid case unexpectedly succeeded: $name"
  fi
  assert_failure_case "$case_dir"
  grep -q '^ssh-keyscan args:' "$case_dir/boundary.log" ||
    fail "invalid case did not reach the fake keyscan boundary: $name"
  assert_sanitized_failure "$case_dir" "$scan_host" "$expected" "$key_data"
}

run_success_case success-port-22 22 "$scan_line"
run_success_case success-non-default-port 2222 "[$scan_host]:2222 $key_type $key_data"

run_failure_case malformed-keyscan malformed
run_failure_case mismatched-fingerprint mismatch "$wrong_fingerprint"
run_failure_case timeout-keyscan timeout
run_failure_case empty-keyscan empty
run_failure_case comment-keyscan comment
run_failure_case extra-field-keyscan extra-field
run_failure_case duplicate-keyscan duplicate
run_failure_case multiple-keyscan multiple
run_failure_case unexpected-host-keyscan unexpected-host
run_failure_case wrong-type-keyscan wrong-type
run_failure_case malformed-public-key malformed-key
run_failure_case keyscan-failure failure
run_failure_case fingerprint-failure valid "$expected_fingerprint" fail
run_failure_case malformed-fingerprint-output valid "$expected_fingerprint" malformed

run_no_scan_failure_case invalid-fingerprint "$scan_host" 22 "not-a-fingerprint"
run_no_scan_failure_case invalid-host 'bad host' 22 "$expected_fingerprint"
run_no_scan_failure_case invalid-port "$scan_host" 0 "$expected_fingerprint"

missing_tools_case=$(make_case missing-tools)
minimal_bin=$missing_tools_case/minimal-bin
mkdir -p "$minimal_bin"
ln -s "$(command -v bash)" "$minimal_bin/bash"
if env \
  PATH="$minimal_bin" \
  HOME="$missing_tools_case/home" \
  RUNNER_TEMP="$missing_tools_case/runner" \
  BETA_RECOVERY_BOUNDARY_LOG="$missing_tools_case/boundary.log" \
  "$materializer" --host "$scan_host" --port 22 \
  --expected-fingerprint "$expected_fingerprint" \
  --output "$missing_tools_case/runner/output/known_hosts" \
  >"$missing_tools_case/stdout" 2>"$missing_tools_case/stderr"; then
  fail "missing-tool case unexpectedly succeeded"
fi
assert_failure_case "$missing_tools_case"
assert_no_boundary_crossing "$missing_tools_case"
assert_sanitized_failure "$missing_tools_case" "$scan_host" "$expected_fingerprint"

unsafe_case=$(make_case unsafe-output-directory)
unsafe_output=$unsafe_case/runner/../known_hosts
if run_materializer "$unsafe_case" "$scan_host" 22 "$expected_fingerprint" valid \
  delegate "$unsafe_output"; then
  fail "output outside RUNNER_TEMP was accepted"
fi
assert_failure_case "$unsafe_case"
[ ! -e "$unsafe_output" ] && [ ! -L "$unsafe_output" ] ||
  fail "unsafe output path was published"
assert_sanitized_failure "$unsafe_case" "$scan_host" "$expected_fingerprint" "$unsafe_output"

linked_case=$(make_case linked-output)
linked_output=$linked_case/runner/output/known_hosts
printf 'linked target\n' >"$linked_case/runner/output/target"
ln -s target "$linked_output"
if run_materializer "$linked_case" "$scan_host" 22 "$expected_fingerprint" valid; then
  fail "linked output was accepted"
fi
if [ -L "$linked_output" ]; then
  [ "$(<"$linked_case/runner/output/target")" = 'linked target' ] ||
    fail "linked output target was changed"
else
  [ "$(<"$linked_output")" = 'linked target' ] ||
    fail "linked output fixture was not preserved"
fi
assert_no_staging "$linked_case"
assert_no_private_output "$linked_case"
assert_sanitized_failure "$linked_case" "$scan_host" "$expected_fingerprint"

wrong_mode_case=$(make_case wrong-mode-output)
chmod 755 "$wrong_mode_case/runner/output"
if [ "$(stat -c '%a' -- "$wrong_mode_case/runner/output")" = 755 ]; then
  if run_materializer "$wrong_mode_case" "$scan_host" 22 "$expected_fingerprint" valid; then
    fail "wrong-mode output directory was accepted"
  fi
  assert_failure_case "$wrong_mode_case"
else
  run_materializer "$wrong_mode_case" "$scan_host" 22 "$expected_fingerprint" valid ||
    fail "mode-preserving platform rejected valid output"
  assert_success_output "$wrong_mode_case" "$scan_line"
fi
assert_sanitized_failure "$wrong_mode_case" "$scan_host" "$expected_fingerprint"

nested_case=$(make_case nested-output)
nested_output=$nested_case/runner/output/nested/known_hosts
mkdir -p "$nested_case/runner/output/nested"
chmod 700 "$nested_case/runner/output/nested"
if run_materializer "$nested_case" "$scan_host" 22 "$expected_fingerprint" valid \
  delegate "$nested_output"; then
  fail "nested output path was accepted"
fi
assert_failure_case "$nested_case" "$nested_output"
assert_sanitized_failure "$nested_case" "$scan_host" "$expected_fingerprint" "$nested_output"

collision_case=$(make_case occupied-output)
collision_output=$collision_case/runner/output/known_hosts
printf 'pre-existing fixture content\n' >"$collision_output"
chmod 600 "$collision_output"
if run_materializer "$collision_case" "$scan_host" 22 "$expected_fingerprint" valid; then
  fail "occupied output was overwritten"
fi
[ "$(<"$collision_output")" = 'pre-existing fixture content' ] ||
  fail "occupied output content changed"
[ "$(stat -c '%a' -- "$collision_output")" = 600 ] ||
  fail "occupied output mode changed"
assert_no_staging "$collision_case"
assert_no_private_output "$collision_case"

race_case=$(make_case publication-race)
race_output=$race_case/runner/output/known_hosts
race_gate=$race_case/ln-barrier
mkdir -p "$race_gate"
chmod 700 "$race_gate"
set +e
(
  run_materializer "$race_case" "$scan_host" 22 "$expected_fingerprint" valid \
    delegate "$race_output" "$race_gate"
  printf '%s\n' "$?" >"$race_case/race-a.status"
) &
race_a_pid=$!
(
  run_materializer "$race_case" "$scan_host" 22 "$expected_fingerprint" valid \
    delegate "$race_output" "$race_gate"
  printf '%s\n' "$?" >"$race_case/race-b.status"
) &
race_b_pid=$!
wait "$race_a_pid"
wait "$race_b_pid"
set -e
race_a_status=$(<"$race_case/race-a.status")
race_b_status=$(<"$race_case/race-b.status")
[ "$race_a_status" -eq 0 ] || [ "$race_b_status" -eq 0 ] ||
  fail "publication race had no winner"
[ "$race_a_status" -ne 0 ] || [ "$race_b_status" -ne 0 ] ||
  fail "publication race had no losing collision"
[ -f "$race_output" ] && [ ! -L "$race_output" ] ||
  fail "publication race lost the winner output"
[ "$(<"$race_output")" = "$scan_line" ] ||
  fail "publication race changed winner content"
race_identity=$(stat -c '%d:%i' -- "$race_output")
[ "$race_identity" = "$(stat -c '%d:%i' -- "$race_output")" ] ||
  fail "publication race changed winner identity"
[ "$(stat -c '%a' -- "$race_output")" = 600 ] ||
  fail "publication race changed winner mode"
assert_no_staging "$race_case"

failure_bin=$temporary_root/failure-bin
mkdir -p "$failure_bin"
chmod 700 "$failure_bin"
write_wrapper "$failure_bin/rm" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${BETA_RECOVERY_FAIL_FIRST_SCAN_RM:-0}" = 1 ]] &&' \
  '  [[ "$*" == *".beta-recovery-keyscan."* ]] &&' \
  '  [ ! -e "${BETA_RECOVERY_RM_MARKER:?}" ]; then' \
  '  : >"$BETA_RECOVERY_RM_MARKER"' \
  '  "${BETA_RECOVERY_REAL_RM:?}" "$@"' \
  '  exit 61' \
  'fi' \
  'exec "${BETA_RECOVERY_REAL_RM:?}" "$@"'

signal_failure_bin=$temporary_root/signal-failure-bin
mkdir -p "$signal_failure_bin"
chmod 700 "$signal_failure_bin"
write_wrapper "$signal_failure_bin/rm" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [ "${BETA_RECOVERY_FAIL_PUBLISHED_RM:-0}" = 1 ] &&' \
  '  [ "${1:-}" = -f ] && [ "${2:-}" = -- ] &&' \
  '  [ "${3:-}" = "${BETA_RECOVERY_OUTPUT:?}" ] &&' \
  '  [ ! -e "${BETA_RECOVERY_RM_MARKER:?}" ]; then' \
  '  : >"$BETA_RECOVERY_RM_MARKER"' \
  '  "${BETA_RECOVERY_REAL_RM:?}" "$@"' \
  '  exit 62' \
  'fi' \
  'exec "${BETA_RECOVERY_REAL_RM:?}" "$@"'

diagnostic_failure_bin=$temporary_root/diagnostic-failure-bin
mkdir -p "$diagnostic_failure_bin"
chmod 700 "$diagnostic_failure_bin"
for utility in realpath stat mktemp chmod; do
  write_wrapper "$diagnostic_failure_bin/$utility" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'echo "injected utility failure $0 $*" >&2' \
    'exit 71'
done

diagnostic_cleanup_bin=$temporary_root/diagnostic-cleanup-bin
mkdir -p "$diagnostic_cleanup_bin"
chmod 700 "$diagnostic_cleanup_bin"
write_wrapper "$diagnostic_cleanup_bin/rm" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$*" == *".beta-recovery-keyscan."* ]] &&' \
  '  [ ! -e "${BETA_RECOVERY_RM_MARKER:?}" ]; then' \
  '  : >"$BETA_RECOVERY_RM_MARKER"' \
  '  "${BETA_RECOVERY_REAL_RM:?}" "$@"' \
  '  echo "injected cleanup failure $*" >&2' \
  '  exit 72' \
  'fi' \
  'exec "${BETA_RECOVERY_REAL_RM:?}" "$@"'

diagnostic_write_bin=$temporary_root/diagnostic-write-bin
mkdir -p "$diagnostic_write_bin"
chmod 700 "$diagnostic_write_bin"
write_wrapper "$diagnostic_write_bin/mktemp" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'path=$("${BETA_RECOVERY_REAL_MKTEMP:?}" "$@")' \
  'case "${1:-}" in' \
  '  *".beta-recovery-known-hosts.XXXXXX")' \
  '    "${BETA_RECOVERY_REAL_CHMOD:?}" 000 "$path" ;;' \
  'esac' \
  '[ -z "${BETA_RECOVERY_STAGING_LOG:-}" ] || printf "%s\n" "$path" >>"$BETA_RECOVERY_STAGING_LOG"' \
  'printf "%s\n" "$path"'

run_utility_failure_case() {
  local name=$1 path_prefix=$2
  local case_dir
  case_dir=$(make_case "$name")
  if run_materializer "$case_dir" "$scan_host" 22 "$expected_fingerprint" valid \
    delegate '' '' "$path_prefix:$fixture_bin"; then
    fail "utility failure unexpectedly succeeded: $name"
  fi
  assert_failure_case "$case_dir"
  assert_sanitized_failure "$case_dir" "$scan_host" "$expected_fingerprint" \
    "$key_data" "$case_dir/runner/output/known_hosts"
}

for utility in realpath stat mktemp chmod; do
  run_utility_failure_case "diagnostic-$utility-failure" "$diagnostic_failure_bin"
done
cleanup_failure_case=$(make_case diagnostic-cleanup-failure)
if run_materializer "$cleanup_failure_case" "$scan_host" 22 "$expected_fingerprint" valid \
  delegate '' '' "$diagnostic_cleanup_bin:$fixture_bin" \
  "$cleanup_failure_case/rm.marker"; then
  fail "diagnostic cleanup failure unexpectedly succeeded"
fi
assert_failure_case "$cleanup_failure_case"
assert_sanitized_failure "$cleanup_failure_case" "$scan_host" \
  "$expected_fingerprint" "$key_data" "$cleanup_failure_case/runner/output/known_hosts"

write_failure_case=$(make_case diagnostic-write-failure)
if run_materializer "$write_failure_case" "$scan_host" 22 "$expected_fingerprint" valid \
  delegate '' '' "$diagnostic_write_bin:$fixture_bin" '' \
  "$write_failure_case/staging.log"; then
  fail "diagnostic write failure unexpectedly succeeded"
fi
assert_failure_case "$write_failure_case"
assert_sanitized_failure "$write_failure_case" "$scan_host" \
  "$expected_fingerprint" "$key_data" "$write_failure_case/runner/output/known_hosts"
[ -s "$write_failure_case/staging.log" ] ||
  fail "diagnostic write failure did not record staging paths"
while IFS= read -r staging_path; do
  assert_sanitized_failure "$write_failure_case" "$staging_path"
done <"$write_failure_case/staging.log"

failure_case=$(make_case cleanup-failure-after-publication)
failure_output=$failure_case/runner/output/known_hosts
set +e
env PATH="$failure_bin:$fixture_bin:$original_path" \
  HOME="$failure_case/home" \
  RUNNER_TEMP="$failure_case/runner" \
  BETA_RECOVERY_BOUNDARY_LOG="$failure_case/boundary.log" \
  BETA_RECOVERY_REAL_SSH_KEYGEN="$real_ssh_keygen" \
  BETA_RECOVERY_REAL_LN="$(command -v ln)" \
  BETA_RECOVERY_REAL_STAT="$(command -v stat)" \
  BETA_RECOVERY_REAL_RM="$real_rm" \
  BETA_RECOVERY_FAIL_FIRST_SCAN_RM=1 \
  BETA_RECOVERY_RM_MARKER="$failure_case/rm.marker" \
  BETA_RECOVERY_SCAN_MODE=valid \
  BETA_RECOVERY_SCAN_LINE="$scan_line" \
  "$materializer" --host "$scan_host" --port 22 \
  --expected-fingerprint "$expected_fingerprint" \
  --output "$failure_output" \
  >"$failure_case/stdout" 2>"$failure_case/stderr"
failure_status=$?
set -e
[ "$failure_status" -ne 0 ] ||
  fail "cleanup failure unexpectedly succeeded"
assert_failure_case "$failure_case"

signal_status() {
  case "$1" in
    HUP) printf 129 ;;
    INT) printf 130 ;;
    TERM) printf 143 ;;
    *) fail "unknown signal in fixture" ;;
  esac
}

for signal in HUP INT TERM; do
  published_signal_case=$(make_case "post-publication-signal-$signal")
  published_signal_output=$published_signal_case/runner/output/known_hosts
  set +e
  env PATH="$fixture_bin:$original_path" \
    HOME="$published_signal_case/home" \
    RUNNER_TEMP="$published_signal_case/runner" \
    BETA_RECOVERY_BOUNDARY_LOG="$published_signal_case/boundary.log" \
    BETA_RECOVERY_REAL_SSH_KEYGEN="$real_ssh_keygen" \
    BETA_RECOVERY_REAL_LN="$(command -v ln)" \
    BETA_RECOVERY_REAL_STAT="$(command -v stat)" \
    BETA_RECOVERY_REAL_RM="$real_rm" \
    BETA_RECOVERY_SIGNAL_AFTER_PUBLICATION=1 \
    BETA_RECOVERY_PUBLICATION_SIGNAL="$signal" \
    BETA_RECOVERY_OUTPUT="$published_signal_output" \
    BETA_RECOVERY_HELPER_PID_FILE="$published_signal_case/helper.pid" \
    BETA_RECOVERY_SCAN_MODE=valid \
    BETA_RECOVERY_SCAN_LINE="$scan_line" \
    "$materializer" --host "$scan_host" --port 22 \
    --expected-fingerprint "$expected_fingerprint" \
    --output "$published_signal_output" \
    >"$published_signal_case/stdout" 2>"$published_signal_case/stderr"
  published_signal_status=$?
  set -e
  [ "$published_signal_status" -eq "$(signal_status "$signal")" ] ||
    fail "post-publication $signal returned $published_signal_status"
  [ ! -e "$published_signal_output" ] && [ ! -L "$published_signal_output" ] ||
    fail "post-publication $signal left published output"
  assert_no_staging "$published_signal_case"
  assert_no_private_output "$published_signal_case"
done

for signal in HUP INT TERM; do
  signal_failure_case=$(make_case "post-publication-signal-$signal-cleanup-failure")
  signal_failure_output=$signal_failure_case/runner/output/known_hosts
  set +e
  env PATH="$signal_failure_bin:$fixture_bin:$original_path" \
    HOME="$signal_failure_case/home" \
    RUNNER_TEMP="$signal_failure_case/runner" \
    BETA_RECOVERY_BOUNDARY_LOG="$signal_failure_case/boundary.log" \
    BETA_RECOVERY_REAL_SSH_KEYGEN="$real_ssh_keygen" \
    BETA_RECOVERY_REAL_LN="$(command -v ln)" \
    BETA_RECOVERY_REAL_STAT="$(command -v stat)" \
    BETA_RECOVERY_REAL_RM="$real_rm" \
    BETA_RECOVERY_FAIL_PUBLISHED_RM=1 \
    BETA_RECOVERY_RM_MARKER="$signal_failure_case/rm.marker" \
    BETA_RECOVERY_SIGNAL_AFTER_PUBLICATION=1 \
    BETA_RECOVERY_PUBLICATION_SIGNAL="$signal" \
    BETA_RECOVERY_OUTPUT="$signal_failure_output" \
    BETA_RECOVERY_HELPER_PID_FILE="$signal_failure_case/helper.pid" \
    BETA_RECOVERY_SCAN_MODE=valid \
    BETA_RECOVERY_SCAN_LINE="$scan_line" \
    "$materializer" --host "$scan_host" --port 22 \
    --expected-fingerprint "$expected_fingerprint" \
    --output "$signal_failure_output" \
    >"$signal_failure_case/stdout" 2>"$signal_failure_case/stderr"
  signal_failure_status=$?
  set -e
  [ "$signal_failure_status" -eq 1 ] ||
    fail "post-publication $signal cleanup failure returned $signal_failure_status"
  [ ! -e "$signal_failure_output" ] && [ ! -L "$signal_failure_output" ] ||
    fail "post-publication $signal cleanup failure left published output"
  assert_no_staging "$signal_failure_case"
  assert_no_private_output "$signal_failure_case"
done

boundary_case=$(make_case fake-ssh-scp-boundaries)
known_for_boundary=$boundary_case/runner/output/known_hosts
printf 'fake boundary input\n' >"$boundary_case/boundary-input"
env PATH="$fixture_bin:$original_path" \
  HOME="$boundary_case/home" \
  BETA_RECOVERY_BOUNDARY_LOG="$boundary_case/boundary.log" \
  ssh -F "$boundary_case/home/.ssh/config" \
  -o UserKnownHostsFile="$known_for_boundary" \
  -o GlobalKnownHostsFile=/dev/null \
  -o KnownHostsCommand=none \
  fixture-host true
env PATH="$fixture_bin:$original_path" \
  HOME="$boundary_case/home" \
  BETA_RECOVERY_BOUNDARY_LOG="$boundary_case/boundary.log" \
  scp -F "$boundary_case/home/.ssh/config" \
  -o UserKnownHostsFile="$known_for_boundary" \
  -o GlobalKnownHostsFile=/dev/null \
  -o KnownHostsCommand=none \
  "$boundary_case/boundary-input" fixture-host:/tmp/fake-boundary
grep -q '^ssh fake boundary argc=' "$boundary_case/boundary.log" ||
  fail "SSH fake boundary was not exercised"
grep -q '^scp fake boundary argc=' "$boundary_case/boundary.log" ||
  fail "SCP fake boundary was not exercised"
assert_no_private_output "$boundary_case"

workflow=$root/.github/workflows/prove-beta-backup-restore.yml
if [ -f "$workflow" ]; then
  grep -Fq 'scripts/materialize-beta-recovery-known-hosts.sh' "$workflow" ||
    fail "actual recovery workflow does not call the materializer"
  grep -Fq 'UserKnownHostsFile="$known"' "$workflow" ||
    fail "actual recovery workflow does not pin UserKnownHostsFile"
  grep -Fq 'GlobalKnownHostsFile=/dev/null' "$workflow" ||
    fail "actual recovery workflow does not isolate global known hosts"
  grep -Fq 'KnownHostsCommand=none' "$workflow" ||
    fail "actual recovery workflow does not disable KnownHostsCommand"
  grep -Fq 'StrictHostKeyChecking=yes' "$workflow" ||
    fail "actual recovery workflow does not require strict host-key checking"
  grep -Fq 'scp_opts=(-F "$config" -i "$key" -P "$PORT"' "$workflow" ||
    fail "actual recovery workflow does not pin SCP options"
  grep -Fq 'ssh_opts=(-F "$config" -i "$key" -p "$PORT"' "$workflow" ||
    fail "actual recovery workflow does not pin SSH options"
fi

consumer_root=$temporary_root/consumers
consumer_bin=$consumer_root/bin
mkdir -p "$consumer_bin"
chmod 700 "$consumer_root" "$consumer_bin"

write_wrapper "$consumer_bin/ssh-keyscan" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "helper-scan" >>"$BETA_RECOVERY_BOUNDARY_LOG"; printf "\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'printf "%s\n" "$BETA_RECOVERY_SCAN_LINE"' \
  'if [ "${BETA_RECOVERY_SIGNAL_PHASE:-}" = scan ]; then kill -"${BETA_RECOVERY_SIGNAL:?}" "$PPID"; fi'

write_wrapper "$consumer_bin/ssh-keygen" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'exec "${BETA_RECOVERY_REAL_SSH_KEYGEN:?}" "$@"'

write_wrapper "$consumer_bin/ln" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'target=${@: -1}' \
  '"${BETA_RECOVERY_REAL_LN:?}" "$@"' \
  'if [ "$(basename -- "$target")" = known_hosts ]; then' \
  '  printf "helper-success\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'fi'

write_wrapper "$consumer_bin/install" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'target=${@: -1}' \
  'case "$(basename -- "$target")" in' \
  '  ssh_config) printf "config-created\n" >>"$BETA_RECOVERY_BOUNDARY_LOG" ;;' \
  '  private_key) printf "private-key-created\n" >>"$BETA_RECOVERY_BOUNDARY_LOG" ;;' \
  'esac' \
  'exec /usr/bin/install "$@"'

write_wrapper "$consumer_bin/rm" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$*" == *"/beta-recovery-ssh."* ]] && [[ "$*" == *" -r "* || "$*" == "-r "* || "$*" == *" -r" ]]; then' \
  '  "${BETA_RECOVERY_REAL_RM:?}" "$@"' \
  '  printf "local-cleanup\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'else' \
  '  exec "${BETA_RECOVERY_REAL_RM:?}" "$@"' \
  'fi'

write_wrapper "$consumer_bin/ssh" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'args=("$@")' \
  'config= key= known=' \
  'for ((i=0; i<${#args[@]}; i++)); do' \
  '  case "${args[i]}" in' \
  '    -F) config=${args[i+1]:-} ;; -i) key=${args[i+1]:-} ;;' \
  '    -o) case "${args[i+1]:-}" in UserKnownHostsFile=*) known=${args[i+1]#UserKnownHostsFile=} ;; esac ;;' \
  '  esac' \
  'done' \
  'required=("-F" "$config" "-i" "$key" "-p" "$PORT" "-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=yes" "-o" "UserKnownHostsFile=$known" "-o" "GlobalKnownHostsFile=/dev/null" "-o" "KnownHostsCommand=none")' \
  'for ((i=0; i<${#required[@]}; i++)); do' \
  '  found=false' \
  '  for ((j=0; j<${#args[@]}; j++)); do [ "${args[j]}" = "${required[i]}" ] && found=true; done' \
  '  "$found" = true || { printf "argv-rejected ssh\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 41; }' \
  'done' \
  'destination=' \
  'for arg in "${args[@]}"; do [[ "$arg" == *"@"* ]] && destination=$arg && break; done' \
  '[ "$destination" = "$SSH_USER@$HOST" ] || { printf "argv-rejected ssh-destination\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 42; }' \
  'effective_args=()' \
  'destination_seen=false' \
  'for arg in "${args[@]}"; do' \
  '  [ "$destination_seen" = false ] || break' \
  '  effective_args+=("$arg")' \
  '  [[ "$arg" == *"@"* ]] && destination_seen=true' \
  'done' \
  '"${BETA_RECOVERY_REAL_SSH:?}" -G "${effective_args[@]}" >"$BETA_RECOVERY_EFFECTIVE_LOG" 2>"$BETA_RECOVERY_EFFECTIVE_ERR" || { printf "effective-config-failed ssh\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 43; }' \
  'grep -Fxq "user $SSH_USER" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fxq "hostname $HOST" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fxq "port $PORT" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fq "userknownhostsfile $known" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fxq "globalknownhostsfile /dev/null" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  '! grep -Eq "^(knownhostscommand|proxycommand|proxyjump|hostkeyalias) " "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fxq "canonicalizehostname false" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'printf "ssh-call\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'if [[ "${args[*]}" == *"sudo test ! -e"* ]]; then' \
  '  printf "remote-cleanup\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '  [ "${BETA_RECOVERY_REMOTE_CLEANUP_FAIL:-0}" = 1 ] && exit 44' \
  '  exit 0' \
  'fi' \
  'printf "remote-mutation\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'touch "${BETA_RECOVERY_MUTATION_SENTINEL:?}"' \
  'printf "remote-admission\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'if [ "${BETA_RECOVERY_SIGNAL_PHASE:-}" = ssh ]; then kill -"${BETA_RECOVERY_SIGNAL:?}" "$PPID"; fi'

write_wrapper "$consumer_bin/scp" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'args=("$@")' \
  'config= key= known=' \
  'for ((i=0; i<${#args[@]}; i++)); do' \
  '  case "${args[i]}" in' \
  '    -F) config=${args[i+1]:-} ;; -i) key=${args[i+1]:-} ;;' \
  '    -o) case "${args[i+1]:-}" in UserKnownHostsFile=*) known=${args[i+1]#UserKnownHostsFile=} ;; esac ;;' \
  '  esac' \
  'done' \
  'required=("-F" "$config" "-i" "$key" "-P" "$PORT" "-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=yes" "-o" "UserKnownHostsFile=$known" "-o" "GlobalKnownHostsFile=/dev/null" "-o" "KnownHostsCommand=none")' \
  'for ((i=0; i<${#required[@]}; i++)); do' \
  '  found=false' \
  '  for ((j=0; j<${#args[@]}; j++)); do [ "${args[j]}" = "${required[i]}" ] && found=true; done' \
  '  "$found" = true || { printf "argv-rejected scp\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 51; }' \
  'done' \
  'destination=' \
  'for arg in "${args[@]}"; do [[ "$arg" == *":"* ]] && destination=$arg && break; done' \
  '[ "$destination" = "$SSH_USER@$HOST:$BETA_RECOVERY_REMOTE/" ] || { printf "argv-rejected scp-destination\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 52; }' \
  '"${BETA_RECOVERY_REAL_SSH:?}" -G -F "$config" -i "$key" -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known" -o GlobalKnownHostsFile=/dev/null -o KnownHostsCommand=none "$SSH_USER@$HOST" >"$BETA_RECOVERY_EFFECTIVE_LOG" 2>"$BETA_RECOVERY_EFFECTIVE_ERR" || { printf "effective-config-failed scp\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 53; }' \
  'grep -Fxq "user $SSH_USER" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fxq "hostname $HOST" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fxq "port $PORT" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fq "userknownhostsfile $known" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fxq "globalknownhostsfile /dev/null" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  '! grep -Eq "^(knownhostscommand|proxycommand|proxyjump|hostkeyalias) " "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'grep -Fxq "canonicalizehostname false" "$BETA_RECOVERY_EFFECTIVE_LOG"' \
  'printf "scp-call\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'printf "scp-mutation\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'touch "${BETA_RECOVERY_MUTATION_SENTINEL:?}"' \
  'printf "scp-admission\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'if [ "${BETA_RECOVERY_SIGNAL_PHASE:-}" = scp ]; then kill -"${BETA_RECOVERY_SIGNAL:?}" "$PPID"; fi'

extract_consumer() {
  local marker=$1 output=$2
  awk -v marker="$marker" '
    index($0, marker) { selected=1 }
    selected && /^        run: \|$/ { running=1; next }
    running && /^      - / { exit }
    running { sub(/^          /, ""); print }
  ' "$workflow" >"$output"
  sed -i 's/\${{ inputs.source_sha }}/0123456789abcdef0123456789abcdef01234567/g' "$output"
  [ -s "$output" ] || fail "consumer body was not extracted: $marker"
}

capture_body=$consumer_root/capture.sh
pre_probe_body=$consumer_root/pre-probe.sh
post_probe_body=$consumer_root/post-probe.sh
extract_consumer '      - name: Stage and run the locked VPS capture' "$capture_body"
extract_consumer '      - name: SSH-only pre-probe' "$pre_probe_body"
extract_consumer '      - id: post_probe' "$post_probe_body"
chmod 700 "$capture_body" "$pre_probe_body" "$post_probe_body"

assert_consumer_residue_absent() {
  local case_dir=$1
  [ -z "$(find "$case_dir/runner" -maxdepth 1 -type d \
    -name 'beta-recovery-ssh.*' -print -quit)" ] ||
    fail "consumer left runner SSH material: $(basename "$case_dir")"
  [ -z "$(find "$case_dir/runner" -type f \
    \( -name private_key -o -name known_hosts -o -name ssh_config \
      -o -name '.beta-recovery-*' \) -print -quit)" ] ||
    fail "consumer left runner SSH files: $(basename "$case_dir")"
  grep -Fqx '  HostName hostile.example.invalid' "$case_dir/home/.ssh/config" ||
    fail "consumer changed hostile HOME: $(basename "$case_dir")"
  ! grep -Eiq 'BEGIN[[:space:]]+[^ ]*PRIVATE KEY|OPENSSH PRIVATE KEY' \
    "$case_dir"/boundary.log "$case_dir"/effective.log "$case_dir"/effective.err \
    2>/dev/null || fail "consumer leaked private key material"
}

assert_event_order() {
  local case_dir=$1
  shift
  awk -v expected="$*" '
    BEGIN {
      count = split(expected, events, " ")
      next_event = 1
    }
    $0 == events[next_event] {
      next_event++
    }
    END {
      exit !(next_event > count)
    }
  ' "$case_dir/boundary.log" ||
    fail "consumer event ordering was incomplete: $(basename "$case_dir")"
}

assert_signal_status() {
  local signal=$1
  case "$signal" in
    HUP) printf 129 ;;
    INT) printf 130 ;;
    TERM) printf 143 ;;
    *) fail "unknown signal in fixture" ;;
  esac
}

run_consumer_case() {
  local name=$1 body=$2 signal=$3 phase=$4 cleanup_failure=${5:-0}
  local case_dir=$consumer_root/cases/$name expected_status
  expected_status=$(assert_signal_status "$signal")
  [ "$cleanup_failure" -eq 0 ] || expected_status=1
  mkdir -p "$case_dir/runner" "$case_dir/home/.ssh"
  chmod 700 "$case_dir" "$case_dir/runner" "$case_dir/home" "$case_dir/home/.ssh"
  printf '%s\n' \
    'Host *' '  HostName hostile.example.invalid' '  Port 1' \
    '  UserKnownHostsFile /tmp/hostile-user-known-hosts' \
    '  GlobalKnownHostsFile /tmp/hostile-global-known-hosts' \
    '  KnownHostsCommand /bin/false' '  ProxyCommand /bin/false' \
    '  ProxyJump hostile-jump.invalid' '  HostKeyAlias hostile-alias' \
    '  CanonicalizeHostname yes' >"$case_dir/home/.ssh/config"
  chmod 600 "$case_dir/home/.ssh/config"
  : >"$case_dir/boundary.log"; : >"$case_dir/effective.log"; : >"$case_dir/effective.err"
  set +e
  env PATH="$consumer_bin:$original_path" HOME="$case_dir/home" \
    RUNNER_TEMP="$case_dir/runner" HOST="$scan_host" PORT=2222 \
    SSH_USER=fixture-user HOST_FINGERPRINT="$expected_fingerprint" \
    SSH_PRIVATE_KEY=fixture-private-key \
    AGE_RECIPIENT=age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m \
    PUBLIC_URL=https://api.whysoezzy.online RECOVERY_ID=recovery-fixture \
    RECOVERY_WORKFLOW=.github/workflows/prove-beta-backup-restore.yml \
    GITHUB_REPOSITORY=fixture/repository GITHUB_RUN_ID=7 GITHUB_OUTPUT="$case_dir/output" \
    BETA_RECOVERY_REAL_SSH_KEYGEN="$real_ssh_keygen" BETA_RECOVERY_REAL_SSH="$(command -v ssh)" \
    BETA_RECOVERY_REAL_LN="$(command -v ln)" BETA_RECOVERY_REAL_RM="$real_rm" \
    BETA_RECOVERY_BOUNDARY_LOG="$case_dir/boundary.log" \
    BETA_RECOVERY_EFFECTIVE_LOG="$case_dir/effective.log" \
    BETA_RECOVERY_EFFECTIVE_ERR="$case_dir/effective.err" \
    BETA_RECOVERY_SCAN_LINE="[$scan_host]:2222 $key_type $key_data" \
    BETA_RECOVERY_REMOTE=/tmp/beta-recovery-recovery-fixture \
    BETA_RECOVERY_MUTATION_SENTINEL="$case_dir/mutation-sentinel" \
    BETA_RECOVERY_SIGNAL="$signal" BETA_RECOVERY_SIGNAL_PHASE="$phase" \
    BETA_RECOVERY_REMOTE_CLEANUP_FAIL="$cleanup_failure" \
    bash "$body" >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
  [ "$status" -eq "$expected_status" ] ||
    fail "consumer $name returned $status instead of $expected_status"
  assert_consumer_residue_absent "$case_dir"
  [ -f "$case_dir/mutation-sentinel" ] ||
    fail "consumer $name did not record downstream mutation"
  [ "$(grep -c '^private-key-created$' "$case_dir/boundary.log")" -eq 1 ] ||
    fail "consumer $name did not materialize a private key"
  grep -Fxq 'config-created' "$case_dir/boundary.log" ||
    fail "consumer $name did not create an empty SSH config"
  if [ "$body" = "$capture_body" ]; then
    [ "$(grep -c '^remote-cleanup$' "$case_dir/boundary.log")" -eq 1 ] ||
      fail "capture $name did not attempt remote cleanup exactly once"
    grep -Fxq 'remote-admission' "$case_dir/boundary.log" ||
      fail "capture $name did not record remote admission"
    assert_event_order "$case_dir" helper-success private-key-created remote-admission \
      remote-cleanup local-cleanup
  else
    ! grep -q '^remote-cleanup$' "$case_dir/boundary.log" ||
      fail "probe $name attempted remote cleanup"
    assert_event_order "$case_dir" helper-success private-key-created remote-admission \
      local-cleanup
  fi
}

for signal in HUP INT TERM; do
  run_consumer_case "capture-$signal" "$capture_body" "$signal" scp
  run_consumer_case "pre-probe-$signal" "$pre_probe_body" "$signal" ssh
  run_consumer_case "post-probe-$signal" "$post_probe_body" "$signal" ssh
done
run_consumer_case capture-TERM-remote-cleanup-failure "$capture_body" TERM scp 1

for signal in HUP INT TERM; do
  pre_case=$consumer_root/cases/capture-pre-$signal
  mkdir -p "$pre_case/runner" "$pre_case/home/.ssh"
  chmod 700 "$pre_case" "$pre_case/runner" "$pre_case/home" "$pre_case/home/.ssh"
  printf '%s\n' \
    'Host *' '  HostName hostile.example.invalid' '  Port 1' \
    '  UserKnownHostsFile /tmp/hostile-user-known-hosts' \
    '  GlobalKnownHostsFile /tmp/hostile-global-known-hosts' \
    '  KnownHostsCommand /bin/false' '  ProxyCommand /bin/false' \
    '  ProxyJump hostile-jump.invalid' '  HostKeyAlias hostile-alias' \
    '  CanonicalizeHostname yes' >"$pre_case/home/.ssh/config"
  chmod 600 "$pre_case/home/.ssh/config"
  : >"$pre_case/boundary.log"; : >"$pre_case/effective.log"; : >"$pre_case/effective.err"
  set +e
  env PATH="$consumer_bin:$original_path" HOME="$pre_case/home" \
    RUNNER_TEMP="$pre_case/runner" HOST="$scan_host" PORT=2222 SSH_USER=fixture-user \
    HOST_FINGERPRINT="$expected_fingerprint" SSH_PRIVATE_KEY=fixture-private-key \
    AGE_RECIPIENT=age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m \
    PUBLIC_URL=https://api.whysoezzy.online RECOVERY_ID=recovery-fixture \
    RECOVERY_WORKFLOW=.github/workflows/prove-beta-backup-restore.yml \
    GITHUB_REPOSITORY=fixture/repository GITHUB_RUN_ID=7 GITHUB_OUTPUT="$pre_case/output" \
    BETA_RECOVERY_REAL_SSH_KEYGEN="$real_ssh_keygen" BETA_RECOVERY_REAL_SSH="$(command -v ssh)" \
    BETA_RECOVERY_REAL_LN="$(command -v ln)" BETA_RECOVERY_REAL_RM="$real_rm" \
    BETA_RECOVERY_BOUNDARY_LOG="$pre_case/boundary.log" \
    BETA_RECOVERY_EFFECTIVE_LOG="$pre_case/effective.log" BETA_RECOVERY_EFFECTIVE_ERR="$pre_case/effective.err" \
    BETA_RECOVERY_SCAN_LINE="[$scan_host]:2222 $key_type $key_data" \
    BETA_RECOVERY_REMOTE=/tmp/beta-recovery-recovery-fixture \
    BETA_RECOVERY_MUTATION_SENTINEL="$pre_case/mutation-sentinel" \
    BETA_RECOVERY_SIGNAL="$signal" BETA_RECOVERY_SIGNAL_PHASE=scan \
    bash "$capture_body" >"$pre_case/stdout" 2>"$pre_case/stderr"
  status=$?
  set -e
  expected_status=$(assert_signal_status "$signal")
  [ "$status" -eq "$expected_status" ] ||
    fail "capture pre-verification $signal returned $status"
  assert_consumer_residue_absent "$pre_case"
  [ ! -e "$pre_case/mutation-sentinel" ] ||
    fail "capture pre-verification $signal crossed the mutation sentinel"
  [ "$(grep -c '^local-cleanup$' "$pre_case/boundary.log")" -eq 1 ] ||
    fail "capture pre-verification $signal did not record local cleanup"
  ! grep -q '^helper-success$' "$pre_case/boundary.log" ||
    fail "capture pre-verification $signal reported helper success"
  ! grep -q '^private-key-created$' "$pre_case/boundary.log" ||
    fail "capture pre-verification $signal created a private key"
  ! grep -q '^ssh-call$' "$pre_case/boundary.log" ||
    fail "capture pre-verification $signal crossed SSH"
  ! grep -q '^scp-call$' "$pre_case/boundary.log" ||
    fail "capture pre-verification $signal crossed SCP"
  ! grep -q '^remote-cleanup$' "$pre_case/boundary.log" ||
    fail "capture pre-verification $signal attempted remote cleanup"
done

if env PATH="$consumer_bin:$original_path" \
  BETA_RECOVERY_BOUNDARY_LOG="$consumer_root/option-rejection.log" \
  HOST="$scan_host" PORT=2222 SSH_USER=fixture-user \
  BETA_RECOVERY_REAL_SSH="$(command -v ssh)" \
  ssh -i "$consumer_root/key" fixture-user@"$scan_host" true; then
  fail "fake SSH accepted incomplete isolation argv"
fi
if env PATH="$consumer_bin:$original_path" \
  BETA_RECOVERY_BOUNDARY_LOG="$consumer_root/option-rejection.log" \
  HOST="$scan_host" PORT=2222 SSH_USER=fixture-user \
  BETA_RECOVERY_REAL_SSH="$(command -v ssh)" \
  scp -i "$consumer_root/key" -P 2222 "$root/README.md" fixture-user@"$scan_host":/tmp/fixture; then
  fail "fake SCP accepted incomplete isolation argv"
fi
grep -Fxq 'argv-rejected ssh' "$consumer_root/option-rejection.log" ||
  fail "fake SSH did not record option rejection"
grep -Fxq 'argv-rejected scp' "$consumer_root/option-rejection.log" ||
  fail "fake SCP did not record option rejection"

echo "beta recovery SSH host-key materialization fixture passed"
