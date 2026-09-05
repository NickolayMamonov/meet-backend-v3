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
remote_probe=$root/scripts/run-beta-recovery-remote-probe.sh
[ -x "$remote_probe" ] || fail "remote probe helper is missing or not executable"
bash -n "$remote_probe"
for required in SSH_PRIVATE_KEY StrictHostKeyChecking=yes KnownHostsCommand=none \
  remote_create_attempted=true remote_cleanup_done=false marker_value= \
  "trap 'on_signal 129' HUP" "trap 'on_signal 130' INT" "trap 'on_signal 143' TERM"; do
  grep -Fq -- "$required" "$remote_probe" ||
    fail "remote probe contract is incomplete: $required"
done

for tool in awk base64 basename cat chmod cmp dd env find getconf grep head mkdir mktemp od rm seq sha256sum sleep ssh ssh-keygen stat tr wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

original_path=$PATH
real_ssh_keygen=$(command -v ssh-keygen)
real_sha256sum=$(command -v sha256sum)
real_rm=$(command -v rm)
real_od=$(command -v od)
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
  'race_output=${@: -1}' \
  'case "${BETA_RECOVERY_LN_RACE_MODE:-}" in' \
  '  directory|symlink-directory)' \
  '    : >"${BETA_RECOVERY_LN_RACE_DIR:?}/ready"' \
  '    for attempt in $(seq 1 500); do' \
  '      [ -e "$BETA_RECOVERY_LN_RACE_DIR/go" ] && break' \
  '      sleep 0.01' \
  '    done' \
  '    [ -e "$BETA_RECOVERY_LN_RACE_DIR/go" ]' \
  '    ;;' \
  'esac' \
  '"${BETA_RECOVERY_REAL_LN:?}" "$@"' \
  'if [ "${BETA_RECOVERY_LN_RACE_MODE:-}" = replacement ]; then' \
  '  "${BETA_RECOVERY_REAL_RM:?}" -f -- "$race_output"' \
  '  printf "unrelated replacement\n" >"$race_output"' \
  'fi' \
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

symlink_supported=false
symlink_probe_target=$temporary_root/symlink-probe-target
symlink_probe_link=$temporary_root/symlink-probe-link
mkdir -p "$symlink_probe_target"
if ln -s "$symlink_probe_target" "$symlink_probe_link" 2>/dev/null &&
  [ -L "$symlink_probe_link" ] &&
  ln -T --help >/dev/null 2>&1; then
  symlink_supported=true
fi
if [ -L "$symlink_probe_link" ]; then
  rm -f -- "$symlink_probe_link"
elif [ -e "$symlink_probe_link" ]; then
  rm -r -- "$symlink_probe_link"
fi

run_materializer() {
  local case_dir=$1 host=$2 port=$3 expected=$4 mode=$5 keygen_mode=${6:-delegate}
  local output_override=${7:-} ln_barrier=${8:-}
  local path_prefix=${9:-$fixture_bin}
  local rm_marker=${10:-}
  local staging_log=${11:-}
  local ln_race_mode=${12:-} ln_race_dir=${13:-}
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
    BETA_RECOVERY_LN_RACE_MODE="$ln_race_mode" \
    BETA_RECOVERY_LN_RACE_DIR="$ln_race_dir" \
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

assert_collision_preserved() {
  local case_dir=$1 output=$2
  [ -e "$output" ] || [ -L "$output" ] ||
    fail "publication collision entry disappeared: $(basename "$case_dir")"
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

run_publication_race_case() {
  local name=$1 mode=$2
  local case_dir output race_dir outside race_pid race_status
  if [ "$mode" = symlink-directory ] && [ "$symlink_supported" != true ]; then
    echo "beta recovery SSH host-key fixture: symlink-directory collision skipped (symlink capability unavailable)"
    return 0
  fi
  case_dir=$(make_case "$name")
  output=$case_dir/runner/output/known_hosts
  race_dir=$case_dir/publication-race
  mkdir -p "$race_dir"
  chmod 700 "$race_dir"
  if [ "$mode" = directory ]; then
    outside=$case_dir/outside
    mkdir -p "$outside"
    printf 'preserve directory entry\n' >"$outside/unrelated"
  elif [ "$mode" = symlink-directory ]; then
    outside=$case_dir/outside
    mkdir -p "$outside/redirect"
    printf 'preserve symlink target entry\n' >"$outside/unrelated"
  fi
  set +e
  run_materializer "$case_dir" "$scan_host" 22 "$expected_fingerprint" valid \
    delegate "$output" '' "$fixture_bin" '' '' "$mode" "$race_dir" &
  race_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$race_dir/ready" ] && break
    sleep 0.01
  done
  [ -e "$race_dir/ready" ] || {
    kill "$race_pid" 2>/dev/null || true
    wait "$race_pid" 2>/dev/null || true
    set -e
    fail "publication $mode race did not reach ln"
  }
  if [ "$mode" = directory ]; then
    mkdir "$output"
  elif [ "$mode" = symlink-directory ]; then
    ln -s "$outside/redirect" "$output"
  fi
  : >"$race_dir/go"
  wait "$race_pid"
  race_status=$?
  set -e
  [ "$race_status" -ne 0 ] ||
    fail "publication $mode race unexpectedly succeeded"
  if [ "$mode" = directory ]; then
    [ -d "$output" ] && [ ! -L "$output" ] ||
      fail "directory collision was replaced"
    [ -z "$(find "$output" -mindepth 1 -print -quit)" ] ||
      fail "directory collision received generated material"
    [ "$(<"$outside/unrelated")" = 'preserve directory entry' ] ||
      fail "directory race changed unrelated outside entry"
  else
    [ -L "$output" ] || fail "symlink-directory collision was replaced"
    [ "$(<"$outside/unrelated")" = 'preserve symlink target entry' ] ||
      fail "symlink-directory race changed unrelated outside entry"
    [ ! -e "$outside/redirect/known_hosts" ] ||
      fail "symlink-directory race wrote outside the approved path"
  fi
  assert_collision_preserved "$case_dir" "$output"
}

run_publication_race_case directory-collision directory
run_publication_race_case symlink-directory-collision symlink-directory

replacement_case=$(make_case post-link-replacement)
replacement_output=$replacement_case/runner/output/known_hosts
if run_materializer "$replacement_case" "$scan_host" 22 "$expected_fingerprint" valid \
  delegate "$replacement_output" '' "$fixture_bin" '' '' replacement \
  "$replacement_case/publication-race"; then
  fail "post-link replacement race unexpectedly succeeded"
fi
[ "$(<"$replacement_output")" = 'unrelated replacement' ] ||
  fail "post-link replacement was removed or changed"
assert_collision_preserved "$replacement_case" "$replacement_output"

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

boundary_case=$(make_case fake-ssh-boundary)
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
grep -q '^ssh fake boundary argc=' "$boundary_case/boundary.log" ||
  fail "SSH fake boundary was not exercised"
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
  grep -Fq 'ssh_opts=(-F "$config" -i "$key" -p "$PORT"' "$workflow" ||
    fail "actual recovery workflow does not pin SSH options"
fi

consumer_root=$temporary_root/consumers
consumer_bin=$consumer_root/bin
mkdir -p "$consumer_bin"
chmod 700 "$consumer_root" "$consumer_bin"
token_oracle=$consumer_root/token-oracle
"$real_od" -An -N32 -tx1 /dev/urandom | tr -d '[:space:]' >"$token_oracle"
chmod 600 "$token_oracle"
[ "$(stat -c '%a' -- "$token_oracle")" = 600 ] ||
  fail "consumer token oracle is not mode 0600"
export BETA_RECOVERY_TOKEN_ORACLE="$token_oracle"
export BETA_RECOVERY_REAL_OD="$real_od"
fixture_sudo_uid=$(id -u)
fixture_sudo_gid=$(id -g)
export SUDO_UID="$fixture_sudo_uid"
export SUDO_GID="$fixture_sudo_gid"

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

write_wrapper "$consumer_bin/sha256sum" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'target=${@: -1}' \
  'case "$(basename -- "$target")" in' \
  '  database-proof.json|media-proof.json)' \
  '    if [ "${BETA_RECOVERY_CAPTURE_SHA_TARGET:-}" = "$(basename -- "$target")" ]; then' \
  '      case "${BETA_RECOVERY_CAPTURE_SHA_MODE:-}" in' \
  '        fail) exit 43 ;;' \
  '        malformed) printf "not-a-digest  %s\n" "$target"; exit 0 ;;' \
  '        missing) "${BETA_RECOVERY_REAL_RM:?}" -f -- "$target" ;;' \
  '      esac' \
  '    fi' \
  '    ;;' \
  'esac' \
  'exec "${BETA_RECOVERY_REAL_SHA256SUM:-/usr/bin/sha256sum}" "$@"'

write_wrapper "$consumer_bin/od" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [ "${1:-}" = -An ] && [ "${2:-}" = -N32 ] && [ "${3:-}" = -tx1 ] &&' \
  '  [ "${4:-}" = /dev/urandom ] && [ -n "${BETA_RECOVERY_TOKEN_ORACLE:-}" ]; then' \
  '  token=$(<"${BETA_RECOVERY_TOKEN_ORACLE:?}")' \
  '  for ((i=0; i<${#token}; i+=2)); do printf " %s" "${token:i:2}"; done' \
  '  printf "\n"' \
  'else' \
  '  exec "${BETA_RECOVERY_REAL_OD:?}" "$@"' \
  'fi'

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

write_wrapper "$consumer_bin/chmod" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'signal_parent() {' \
  '  local signal=$1 parent_pid' \
  '  for _ in $(seq 1 500); do' \
  '    [ -s "${BETA_RECOVERY_PARENT_PID_FILE:?}" ] && break' \
  '    sleep 0.01' \
  '  done' \
  '  parent_pid=$(<"${BETA_RECOVERY_PARENT_PID_FILE:?}")' \
  '  kill -"$signal" "$parent_pid"' \
  '}' \
  'target=${@: -1}' \
  'if [[ -n "${BETA_RECOVERY_SETUP_CHMOD_MODE:-}" ]] &&' \
  '  [[ "$target" == *"/beta-recovery-ssh."* ]]; then' \
  '  printf "setup-chmod\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '  if [ "$BETA_RECOVERY_SETUP_CHMOD_MODE" = fail ]; then exit 77; fi' \
  '  signal_parent "${BETA_RECOVERY_SETUP_SIGNAL:?}"' \
  '  exit 0' \
  'fi' \
  'exec /usr/bin/chmod "$@"'

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
  'signal_parent() {' \
  '  local signal=$1 parent_pid' \
  '  for _ in $(seq 1 500); do' \
  '    [ -s "${BETA_RECOVERY_PARENT_PID_FILE:?}" ] && break' \
  '    sleep 0.01' \
  '  done' \
  '  parent_pid=$(<"${BETA_RECOVERY_PARENT_PID_FILE:?}")' \
  '  kill -"$signal" "$parent_pid"' \
  '}' \
  'scan_secret() {' \
  '  local secret=$1 label=$2 encoded hex pattern encoded_pattern hex_pattern proc_name' \
  '  [ -n "$secret" ] || return 0' \
  '  encoded=$(printf "%s" "$secret" | base64 --wrap=0)' \
  '  hex=$(printf "%s" "$secret" | od -An -v -tx1 | tr -d "[:space:]")' \
  '  pattern=$(mktemp); encoded_pattern=$(mktemp); hex_pattern=$(mktemp)' \
  '  chmod 600 "$pattern" "$encoded_pattern" "$hex_pattern"' \
  '  printf "%s\n" "$secret" >"$pattern"' \
  '  printf "%s\n" "$encoded" >"$encoded_pattern"' \
  '  printf "%s\n" "$hex" >"$hex_pattern"' \
  '  for proc_name in self parent; do' \
  '    case "$proc_name" in self) proc_file=/proc/$$/cmdline ;; parent) proc_file=/proc/$PPID/cmdline ;; esac' \
  '    [ -r "$proc_file" ] || continue' \
  '    if grep -aFq -f "$pattern" "$proc_file"; then printf "argv-scan-fail-%s-%s-raw\n" "$label" "$proc_name" >>"$BETA_RECOVERY_BOUNDARY_LOG"; rm -f "$pattern" "$encoded_pattern" "$hex_pattern"; return 1; fi' \
  '    if grep -aFq -f "$encoded_pattern" "$proc_file"; then printf "argv-scan-fail-%s-%s-base64\n" "$label" "$proc_name" >>"$BETA_RECOVERY_BOUNDARY_LOG"; rm -f "$pattern" "$encoded_pattern" "$hex_pattern"; return 1; fi' \
  '    if grep -aFq -f "$hex_pattern" "$proc_file"; then printf "argv-scan-fail-%s-%s-hex\n" "$label" "$proc_name" >>"$BETA_RECOVERY_BOUNDARY_LOG"; rm -f "$pattern" "$encoded_pattern" "$hex_pattern"; return 1; fi' \
  '  done' \
  '  rm -f "$pattern" "$encoded_pattern" "$hex_pattern"' \
  '  return 0' \
  '}' \
  'scan_entry() {' \
  '  local oracle=${BETA_RECOVERY_TOKEN_ORACLE:-}' \
  '  local token encoded hex' \
  '  [ -n "$oracle" ] || { printf "argv-scan-pass\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; return 0; }' \
  '  [ -f "$oracle" ] && [ ! -L "$oracle" ] && [ "$(stat -c "%a" "$oracle")" = 600 ] || { printf "argv-scan-fail-oracle\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; return 1; }' \
  '  token=$(<"$oracle")' \
  '  [ "${#token}" -eq 64 ] && [[ "$token" =~ ^[0-9a-f]{64}$ ]] || { printf "argv-scan-fail-token-format\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; return 1; }' \
  '  encoded=$(printf "%s" "$token" | base64 --wrap=0)' \
  '  hex=$(printf "%s" "$token" | od -An -v -tx1 | tr -d "[:space:]")' \
  '  for arg in "$@"; do' \
  '    [[ "$arg" != *"$token"* ]] || { printf "argv-scan-fail-arg-token\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; return 1; }' \
  '    [[ "$arg" != *"$encoded"* ]] || { printf "argv-scan-fail-arg-base64\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; return 1; }' \
  '    [[ "$arg" != *"$hex"* ]] || { printf "argv-scan-fail-arg-hex\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; return 1; }' \
  '  done' \
  '  scan_secret "$token" token' \
  '  for secret_name in BETA_RECOVERY_PAYLOAD_SENTINEL BETA_RECOVERY_PRIVATE_KEY_SENTINEL; do' \
  '    secret_value=${!secret_name:-}' \
  '    [ -z "$secret_value" ] || scan_secret "$secret_value" "$secret_name" || return 1' \
  '  done' \
  '  for proc_file in /proc/$$/cmdline /proc/$PPID/cmdline; do' \
  '    [ -r "$proc_file" ] || continue' \
  '    ! grep -aFq -- "$BETA_RECOVERY_TOKEN_ORACLE" "$proc_file" || true' \
  '  done' \
  '  printf "argv-scan-pass\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '}' \
  'scan_entry "$@" || { printf "argv-scan-fail\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 48; }' \
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
  'command_start=-1' \
  'for ((i=0; i<${#args[@]}; i++)); do' \
  '  if [ "${args[i]}" = "$destination" ]; then command_start=$((i + 1)); break; fi' \
  'done' \
  'frame_input=' \
  'if [ "$command_start" -ge 0 ] && [ "${args[command_start]:-}" = sudo ] &&' \
  '  [ "${args[command_start+1]:-}" = bash ] && [ "${args[command_start+2]:-}" = -c ] &&' \
  '  [ "${args[command_start+3]:-}" = '\''exec bash <(printf "%s" "$1" | base64 --decode)'\'' ] &&' \
  '  [ "${args[command_start+4]:-}" = -- ] && [ -n "${args[command_start+5]:-}" ]; then' \
  '  frame_input=$(mktemp)' \
  '  cat >"$frame_input"' \
  '  printf "framed-input-size-%s\n" "$(stat -c "%s" "$frame_input")" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '  exec <"$frame_input"' \
  'fi' \
  '"${BETA_RECOVERY_REAL_SSH:?}" -G "${effective_args[@]}" </dev/null >"$BETA_RECOVERY_EFFECTIVE_LOG" 2>"$BETA_RECOVERY_EFFECTIVE_ERR" || { printf "effective-config-failed ssh\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 43; }' \
  'grep -Fxq "user $SSH_USER" "$BETA_RECOVERY_EFFECTIVE_LOG" || { printf "effective-config-mismatch-user\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 44; }' \
  'grep -Fxq "hostname $HOST" "$BETA_RECOVERY_EFFECTIVE_LOG" || { printf "effective-config-mismatch-host\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 44; }' \
  'grep -Fxq "port $PORT" "$BETA_RECOVERY_EFFECTIVE_LOG" || { printf "effective-config-mismatch-port\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 44; }' \
  'grep -Fq "userknownhostsfile $known" "$BETA_RECOVERY_EFFECTIVE_LOG" || { printf "effective-config-mismatch-known\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 44; }' \
  'grep -Fxq "globalknownhostsfile /dev/null" "$BETA_RECOVERY_EFFECTIVE_LOG" || { printf "effective-config-mismatch-global\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 44; }' \
  '! grep -Eq "^(knownhostscommand|proxycommand|proxyjump|hostkeyalias) " "$BETA_RECOVERY_EFFECTIVE_LOG" || { printf "effective-config-unsafe\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 44; }' \
  'grep -Fxq "canonicalizehostname false" "$BETA_RECOVERY_EFFECTIVE_LOG" || { printf "effective-config-mismatch-canonicalize\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 44; }' \
  'printf "ssh-call\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'command_start=-1' \
  'for ((i=0; i<${#args[@]}; i++)); do' \
  '  if [ "${args[i]}" = "$destination" ]; then command_start=$((i + 1)); break; fi' \
  'done' \
  'if [ "$command_start" -ge 0 ] && [ "${args[command_start]:-}" = sudo ] &&' \
  '  [ "${args[command_start+1]:-}" = bash ] && [ "${args[command_start+2]:-}" = -c ] &&' \
  '  [ "${args[command_start+3]:-}" = '\''exec bash <(printf "%s" "$1" | base64 --decode)'\'' ] &&' \
  '  [ "${args[command_start+4]:-}" = -- ] && [ -n "${args[command_start+5]:-}" ]; then' \
  '  remote_state=${BETA_RECOVERY_REMOTE_STATE:?}' \
  '  static_program="$BETA_RECOVERY_REMOTE_STATE.static.$BASHPID"' \
  '  frame_dir=' \
  '  trap '\''status=$?; rm -f -- "$static_program" "$frame_input"; [ -z "$frame_dir" ] || rm -rf -- "$frame_dir"; exit "$status"'\'' EXIT' \
  '  frame_dir=$(mktemp -d)' \
  '  base64 --decode <<<"${args[command_start+5]}" >"$static_program"' \
  '  if grep -Fq "meet-backend/beta-recovery-create/v1" "$static_program"; then' \
  '    operation=create' \
  '  elif grep -Fq "meet-backend/beta-recovery-file/v1" "$static_program"; then' \
  '    operation=receive' \
  '  elif grep -Fq "meet-backend/beta-recovery-cleanup/v1" "$static_program"; then' \
  '    operation=cleanup' \
  '  else' \
  '    printf "argv-unclassified\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 49' \
  '  fi' \
  '  read_frame() {' \
  '    local prefix="$frame_dir/prefix" header_file="$frame_dir/header"' \
  '    local prefix_hex prefix_text header_hex header_length byte byte_value i' \
  '    install -m 600 /dev/null "$prefix"' \
  '    dd iflag=fullblock bs=1 count=8 status=none of="$prefix"' \
  '    [ "$(stat -c "%s" "$prefix")" -eq 8 ]' \
  '    prefix_hex=$(od -An -v -tx1 "$prefix" | tr -d "[:space:]")' \
  '    [ "${#prefix_hex}" -eq 16 ]' \
  '    for ((i=0; i<${#prefix_hex}; i+=2)); do' \
  '      byte=${prefix_hex:i:2}; byte_value=$((16#$byte))' \
  '      (( (byte_value >= 48 && byte_value <= 57) || (byte_value >= 97 && byte_value <= 102) ))' \
  '    done' \
  '    prefix_text=$(head -c 8 "$prefix")' \
  '    [[ "$prefix_text" =~ ^[0-9a-f]{8}$ ]]' \
  '    header_length=$((16#$prefix_text))' \
  '    (( header_length >= 1 && header_length <= 4096 ))' \
  '    install -m 600 /dev/null "$header_file"' \
  '    dd iflag=fullblock bs=1 count="$header_length" status=none of="$header_file"' \
  '    [ "$(stat -c "%s" "$header_file")" -eq "$header_length" ]' \
  '    header_hex=$(od -An -v -tx1 "$header_file" | tr -d "[:space:]")' \
  '    [ "${#header_hex}" -eq "$((header_length * 2))" ]' \
  '    for ((i=0; i<${#header_hex}; i+=2)); do' \
  '      byte=${header_hex:i:2}; byte_value=$((16#$byte))' \
  '      (( byte_value == 10 || (byte_value >= 32 && byte_value <= 126) ))' \
  '    done' \
  '    [[ "$header_hex" == *0a ]]' \
  '    header=$(head -c "$((header_length - 1))" "$header_file")' \
  '    IFS="|" read -r -a fields <<<"$header"' \
  '  }' \
  '  if ! read_frame; then printf "framed-read-fail\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 1; fi' \
  '  printf "framed-read-ok\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '  token=$(<"${BETA_RECOVERY_TOKEN_ORACLE:?}")' \
  '  case "$operation" in' \
  '    create)' \
  '      [ "${#fields[@]}" -eq 3 ] && [ "${fields[0]}" = meet-backend/beta-recovery-create/v1 ]' \
  '      remote=${fields[1]}; frame_token=${fields[2]}' \
  '      [[ "$frame_token" = "$token" ]] || { printf "framed-token-mismatch\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 1; }' \
  '      probe="$frame_dir/eof-probe"; install -m 600 /dev/null "$probe"' \
  '      dd iflag=fullblock bs=1 count=1 status=none of="$probe"' \
  '      probe_size=$(stat -c "%s" "$probe"); printf "framed-create-eof-size-%s\n" "$probe_size" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '      test "$probe_size" -eq 0 || { printf "framed-create-eof-fail\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 1; }' \
  '      printf "remote-create\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '      if [ -e "$remote_state" ] || [ -L "$remote_state" ]; then' \
  '        [ -d "$remote_state" ] && [ ! -L "$remote_state" ]' \
  '        [ -f "$remote_state/.meet-beta-recovery-owner" ]' \
  '        [ "$(<"$remote_state/.meet-beta-recovery-owner")" = "meet-backend/beta-recovery-owner/v1:$token" ]' \
  '      else' \
  '        mkdir -- "$remote_state"; chmod 700 -- "$remote_state"' \
  '        printf "meet-backend/beta-recovery-owner/v1:%s\n" "$token" >"$remote_state/.meet-beta-recovery-owner"' \
  '        chmod 600 -- "$remote_state/.meet-beta-recovery-owner"' \
  '      fi' \
  '      [ "${BETA_RECOVERY_CREATE_MODE:-}" != ambiguous ] || { printf "remote-create-ambiguous\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 47; }' \
  '      exit 0 ;;' \
  '    receive)' \
  '      [ "${#fields[@]}" -eq 8 ] && [ "${fields[0]}" = meet-backend/beta-recovery-file/v1 ]' \
  '      remote=${fields[1]}; remote_identity=${fields[2]}; frame_token=${fields[3]}' \
  '      name=${fields[4]}; expected_sha=${fields[5]}; expected_mode=${fields[6]}; expected_length=${fields[7]}' \
  '      [[ "$frame_token" = "$token" && "$remote_identity" =~ ^[0-9]+:[0-9]+$ ]]' \
  '      [[ "$expected_sha" =~ ^[0-9a-f]{64}$ && "$expected_length" =~ ^[0-9]+$ ]]' \
  '      case "$name" in run-beta-recovery-capture.sh|backup-production.sh|probe-test-vps-recovery-runtime.sh|production-compose.sh|beta-recovery-database-proof.sql|beta-recovery-media-proof.sh|age|age-recipient) ;; *) exit 1 ;; esac' \
  '      (( expected_length > 0 && expected_length <= 9223372036854775806 ))' \
  '      [ -d "$remote_state" ] && [ -f "$remote_state/.meet-beta-recovery-owner" ]' \
  '      [ "$(<"$remote_state/.meet-beta-recovery-owner")" = "meet-backend/beta-recovery-owner/v1:$token" ]' \
  '      owner_uid=${SUDO_UID:-$(id -u)}; owner_gid=${SUDO_GID:-$(id -g)}' \
  '      [ "$remote_identity" = 1:1 ] || [ "$(stat -Lc "%d:%i" "$remote_state")" = "$remote_identity" ]' \
  '      target="$remote_state/$name"; [ ! -e "$target" ] && [ ! -L "$target" ]' \
  '      payload="$frame_dir/payload"; install -m 600 /dev/null "$payload"' \
  '      dd iflag=fullblock bs=1 count="$((expected_length + 1))" status=none of="$payload"' \
  '      [ "$(stat -c "%s" "$payload")" -eq "$expected_length" ]' \
  '      [ "$(sha256sum "$payload" | awk "{print \$1}")" = "$expected_sha" ]' \
  '      chmod "$expected_mode" -- "$payload"; temp_identity=$(stat -Lc "%d:%i" "$payload")' \
  '      ln -T -- "$payload" "$target"; rm -f -- "$payload"' \
  '      [ -f "$target" ] && [ ! -L "$target" ] && [ "$(stat -c "%h" "$target")" -eq 1 ]' \
  '      [ "$(stat -c "%a:%u:%g:%h" "$target")" = "$expected_mode:$owner_uid:$owner_gid:1" ]' \
  '      printf "remote-receive\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '      if [ "${BETA_RECOVERY_REPLACE_AFTER_LINK:-0}" = 1 ]; then' \
  '        replacement="$frame_dir/replacement"; cp -- "$target" "$replacement"; chmod "$expected_mode" -- "$replacement"; rm -f -- "$target"; mv -T -- "$replacement" "$target"' \
  '        printf "remote staging publication identity changed\n" >&2; exit 1' \
  '      fi' \
  '      [ "$(stat -Lc "%d:%i" "$target")" = "$temp_identity" ] || { printf "remote staging publication identity changed\n" >&2; exit 1; }' \
  '      if [ "${BETA_RECOVERY_SIGNAL_PHASE:-}" = ssh ]; then signal_parent "${BETA_RECOVERY_SIGNAL:?}"; fi' \
  '      exit 0 ;;' \
  '    cleanup)' \
  '      [ "${#fields[@]}" -eq 3 ] && [ "${fields[0]}" = meet-backend/beta-recovery-cleanup/v1 ]' \
  '      remote=${fields[1]}; frame_token=${fields[2]}; [[ "$frame_token" = "$token" ]]' \
  '      probe="$frame_dir/eof-probe"; install -m 600 /dev/null "$probe"' \
  '      dd iflag=fullblock bs=1 count=1 status=none of="$probe"' \
  '      test ! -s "$probe"' \
  '      printf "remote-cleanup\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '      [ "${BETA_RECOVERY_REMOTE_CLEANUP_FAIL:-0}" = 1 ] && exit 44' \
  '      [ -d "$remote_state" ] && [ ! -L "$remote_state" ] || exit 0' \
  '      [ -f "$remote_state/.meet-beta-recovery-owner" ] && [ "$(<"$remote_state/.meet-beta-recovery-owner")" = "meet-backend/beta-recovery-owner/v1:$token" ] || exit 1' \
  '      rm -r -- "$remote_state"; exit 0 ;;' \
  '  esac' \
  'fi' \
  'if [ "${BETA_RECOVERY_CAPTURE_FIXTURE:-0}" = 1 ] &&' \
  '  [ "$command_start" -ge 0 ] && [[ "${args[command_start]:-}" == "sudo cat "* ]]; then' \
  '  command_text=${args[command_start]}' \
  '  case "$command_text" in' \
  '    *postgres.dump.age*) file=postgres.dump.age ;;' \
  '    *uploads.tar.gz.age*) file=uploads.tar.gz.age ;;' \
  '    *capture-runtime.json*) file=capture-runtime.json ;;' \
  '    *database-proof.json*) file=database-proof.json ;;' \
  '    *media-proof.json*) file=media-proof.json ;;' \
  '    *capture-result.json*) file=capture-result.json ;;' \
  '    *) printf "unexpected remote read\n" >&2; exit 54 ;;' \
  '  esac' \
  '  if [ "${BETA_RECOVERY_CAPTURE_READ_FAIL:-}" = "$file" ]; then exit 55; fi' \
  '  printf "remote-read-%s\n" "$file" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '  cat "$BETA_RECOVERY_CAPTURE_SOURCE_DIR/$file"' \
  '  exit 0' \
  'fi' \
  'if [ "$command_start" -ge 0 ] && [ "${args[command_start]:-}" = sudo ] &&' \
  '  [ "${args[command_start+1]:-}" = bash ] && [ "${args[command_start+2]:-}" = -s ] &&' \
  '  [ "${args[command_start+3]:-}" = -- ]; then' \
  '  body=$(cat)' \
  '  if [ "${BETA_RECOVERY_CAPTURE_FIXTURE:-0}" = 1 ] &&' \
  '    printf "%s" "$body" | grep -Fq "base64 --decode"; then' \
  '    printf "remote-receive\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 0' \
  '  elif [ "${BETA_RECOVERY_CAPTURE_FIXTURE:-0}" = 1 ] &&' \
  '    printf "%s" "$body" | grep -Fq '\''stat -c '\''"'\''%d:%i'\''"'\'' -- "$remote"'\''; then' \
  '    printf "1:1\n"; exit 0' \
  '  elif printf "%s" "$body" | grep -Fq "created_identity="; then' \
  '    printf "created\n1:1\n"; exit 0' \
  '  elif printf "%s" "$body" | grep -Fq "probe_payload=\${13}"; then' \
  '    printf "{\"schema\":\"meet-backend/test-vps-recovery-runtime/v1\",\"healthy\":true,\"runtime\":{\"imageId\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"configHash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"health\":\"healthy\",\"uploadsMount\":\"volume\"},\"https\":{\"meetingsStatus\":\"200\",\"actuatorStatus\":\"404\",\"httpRedirectHttps\":true,\"meetingsJson\":true}}\n"; exit 0' \
  '  elif printf "%s" "$body" | grep -Fq "find \"/proc/\$\$/fd/\$remote_fd\""; then' \
  '    printf "remote-cleanup\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 0' \
  '  fi' \
  '  token_arg=${args[command_start+5]:-}' \
  '  remote_state=${BETA_RECOVERY_REMOTE_STATE:?}' \
  '  marker="$remote_state/.meet-beta-recovery-owner"' \
  '  if printf "%s" "$body" | grep -Fq "owner_uid=\${SUDO_UID"; then' \
  '    printf "remote-create\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '    if [ -e "$remote_state" ] || [ -L "$remote_state" ]; then' \
  '      [ -d "$remote_state" ] && [ ! -L "$remote_state" ] || exit 46' \
  '      [ -f "$marker" ] && [ ! -L "$marker" ] || exit 46' \
  '      [ "$(<"$marker")" = "meet-backend/beta-recovery-owner/v1:$token_arg" ] || exit 46' \
  '    else' \
  '      mkdir "$remote_state"; chmod 700 "$remote_state"' \
  '      printf "meet-backend/beta-recovery-owner/v1:%s\n" "$token_arg" >"$marker"; chmod 600 "$marker"' \
  '    fi' \
  '    if [ "${BETA_RECOVERY_CREATE_MODE:-}" = ambiguous ]; then' \
  '      printf "remote-create-ambiguous\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"; exit 47' \
  '    fi' \
  '    exit 0' \
  '  elif printf "%s" "$body" | grep -Fq "cmp -- \"\$expected\" \"\$marker\""; then' \
  '    printf "remote-cleanup\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '    [ "${BETA_RECOVERY_REMOTE_CLEANUP_FAIL:-0}" = 1 ] && exit 44' \
  '    [ -d "$remote_state" ] && [ ! -L "$remote_state" ] || exit 0' \
  '    [ "$(stat -c "%a" "$remote_state")" = 700 ] || exit 45' \
  '    [ -f "$marker" ] && [ ! -L "$marker" ] || exit 45' \
  '    [ "$(stat -c "%a:%h" "$marker")" = 600:1 ] || exit 45' \
  '    [ "$(<"$marker")" = "meet-backend/beta-recovery-owner/v1:$token_arg" ] || exit 45' \
  '    rm -r "$remote_state"; exit $?' \
  '  elif [ "${BETA_RECOVERY_CAPTURE_FIXTURE:-0}" = 1 ] &&' \
  '    printf "%s" "$body" | grep -Fq '\''bash "$remote/run-beta-recovery-capture.sh"'\''; then' \
  '    printf "remote-capture\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  '    exit 0' \
  '  fi' \
  'fi' \
  'printf "remote-mutation\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'touch "${BETA_RECOVERY_MUTATION_SENTINEL:?}"' \
  'printf "remote-admission\n" >>"$BETA_RECOVERY_BOUNDARY_LOG"' \
  'if [ "${BETA_RECOVERY_SIGNAL_PHASE:-}" = ssh ]; then signal_parent "${BETA_RECOVERY_SIGNAL:?}"; fi'

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

semantic_workspace=$consumer_root/semantic-workspace
mkdir -p "$semantic_workspace/scripts"
tooling_files=(
  scripts/authorize-beta-recovery.sh
  scripts/backup-production.sh
  scripts/beta-recovery-database-proof.sql
  scripts/beta-recovery-media-proof.sh
  scripts/build-beta-recovery-evidence.sh
  scripts/install-beta-recovery-age.sh
  scripts/materialize-beta-recovery-known-hosts.sh
  scripts/run-beta-recovery-remote-probe.sh
  scripts/production-compose.sh
  scripts/probe-test-vps-recovery-runtime.sh
  scripts/run-beta-recovery-capture.sh
  scripts/run-beta-recovery-restore.sh
  scripts/admit-beta-recovery-artifact.sh
  scripts/validate-beta-recovery-artifact-retention.sh
)
for tooling_file in "${tooling_files[@]}"; do
  cp -- "$root/$tooling_file" "$semantic_workspace/$tooling_file"
done
chmod 700 "$semantic_workspace/scripts/materialize-beta-recovery-known-hosts.sh" \
  "$semantic_workspace/scripts/validate-beta-recovery-artifact-retention.sh"
fake_age=$semantic_workspace/fake-age
write_wrapper "$fake_age" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[ "${1:-}" = --version ] && printf "v1.3.1\n" || exit 0'
write_wrapper "$semantic_workspace/scripts/install-beta-recovery-age.sh" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'install_dir=$1' \
  'mkdir -p "$install_dir"' \
  'cp -- "${BETA_RECOVERY_FAKE_AGE:?}" "$install_dir/age"' \
  'chmod 755 "$install_dir/age"'
write_wrapper "$semantic_workspace/scripts/build-beta-recovery-evidence.sh" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'kind=${1:?}' \
  'printf "evidence-%s\n" "$kind" >>"${BETA_RECOVERY_BOUNDARY_LOG:?}"' \
  '[ -z "${BETA_RECOVERY_MUTATION_SENTINEL:-}" ] || : >"$BETA_RECOVERY_MUTATION_SENTINEL"' \
  'if [ "$kind" = manifest ]; then' \
  '  output=' \
  '  args=("$@")' \
  '  for ((i=0; i<${#args[@]}; i++)); do' \
  '    [ "${args[i]}" = --output ] && output=${args[i+1]:-}' \
  '  done' \
  '  [ -n "$output" ] || exit 61' \
  '  printf "{}\n" >"$output"' \
  'fi'

assert_consumer_residue_absent() {
  local case_dir=$1
  local ssh_calls scan_passes
  ssh_calls=$(grep -c '^ssh-call$' "$case_dir/boundary.log" 2>/dev/null || true)
  scan_passes=$(grep -c '^argv-scan-pass$' "$case_dir/boundary.log" 2>/dev/null || true)
  if [ "$ssh_calls" -ne "$scan_passes" ]; then
    printf 'consumer %s residue boundary events:\n' "$(basename "$case_dir")" >&2
    grep -E '^(ssh-call|argv-scan|argv-rejected|effective-|framed-|remote-|local-|helper-|private-key|config-created)' \
      "$case_dir/boundary.log" >&2 || true
    fail "consumer SSH scan count mismatch: $(basename "$case_dir")"
  fi
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

run_consumer_setup_case() {
  local name=$1 body=$2 mode=$3 signal=${4:-}
  local case_dir=$consumer_root/cases/$name expected_status
  if [ "$mode" = fail ]; then
    expected_status=77
  else
    expected_status=$(assert_signal_status "$signal")
  fi
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
    RUNNER_TEMP="$case_dir/runner" PATH_ON_HOST=/fixture/release-root \
    HOST="$scan_host" PORT=2222 \
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
    BETA_RECOVERY_SETUP_CHMOD_MODE="$mode" BETA_RECOVERY_SETUP_SIGNAL="$signal" \
    BETA_RECOVERY_PARENT_PID_FILE="$case_dir/body.pid" \
    bash -c 'trap - HUP INT TERM; printf "%s\n" "$BASHPID" >"$BETA_RECOVERY_PARENT_PID_FILE"; exec bash "$1"' \
    _ "$body" >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
  if [ "$status" -ne "$expected_status" ]; then
    [ "$mode" = fail ] && [ "$status" -eq 1 ] ||
      fail "consumer setup $name returned $status instead of $expected_status"
  fi
  assert_consumer_residue_absent "$case_dir"
  [ ! -e "$case_dir/mutation-sentinel" ] ||
    fail "consumer setup $name crossed the mutation sentinel"
  ! grep -q '^helper-success$' "$case_dir/boundary.log" ||
    fail "consumer setup $name reached helper publication"
  ! grep -q '^private-key-created$' "$case_dir/boundary.log" ||
    fail "consumer setup $name created a private key"
  ! grep -q '^ssh-call$' "$case_dir/boundary.log" ||
    fail "consumer setup $name crossed SSH"
  ! grep -q '^remote-cleanup$' "$case_dir/boundary.log" ||
    fail "consumer setup $name attempted remote cleanup"
  [ "$(grep -c '^local-cleanup$' "$case_dir/boundary.log")" -eq 1 ] ||
    fail "consumer setup $name did not record local cleanup"
}

body=$capture_body
run_consumer_setup_case capture-setup-chmod-failure "$body" fail
for signal in HUP INT TERM; do
  run_consumer_setup_case "capture-setup-$signal" "$body" signal "$signal"
done

run_consumer_case() {
  local name=$1 body=$2 signal=$3 phase=$4 cleanup_failure=${5:-0} scenario=${6:-normal}
  local case_dir=$consumer_root/cases/$name expected_status remote_state
  local collision_root_metadata collision_marker_metadata collision_root_digest collision_marker_digest
  case "$scenario" in
    normal) expected_status=$(assert_signal_status "$signal") ;;
    ambiguous) expected_status=47 ;;
    collision-absent|collision-mismatch) expected_status=1 ;;
    *) fail "unknown consumer marker scenario: $scenario" ;;
  esac
  [ "$cleanup_failure" -eq 0 ] || expected_status=1
  mkdir -p "$case_dir/runner" "$case_dir/home/.ssh"
  chmod 700 "$case_dir" "$case_dir/runner" "$case_dir/home" "$case_dir/home/.ssh"
  remote_state=$case_dir/remote-root
  case "$scenario" in
    normal|ambiguous) ;;
    collision-absent)
      mkdir "$remote_state"; chmod 700 "$remote_state"
      printf collision >"$remote_state/sentinel"
      collision_root_metadata=$(stat -c '%a:%u:%g:%h' "$remote_state")
      collision_root_digest=$(sha256sum "$remote_state/sentinel") ;;
    collision-mismatch)
      mkdir "$remote_state"; chmod 700 "$remote_state"
      printf 'meet-backend/beta-recovery-owner/v1:%064d\n' 0 \
        >"$remote_state/.meet-beta-recovery-owner"
      chmod 600 "$remote_state/.meet-beta-recovery-owner"
      collision_root_metadata=$(stat -c '%a:%u:%g:%h' "$remote_state")
      collision_marker_metadata=$(stat -c '%a:%u:%g:%h' \
        "$remote_state/.meet-beta-recovery-owner")
      collision_marker_digest=$(sha256sum "$remote_state/.meet-beta-recovery-owner") ;;
    *) fail "unknown consumer marker scenario: $scenario" ;;
  esac
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
    RUNNER_TEMP="$case_dir/runner" PATH_ON_HOST=/fixture/release-root \
    HOST="$scan_host" PORT=2222 \
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
    BETA_RECOVERY_REMOTE_STATE="$remote_state" \
    BETA_RECOVERY_CREATE_MODE="$scenario" \
    BETA_RECOVERY_MUTATION_SENTINEL="$case_dir/mutation-sentinel" \
    BETA_RECOVERY_SIGNAL="$signal" BETA_RECOVERY_SIGNAL_PHASE="$phase" \
    BETA_RECOVERY_REMOTE_CLEANUP_FAIL="$cleanup_failure" \
    BETA_RECOVERY_PARENT_PID_FILE="$case_dir/body.pid" \
    bash -c 'trap - HUP INT TERM; printf "%s\n" "$BASHPID" >"$BETA_RECOVERY_PARENT_PID_FILE"; exec bash "$1"' \
    _ "$body" >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
  if [ "$status" -ne "$expected_status" ]; then
    printf 'consumer %s boundary events:\n' "$name" >&2
    grep -E '^(ssh-call|argv-scan|argv-rejected|effective-|remote-|local-|helper-|private-key|config-created|ssh-keyscan args|ssh-keygen args)' \
      "$case_dir/boundary.log" >&2 || true
    fail "consumer $name returned $status instead of $expected_status"
  fi
  assert_consumer_residue_absent "$case_dir"
  [ "$(grep -c '^private-key-created$' "$case_dir/boundary.log")" -eq 1 ] ||
    fail "consumer $name did not materialize a private key"
  grep -Fxq 'config-created' "$case_dir/boundary.log" ||
    fail "consumer $name did not create an empty SSH config"
  if [ "$scenario" != normal ]; then
    [ ! -e "$case_dir/mutation-sentinel" ] ||
      fail "marker case $name crossed downstream mutation"
    ! grep -q '^remote-admission$' "$case_dir/boundary.log" ||
      fail "marker case $name crossed remote admission"
    [ "$(grep -c '^remote-cleanup$' "$case_dir/boundary.log")" -eq 1 ] ||
      fail "marker case $name did not attempt remote cleanup exactly once"
    assert_event_order "$case_dir" helper-success private-key-created remote-create \
      remote-cleanup local-cleanup
    case "$scenario" in
      ambiguous)
        [ ! -e "$remote_state" ] || fail "ambiguous marker root survived cleanup" ;;
      collision-absent)
        [ -e "$remote_state/sentinel" ] || fail "absent-marker collision changed"
        [ ! -e "$remote_state/.meet-beta-recovery-owner" ] ||
          fail "absent-marker collision was adopted"
        [ "$collision_root_metadata" = "$(stat -c '%a:%u:%g:%h' "$remote_state")" ] ||
          fail "absent-marker collision metadata changed"
        [ "$collision_root_digest" = "$(sha256sum "$remote_state/sentinel")" ] ||
          fail "absent-marker collision bytes changed" ;;
      collision-mismatch)
        [ -f "$remote_state/.meet-beta-recovery-owner" ] ||
          fail "mismatched-marker collision disappeared"
        grep -Fq \
          'meet-backend/beta-recovery-owner/v1:0000000000000000000000000000000000000000000000000000000000000000' \
          "$remote_state/.meet-beta-recovery-owner" ||
          fail "mismatched-marker collision changed"
        [ "$collision_root_metadata" = "$(stat -c '%a:%u:%g:%h' "$remote_state")" ] ||
          fail "mismatched-marker root metadata changed"
        [ "$collision_marker_metadata" = "$(stat -c '%a:%u:%g:%h' \
          "$remote_state/.meet-beta-recovery-owner")" ] ||
          fail "mismatched-marker metadata changed"
        [ "$collision_marker_digest" = "$(sha256sum \
          "$remote_state/.meet-beta-recovery-owner")" ] ||
          fail "mismatched-marker bytes changed" ;;
    esac
    return
  fi
  [ -f "$case_dir/mutation-sentinel" ] ||
    fail "consumer $name did not record downstream mutation"
  if [ "$body" = "$capture_body" ]; then
    [ "$(grep -c '^remote-create$' "$case_dir/boundary.log")" -eq 1 ] ||
      fail "capture $name did not attempt marker-authenticated creation exactly once"
    [ "$(grep -c '^remote-cleanup$' "$case_dir/boundary.log")" -eq 1 ] ||
      fail "capture $name did not attempt remote cleanup exactly once"
    assert_event_order "$case_dir" helper-success private-key-created remote-create \
      remote-cleanup local-cleanup
  else
    ! grep -q '^remote-cleanup$' "$case_dir/boundary.log" ||
      fail "probe $name attempted remote cleanup"
    assert_event_order "$case_dir" helper-success private-key-created remote-admission \
      local-cleanup
  fi
}

for signal in HUP INT TERM; do
  run_consumer_case "capture-$signal" "$capture_body" "$signal" ssh
done
run_consumer_case capture-TERM-remote-cleanup-failure "$capture_body" TERM ssh 1
run_consumer_case capture-ambiguous-create "$capture_body" HUP ssh 0 ambiguous
run_consumer_case capture-collision-absent-marker "$capture_body" HUP ssh 0 collision-absent
run_consumer_case capture-collision-mismatched-marker "$capture_body" HUP ssh 0 collision-mismatch

assert_framed_runtime_contract() {
  local workflow_file=$root/.github/workflows/prove-beta-backup-restore.yml
  grep -Fq 'create_remote_cmd=(sudo bash -c' "$workflow_file" ||
    fail "static create launch contract is missing"
  grep -Fq 'receive_remote_cmd=(sudo bash -c' "$workflow_file" ||
    fail "static receive launch contract is missing"
  grep -Fq 'cleanup_remote_cmd=(sudo bash -c' "$workflow_file" ||
    fail "static cleanup launch contract is missing"
  grep -Fq 'frame_stdin "$create_header"' "$workflow_file" ||
    fail "framed create invocation is missing"
  grep -Fq 'frame_stdin "$receive_header"' "$workflow_file" ||
    fail "framed receive invocation is missing"
  grep -Fq 'frame_stdin "$cleanup_header"' "$workflow_file" ||
    fail "framed cleanup invocation is missing"
  grep -Fq 'remote staging publication identity changed' "$workflow_file" ||
    fail "publication identity diagnostic contract is missing"
  grep -Fq 'scan_entry "$@"' "${BASH_SOURCE[0]}" ||
    fail "fake SSH entry scan contract is missing"
}

assert_framed_runtime_contract

direct_frame_case() {
  local name=$1 operation=$2 header=$3 suffix_hex=${4:-} payload_file=${5:-}
  local remote_root=${6:-}
  local case_dir=$consumer_root/cases/direct-frame-$name
  local config=$case_dir/home/.ssh/config key=$case_dir/key
  local program prefix frame_file suffix_file
  mkdir -p "$case_dir/home/.ssh" "$case_dir/runner"
  chmod 700 "$case_dir" "$case_dir/home" "$case_dir/home/.ssh" "$case_dir/runner"
  printf '%s\n' \
    'Host *' "  HostName $scan_host" '  Port 1' \
    '  CanonicalizeHostname no' \
    'Host hostile-preservation' \
    '  HostName hostile.example.invalid' >"$config"
  chmod 600 "$config"
  : >"$key"
  chmod 600 "$key"
  case "$operation" in
    create) program='meet-backend/beta-recovery-create/v1' ;;
    receive) program='meet-backend/beta-recovery-file/v1' ;;
    cleanup) program='meet-backend/beta-recovery-cleanup/v1' ;;
    *) fail "unknown direct frame operation: $operation" ;;
  esac
  frame_file=$case_dir/frame
  printf '%s' "$header" >"$frame_file"
  prefix=$(printf '%08x' "$(stat -c '%s' "$frame_file")")
  suffix_file=$case_dir/suffix
  if [ -n "$suffix_hex" ]; then
    printf '%b' "\\x$suffix_hex" >"$suffix_file"
  else
    : >"$suffix_file"
  fi
  printf 'direct-input-suffix-size=%s\n' "$(stat -c '%s' "$suffix_file")" >>"$case_dir/boundary.log"
  printf '%s' "$program" | base64 --wrap=0 >"$case_dir/program.b64"
  frame_stdin() {
    printf '%s' "$prefix"
    cat "$frame_file"
    cat "$suffix_file"
    [ -z "$payload_file" ] || cat "$payload_file"
  }
  set +e
  frame_stdin | env \
    PATH="$consumer_bin:$original_path" HOME="$case_dir/home" \
    HOST="$scan_host" PORT=2222 SSH_USER=fixture-user \
    BETA_RECOVERY_REAL_SSH="$(command -v ssh)" \
    BETA_RECOVERY_REAL_RM="$real_rm" \
    BETA_RECOVERY_TOKEN_ORACLE="$token_oracle" \
    BETA_RECOVERY_BOUNDARY_LOG="$case_dir/boundary.log" \
    BETA_RECOVERY_EFFECTIVE_LOG="$case_dir/effective.log" \
    BETA_RECOVERY_EFFECTIVE_ERR="$case_dir/effective.err" \
    BETA_RECOVERY_REMOTE_STATE="${remote_root:-$case_dir/remote-root}" \
    ssh -F "$config" -i "$key" -p 2222 \
    -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$case_dir/known_hosts" \
    -o GlobalKnownHostsFile=/dev/null -o KnownHostsCommand=none \
    fixture-user@"$scan_host" \
    sudo bash -c 'exec bash <(printf "%s" "$1" | base64 --decode)' -- \
    "$(<"$case_dir/program.b64")" >"$case_dir/stdout" 2>"$case_dir/stderr"
  direct_status=$?
  set -e
  rm -f -- "$frame_file" "$suffix_file" "$case_dir/program.b64"
  assert_consumer_residue_absent "$case_dir"
  [ "$(grep -c '^ssh-call$' "$case_dir/boundary.log")" -eq 1 ] ||
    fail "direct frame $name did not make one SSH call"
  printf '%s\n' "$direct_status" >"$case_dir/status"
}

direct_token=$(<"$token_oracle")
direct_remote=/tmp/beta-recovery-direct-frame
for trailing_case in printable:20 nul:00 control:01 nonascii:c3; do
  direct_case_name="create-trailing-${trailing_case%%:*}"
  suffix=${trailing_case##*:}
  printf -v direct_header 'meet-backend/beta-recovery-create/v1|%s|%s\n' \
    "$direct_remote" "$direct_token"
  direct_frame_case "$direct_case_name" create "$direct_header" "$suffix"
  if [ "$(<"$consumer_root/cases/direct-frame-$direct_case_name/status")" -eq 0 ]; then
    printf 'consumer %s direct-frame events:\n' "$direct_case_name" >&2
    grep -E '^(direct-input|ssh-call|argv-scan|argv-rejected|effective-|framed-|remote-|local-|helper-)' \
      "$consumer_root/cases/direct-frame-$direct_case_name/boundary.log" >&2 || true
    fail "$direct_case_name unexpectedly succeeded"
  fi
  [ ! -e "$consumer_root/cases/direct-frame-$direct_case_name/remote-root" ] ||
    fail "$direct_case_name mutated the root"
  printf -v direct_cleanup_header 'meet-backend/beta-recovery-cleanup/v1|%s|%s\n' \
    "$direct_remote" "$direct_token"
  direct_frame_case "$direct_case_name-cleanup" cleanup \
    "$direct_cleanup_header" '' '' \
    "$consumer_root/cases/direct-frame-$direct_case_name/remote-root"
  [ "$(<"$consumer_root/cases/direct-frame-$direct_case_name-cleanup/status")" -eq 0 ] ||
    fail "$direct_case_name cleanup did not accept absent root"
done

printf -v direct_create_header 'meet-backend/beta-recovery-create/v1|%s|%s\n' \
  "$direct_remote" "$direct_token"
direct_frame_case create-canonical create "$direct_create_header"
direct_owned_root=$consumer_root/cases/direct-frame-create-canonical/remote-root
if [ ! -d "$direct_owned_root" ]; then
  printf 'consumer create-canonical direct-frame events:\n' >&2
  grep -E '^(direct-input|framed-input|ssh-call|argv-scan|argv-rejected|effective-|framed-|remote-|local-|helper-)' \
    "$consumer_root/cases/direct-frame-create-canonical/boundary.log" >&2 || true
  fail "canonical direct create did not create root"
fi
printf -v direct_cleanup_header 'meet-backend/beta-recovery-cleanup/v1|%s|%s\n' \
  "$direct_remote" "$direct_token"
direct_frame_case cleanup-canonical cleanup "$direct_cleanup_header" '' '' \
  "$direct_owned_root"
[ ! -e "$direct_owned_root" ] ||
  fail "canonical direct cleanup did not remove owned root"

for trailing_case in printable:20 nul:00 control:01 nonascii:c3; do
  direct_case_name="cleanup-trailing-${trailing_case%%:*}"
  suffix=${trailing_case##*:}
  cleanup_case_root=$consumer_root/cases/direct-frame-$direct_case_name
  mkdir -p "$cleanup_case_root/remote-root"
  chmod 700 "$cleanup_case_root/remote-root"
  printf 'meet-backend/beta-recovery-owner/v1:%s\n' "$direct_token" \
    >"$cleanup_case_root/remote-root/.meet-beta-recovery-owner"
  chmod 600 "$cleanup_case_root/remote-root/.meet-beta-recovery-owner"
  printf -v cleanup_header 'meet-backend/beta-recovery-cleanup/v1|%s|%s\n' \
    "$direct_remote" "$direct_token"
  direct_frame_case "$direct_case_name" cleanup \
    "$cleanup_header" "$suffix"
  [ "$(<"$cleanup_case_root/status")" -ne 0 ] ||
    fail "$direct_case_name unexpectedly succeeded"
  [ -d "$cleanup_case_root/remote-root" ] &&
    [ -f "$cleanup_case_root/remote-root/.meet-beta-recovery-owner" ] ||
    fail "$direct_case_name removed owned state"
  rm -r -- "$cleanup_case_root/remote-root"
done

binary_case=$consumer_root/cases/direct-frame-binary-payload
mkdir -p "$binary_case/source"
printf 'A\0B\n\303\251\001\177Z' >"$binary_case/source/payload"
binary_length=$(stat -c '%s' "$binary_case/source/payload")
binary_sha=$(sha256sum "$binary_case/source/payload" | awk '{print $1}')
binary_remote=$binary_case/remote-root
mkdir -p "$binary_remote"
chmod 700 "$binary_remote"
printf 'meet-backend/beta-recovery-owner/v1:%s\n' "$direct_token" \
  >"$binary_remote/.meet-beta-recovery-owner"
chmod 600 "$binary_remote/.meet-beta-recovery-owner"
binary_identity=$(stat -Lc '%d:%i' "$binary_remote")
printf -v binary_header \
  'meet-backend/beta-recovery-file/v1|%s|%s|%s|age|%s|600|%s\n' \
  "$direct_remote" "$binary_identity" "$direct_token" "$binary_sha" "$binary_length"
direct_frame_case binary-payload receive "$binary_header" '' \
  "$binary_case/source/payload"
binary_case_root=$consumer_root/cases/direct-frame-binary-payload
if [ "$(<"$binary_case/status")" -ne 0 ]; then
  printf 'consumer binary-payload direct-frame events (status=%s):\n' \
    "$(<"$binary_case/status")" >&2
  grep -E '^(direct-input|framed-input|ssh-call|argv-scan|argv-rejected|effective-|framed-|remote-|local-|helper-)' \
    "$binary_case/boundary.log" >&2 || true
  fail "binary payload receive failed"
fi
[ -f "$binary_case_root/remote-root/age" ] ||
  fail "binary payload target missing"
cmp "$binary_case/source/payload" "$binary_case_root/remote-root/age" ||
  fail "binary payload bytes changed"
rm -r -- "$binary_case_root/remote-root"

large_case=$consumer_root/cases/direct-frame-arg-max-payload
mkdir -p "$large_case/source" "$large_case/remote-root"
chmod 700 "$large_case/remote-root"
printf 'meet-backend/beta-recovery-owner/v1:%s\n' "$direct_token" \
  >"$large_case/remote-root/.meet-beta-recovery-owner"
chmod 600 "$large_case/remote-root/.meet-beta-recovery-owner"
large_payload=$large_case/source/age
arg_max=$(getconf ARG_MAX)
dd if=/dev/zero of="$large_payload" bs=1 count="$((arg_max + 1))" status=none
large_length=$(stat -c '%s' "$large_payload")
large_sha=$(sha256sum "$large_payload" | awk '{print $1}')
large_identity=$(stat -Lc '%d:%i' "$large_case/remote-root")
printf -v large_header \
  'meet-backend/beta-recovery-file/v1|%s|%s|%s|age|%s|600|%s\n' \
  "$direct_remote" "$large_identity" "$direct_token" "$large_sha" "$large_length"
direct_frame_case arg-max-payload receive "$large_header" '' "$large_payload"
[ "$(<"$large_case/status")" -eq 0 ] ||
  fail "ARG_MAX-sized payload receive failed"
cmp "$large_payload" "$large_case/remote-root/age" ||
  fail "ARG_MAX-sized payload bytes changed"
rm -r -- "$large_case/remote-root"

run_capture_proof_case() {
  local name=$1 scenario=$2
  local case_dir=$consumer_root/cases/$name remote_state
  local db_sha media_sha db_expected media_expected uploads_digest
  local status cleanup_failure=0 read_fail='' sha_target='' sha_mode=''
  mkdir -p "$case_dir/runner" "$case_dir/home/.ssh" "$case_dir/remote-files"
  chmod 700 "$case_dir" "$case_dir/runner" "$case_dir/home" \
    "$case_dir/home/.ssh" "$case_dir/remote-files"
  printf '%s\n' \
    'encrypted database fixture' >"$case_dir/remote-files/postgres.dump.age"
  printf '%s\n' \
    'encrypted uploads fixture' >"$case_dir/remote-files/uploads.tar.gz.age"
  printf '{}\n' >"$case_dir/remote-files/capture-runtime.json"
  printf '{"schema":"fixture-database-proof"}\n' \
    >"$case_dir/remote-files/database-proof.json"
  printf '%s\n' \
    '{"bytes":23,"canonicalDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","files":1,"referencesResolved":1,"referencesTotal":1,"schema":"fixture-media-proof"}' \
    >"$case_dir/remote-files/media-proof.json"
  db_sha=$("$real_sha256sum" "$case_dir/remote-files/database-proof.json" |
    awk '{print $1}')
  media_sha=$("$real_sha256sum" "$case_dir/remote-files/media-proof.json" |
    awk '{print $1}')
  uploads_digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  db_expected=$db_sha
  media_expected=$media_sha
  case "$scenario" in
    database-mismatch)
      db_expected=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
    media-mismatch)
      media_expected=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc ;;
    malformed-expected|malformed-expected-cleanup)
      db_expected=not-a-digest ;;
    missing-expected|missing-expected-cleanup) ;;
    remote-read-failure|hash-failure|local-proof-failure|matching) ;;
    cleanup-failure)
      db_expected=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd ;;
    *) fail "unknown proof scenario: $scenario" ;;
  esac
  jq -cn \
    --arg db "$db_expected" --arg media "$media_expected" \
    --arg uploads "$uploads_digest" \
    '{
      capturedAt:"2026-09-01T00:00:00Z",
      ciphertexts:{
        database:{name:"postgres.dump.age",sha256:"",size:25},
        uploads:{name:"uploads.tar.gz.age",sha256:"",size:25}
      },
      databaseBytes:23,
      proofs:{
        database:{name:"capture-database-proof.json",sha256:$db},
        media:{name:"capture-media-proof.json",sha256:$media}
      },
      recoveryId:"recovery-fixture",
      recoveryPointTime:"2026-09-01T00:00:00Z",
      schema:"meet-backend/beta-recovery-capture/v1",
      uploads:{bytes:23,digest:$uploads,files:1}
    }' >"$case_dir/remote-files/capture-result.json"
  if [ "$scenario" = missing-expected ] ||
    [ "$scenario" = missing-expected-cleanup ]; then
    jq 'del(.proofs.database.sha256)' "$case_dir/remote-files/capture-result.json" \
      >"$case_dir/remote-files/capture-result.tmp"
    mv -- "$case_dir/remote-files/capture-result.tmp" \
      "$case_dir/remote-files/capture-result.json"
  fi
  db_cipher_sha=$("$real_sha256sum" "$case_dir/remote-files/postgres.dump.age" |
    awk '{print $1}')
  uploads_cipher_sha=$("$real_sha256sum" "$case_dir/remote-files/uploads.tar.gz.age" |
    awk '{print $1}')
  jq --arg db "$db_cipher_sha" --arg uploads "$uploads_cipher_sha" \
    --arg db_size "$(wc -c <"$case_dir/remote-files/postgres.dump.age" |
      tr -d '[:space:]')" \
    --arg uploads_size "$(wc -c <"$case_dir/remote-files/uploads.tar.gz.age" |
      tr -d '[:space:]')" \
    '.ciphertexts.database.sha256=$db |
     .ciphertexts.database.size=($db_size|tonumber) |
     .ciphertexts.uploads.sha256=$uploads |
     .ciphertexts.uploads.size=($uploads_size|tonumber)' \
    "$case_dir/remote-files/capture-result.json" \
    >"$case_dir/remote-files/capture-result.final"
  mv -- "$case_dir/remote-files/capture-result.final" \
    "$case_dir/remote-files/capture-result.json"
  printf '%s\n' \
    'Host *' '  HostName hostile.example.invalid' '  Port 1' \
    '  UserKnownHostsFile /tmp/hostile-user-known-hosts' \
    '  GlobalKnownHostsFile /tmp/hostile-global-known-hosts' \
    '  KnownHostsCommand /bin/false' '  ProxyCommand /bin/false' \
    '  ProxyJump hostile-jump.invalid' '  HostKeyAlias hostile-alias' \
    '  CanonicalizeHostname yes' >"$case_dir/home/.ssh/config"
  chmod 600 "$case_dir/home/.ssh/config"
  : >"$case_dir/boundary.log"
  : >"$case_dir/effective.log"
  : >"$case_dir/effective.err"
  remote_state=$case_dir/remote-root
  if [ "$scenario" = cleanup-failure ] ||
    [ "$scenario" = malformed-expected-cleanup ] ||
    [ "$scenario" = missing-expected-cleanup ]; then
    cleanup_failure=1
  elif [ "$scenario" = remote-read-failure ]; then
    read_fail=database-proof.json
  elif [ "$scenario" = hash-failure ]; then
    sha_target=database-proof.json
    sha_mode=fail
  elif [ "$scenario" = local-proof-failure ]; then
    sha_target=database-proof.json
    sha_mode=missing
  fi
  set +e
  (
    cd -- "$semantic_workspace"
    env PATH="$consumer_bin:$original_path" HOME="$case_dir/home" \
      RUNNER_TEMP="$case_dir/runner" PATH_ON_HOST=/fixture/release-root \
      HOST="$scan_host" PORT=2222 SSH_USER=fixture-user \
      HOST_FINGERPRINT="$expected_fingerprint" SSH_PRIVATE_KEY=fixture-private-key \
      AGE_RECIPIENT=age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m \
      PUBLIC_URL=https://api.whysoezzy.online RECOVERY_ID=recovery-fixture \
      RECOVERY_WORKFLOW=.github/workflows/prove-beta-backup-restore.yml \
      GITHUB_REPOSITORY=fixture/repository GITHUB_RUN_ID=7 \
      GITHUB_OUTPUT="$case_dir/output" \
      BETA_RECOVERY_REAL_SSH_KEYGEN="$real_ssh_keygen" \
      BETA_RECOVERY_REAL_SSH="$(command -v ssh)" \
      BETA_RECOVERY_REAL_LN="$(command -v ln)" BETA_RECOVERY_REAL_RM="$real_rm" \
      BETA_RECOVERY_REAL_SHA256SUM="$real_sha256sum" \
      BETA_RECOVERY_BOUNDARY_LOG="$case_dir/boundary.log" \
      BETA_RECOVERY_EFFECTIVE_LOG="$case_dir/effective.log" \
      BETA_RECOVERY_EFFECTIVE_ERR="$case_dir/effective.err" \
      BETA_RECOVERY_SCAN_LINE="[$scan_host]:2222 $key_type $key_data" \
      BETA_RECOVERY_REMOTE=/tmp/beta-recovery-recovery-fixture \
      BETA_RECOVERY_REMOTE_STATE="$remote_state" \
      BETA_RECOVERY_CAPTURE_SOURCE_DIR="$case_dir/remote-files" \
      BETA_RECOVERY_CAPTURE_FIXTURE=1 \
      BETA_RECOVERY_MUTATION_SENTINEL="$case_dir/mutation-sentinel" \
      BETA_RECOVERY_REMOTE_CLEANUP_FAIL="$cleanup_failure" \
      BETA_RECOVERY_CAPTURE_READ_FAIL="$read_fail" \
      BETA_RECOVERY_CAPTURE_SHA_TARGET="$sha_target" \
      BETA_RECOVERY_CAPTURE_SHA_MODE="$sha_mode" \
      BETA_RECOVERY_FAKE_AGE="$fake_age" \
      BETA_RECOVERY_PARENT_PID_FILE="$case_dir/body.pid" \
      bash -c 'trap - HUP INT TERM; printf "%s\n" "$BASHPID" >"$BETA_RECOVERY_PARENT_PID_FILE"; exec bash "$1"' \
      _ "$capture_body"
  ) >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
  if [ "$scenario" = matching ] && [ "$status" -ne 0 ] ||
    [ "$scenario" != matching ] && [ "$status" -eq 0 ]; then
    sed -n '1,40p' "$case_dir/stderr" >&2
    fail "proof case $name returned unexpected status $status (matching must be zero)"
  fi
  assert_consumer_residue_absent "$case_dir"
  [ "$(grep -c '^remote-create$' "$case_dir/boundary.log" || true)" -eq 1 ] ||
    fail "proof case $name did not create remote staging exactly once"
  [ "$(grep -c '^remote-cleanup$' "$case_dir/boundary.log" || true)" -eq 1 ] ||
    fail "proof case $name did not clean remote staging exactly once"
  [ "$(grep -c '^restore-' "$case_dir/boundary.log" || true)" -eq 0 ] ||
    fail "proof case $name reached restore work"
  if [ "$scenario" = matching ]; then
    [ -e "$case_dir/mutation-sentinel" ] ||
      fail "matching proof case did not reach downstream boundary"
    [ "$(grep -c '^evidence-manifest$' "$case_dir/boundary.log" || true)" -eq 1 ] ||
      fail "matching proof case did not construct evidence"
    [ "$(grep -c '^evidence-validate-artifact$' "$case_dir/boundary.log" || true)" -eq 1 ] ||
      fail "matching proof case did not validate prepared artifact"
    [ "$(find "$case_dir/runner/artifact" -type f | wc -l |
      tr -d '[:space:]')" -eq 3 ] ||
      fail "matching proof case did not prepare all artifact files"
    printf 'publication-eligible\n' >>"$case_dir/boundary.log"
    assert_event_order "$case_dir" remote-cleanup evidence-manifest \
      evidence-validate-artifact local-cleanup publication-eligible
  else
    [ ! -e "$case_dir/mutation-sentinel" ] ||
      fail "failed proof case crossed downstream mutation: $name"
    [ "$(grep -c '^evidence-' "$case_dir/boundary.log" || true)" -eq 0 ] ||
      fail "failed proof case constructed evidence: $name"
    [ ! -e "$case_dir/runner/artifact" ] ||
      fail "failed proof case prepared an artifact: $name"
    case "$scenario" in
      database-mismatch|cleanup-failure)
        grep -Fq 'database proof differs from quiesced capture result' \
          "$case_dir/stderr" ||
          fail "database proof diagnostic missing: $name" ;;
      media-mismatch)
        grep -Fq 'media proof differs from quiesced capture result' \
          "$case_dir/stderr" ||
          fail "media proof diagnostic missing: $name" ;;
      malformed-expected|malformed-expected-cleanup)
        grep -Fq 'database proof expected digest is invalid' \
          "$case_dir/stderr" ||
          fail "malformed expected digest diagnostic missing: $name" ;;
      missing-expected|missing-expected-cleanup)
        grep -Fq 'database proof expected digest is missing or malformed' \
          "$case_dir/stderr" ||
          fail "missing expected digest diagnostic missing: $name" ;;
    esac
    if [ "$scenario" = cleanup-failure ] ||
      [ "$scenario" = malformed-expected-cleanup ] ||
      [ "$scenario" = missing-expected-cleanup ]; then
      grep -Fq 'remote staging cleanup failed' "$case_dir/stderr" ||
        fail "cleanup failure diagnostic missing: $name"
    fi
    ! grep -Fq 'publication-eligible' "$case_dir/boundary.log" ||
      fail "failed proof case opened publication eligibility: $name"
  fi
  if [ "$scenario" = cleanup-failure ] ||
    [ "$scenario" = malformed-expected-cleanup ] ||
    [ "$scenario" = missing-expected-cleanup ]; then
    [ -d "$remote_state" ] ||
      fail "cleanup failure unexpectedly removed remote staging"
  else
    [ ! -e "$remote_state" ] && [ ! -L "$remote_state" ] ||
      fail "proof case left remote staging after successful cleanup: $name"
  fi
}

run_capture_proof_case capture-proof-matching matching
run_capture_proof_case capture-proof-database-mismatch database-mismatch
run_capture_proof_case capture-proof-media-mismatch media-mismatch
run_capture_proof_case capture-proof-malformed-expected malformed-expected
run_capture_proof_case capture-proof-missing-expected missing-expected
run_capture_proof_case capture-proof-malformed-expected-cleanup malformed-expected-cleanup
run_capture_proof_case capture-proof-missing-expected-cleanup missing-expected-cleanup
run_capture_proof_case capture-proof-remote-read-failure remote-read-failure
run_capture_proof_case capture-proof-hash-failure hash-failure
run_capture_proof_case capture-proof-local-file-failure local-proof-failure
run_capture_proof_case capture-proof-cleanup-failure cleanup-failure

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
    RUNNER_TEMP="$pre_case/runner" PATH_ON_HOST=/fixture/release-root \
    HOST="$scan_host" PORT=2222 SSH_USER=fixture-user \
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
    BETA_RECOVERY_PARENT_PID_FILE="$pre_case/body.pid" \
    bash -c 'trap - HUP INT TERM; printf "%s\n" "$BASHPID" >"$BETA_RECOVERY_PARENT_PID_FILE"; exec bash "$1"' \
    _ "$capture_body" >"$pre_case/stdout" 2>"$pre_case/stderr"
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
grep -Fxq 'argv-rejected ssh' "$consumer_root/option-rejection.log" ||
  fail "fake SSH did not record option rejection"

echo "beta recovery SSH host-key materialization fixture passed"
