#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
umask 077

fail() {
  echo "beta recovery SSH host-key fixture failed: $*" >&2
  exit 1
}

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
materializer=$root/scripts/materialize-beta-recovery-known-hosts.sh
[ -x "$materializer" ] || fail "materializer is missing or not executable"

for tool in awk basename chmod env find grep mkdir mktemp rm scp ssh ssh-keygen stat tr wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

original_path=$PATH
real_ssh_keygen=$(command -v ssh-keygen)
temporary_root=$(mktemp -d)
chmod 700 -- "$temporary_root"
if [ "$(stat -c '%a' -- "$temporary_root")" != 700 ]; then
  echo "beta recovery SSH host-key fixture skipped: POSIX mode checks unavailable"
  exit 0
fi

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -r -- "$temporary_root" || status=1
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
  '  ambiguous) printf "%s\n%s\n" "${BETA_RECOVERY_SCAN_LINE:?}" "${BETA_RECOVERY_SCAN_ALT_LINE:?}" ;;' \
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
  'exec "${BETA_RECOVERY_REAL_SSH_KEYGEN:?}" "$@"'

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
  local output_override=${7:-}
  local output=$case_dir/runner/output/known_hosts scan_line_for_case=$scan_line
  [ "$port" = 22 ] || scan_line_for_case="[$host]:$port $key_type $key_data"
  [ -n "$output_override" ] && output=$output_override
  env \
    PATH="$fixture_bin:$original_path" \
    HOME="$case_dir/home" \
    RUNNER_TEMP="$case_dir/runner" \
    BETA_RECOVERY_BOUNDARY_LOG="$case_dir/boundary.log" \
    BETA_RECOVERY_REAL_SSH_KEYGEN="$real_ssh_keygen" \
    BETA_RECOVERY_SCAN_MODE="$mode" \
    BETA_RECOVERY_SCAN_LINE="$scan_line_for_case" \
    BETA_RECOVERY_SCAN_ALT_LINE="$scan_line_for_case" \
    BETA_RECOVERY_KEYGEN_MODE="$keygen_mode" \
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
  local output=$case_dir/runner/output/known_hosts
  if [ -e "$output" ] || [ -L "$output" ]; then
    fail "failed case published output: $(basename "$case_dir")"
  fi
  assert_no_staging "$case_dir"
  assert_no_private_output "$case_dir"
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
}

run_success_case success-port-22 22 "$scan_line"
run_success_case success-non-default-port 2222 "[$scan_host]:2222 $key_type $key_data"

run_failure_case malformed-keyscan malformed
run_failure_case mismatched-fingerprint mismatch "$wrong_fingerprint"
run_failure_case ambiguous-keyscan ambiguous
run_failure_case keyscan-failure failure
run_failure_case fingerprint-failure valid "$expected_fingerprint" fail

unsafe_case=$(make_case unsafe-output-directory)
unsafe_output=$unsafe_case/runner/../known_hosts
if run_materializer "$unsafe_case" "$scan_host" 22 "$expected_fingerprint" valid \
  delegate "$unsafe_output"; then
  fail "output outside RUNNER_TEMP was accepted"
fi
assert_failure_case "$unsafe_case"
[ ! -e "$unsafe_output" ] && [ ! -L "$unsafe_output" ] ||
  fail "unsafe output path was published"

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

echo "beta recovery SSH host-key materialization fixture passed"
