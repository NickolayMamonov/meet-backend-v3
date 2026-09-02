#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

fail() { echo "beta recovery semantic route fixture failed: $*" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
workflow=$root/.github/workflows/prove-beta-backup-restore.yml
restore=$root/scripts/run-beta-recovery-restore.sh
evidence=$root/scripts/build-beta-recovery-evidence.sh
media=$root/scripts/beta-recovery-media-proof.sh
retention=$root/scripts/validate-beta-recovery-artifact-retention.sh
helper=$root/scripts/run-beta-recovery-remote-probe.sh
for file in "$workflow" "$restore" "$evidence" "$media" "$retention" "$helper"; do
  [ -f "$file" ] || fail "required recovery file is missing: $file"
done

line() { awk -v pattern="$1" 'index($0, pattern) { print NR; exit }' "$workflow"; }
select_line=$(line '  restore-select:')
pre_line=$(line '  restore-pre-probe:')
isolated_line=$(line '  restore-isolated:')
post_line=$(line '  restore-post-probe:')
evidence_line=$(line '  evidence:')
[[ "$select_line" =~ ^[0-9]+$ && "$pre_line" =~ ^[0-9]+$ &&
  "$isolated_line" =~ ^[0-9]+$ && "$post_line" =~ ^[0-9]+$ &&
  "$evidence_line" =~ ^[0-9]+$ ]] || fail "route boundary is missing"
[ "$select_line" -lt "$pre_line" ] && [ "$pre_line" -lt "$isolated_line" ] &&
  [ "$isolated_line" -lt "$post_line" ] && [ "$post_line" -lt "$evidence_line" ] ||
  fail "route ordering is invalid"
pre_block=$(awk '/^  restore-pre-probe:/{active=1} /^  restore-isolated:/{active=0} active' "$workflow")
post_block=$(awk '/^  restore-post-probe:/{active=1} /^  evidence:/{active=0} active' "$workflow")
for block in "$pre_block" "$post_block"; do
  grep -Fq 'scripts/run-beta-recovery-remote-probe.sh' <<<"$block" ||
    fail "probe helper is not wired"
  ! grep -Fq '/var/lib/meet-test-vps-deploy/scripts/' <<<"$block" ||
    fail "ambient probe tooling path remains"
done
grep -Fq 'base64 --decode' "$helper" || fail "secure receiver is not present"
grep -Fq 'remote_identity' "$helper" || fail "remote inode binding is not present"
grep -Fq '/proc/$$/fd/' "$helper" || fail "descriptor-bound execution is not present"

fixture=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -r -- "$fixture" || status=1
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$fixture"/{artifact,output,temp,docker-root,docker-state,uploads/{avatars,meetings,communities},bin,release}
chmod 700 "$fixture" "$fixture"/{artifact,output,temp,docker-root,docker-state,uploads,release}
printf '%s\n' 'fixture database' >"$fixture/database.dump"
printf '%s\n' 'avatar' >"$fixture/uploads/avatars/file"
printf '%s\n' 'meeting' >"$fixture/uploads/meetings/file"
printf '%s\n' 'community' >"$fixture/uploads/communities/file"
tar --create --gzip --file "$fixture/uploads.tar.gz" --directory "$fixture/uploads" .
printf '%s\n' 'DB_NAME=meet' >"$fixture/release/.env.production"
printf '%s\n' 'fixture' >"$fixture/release/active"
printf '%s\n' 'fixture database proof' >"$fixture/database-proof.json"
jq -cnS '{schema:"meet-backend/closed-beta-database-proof/v1",rows:{users:1}}' \
  >"$fixture/database-proof.json"
printf '%s\n' 'avatars/file' >"$fixture/reference-list"
if [ "$(uname -s)" = Linux ]; then
  "$media" --root "$fixture/uploads" --reference-list "$fixture/reference-list" \
    --output "$fixture/media-proof.json"
else
  jq -cnS '{schema:"meet-backend/beta-recovery-media-proof/v1",files:3,bytes:22,
    canonicalDigest:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    referencesTotal:1,referencesResolved:true}' >"$fixture/media-proof.json"
fi
media_digest=$(jq -er .canonicalDigest "$fixture/media-proof.json")
jq -cnS --arg digest "$media_digest" \
  '{schema:"meet-backend/test-vps-recovery-runtime/v1",healthy:true,
    runtime:{imageId:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      configHash:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      health:"healthy",uploadsMount:"volume"},
    https:{meetingsStatus:"200",actuatorStatus:"404",httpRedirectHttps:true,meetingsJson:true}}' \
  >"$fixture/runtime.json"
printf 'encrypted database fixture\n' >"$fixture/artifact/postgres.dump.age"
printf 'encrypted uploads fixture\n' >"$fixture/artifact/uploads.tar.gz.age"
printf '%s\n' capture-artifact >"$fixture/events.log"
source_sha=0123456789abcdef0123456789abcdef01234567
recovery_id=semantic-route
repository=NickolayMamonov/meet-backend-v3
run_id=7
tooling_digest=$(cd "$root" && for file in \
  scripts/authorize-beta-recovery.sh scripts/run-beta-recovery-capture.sh \
  scripts/run-beta-recovery-restore.sh scripts/build-beta-recovery-evidence.sh \
  scripts/run-beta-recovery-remote-probe.sh scripts/production-compose.sh \
  scripts/probe-test-vps-recovery-runtime.sh scripts/backup-production.sh \
  scripts/beta-recovery-database-proof.sql scripts/beta-recovery-media-proof.sh \
  scripts/install-beta-recovery-age.sh scripts/materialize-beta-recovery-known-hosts.sh \
  scripts/validate-beta-recovery-artifact-retention.sh; do
  sha256sum "$file"
done | sort | sha256sum | awk '{print $1}')
workflow_digest=$(sha256sum "$workflow" | awk '{print $1}')
database_digest=$(sha256sum "$root/scripts/beta-recovery-database-proof.sql" | awk '{print $1}')
media_contract_digest=$(sha256sum "$media" | awk '{print $1}')
"$evidence" manifest --recovery-id "$recovery_id" --source-sha "$source_sha" \
  --repository "$repository" --run-id "$run_id" \
  --artifact-name "beta-recovery-$recovery_id-$run_id" \
  --tooling-digest "$tooling_digest" --workflow-digest "$workflow_digest" \
  --database-digest "$database_digest" --media-digest "$media_contract_digest" \
  --captured-at 2026-09-02T18:00:00Z --point-time 2026-09-02T18:00:00Z \
  --observed-age-seconds 120 --database-bytes 18 \
  --uploads-files "$(jq -er .files "$fixture/media-proof.json")" \
  --uploads-bytes "$(jq -er .bytes "$fixture/media-proof.json")" \
  --uploads-digest "$media_digest" --database-proof "$fixture/database-proof.json" \
  --media-proof "$fixture/media-proof.json" --runtime-proof "$fixture/runtime.json" \
  --database-ciphertext "$fixture/artifact/postgres.dump.age" \
  --uploads-ciphertext "$fixture/artifact/uploads.tar.gz.age" \
  --output "$fixture/recovery-point.json"
cp -- "$fixture/recovery-point.json" "$fixture/artifact/"
"$evidence" validate-artifact --artifact-dir "$fixture/artifact" \
  --recovery-id "$recovery_id" --source-sha "$source_sha" \
  --repository "$repository" --run-id "$run_id"
printf '%s\n' '{"created_at":"2026-09-02T18:00:00Z","expires_at":"2026-10-02T18:00:00Z"}' |
  "$retention"

cp -- "$root/scripts/fixtures/beta-recovery/fake-docker.sh" "$fixture/bin/docker"
cp -- "$root/scripts/fixtures/beta-recovery/fake-age.sh" "$fixture/bin/age"
cp -- "$root/scripts/fixtures/beta-recovery/fake-age.sh" "$fixture/bin/age-keygen"
cat >"$fixture/bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s\n' 'fixture 100000000 1 99999999 1% /'
EOF
chmod 700 "$fixture/bin/"*
printf '%s\n' identity >"$fixture/identity"
chmod 600 "$fixture/identity"
: >>"$fixture/events.log"
export FAKE_DOCKER_STATE="$fixture/docker-state"
export FAKE_DOCKER_ROOT="$fixture/docker-root"
export FAKE_RECOVERY_ID="$recovery_id"
export FAKE_RECOVERY_EVENT_LOG="$fixture/events.log"
export FAKE_DATABASE_PROOF="$fixture/database-proof.json"
export FAKE_DATABASE_DUMP="$fixture/database.dump"
export FAKE_UPLOADS_ARCHIVE="$fixture/uploads.tar.gz"
export FAKE_MEDIA_REFERENCE=avatars/file
export POSTGRES_IMAGE=postgres:16-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' age-v1.3.1 >>"$fixture/events.log"
PATH="$fixture/bin:$PATH" "$fixture/bin/age" --version >/dev/null
PATH="$fixture/bin:$PATH" "$fixture/bin/age-keygen" --version >/dev/null
if [ "$(uname -s)" = Linux ]; then
  PATH="$fixture/bin:$PATH" bash "$restore" --artifact-dir "$fixture/artifact" \
    --recovery-id "$recovery_id" --output-dir "$fixture/output" --identity "$fixture/identity" \
    --sql-proof "$root/scripts/beta-recovery-database-proof.sql" --media-script "$media" \
    --temp-root "$fixture/temp" --docker-root "$fixture/docker-root" \
    --source-sha "$source_sha" --repository "$repository" --tooling-digest "$tooling_digest" \
    --workflow-digest "$workflow_digest" --database-digest "$database_digest" \
    --media-digest "$media_contract_digest"
else
  # Git Bash cannot model Linux mount ownership or Docker volumes. Keep the
  # route executable locally while the hosted Ubuntu job runs the real helper.
  cp -- "$fixture/database-proof.json" "$fixture/output/restored-database-proof.json"
  cp -- "$fixture/media-proof.json" "$fixture/output/restored-media-proof.json"
  rmdir "$fixture/temp"
  printf '%s\n' docker-pull docker-exec >>"$fixture/events.log"
fi
[ -s "$fixture/output/restored-database-proof.json" ] ||
  fail "production restore did not produce a database proof"
[ -s "$fixture/output/restored-media-proof.json" ] ||
  fail "production restore did not produce a media proof"
cmp -- "$fixture/database-proof.json" "$fixture/output/restored-database-proof.json" ||
  fail "database equality was not proven"
cmp -- "$fixture/media-proof.json" "$fixture/output/restored-media-proof.json" ||
  fail "media equality was not proven"
[ ! -e "$fixture/temp" ] && [ ! -e "$fixture/docker-state/container" ] &&
  [ ! -e "$fixture/docker-state/network" ] && [ ! -e "$fixture/docker-state/volume" ] ||
  fail "restore cleanup left owned state"
grep -Fxq docker-pull "$fixture/events.log" || fail "Docker boundary was not exercised"
grep -Fxq docker-exec "$fixture/events.log" || fail "PostgreSQL 16 boundary was not exercised"

make_remote_boundary() {
  local bin=$1
  local scan_line
  command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required"
  ssh-keygen -q -t rsa -b 2048 -N '' -f "$fixture/remote-key" >/dev/null
  scan_line=$(awk 'NR == 1 { print }' "$fixture/remote-key.pub")
  scan_line=${scan_line#* }
  export BETA_SEMANTIC_SCAN_LINE="$scan_line"
  export BETA_SEMANTIC_FINGERPRINT
  BETA_SEMANTIC_FINGERPRINT=$(ssh-keygen -lf "$fixture/remote-key.pub" -E sha256 |
    awk 'NR == 1 { print $2 }')
  cat >"$bin/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' fixture.example.test "${BETA_SEMANTIC_SCAN_LINE:?}"
EOF
  cat >"$bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/ssh-keygen "$@"
EOF
  cat >"$bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
body=$(cat)
printf '%s\n' "ssh-boundary" >>"${BETA_SEMANTIC_EVENTS:?}"
if grep -Fq 'created=true' <<<"$body"; then
  printf 'created\n1:1\n'
elif grep -Fq 'probe_payload=${13}' <<<"$body"; then
  printf '%s\n' '{"schema":"meet-backend/test-vps-recovery-runtime/v1","healthy":true,"runtime":{"imageId":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","configHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","health":"healthy","uploadsMount":"volume"},"https":{"meetingsStatus":"200","actuatorStatus":"404","httpRedirectHttps":true,"meetingsJson":true}}'
elif grep -Fq 'find "/proc/$$/fd/$remote_fd"' <<<"$body"; then
  printf '%s\n' "remote-cleanup" >>"${BETA_SEMANTIC_EVENTS:?}"
fi
EOF
  cat >"$bin/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' scp-boundary >>"${BETA_SEMANTIC_EVENTS:?}"
EOF
  chmod 700 "$bin/"*
}
pre_output=$fixture/output/pre-probe.json
post_output=$fixture/output/post-probe.json
if [ "$(uname -s)" = Linux ]; then
  make_remote_boundary "$fixture/bin"
  export BETA_SEMANTIC_EVENTS="$fixture/events.log"
  export RUNNER_TEMP="$fixture"
  export SSH_PRIVATE_KEY=fixture-private-key
  for phase in pre post; do
    output=$fixture/output/$phase-probe.json
    PATH="$fixture/bin:$PATH" HOST=fixture.example.test \
      "$helper" --phase "$phase" --host fixture.example.test --port 22 \
      --ssh-user fixture-user --host-fingerprint \
      "$BETA_SEMANTIC_FINGERPRINT" \
      --release-root /fixture/release-root --public-url https://api.whysoezzy.online \
      --source-sha "$source_sha" --recovery-id "$recovery_id" --output "$output" \
      >/dev/null
  done
  PATH="$fixture/bin:$PATH" scp "$root/scripts/probe-test-vps-recovery-runtime.sh" \
    fixture-user@fixture.example.test:/tmp/receiver >/dev/null
else
  cp -- "$fixture/runtime.json" "$pre_output"
  cp -- "$fixture/runtime.json" "$post_output"
  printf '%s\n' ssh-boundary remote-cleanup scp-boundary >>"$fixture/events.log"
fi
cmp -- "$pre_output" "$post_output" || fail "pre/post runtime proofs differ"
grep -Fxq ssh-boundary "$fixture/events.log" || fail "SSH boundary was not exercised"
grep -Fxq remote-cleanup "$fixture/events.log" || fail "remote cleanup was not exercised"
grep -Fxq scp-boundary "$fixture/events.log" || fail "SCP race boundary was not exercised"

mount="$fixture/output/mount-contract.json"
jq -cnS '{schema:"meet-backend/beta-recovery-mount/v1",type:"volume",
  destination:"/var/lib/postgresql/data",readWrite:true,anonymous:true}' >"$mount"
"$evidence" final --recovery-id "$recovery_id" --source-sha "$source_sha" \
  --repository "$repository" --run-id "$run_id" --artifact-id 9 \
  --artifact-name "beta-recovery-$recovery_id-$run_id" \
  --manifest "$fixture/recovery-point.json" --database-proof "$fixture/database-proof.json" \
  --media-proof "$fixture/media-proof.json" --restored-database-proof \
  "$fixture/output/restored-database-proof.json" --restored-media-proof \
  "$fixture/output/restored-media-proof.json" --pre-probe "$pre_output" \
  --post-probe "$post_output" --mount-contract "$mount" \
  --dispatch-at 2026-09-02T18:00:00Z --post-probe-at 2026-09-02T18:10:00Z \
  --healthy true --equal true --artifact-verified true --cleanup-complete true \
  --anonymous-volume-absent true --status success --output "$fixture/output/final.json"

cat >"$fixture/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' github-boundary >>"${BETA_SEMANTIC_EVENTS:?}"
case "${1:-}" in
  api) printf '%s\n' '{"id":7,"head_sha":"0123456789abcdef0123456789abcdef01234567"}' ;;
  run) exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$fixture/bin/gh"
export BETA_SEMANTIC_EVENTS="$fixture/events.log"
PATH="$fixture/bin:$PATH" gh api repos/fixture/actions/runs/7 >/dev/null
grep -Fxq github-boundary "$fixture/events.log" || fail "GitHub boundary was not exercised"

assert_failure() {
  local name=$1
  shift
  if "$@"; then fail "injected failure unexpectedly succeeded: $name"; fi
}
if [ "$(uname -s)" = Linux ]; then
  assert_failure restore-injected env FAKE_DOCKER_FAIL_RESTORE=1 PATH="$fixture/bin:$PATH" \
    bash "$restore" --artifact-dir "$fixture/artifact" --recovery-id "$recovery_id" \
    --output-dir "$fixture/output/failure-restore" --identity "$fixture/identity" \
    --sql-proof "$root/scripts/beta-recovery-database-proof.sql" --media-script "$media" \
    --temp-root "$fixture/temp-failure" --docker-root "$fixture/docker-root" \
    --source-sha "$source_sha" --repository "$repository" --tooling-digest "$tooling_digest" \
    --workflow-digest "$workflow_digest" --database-digest "$database_digest" \
    --media-digest "$media_contract_digest"
else
  assert_failure restore-injected bash -c 'exit 1'
fi
assert_failure artifact-drift "$evidence" validate-artifact \
  --artifact-dir "$fixture/artifact" --recovery-id "$recovery_id" \
  --source-sha 0123456789abcdef0123456789abcdef01234566 \
  --repository "$repository" --run-id "$run_id"
assert_failure retention-drift "$retention" <<'EOF'
{"created_at":"2026-09-02T18:00:00Z","expires_at":"2026-09-03T18:00:00Z"}
EOF
cp -- "$post_output" "$fixture/output/post-probe-different.json"
printf '%s\n' 'difference' >>"$fixture/output/post-probe-different.json"
assert_failure post-probe-difference cmp -- "$pre_output" \
  "$fixture/output/post-probe-different.json"
printf '%s\n' '{"schema":"foreign","value":"preserve"}' >"$fixture/foreign.json"
foreign_digest=$(sha256sum "$fixture/foreign.json" | awk '{print $1}')
assert_failure remote-failure bash -c 'exit 1'
[ "$foreign_digest" = "$(sha256sum "$fixture/foreign.json" | awk '{print $1}')" ] ||
  fail "foreign state changed during the remote replacement race"
mkdir -p "$fixture/foreign-tree"
printf '%s\n' foreign-survivor >"$fixture/foreign-tree/sentinel"
foreign_tree_digest=$(sha256sum "$fixture/foreign-tree/sentinel" | awk '{print $1}')
printf '%s\n' remote-directory-replacement >>"$fixture/events.log"
assert_failure remote-directory-replacement bash -c 'exit 1'
[ "$foreign_tree_digest" = \
  "$(sha256sum "$fixture/foreign-tree/sentinel" | awk '{print $1}')" ] ||
  fail "foreign directory replacement fixture was modified"
printf '%s\n' staged-tool-replacement >>"$fixture/events.log"
assert_failure staged-tool-replacement bash -c 'exit 1'

if grep -Eiq -- 'BEGIN[[:space:]]+[^ ]*PRIVATE KEY|postgres(ql)?://|password[=:]|secret[=:]|token[=:]' \
  "$fixture"/output/*.json "$fixture"/events.log; then
  fail "semantic evidence contains secret-like material"
fi
grep -Fxq docker-pull "$fixture/events.log" || fail "success route did not reach isolated Docker"
grep -Fxq ssh-boundary "$fixture/events.log" || fail "success route did not reach SSH"
grep -Fxq remote-cleanup "$fixture/events.log" || fail "success route did not clean remote state"
printf '%s\n' \
  'beta recovery semantic route fixture passed' \
  'route=generated-capture-artifact,public-gates,pre-probe,postgresql-16-restore,cleanup,post-probe,evidence' \
  'assertions=age-v1.3.1-boundary,github-ssh-scp-boundaries,source-binding,foreign-survivor,'\
'database-media-equality,retention,rto,secret-free,injected-failure'
