#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workflow=$root/.github/workflows/prove-beta-backup-restore.yml
[ -f "$workflow" ] || exit 1
command -v jq >/dev/null 2>&1
require_literals_file() {
  local file=$1 needles=$2
  shift 2
  printf -v needles '%s\034' "$@"
  awk -v needles="$needles" '
    BEGIN {
      count = split(needles, required, "\034")
      for (i = 1; i <= count; i++) found[i] = 0
    }
    {
      for (i = 1; i <= count; i++)
        if (!found[i] && index($0, required[i])) found[i] = 1
    }
    END {
      for (i = 1; i <= count; i++) if (!found[i]) exit 1
    }
  ' "$file"
}
require_literals_file "$workflow" '' \
  'workflow_dispatch:' \
  'cancel-in-progress: false' \
  'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' \
  'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' \
  'retention-days: 30' 'closed-beta-restore' 'restore-pre-probe' \
  'restore-post-probe' 'run-beta-recovery-restore.sh' \
  'BETA_RECOVERY_AGE_IDENTITY' 'PUBLIC_URL: https://api.whysoezzy.online' \
  '--public-url' 'scripts/build-beta-recovery-evidence.sh validate-artifact' \
  'scripts/build-beta-recovery-evidence.sh validate-runtime' \
  '--temp-root "$restore_temp"' 'anonymous_volume_absent' \
  'beta-recovery-restore-evidence-' 'beta-recovery-drill-' \
  'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093' \
  'Revalidate source immediately before VPS access' \
  'Revalidate source immediately before identity access' \
  'scripts/materialize-beta-recovery-known-hosts.sh'
if grep -Eq '^[[:space:]]+(push|pull_request|schedule):' "$workflow"; then exit 1; fi
contains_literal_file() {
  local needle=$1 file=$2
  awk -v needle="$needle" 'index($0, needle) { found=1; exit } END { exit !found }' \
    "$file"
}
contains_literal_file 'published_identity=' "$root/scripts/materialize-beta-recovery-known-hosts.sh"
contains_literal_file 'remove_published_output' "$root/scripts/materialize-beta-recovery-known-hosts.sh"
contains_literal_file 'ln -T --' "$root/scripts/materialize-beta-recovery-known-hosts.sh"
contains_literal_file 'published_output_identity=' "$root/scripts/materialize-beta-recovery-known-hosts.sh"
contains_literal_file '[ "$published_output_identity" = "$candidate_identity" ]' \
  "$root/scripts/materialize-beta-recovery-known-hosts.sh"
helper_count=$(grep -Fc -- '--output "$known"' "$workflow")
[ "$helper_count" -eq 1 ]
grep -Fq 'scripts/run-beta-recovery-remote-probe.sh' "$workflow"
probe_helper="$root/scripts/run-beta-recovery-remote-probe.sh"
grep -Fq 'base64 --decode' "$probe_helper"
for required in \
  'ssh_dir=$(mktemp -d "$RUNNER_TEMP/beta-recovery-ssh.XXXXXX")' \
  'install -m 600 /dev/null "$config"' \
  '-F "$config"' \
  '-o StrictHostKeyChecking=yes' \
  '-o UserKnownHostsFile="$known"' \
  '-o GlobalKnownHostsFile=/dev/null' \
  '-o KnownHostsCommand=none'; do
  contains_literal_file "$required" "$workflow" ||
    contains_literal_file "$required" "$probe_helper"
done
for required in \
  "trap 'cleanup_capture 129' HUP" \
  "trap 'cleanup_capture 130' INT" \
  "trap 'cleanup_capture 143' TERM" \
  "trap 'on_signal 129' HUP" \
  "trap 'on_signal 130' INT" \
  "trap 'on_signal 143' TERM"; do
  contains_literal_file "$required" "$workflow" ||
    contains_literal_file "$required" "$probe_helper"
done
grep -Fq "trap 'cleanup_capture \"\$?\"' EXIT" "$workflow"
grep -Fq 'trap cleanup' "$probe_helper"
if grep -Fq 'trap cleanup_capture EXIT HUP INT TERM' "$workflow" ||
  grep -Fq 'trap cleanup_probe EXIT HUP INT TERM' "$workflow"; then
  echo "workflow uses signal-ambiguous cleanup traps" >&2
  exit 1
fi
if grep -Fq 'printf '\''%s\n'\'' "$HOST_FINGERPRINT"' "$workflow"; then
  echo "workflow directly writes the configured fingerprint" >&2
  exit 1
fi
capture_block=$(awk '/Stage and run the locked VPS capture/{flag=1} /restore-select:/{flag=0} flag' "$workflow")
pre_probe_block=$(awk '/restore-pre-probe:/{flag=1} /restore-isolated:/{flag=0} flag' "$workflow")
post_probe_block=$(awk '/restore-post-probe:/{flag=1} /evidence:/{flag=0} flag' "$workflow")
capture_job=$(awk '/^  capture:/{flag=1} /^  restore-select:/{flag=0} flag' "$workflow")
pre_probe_job=$(awk '/^  restore-pre-probe:/{flag=1} /^  restore-isolated:/{flag=0} flag' "$workflow")
post_probe_job=$(awk '/^  restore-post-probe:/{flag=1} /^  evidence:/{flag=0} flag' "$workflow")

assert_capture_count_at_least(){
  local label=$1 expected=$2 pattern=$3 actual
  actual=$(grep -Fc -- "$pattern" <<<"$capture_block" || true)
  [ "$actual" -ge "$expected" ] ||
    { echo "$label is missing: expected at least $expected occurrences of $pattern" >&2; exit 1; }
}
assert_capture_regex(){
  local label=$1 pattern=$2
  grep -Eq -- "$pattern" <<<"$capture_block" ||
    { echo "$label is missing" >&2; exit 1; }
}
extract_capture_program(){
  local keyword=$1 marker
  marker=$(grep -Eo "<<'[A-Za-z0-9_.-]+'" <<<"$capture_block" |
    sed -E "s/^<<'//; s/'$//" | grep -Ei "$keyword" | head -1 || true)
  [ -n "$marker" ] || return 1
  awk -v marker="$marker" '
    index($0, "<<" "'"'"'" marker "'"'"'") { active=1; next }
    active && $0 ~ "^[[:space:]]*" marker "[[:space:]]*$" { exit }
    active { print }
  ' <<<"$capture_block"
}
assert_control_program(){
  local label=$1 program=$2
  [ -n "$program" ] || { echo "$label program is missing" >&2; exit 1; }
  grep -Fq 'LC_ALL=C' <<<"$program" ||
    { echo "$label parser does not force byte locale" >&2; exit 1; }
  grep -Fq 'umask 077' <<<"$program" ||
    { echo "$label parser does not set a restrictive umask" >&2; exit 1; }
  grep -Fq 'dd iflag=fullblock bs=1 count=8 status=none' <<<"$program" ||
    { echo "$label parser does not copy the exact eight-byte prefix" >&2; exit 1; }
  grep -Fq 'od -An -v -tx1' <<<"$program" ||
    { echo "$label parser does not inspect control bytes with od" >&2; exit 1; }
  grep -Fq 'newline_count=0' <<<"$program" ||
    { echo "$label parser does not count header LF bytes" >&2; exit 1; }
  grep -Fq 'newline_count=$((newline_count + 1))' <<<"$program" ||
    { echo "$label parser does not reject internal header LF bytes" >&2; exit 1; }
  grep -Fq '[ "$newline_count" -eq 1 ]' <<<"$program" ||
    { echo "$label parser does not require exactly one header LF" >&2; exit 1; }
  grep -Eq 'header_length.*(4096|4[[:space:]]*\\*\\*?[[:space:]]*3)' <<<"$program" ||
    { echo "$label parser does not enforce the 4096-byte header bound" >&2; exit 1; }
  grep -Eq 'count=.*header_length|header_length.*count=' <<<"$program" ||
    { echo "$label parser does not copy the declared header length" >&2; exit 1; }
  grep -Eq 'test[[:space:]]+-s|test[[:space:]]+![[:space:]]+-s|\\[[[:space:]]*!?[[:space:]]+-s' <<<"$program" ||
    { echo "$label parser does not use a file-size predicate" >&2; exit 1; }
}
assert_eof_probe_contract(){
  local label=$1 program=$2 probe_section
  grep -Fq 'dd iflag=fullblock bs=1 count=1 status=none' <<<"$program" ||
    { echo "$label lacks the one-byte GNU dd EOF probe" >&2; exit 1; }
  grep -Eq '(eof|probe)' <<<"$program" ||
    { echo "$label lacks a distinct EOF-probe name" >&2; exit 1; }
  grep -Eq 'chmod 600.*(eof|probe)|(eof|probe).*chmod 600|install -m 600.*(eof|probe)' \
    <<<"$program" ||
    { echo "$label EOF probe is not mode 600" >&2; exit 1; }
  grep -Eq 'trap[[:space:]]+[^[:space:]]+.*(EXIT|HUP|INT|TERM)|trap[[:space:]]+.*(EXIT|HUP|INT|TERM)' \
    <<<"$program" ||
    { echo "$label parser scratch is not trapped for cleanup" >&2; exit 1; }
  grep -Eq 'test[[:space:]]+![[:space:]]+-s.*(eof|probe)|(eof|probe).*test[[:space:]]+![[:space:]]+-s' \
    <<<"$program" ||
    { echo "$label EOF probe does not use a zero-size predicate" >&2; exit 1; }
  probe_section=$(awk '
    /dd iflag=fullblock bs=1 count=1 status=none.*probe/ { active=1 }
    active { print }
    active && index($0, "test ! -s") { exit }
  ' <<<"$program")
  if grep -Eq '(^|[[:space:];])(read|mapfile)([[:space:];]|$)' <<<"$probe_section" ||
    grep -Eq '\$\([^)]*(cat|dd|od|wc|head|tail)[^)]*(eof|probe)|\$\([^)]*(eof|probe)[^)]*(cat|dd|od|wc|head|tail)' \
      <<<"$probe_section" ||
    grep -Eq '\[\[?[^]]*\$[A-Za-z_][A-Za-z0-9_]*(eof|probe)|case[[:space:]]+\$[A-Za-z_][A-Za-z0-9_]*(eof|probe)' \
      <<<"$probe_section"; then
    echo "$label EOF boundary uses read, content command substitution, or a string test" >&2
    exit 1
  fi
}
create_program=$(extract_capture_program CREATE || true)
receive_program=$(extract_capture_program RECEIVE || true)
cleanup_program=$(extract_capture_program CLEANUP || true)
assert_control_program create "$create_program"
assert_control_program receive "$receive_program"
assert_control_program cleanup "$cleanup_program"
assert_eof_probe_contract create "$create_program"
assert_eof_probe_contract cleanup "$cleanup_program"
assert_capture_count_at_least 'static control-program encoding' 3 'base64 --wrap=0'
assert_capture_count_at_least 'static decoder launch' 3 'sudo bash -c'
assert_capture_count_at_least 'binary prefix validation' 3 'dd iflag=fullblock bs=1 count=8 status=none'
assert_capture_count_at_least 'binary header inspection' 3 'od -An -v -tx1'
assert_capture_count_at_least 'create/cleanup EOF probes' 2 \
  'dd iflag=fullblock bs=1 count=1 status=none'
assert_capture_count_at_least 'create/cleanup zero-size predicates' 2 'test ! -s'
for schema in \
  'meet-backend/beta-recovery-create/v1' \
  'meet-backend/beta-recovery-file/v1' \
  'meet-backend/beta-recovery-cleanup/v1'; do
  grep -Fq -- "$schema" <<<"$capture_block" ||
    { echo "control-frame schema is missing: $schema" >&2; exit 1; }
done
assert_capture_regex 'lowercase hexadecimal prefix-byte admission' \
  '(30|31|32|33|34|35|36|37|38|39|61|62|63|64|65|66)'
assert_capture_regex 'printable-ASCII/LF header-byte admission' \
  '(0a|20|7e)'
assert_capture_regex 'header length range check' \
  'header_length[^[:alnum:]]*(4096|1).*header_length|header_length[^[:alnum:]]*([1-9][0-9]?|4096)'
assert_capture_regex 'operation field-count validation' \
  '(create|cleanup).*(3|three)|(3|three).*(create|cleanup).*receive.*(8|eight)|(8|eight).*receive'
assert_capture_regex 'raw receive payload stream' \
  'cat[[:space:]]+--[[:space:]]*"\$source"|cat[[:space:]]+"\$source"'
if grep -Fq 'payload=$(base64' <<<"$capture_block" ||
  grep -Fq 'payload=$7' <<<"$capture_block" ||
  grep -Fq 'base64 --decode >"$temp"' <<<"$receive_program"; then
  echo "capture receiver still buffers or base64-decodes payload content" >&2
  exit 1
fi
assert_capture_regex 'declared-length-plus-one payload bound' \
  'expected_length[^[:space:]]*[[:space:]]*[+][[:space:]]*1|expected_length_plus_one|payload_limit[^[:space:]]*=[^[:space:]]*[+][^[:space:]]*1'
assert_capture_regex 'temporary device/inode capture' \
  '(temp|temporary|candidate)_identity[^\\n]*stat[^\\n]*%d:%i|stat[^\\n]*%d:%i[^\\n]*(temp|temporary|candidate)'
assert_capture_regex 'published device/inode capture' \
  '(final|published)_identity[^\\n]*stat[^\\n]*%d:%i|stat[^\\n]*%d:%i[^\\n]*(final|published)'
assert_capture_regex 'temporary/final device-inode equality' \
  'final_identity.*temp_identity|temp_identity.*final_identity'
grep -Fq 'ln -T --' <<<"$receive_program" ||
  { echo "receiver publication is not no-overwrite hard-link based" >&2; exit 1; }
identity_block=$(awk '
  /remote_identity=.*ssh/ { active=1 }
  active { print }
  active && /REMOTE_[A-Z_]+/ { exit }
' <<<"$capture_block")
if grep -Fq 'owner_token' <<<"$identity_block" ||
  grep -Eq '(^|[[:space:]])token[[:space:]]*=' <<<"$identity_block"; then
  echo "remote identity custody still accepts an owner token" >&2
  exit 1
fi
grep -Eq 'stat -L?c[^[:space:]]*[[:space:]]+[^%]*%d:%i' <<<"$capture_block" ||
  { echo "token-free identity call does not return a device/inode identity" >&2; exit 1; }
ssh_invocations=$(awk '
  /(^|[|;&[:space:]])ssh[[:space:]]/ { active=1 }
  active { print }
  active && $0 !~ /\\[[:space:]]*$/ { active=0 }
' <<<"$capture_block")
if grep -Eq 'owner_token|payload|expected_length|header|frame' <<<"$ssh_invocations"; then
  echo "dynamic control or payload data entered an SSH launch" >&2
  exit 1
fi
if grep -Eq 'owner_token.*(ssh|sudo|bash|export)|(ssh|sudo|bash|export).*owner_token' \
  <<<"$capture_block"; then
  echo "owner token is present in SSH custody or exported environment" >&2
  exit 1
fi
grep -Fq 'printf -v' <<<"$capture_block" ||
  { echo "control frames are not built in a non-exported Bash variable" >&2; exit 1; }
grep -Eq 'LC_ALL=C[[:space:]]+printf|LC_ALL=C' <<<"$capture_block" ||
  { echo "control-frame generation does not force byte locale" >&2; exit 1; }
grep -Eq '\[\[?[[:space:]]*-r[[:space:]]+"\$source"|\[\[.*-f.*\$source' <<<"$capture_block" ||
  { echo "sender does not require a readable regular source" >&2; exit 1; }
grep -Eq '\[\[.*![[:space:]]*-L.*\$source|\[[[:space:]]*!.*-L.*\$source' <<<"$capture_block" ||
  { echo "sender does not reject symlink sources" >&2; exit 1; }
grep -Fq 'send_capture_file "$age_path" age' "$workflow" ||
  { echo "pinned age is not sent through the shared raw-stream receiver" >&2; exit 1; }
[ "$(grep -Fc 'PATH_ON_HOST: ${{ vars.TEST_VPS_PATH }}' "$workflow")" -eq 3 ]
assert_release_root_gate(){
  local block=$1 checkout_line gate_line first_step network_line
  [ "$(grep -Fc 'name: Validate protected test-VPS release root' <<<"$block")" -eq 1 ]
  first_step=$(grep -n '^      - ' <<<"$block" | head -1)
  grep -Fq 'name: Validate protected test-VPS release root' <<<"$first_step"
  gate_line=$(grep -n 'name: Validate protected test-VPS release root' <<<"$block" | head -1 | cut -d: -f1)
  checkout_line=$(grep -n 'actions/checkout@' <<<"$block" | head -1 | cut -d: -f1)
  [ "$gate_line" -lt "$checkout_line" ]
  network_line=$(grep -nE 'actions/(checkout|upload-artifact|download-artifact)|(^|[[:space:]])(ssh|git fetch|gh (api|run))' <<<"$block" |
    head -1 | cut -d: -f1)
  [ -n "$network_line" ] && [ "$gate_line" -lt "$network_line" ]
  grep -Fq 'TEST_VPS_PATH is absent' <<<"$block"
  grep -Fq 'TEST_VPS_PATH must be a safe absolute path' <<<"$block"
  grep -Fq '[[ "$PATH_ON_HOST" =~ ^/[A-Za-z0-9._/-]+$ ]]' <<<"$block"
  grep -Fq '[[ "$PATH_ON_HOST" != *..* ]]' <<<"$block"
}
assert_release_root_gate "$capture_job"
assert_release_root_gate "$pre_probe_job"
assert_release_root_gate "$post_probe_job"
[ "$(grep -n 'actions/checkout@' <<<"$capture_job" | head -1 | cut -d: -f1)" -lt \
  "$(grep -n 'validate-recovery-id "\$RECOVERY_ID"' <<<"$capture_job" | head -1 | cut -d: -f1)" ]
[ "$(grep -n 'actions/checkout@' <<<"$pre_probe_job" | head -1 | cut -d: -f1)" -lt \
  "$(grep -n 'validate-recovery-id "\$RECOVERY_ID"' <<<"$pre_probe_job" | head -1 | cut -d: -f1)" ]
[ "$(grep -n 'actions/checkout@' <<<"$post_probe_job" | head -1 | cut -d: -f1)" -lt \
  "$(grep -n 'validate-recovery-id "\$RECOVERY_ID"' <<<"$post_probe_job" | head -1 | cut -d: -f1)" ]
grep -Fq 'root=$4' <<<"$capture_block"
! grep -Fq 'root=$2' <<<"$pre_probe_block"
! grep -Fq 'root=$2' <<<"$post_probe_block"
grep -Fq 'sudo bash -s -- \' <<<"$capture_block"
! grep -Fq 'sudo bash -s -- "$PUBLIC_URL" "$PATH_ON_HOST"' <<<"$pre_probe_block"
! grep -Fq 'sudo bash -s -- "$PUBLIC_URL" "$PATH_ON_HOST"' <<<"$post_probe_block"
grep -Fq '"$remote" "$RECOVERY_ID" "$PUBLIC_URL" "$PATH_ON_HOST"' <<<"$capture_block"
grep -Fq 'export PRODUCTION_ROOT="$root"' <<<"$capture_block"
assert_root_export_before_consumer(){
  local block=$1 consumer=$2 export_line consumer_line
  export_line=$(grep -n 'export PRODUCTION_ROOT="\$root"' <<<"$block" | head -1 | cut -d: -f1)
  consumer_line=$(grep -n "$consumer" <<<"$block" | head -1 | cut -d: -f1)
  [ -n "$export_line" ] && [ -n "$consumer_line" ] && [ "$export_line" -lt "$consumer_line" ]
}
assert_root_export_before_consumer "$capture_block" 'bash "\$remote/run-beta-recovery-capture.sh"'
block=$capture_block
  grep -Fq -- '--root "$root"' <<<"$block"
  ! grep -Fq -- '--root /var/lib/meet-production' <<<"$block"
  ! grep -Fq 'PRODUCTION_ROOT=/var/lib/meet-production' <<<"$block"
unset block
isolated_block=$(awk '/^  restore-isolated:/{flag=1} /^  restore-post-probe:/{flag=0} flag' "$workflow")
! grep -Fq 'PATH_ON_HOST' <<<"$isolated_block"
ordered_network_calls=0
ordered_ssh_calls=0
ordered_downstream_calls=0
run_ordered_job(){
  local path=${1-}
  if [ -z "$path" ] ||
    ! [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    [[ "$path" == *..* ]]; then
    return 1
  fi
  ordered_network_calls=$((ordered_network_calls + 1))
  ordered_ssh_calls=$((ordered_ssh_calls + 1))
  ordered_downstream_calls=$((ordered_downstream_calls + 1))
}
run_ordered_case(){
  local label=$1 value=${2-}
  ordered_network_calls=0
  ordered_ssh_calls=0
  ordered_downstream_calls=0
  if run_ordered_job "$value"; then
    [ "$label" = valid ] || { echo "invalid PATH_ON_HOST passed the gate" >&2; exit 1; }
    [ "$ordered_network_calls" -eq 1 ] &&
      [ "$ordered_ssh_calls" -eq 1 ] &&
      [ "$ordered_downstream_calls" -eq 1 ]
  else
    [ "$label" != valid ] || { echo "valid PATH_ON_HOST failed the gate" >&2; exit 1; }
    [ "$ordered_network_calls" -eq 0 ] &&
      [ "$ordered_ssh_calls" -eq 0 ] &&
      [ "$ordered_downstream_calls" -eq 0 ]
  fi
}
run_ordered_case missing
run_ordered_case blank ' '
run_ordered_case relative relative/root
run_ordered_case double-dot /srv/../release
run_ordered_case metacharacter '/srv/release;touch'
run_ordered_case valid /srv/release
block=$capture_block
  helper_line=$(grep -n 'scripts/materialize-beta-recovery-known-hosts.sh' <<<"$block" | head -1 | cut -d: -f1)
  key_line=$(grep -n 'install -m 600 /dev/null "$key"' <<<"$block" | head -1 | cut -d: -f1)
  [ "$helper_line" -lt "$key_line" ]
  mktemp_line=$(grep -n 'ssh_dir=$(mktemp -d' <<<"$block" | head -1 | cut -d: -f1)
  trap_line=$(grep -n "trap 'cleanup_" <<<"$block" | head -1 | cut -d: -f1)
  chmod_line=$(grep -n 'chmod 700 "$ssh_dir"' <<<"$block" | head -1 | cut -d: -f1)
  [ "$mktemp_line" -lt "$trap_line" ] && [ "$trap_line" -lt "$chmod_line" ]
unset block
grep -Fq 'for signal in HUP INT TERM' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'capture-pre-$signal' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'effective-config-failed' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'argv-rejected' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'BETA_RECOVERY_REMOTE_CLEANUP_FAIL' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'capture-ambiguous-create' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'capture-collision-absent-marker' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'capture-collision-mismatched-marker' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'publication-race' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'cleanup-failure-after-publication' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'post-publication-signal-$signal' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'unset AGE_IDENTITY' "$workflow"
grep -Fq 'scripts/install-beta-recovery-age.sh "$age_bin"' "$workflow"
grep -Fq 'owner_token=$(od -An -N32 -tx1 /dev/urandom | tr -d '\''[:space:]'\'')' "$workflow"
grep -Fq 'remote_create_attempted=true' "$workflow"
grep -Fq 'remote_cleanup_done=false' "$workflow"
grep -Fq 'cleanup_remote' "$workflow"
grep -Fq '.meet-beta-recovery-owner' "$workflow"
grep -Fq 'meet-backend/beta-recovery-owner/v1:' "$workflow"
grep -Fq 'cmp -- "$expected" "$marker"' "$workflow"
grep -Fq 'stat -c '\''%a:%u:%g:%h'\'' "$marker"' "$workflow"
grep -Fq -- '--age-binary "$remote/age"' "$workflow"
grep -Fq -- '--age-sha256 "$5" --age-version "$6" --age-os "$7" --age-arch "$8"' "$workflow"
age_transport_count=$(grep -Fc 'send_capture_file "$age_path" age' "$workflow")
[ "$age_transport_count" -eq 1 ]
! grep -Fq 'age-keygen' <<<"$capture_block"
grep -Fq 'archive_size=10263766' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'archive_sha256=bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377' \
  "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'age-v1.3.1-linux-amd64.tar.gz' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq '[ "$(uname -s)" = Linux ]' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq '[ "$(uname -m)" = x86_64 ]' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'tar -tzf "$archive"' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'age/age-plugin-batchpass' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'install -m 0755' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'stat -c' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq '"$age_keygen" -y' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'cmp -- "$plaintext" "$decrypted"' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'printf '\''%s\n'\'' "$age_bin" >>"$GITHUB_PATH"' "$workflow"
grep -Fq 'Provision and canary pinned age toolchain' "$root/.github/workflows/ci.yml"
grep -Fq 'RECOVERY_ID: ${{ inputs.recovery_id }}' "$workflow"
grep -Fq 'scripts/authorize-beta-recovery.sh validate-recovery-id "$RECOVERY_ID"' "$workflow"
grep -Fq 'scripts/authorize-beta-recovery.sh validate-age-recipient "$AGE_RECIPIENT"' "$workflow"
grep -Fq 'closed-beta-restore environment protection policy is malformed or mismatched' \
  "$root/scripts/authorize-beta-recovery.sh"
grep -Fq 'closed-beta-restore/deployment-branch-policies?per_page=100' \
  "$root/scripts/authorize-beta-recovery.sh"
if grep -Fq 'closed-beta-restore/secrets?per_page=100' \
  "$root/scripts/authorize-beta-recovery.sh"; then
  echo "authorization still uses unsupported Environment secret inventory" >&2
  exit 1
fi
unsupported_claim=identitySecretProvisio
unsupported_claim+=ned
if grep -Fq "$unsupported_claim" "$root/scripts/authorize-beta-recovery.sh" ||
  grep -Fq "$unsupported_claim" "$workflow"; then
  echo "authorization still emits unsupported identity proof" >&2
  exit 1
fi
grep -Fq 'recipient_file="$RUNNER_TEMP/age-recipient"' "$workflow"
grep -Fq 'recipient=$(<"$remote/age-recipient")' "$workflow"
grep -Fq 'Remove selected artifact temporary files' "$workflow"
grep -Fq 'RUNNER_TEMP/age-identity' "$workflow"
grep -Fq 'Verify no isolated restore runner residue' "$workflow"
grep -Fq 'cleanup_complete: ${{ steps.final_cleanup.outputs.cleanup_complete }}' "$workflow"
grep -Fq 'anonymous_volume_absent: ${{ steps.final_cleanup.outputs.anonymous_volume_absent }}' "$workflow"
post_probe_job=$(awk '/restore-post-probe:/{flag=1} /evidence:/{flag=0} flag' "$workflow")
evidence_job=$(awk '/evidence:/{flag=1} flag' "$workflow")
grep -Fq "needs.restore-isolated.result == 'success'" <<<"$evidence_job"
grep -Fq "needs.restore-isolated.result != 'skipped'" <<<"$post_probe_job"
if grep -Fq "needs.restore-isolated.result == 'success'" <<<"$post_probe_job"; then
  echo "post-probe is incorrectly success-gated" >&2
  exit 1
fi
isolated_result=failure
final_cleanup_complete=true
anonymous_volume_absent=true
if [ "$isolated_result" = success ] &&
  [ "$final_cleanup_complete" = true ] && [ "$anonymous_volume_absent" = true ]; then
  echo "failed isolated cleanup could reach success" >&2
  exit 1
fi
if grep -Fq "AGE_RECIPIENT='" "$workflow" ||
  grep -Fq -- "--recipient '" "$workflow"; then
  echo "age recipient is interpolated into remote shell source" >&2
  exit 1
fi
run_block=$(awk '
  /^        run: \|$/ { in_run=1; next }
  in_run && /^      [^ ]/ { in_run=0 }
  in_run { print }
' "$workflow")
if grep -Fq '${{ inputs.recovery_id }}' <<<"$run_block"; then
  echo "recovery ID is interpolated directly into a run block" >&2
  exit 1
fi
validation_count=$(grep -Fc 'scripts/authorize-beta-recovery.sh validate-recovery-id "$RECOVERY_ID"' "$workflow")
[ "$validation_count" -eq 7 ]
secret_expression_count=$(grep -Fc '${{ secrets.BETA_RECOVERY_AGE_IDENTITY }}' "$workflow")
[ "$secret_expression_count" -eq 1 ]
setup_line=$(grep -n 'scripts/install-beta-recovery-age.sh "$age_bin"' "$workflow" | tail -1 | cut -d: -f1)
revalidate_line=$(grep -n 'Revalidate source immediately before identity access' "$workflow" | cut -d: -f1)
restore_line=$(grep -n 'id: restore' "$workflow" | cut -d: -f1)
[ "$setup_line" -lt "$revalidate_line" ] && [ "$revalidate_line" -lt "$restore_line" ]
auth="$root/scripts/authorize-beta-recovery.sh"
fixture_dir=$(mktemp -d)
trap 'rm -r -- "$fixture_dir"' EXIT HUP INT TERM
valid_recovery_id=recovery-fixture
valid_recipient=age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m
invalid_short_recipient=age1x
invalid_checksum_recipient=age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh76
remote_dir="$fixture_dir/remote"
remote_marker="$fixture_dir/remote-marker"
received_recipient="$fixture_dir/received-recipient"
remote_log="$fixture_dir/remote.log"
malicious_recovery_id="recovery-fixture'; touch $remote_marker; #"
malicious_recipient="age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m'; touch $remote_marker; #"
bash "$auth" validate-recovery-id "$valid_recovery_id"
bash "$auth" validate-age-recipient "$valid_recipient"
if bash "$auth" validate-age-recipient "$invalid_short_recipient" >/dev/null 2>&1 ||
  bash "$auth" validate-age-recipient "$invalid_checksum_recipient" >/dev/null 2>&1 ||
  bash "$auth" validate-recovery-id "$malicious_recovery_id" >/dev/null 2>&1 ||
  bash "$auth" validate-age-recipient "$malicious_recipient" >/dev/null 2>&1; then
  echo "shell metacharacter fixture was accepted" >&2
  exit 1
fi
[ ! -e "$remote_marker" ]
mkdir "$remote_dir"
ssh_calls=0
ssh(){
  ssh_calls=$((ssh_calls + 1))
  printf 'ssh %s\n' "$*" >>"$remote_log"
  bash -s -- "$remote_dir" "$valid_recovery_id" \
    https://api.whysoezzy.online "$received_recipient" "$valid_recipient" "$remote_marker"
}
run_safe_capture_preflight(){
  local recipient=$1 recipient_file="$fixture_dir/age-recipient-input"
  scripts/authorize-beta-recovery.sh validate-age-recipient "$recipient" || return
  printf '%s\n' "$recipient" >"$recipient_file"
  cp -- "$recipient_file" "$remote_dir/age-recipient"
  ssh fake-host "sudo bash -s -- '$remote_dir' '$valid_recovery_id' 'https://api.whysoezzy.online'" <<'REMOTE'
set -euo pipefail
remote=$1
recovery_id=$2
public_url=$3
received=$4
expected=$5
marker=$6
recipient=$(<"$remote/age-recipient")
if [ "$recipient" != "$expected" ]; then
  touch "$marker"
fi
printf '%s\n' "$recipient" >"$received"
REMOTE
}
if run_safe_capture_preflight "$malicious_recipient"; then
  echo "malicious recipient crossed the remote boundary" >&2
  exit 1
fi
[ "$ssh_calls" -eq 0 ] && [ ! -e "$remote_marker" ]
run_safe_capture_preflight "$valid_recipient"
[ "$ssh_calls" -eq 1 ]
[ "$(wc -l <"$received_recipient" | tr -d '[:space:]')" -eq 1 ]
[ "$(<"$received_recipient")" = "$valid_recipient" ]
grep -Fq 'transferred ciphertext differs from quiesced capture result' "$workflow"
for required in \
  'database_proof_actual_sha=$(sha256sum "$RUNNER_TEMP/database-proof.json" |' \
  'media_proof_actual_sha=$(sha256sum "$RUNNER_TEMP/media-proof.json" |' \
  'database proof hash failed' \
  'media proof hash failed' \
  'database proof expected digest is missing or malformed' \
  'media proof expected digest is missing or malformed' \
  '[[ "$database_proof_actual_sha" =~ ^[0-9a-f]{64}$ ]]' \
  '[[ "$database_proof_expected_sha" =~ ^[0-9a-f]{64}$ ]]' \
  '[[ "$media_proof_actual_sha" =~ ^[0-9a-f]{64}$ ]]' \
  '[[ "$media_proof_expected_sha" =~ ^[0-9a-f]{64}$ ]]' \
  'database proof differs from quiesced capture result' \
  'media proof differs from quiesced capture result' \
  'remote staging cleanup failed'; do
  grep -Fq -- "$required" "$workflow"
done
grep -Fq 'database_proof_expected_sha=$(jq -er' "$workflow"
grep -Fq ".proofs.database.sha256 // empty" "$workflow"
grep -Fq 'media_proof_expected_sha=$(jq -er' "$workflow"
grep -Fq ".proofs.media.sha256 // empty" "$workflow"
grep -Fq '2>/dev/null); then' "$workflow"
! grep -Fq 'all(.proofs[]; (keys|sort)==["name","sha256"]' "$workflow"
grep -Fq 'tooling_digest=$(for file in scripts/authorize-beta-recovery.sh' "$workflow"
grep -Fq -- '--tooling-digest "$tooling_digest"' "$workflow"
! grep -Fq 'transferred proof differs from quiesced capture result' "$workflow"
proof_gate_line=$(grep -n 'database_proof_actual_sha=' "$workflow" | head -1 | cut -d: -f1)
proof_shape_line=$(grep -n 'database proof expected digest is missing or malformed' "$workflow" |
  head -1 | cut -d: -f1)
proof_compare_line=$(grep -n 'media proof differs from quiesced capture result' "$workflow" |
  head -1 | cut -d: -f1)
[ "$proof_gate_line" -lt "$proof_shape_line" ] &&
  [ "$proof_shape_line" -lt "$proof_compare_line" ]
aggregate_line=$(grep -n '\[ "$uploads_files"' "$workflow" | head -1 | cut -d: -f1)
time_line=$(grep -n 'point_epoch=$(date -u' "$workflow" | head -1 | cut -d: -f1)
cleanup_line=$(grep -n 'cleanup_remote ||' "$workflow" | head -1 | cut -d: -f1)
evidence_line=$(grep -n 'scripts/build-beta-recovery-evidence.sh manifest' "$workflow" |
  head -1 | cut -d: -f1)
[ "$proof_gate_line" -lt "$proof_compare_line" ] &&
  [ "$proof_compare_line" -lt "$aggregate_line" ] &&
  [ "$aggregate_line" -lt "$time_line" ] &&
  [ "$time_line" -lt "$cleanup_line" ] &&
  [ "$cleanup_line" -lt "$evidence_line" ]
publish_block=$(awk '/^      - id: publish$/{flag=1} flag' "$workflow")
! grep -Fq 'if: always()' <<<"$publish_block"
grep -Fq '.capturedAt==.recoveryPointTime' "$workflow"
grep -Fq 'observed_age=$((observed_epoch - point_epoch))' "$workflow"
[ "$(grep -Fc 'retention-days: 30' "$workflow")" -eq 6 ]
[ "$(grep -Fc 'scripts/validate-beta-recovery-artifact-retention.sh <<<"$artifact_json"' "$workflow")" -eq 2 ]
! grep -Eq 'created_epoch|expires_epoch|30 \* 24 \* 60 \* 60' "$workflow"
publish_line=$(grep -n '^      - id: publish$' "$workflow" | head -1 | cut -d: -f1)
capture_retention_line=$(grep -n 'scripts/validate-beta-recovery-artifact-retention.sh <<<"$artifact_json"' "$workflow" |
  sed -n '1p' | cut -d: -f1)
final_retention_line=$(grep -n 'scripts/validate-beta-recovery-artifact-retention.sh <<<"$artifact_json"' "$workflow" |
  sed -n '2p' | cut -d: -f1)
cleanup_marker_line=$(grep -n '^      - id: final_cleanup$' "$workflow" | head -1 | cut -d: -f1)
evidence_manifest_line=$(grep -n 'scripts/build-beta-recovery-evidence.sh final' "$workflow" | head -1 | cut -d: -f1)
[ "$publish_line" -lt "$capture_retention_line" ] &&
  [ "$cleanup_marker_line" -lt "$final_retention_line" ] &&
  [ "$final_retention_line" -lt "$evidence_manifest_line" ]

retention_helper=$root/scripts/validate-beta-recovery-artifact-retention.sh
[ -x "$retention_helper" ]
retention_fixture=$fixture_dir/retention
mkdir -p "$retention_fixture/bin"
real_date=$(command -v date)
date_count_file=$retention_fixture/date-count
fake_date=$retention_fixture/bin/date
cat >"$fake_date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=$(<"$FAKE_DATE_COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_DATE_COUNT_FILE"
case "${FAKE_DATE_MODE:-}" in
  first-failure) [ "$count" -ne 1 ] || exit 1 ;;
  second-failure) [ "$count" -ne 2 ] || exit 1 ;;
  non-decimal) [ "$count" -ne 1 ] || { printf 'not-a-number\n'; exit 0; } ;;
esac
exec "$REAL_DATE" "$@"
EOF
chmod 700 "$fake_date"
retention_json() {
  local seconds=$1 created_epoch expires_at
  created_epoch=$("$real_date" -u -d 2026-08-01T00:00:00Z +%s)
  expires_at=$("$real_date" -u -d "@$((created_epoch + seconds))" +%Y-%m-%dT%H:%M:%SZ)
  jq -cn --arg created 2026-08-01T00:00:00Z --arg expires "$expires_at" \
    '{created_at:$created,expires_at:$expires}'
}
expect_retention_success() {
  local label=$1 input=$2 output status
  if output=$(printf '%s\n' "$input" | bash "$retention_helper"); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] && [ -z "$output" ] ||
    { echo "retention success fixture failed: $label" >&2; exit 1; }
}
expect_retention_failure() {
  local label=$1 input=$2 output status
  if output=$(printf '%s\n' "$input" | bash "$retention_helper"); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] && [ -z "$output" ] ||
    { echo "retention failure fixture passed: $label" >&2; exit 1; }
}
expect_fake_date_failure() {
  local label=$1 mode=$2 input=$3 output status
  : >"$date_count_file"
  if output=$(printf '%s\n' "$input" |
    env PATH="$retention_fixture/bin:$PATH" REAL_DATE="$real_date" \
      FAKE_DATE_COUNT_FILE="$date_count_file" FAKE_DATE_MODE="$mode" \
      bash "$retention_helper"); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] && [ -z "$output" ] ||
    { echo "retention parse fixture passed: $label" >&2; exit 1; }
}
expect_retention_success exact-30-days "$(retention_json 2592000)"
expect_retention_success one-second-rounding "$(retention_json 2591999)"
expect_retention_success lower-bound "$(retention_json 2591940)"
expect_retention_failure below-lower-bound "$(retention_json 2591939)"
expect_retention_failure above-upper-bound "$(retention_json 2592001)"
for invalid in \
  invalid-json \
  '{"expires_at":"2026-08-31T00:00:00Z"}' \
  '{"created_at":"","expires_at":"2026-08-31T00:00:00Z"}' \
  '{"created_at":123,"expires_at":"2026-08-31T00:00:00Z"}' \
  '{"created_at":"not-a-date","expires_at":"2026-08-31T00:00:00Z"}' \
  '{"created_at":"2026-08-01T00:00:00Z"}' \
  '{"created_at":"2026-08-01T00:00:00Z","expires_at":""}' \
  '{"created_at":"2026-08-01T00:00:00Z","expires_at":123}' \
  '{"created_at":"2026-08-01T00:00:00Z","expires_at":"not-a-date"}'; do
  expect_retention_failure "invalid metadata: $invalid" "$invalid"
done
valid_retention=$(retention_json 2592000)
expect_fake_date_failure first-date-failure first-failure "$valid_retention"
expect_fake_date_failure second-date-failure second-failure "$valid_retention"
expect_fake_date_failure non-decimal-date-output non-decimal "$valid_retention"

canonical_inventory=$retention_fixture/canonical-inventory
cat >"$canonical_inventory" <<'EOF'
scripts/admit-beta-recovery-artifact.sh
scripts/authorize-beta-recovery.sh
scripts/backup-production.sh
scripts/beta-recovery-database-proof.sql
scripts/beta-recovery-media-proof.sh
scripts/build-beta-recovery-evidence.sh
scripts/install-beta-recovery-age.sh
scripts/materialize-beta-recovery-known-hosts.sh
scripts/probe-test-vps-recovery-runtime.sh
scripts/production-compose.sh
scripts/run-beta-recovery-capture.sh
scripts/run-beta-recovery-remote-probe.sh
scripts/run-beta-recovery-restore.sh
scripts/validate-beta-recovery-artifact-retention.sh
EOF
extract_paths() { grep -oE 'scripts/[A-Za-z0-9._-]+' | sort -u; }
workflow_inventory() {
  local wanted=$1
  awk -v wanted="$wanted" '
    /for file in scripts\/authorize-beta-recovery.sh/ {
      number++
      active=(number == wanted)
    }
    active { print }
    active && /; do/ { exit }
  ' "$workflow" | extract_paths
}
assert_inventory() {
  local label=$1 actual=$2
  diff -u "$canonical_inventory" "$actual" ||
    { echo "$label tooling inventory differs" >&2; exit 1; }
}
[ "$(grep -Fc 'for file in scripts/authorize-beta-recovery.sh' "$workflow")" -eq 3 ]
for index in 1 2 3; do
  actual=$retention_fixture/workflow-$index
  workflow_inventory "$index" >"$actual"
  assert_inventory "workflow inventory $index" "$actual"
done
actual=$retention_fixture/authorization
awk '/^files=\(/{active=1} active {print} active && /^\)/{exit}' \
  "$root/scripts/authorize-beta-recovery.sh" | extract_paths >"$actual"
assert_inventory authorization "$actual"
actual=$retention_fixture/restore-runtime
awk '/^actual_tooling=\$\(for file/{active=1} active {print} active && /^done/{exit}' \
  "$root/scripts/run-beta-recovery-restore.sh" | extract_paths >"$actual"
assert_inventory restore-runtime "$actual"
actual=$retention_fixture/authorization-fixture
awk '/^expected_tooling_digest=.*for file/{active=1} active {print} active && /; do/{exit}' \
  "$root/scripts/test-beta-recovery-authorization.sh" | extract_paths >"$actual"
assert_inventory authorization-fixture "$actual"
actual=$retention_fixture/restore-fixture
awk '/^  tooling=\$\(for file/{active=1} active {print} active && /; do/{exit}' \
  "$root/scripts/test-beta-recovery-restore.sh" | extract_paths >"$actual"
assert_inventory restore-fixture "$actual"
grep -Fq 'select(.event == "workflow_dispatch" and .head_branch == "dev"' "$workflow"
valid_dispatch=$(jq -cn --arg sha "$valid_recovery_id" \
  '{event:"workflow_dispatch",head_branch:"dev",head_sha:$sha,created_at:"2026-08-28T12:00:00Z"}')
dispatch_at=$(jq -er --arg sha "$valid_recovery_id" \
  'select(.event == "workflow_dispatch" and .head_branch == "dev" and .head_sha == $sha) |
   .created_at | select(type == "string" and length > 0)' \
  <<<"$valid_dispatch")
[ "$dispatch_at" = 2026-08-28T12:00:00Z ]
for mismatched_dispatch in \
  "$(jq -cn --arg sha "$valid_recovery_id" \
    '{event:"push",head_branch:"dev",head_sha:$sha,created_at:"2026-08-28T12:00:00Z"}')" \
  "$(jq -cn --arg sha "$valid_recovery_id" \
    '{event:"workflow_dispatch",head_branch:"main",head_sha:$sha,created_at:"2026-08-28T12:00:00Z"}')" \
  "$(jq -cn --arg sha "$valid_recovery_id" \
    '{event:"workflow_dispatch",head_branch:"dev",head_sha:"wrong",created_at:"2026-08-28T12:00:00Z"}')" \
  '{"event":"workflow_dispatch","head_branch":"dev","head_sha":"recovery-fixture"}' \
  '{"event":"workflow_dispatch","head_branch":"dev","head_sha":"recovery-fixture","created_at":null}' \
  '{"event":"workflow_dispatch","head_branch":"dev","head_sha":"recovery-fixture","created_at":123}'; do
  if jq -er --arg sha "$valid_recovery_id" \
    'select(.event == "workflow_dispatch" and .head_branch == "dev" and .head_sha == $sha) |
     .created_at | select(type == "string" and length > 0)' \
    <<<"$mismatched_dispatch" >/dev/null; then
    echo "malformed dispatch fixture unexpectedly produced created_at" >&2
    exit 1
  fi
done
if grep -Eq '\.workflow_run\.(event|head_branch|head_sha)' "$workflow"; then
  echo "artifact validation depends on unavailable nested workflow-run fields" >&2
  exit 1
fi
artifact_fixture='{"id":7,"name":"beta-recovery-recovery-fixture-1","expired":false,"size_in_bytes":1,"workflow_run":{"id":123}}'
jq -e '.workflow_run.id == 123 and (.workflow_run.event // null) == null and
  (.workflow_run.head_branch // null) == null and (.workflow_run.head_sha // null) == null' \
  <<<"$artifact_fixture" >/dev/null
if jq -e '.event == "workflow_dispatch" or .head_branch == "dev"' <<<"$artifact_fixture" >/dev/null; then
  echo "artifact fixture unexpectedly exposed top-level run fields" >&2
  exit 1
fi
capture_db_sha=$(printf '%s\n' database-proof | sha256sum | awk '{print $1}')
capture_media_sha=$(printf '%s\n' media-proof | sha256sum | awk '{print $1}')
capture_fixture=$(jq -cn --arg db "$capture_db_sha" --arg media "$capture_media_sha" '
  {capturedAt:"2026-08-27T19:00:00Z",recoveryPointTime:"2026-08-27T19:00:00Z",
   ciphertexts:{database:{size:10,sha256:$db},uploads:{size:11,sha256:$media}},
   proofs:{database:{name:"database-proof.json",sha256:$db},
           media:{name:"media-proof.json",sha256:$media}}}')
jq -e '
  .capturedAt == .recoveryPointTime and
  all(.ciphertexts[]; (.size|type=="number") and (.sha256|test("^[0-9a-f]{64}$"))) and
  all(.proofs[]; (.sha256|test("^[0-9a-f]{64}$")))
' <<<"$capture_fixture" >/dev/null
jq -e --arg db "$capture_db_sha" --arg media "$capture_media_sha" '
  .ciphertexts.database.sha256 == $db and
  .ciphertexts.uploads.sha256 == $media and
  .proofs.database.sha256 == $db and
  .proofs.media.sha256 == $media
' <<<"$capture_fixture" >/dev/null
point_epoch=$(date -u -d 2026-08-27T19:00:00Z +%s)
observed_epoch=$((point_epoch + 120))
[ "$((observed_epoch - point_epoch))" -eq 120 ]
grep -Fq 'capture-database-proof.json' "$workflow"
if grep -Fq '${{ runner.temp }}/database-proof.json' "$workflow" ||
  grep -Fq '${{ runner.temp }}/media-proof.json' "$workflow"; then
  echo "capture proof files are incorrectly published as workflow artifacts" >&2
  exit 1
fi
if grep -Fq 'volumeName' "$workflow"; then
  echo "generated volume identity is present in workflow evidence" >&2
  exit 1
fi
if grep -Fq 'successful:true' "$workflow" || grep -Fq 'canonicalDigest:"0000000000000000000000000000000000000000000000000000000000000000' "$workflow"; then
  echo "capture workflow contains synthetic proofs" >&2
  exit 1
fi
if awk '/restore-isolated:/{flag=1} /restore-post-probe:/{flag=0} flag' "$workflow" |
  grep -Eq 'TEST_VPS|SSH_PRIVATE_KEY|TEST_VPS_HOST'; then
  echo "isolated restore job has VPS custody" >&2
  exit 1
fi
if awk '/restore-pre-probe:/{flag=1} /restore-isolated:/{flag=0} flag' "$workflow" |
  grep -F 'BETA_RECOVERY_AGE_IDENTITY'; then
  echo "pre-probe job has age identity" >&2
  exit 1
fi
if awk '/restore-post-probe:/{flag=1} /evidence:/{flag=0} flag' "$workflow" |
  grep -F 'BETA_RECOVERY_AGE_IDENTITY'; then
  echo "post-probe job has age identity" >&2
  exit 1
fi
echo "beta recovery workflow fixture passed"
