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
admit=$root/scripts/admit-beta-recovery-artifact.sh
helper=$root/scripts/run-beta-recovery-remote-probe.sh
age_installer=$root/scripts/install-beta-recovery-age.sh
for file in "$workflow" "$restore" "$evidence" "$media" "$retention" "$admit" "$helper"; do
  [ -f "$file" ] || fail "required recovery file is missing: $file"
done
[ -x "$age_installer" ] || fail "pinned age installer is missing or not executable"

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
grep -Fq 'remote_identity' "$helper" || fail "remote inode binding is not present"
grep -Fq '/proc/$$/fd/' "$helper" || fail "descriptor-bound execution is not present"
grep -Fq 'base64 --decode' "$helper" || fail "base64 receiver is not present"

fixture=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -r -- "$fixture" || status=1
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$fixture"/{artifact,output,temp,docker-root,docker-state,uploads/{avatars,meetings,communities},bin,release,age-bin,remote-model}
chmod 700 "$fixture" "$fixture"/{artifact,output,temp,docker-root,docker-state,uploads,release,age-bin,remote-model}
printf '%s\n' 'fixture database' >"$fixture/database.dump"
printf '%s\n' 'avatar' >"$fixture/uploads/avatars/file"
printf '%s\n' 'meeting' >"$fixture/uploads/meetings/file"
printf '%s\n' 'community' >"$fixture/uploads/communities/file"
tar --create --gzip --file "$fixture/uploads.tar.gz" --directory "$fixture/uploads" .
printf '%s\n' 'DB_NAME=meet' >"$fixture/release/.env.production"
printf '%s\n' 'fixture' >"$fixture/release/active"
printf '%s\n' 'services: {}' >"$fixture/release/docker-compose.production.yml"
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
printf '%s\n' capture-artifact >"$fixture/events.log"
source_sha=0123456789abcdef0123456789abcdef01234567
recovery_id=semantic-route
repository=NickolayMamonov/meet-backend-v3
run_id=7
if [ "$(uname -s)" = Linux ]; then
  export RUNNER_TEMP="$fixture"
  "$age_installer" "$fixture/age-bin" >/dev/null
  age=$fixture/age-bin/age
  age_keygen=$fixture/age-bin/age-keygen
  [ "$("$age" --version)" = v1.3.1 ] || fail "pinned age version differs"
  [ "$("$age_keygen" --version)" = v1.3.1 ] || fail "pinned age-keygen version differs"
  "$age_keygen" -o "$fixture/identity" >/dev/null
  chmod 600 "$fixture/identity"
  cp -- "$fixture/identity" "$fixture/failure-identity"
  chmod 600 "$fixture/failure-identity"
  recipient=$("$age_keygen" -y "$fixture/identity")
  [ -n "$recipient" ] || fail "ephemeral age recipient is empty"
  "$age" -r "$recipient" -o "$fixture/artifact/postgres.dump.age" "$fixture/database.dump" >/dev/null
  "$age" -r "$recipient" -o "$fixture/artifact/uploads.tar.gz.age" "$fixture/uploads.tar.gz" >/dev/null
  head -c 24 "$fixture/artifact/postgres.dump.age" | grep -Fq 'age-encryption.org/v1' ||
    fail "database fixture is not age ciphertext"
  head -c 24 "$fixture/artifact/uploads.tar.gz.age" | grep -Fq 'age-encryption.org/v1' ||
    fail "uploads fixture is not age ciphertext"
else
  fail "semantic route requires Linux age and remote-filesystem semantics"
fi
printf '%s\n' age-install age-keygen age-encrypt-database age-encrypt-uploads >>"$fixture/events.log"
tooling_digest=$(cd "$root" && for file in \
  scripts/authorize-beta-recovery.sh scripts/run-beta-recovery-capture.sh \
  scripts/run-beta-recovery-restore.sh scripts/build-beta-recovery-evidence.sh \
  scripts/run-beta-recovery-remote-probe.sh scripts/production-compose.sh \
  scripts/probe-test-vps-recovery-runtime.sh scripts/backup-production.sh \
  scripts/beta-recovery-database-proof.sql scripts/beta-recovery-media-proof.sh \
  scripts/install-beta-recovery-age.sh scripts/materialize-beta-recovery-known-hosts.sh \
  scripts/validate-beta-recovery-artifact-retention.sh \
  scripts/admit-beta-recovery-artifact.sh; do
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
command -v zip >/dev/null 2>&1 || fail "zip is required for the semantic route"
artifact_zip=$fixture/artifact.zip
zip -q -j "$artifact_zip" "$fixture/artifact/postgres.dump.age" \
  "$fixture/artifact/uploads.tar.gz.age" "$fixture/artifact/recovery-point.json"
cat >"$fixture/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=${2:-}
mode=${BETA_SEMANTIC_GH_MODE:-success}
case "$url" in
  */actions/artifacts/7)
    printf '%s\n' "${BETA_SEMANTIC_GATE:-unknown}-artifact-api" \
      >>"${BETA_SEMANTIC_EVENTS:?}"
    case "$mode" in
      artifact-id) id=8; name=beta-recovery-semantic-route-7 ;;
      artifact-name) id=7; name=unrelated-artifact ;;
      artifact-identity) id=7; name=beta-recovery-semantic-route-8 ;;
      retention|expiry|size) id=7; name=beta-recovery-semantic-route-7 ;;
      *) id=7; name=beta-recovery-semantic-route-7 ;;
    esac
    if [ "$mode" = retention ]; then
      printf '%s\n' \
        "{\"id\":$id,\"name\":\"$name\",\"expired\":false,\"size_in_bytes\":1,\"workflow_run\":{\"id\":7},\"created_at\":\"2026-09-02T18:00:00Z\",\"expires_at\":\"2026-09-02T18:00:00Z\"}"
    elif [ "$mode" = expiry ]; then
      printf '%s\n' \
        "{\"id\":$id,\"name\":\"$name\",\"expired\":true,\"size_in_bytes\":1,\"workflow_run\":{\"id\":7},\"created_at\":\"2026-09-02T18:00:00Z\",\"expires_at\":\"2026-09-02T18:00:00Z\"}"
    elif [ "$mode" = size ]; then
      printf '%s\n' \
        "{\"id\":$id,\"name\":\"$name\",\"expired\":false,\"size_in_bytes\":0,\"workflow_run\":{\"id\":7},\"created_at\":\"2026-09-02T18:00:00Z\",\"expires_at\":\"2026-10-02T18:00:00Z\"}"
    else
      printf '%s\n' \
        "{\"id\":$id,\"name\":\"$name\",\"expired\":false,\"size_in_bytes\":1,\"workflow_run\":{\"id\":7},\"created_at\":\"2026-09-02T18:00:00Z\",\"expires_at\":\"2026-10-02T18:00:00Z\"}"
    fi
    ;;
  */actions/runs/7)
    printf '%s\n' "${BETA_SEMANTIC_GATE:-unknown}-run-api" \
      >>"${BETA_SEMANTIC_EVENTS:?}"
    event=workflow_dispatch; branch=dev; sha=$BETA_SEMANTIC_SOURCE_SHA
    path=.github/workflows/prove-beta-backup-restore.yml
    title='Beta recovery capture semantic-route'
    case "$mode" in
      run-status) status=queued; conclusion=success ;;
      run-conclusion) status=completed; conclusion=failure ;;
      run-event) status=completed; conclusion=success; event=push ;;
      run-branch) status=completed; conclusion=success; branch=master ;;
      run-source) status=completed; conclusion=success; sha=ffffffffffffffffffffffffffffffffffffffff ;;
      run-workflow) status=completed; conclusion=success; path=.github/workflows/other.yml ;;
      run-title) status=completed; conclusion=success; title=unrelated ;;
      run-title-wrong-recovery) status=completed; conclusion=success; \
        title='Beta recovery capture other-recovery' ;;
      *) status=completed; conclusion=success ;;
    esac
    printf '%s\n' \
      "{\"id\":7,\"status\":\"$status\",\"conclusion\":\"$conclusion\",\"event\":\"$event\",\"head_branch\":\"$branch\",\"head_sha\":\"$sha\",\"path\":\"$path\",\"display_title\":\"$title\"}"
    ;;
  */actions/artifacts/7/zip)
    printf '%s\n' "${BETA_SEMANTIC_GATE:-unknown}-artifact-transfer" \
      >>"${BETA_SEMANTIC_EVENTS:?}"
    [ "$mode" != transfer-failure ] || {
      head -c 32 "$BETA_SEMANTIC_ARTIFACT_ZIP"
      exit 55
    }
    [ "$mode" != residue-file ] || {
      printf 'foreign residue\n' >"${BETA_SEMANTIC_RESIDUE_PATH:?}"
      {
        stat -c '%F:%a:%u:%g:%h:%s' -- "$BETA_SEMANTIC_RESIDUE_PATH"
        sha256sum -- "$BETA_SEMANTIC_RESIDUE_PATH"
      } >"${BETA_SEMANTIC_RESIDUE_METADATA:?}"
      exit 56
    }
    [ "$mode" != residue-directory ] || {
      mkdir -- "${BETA_SEMANTIC_RESIDUE_PATH:?}"
      printf 'foreign residue\n' >"$BETA_SEMANTIC_RESIDUE_PATH/entry"
      {
        stat -c '%F:%a:%u:%g:%h:%s' -- "$BETA_SEMANTIC_RESIDUE_PATH"
        stat -c '%F:%a:%u:%g:%h:%s' -- "$BETA_SEMANTIC_RESIDUE_PATH/entry"
        sha256sum -- "$BETA_SEMANTIC_RESIDUE_PATH/entry"
      } >"${BETA_SEMANTIC_RESIDUE_METADATA:?}"
      exit 57
    }
    [ "$mode" != zip-corruption ] || { head -c 32 "$BETA_SEMANTIC_ARTIFACT_ZIP"; exit 0; }
    [ "$mode" != zip-extraction ] || {
      cp -- "$BETA_SEMANTIC_ARTIFACT_ZIP" "$BETA_SEMANTIC_ARTIFACT_ZIP.extraction"
      dd if=/dev/zero of="$BETA_SEMANTIC_ARTIFACT_ZIP.extraction" \
        bs=1 seek=128 count=1 conv=notrunc status=none
      cat "$BETA_SEMANTIC_ARTIFACT_ZIP.extraction"
      rm -f -- "$BETA_SEMANTIC_ARTIFACT_ZIP.extraction"
      exit 0
    }
    if [[ "$mode" = manifest-* ]]; then
      variant=${mode#manifest-}
      variant_var=BETA_SEMANTIC_ARTIFACT_VARIANT_$variant
      variant_file=${!variant_var}
      cat "$variant_file"
      exit 0
    fi
    cat "${BETA_SEMANTIC_ARTIFACT_ZIP:?}"
    ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$fixture/bin/gh"
for manifest_field in source repository recovery run name ciphertext; do
  variant_dir="$fixture/manifest-$manifest_field"
  mkdir -p -- "$variant_dir/files"
  unzip -q "$artifact_zip" -d "$variant_dir/files"
  case "$manifest_field" in
    source) jq '.sourceSha = "ffffffffffffffffffffffffffffffffffffffff"' \
      "$variant_dir/files/recovery-point.json" >"$variant_dir/manifest.json" ;;
    repository) jq '.repository = "foreign/repository"' \
      "$variant_dir/files/recovery-point.json" >"$variant_dir/manifest.json" ;;
    recovery) jq '.recoveryId = "foreign-recovery"' \
      "$variant_dir/files/recovery-point.json" >"$variant_dir/manifest.json" ;;
    run) jq '.runId = 8' "$variant_dir/files/recovery-point.json" \
      >"$variant_dir/manifest.json" ;;
    name) jq '.artifactName = "foreign-artifact"' \
      "$variant_dir/files/recovery-point.json" >"$variant_dir/manifest.json" ;;
    ciphertext) jq '.source.ciphertexts.database.sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
      "$variant_dir/files/recovery-point.json" >"$variant_dir/manifest.json" ;;
  esac
  mv -- "$variant_dir/manifest.json" "$variant_dir/files/recovery-point.json"
  (cd "$variant_dir/files" && zip -q -j "$variant_dir.zip" \
    postgres.dump.age uploads.tar.gz.age recovery-point.json)
  eval "export BETA_SEMANTIC_ARTIFACT_VARIANT_$manifest_field=\"$variant_dir.zip\""
done
mkdir -p "$fixture/selection-runner" "$fixture/admission-runner"
chmod 700 "$fixture/selection-runner" "$fixture/admission-runner"
export GITHUB_REPOSITORY="$repository"
export RECOVERY_WORKFLOW=.github/workflows/prove-beta-backup-restore.yml
export GITHUB_RUN_ID=99
export ARTIFACT_ID=7
export BETA_SEMANTIC_SOURCE_SHA="$source_sha"
export BETA_SEMANTIC_ARTIFACT_ZIP="$artifact_zip"
export BETA_SEMANTIC_ARTIFACT_SOURCE="$fixture/artifact"
export SOURCE_SHA="$source_sha"
export RECOVERY_ID="$recovery_id"
export BETA_SEMANTIC_EVENTS="$fixture/events.log"
BETA_SEMANTIC_GATE=restore-select RUNNER_TEMP="$fixture/selection-runner" \
  GITHUB_OUTPUT="$fixture/selection-output" PATH="$fixture/bin:$PATH" \
  "$admit" --artifact-id "$ARTIFACT_ID" --recovery-id "$recovery_id" \
  --source-sha "$source_sha" --repository "$repository" \
  --workflow-path "$RECOVERY_WORKFLOW" \
  --destination "$fixture/selection-runner/artifact" \
  --zip-path "$fixture/selection-runner/artifact.zip"
selected_artifact=$fixture/selection-runner/artifact
[ -d "$selected_artifact" ] || fail "restore-select did not publish an artifact"
cmp -- "$fixture/artifact/postgres.dump.age" "$selected_artifact/postgres.dump.age"
cmp -- "$fixture/artifact/uploads.tar.gz.age" "$selected_artifact/uploads.tar.gz.age"
printf '%s\n' restore-select-admitted >>"$fixture/events.log"
cp -- "$root/scripts/fixtures/beta-recovery/fake-docker.sh" "$fixture/bin/docker"
cat >"$fixture/bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s\n' 'fixture 100000000 1 99999999 1% /'
EOF
chmod 700 "$fixture/bin/"*
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
run_restore() {
  [ "$(uname -s)" = Linux ] ||
    fail "semantic route requires Linux restore and remote-filesystem semantics"
  printf '%s\n' age-identity-access >>"$fixture/events.log"
  PATH="$fixture/age-bin:$fixture/bin:$PATH" bash "$restore" --artifact-dir "$admitted_artifact" \
    --recovery-id "$recovery_id" --output-dir "$fixture/output" --identity "$fixture/identity" \
    --sql-proof "$root/scripts/beta-recovery-database-proof.sql" --media-script "$media" \
    --temp-root "$fixture/temp" --docker-root "$fixture/docker-root" \
    --source-sha "$source_sha" --repository "$repository" --tooling-digest "$tooling_digest" \
    --workflow-digest "$workflow_digest" --database-digest "$database_digest" \
    --media-digest "$media_contract_digest"
  printf '%s\n' age-decrypt-database age-decrypt-uploads restore-cleanup >>"$fixture/events.log"
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
}

make_remote_boundary() {
  local bin=$1
  local scan_line
  command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required"
  ssh-keygen -q -t rsa -b 2048 -N '' -f "$fixture/remote-key" >/dev/null
  scan_line=$(awk 'NR == 1 { print $2 }' "$fixture/remote-key.pub")
  export BETA_SEMANTIC_SCAN_LINE="$scan_line"
  export BETA_SEMANTIC_FINGERPRINT
  BETA_SEMANTIC_FINGERPRINT=$(ssh-keygen -lf "$fixture/remote-key.pub" -E sha256 |
    awk 'NR == 1 { print $2 }')
  cat >"$bin/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s ssh-rsa %s\n' fixture.example.test "${BETA_SEMANTIC_SCAN_LINE:?}"
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
printf '%s\n' ssh-boundary >>"${BETA_SEMANTIC_EVENTS:?}"
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
[ "${1:-}" = -- ] || exit 2
shift
protocol=("$@")
model_root=${BETA_SEMANTIC_MODEL_ROOT:?}
model_lock=$model_root/deploy.lock
mkdir -p -- "$model_root"
touch -- "$model_lock"
body=$(sed "s|/var/lib/meet-test-vps-deploy/.deploy.lock|$model_lock|g" <<<"$body")
mutation=${BETA_SEMANTIC_MUTATION:-}
mutation_ready=${BETA_SEMANTIC_MUTATION_READY:-}
mutation_go=${BETA_SEMANTIC_MUTATION_GO:-}
mutation_done=${BETA_SEMANTIC_MUTATION_DONE:-}
mutation_finish=${BETA_SEMANTIC_MUTATION_FINISH:-}
receiver_prefix=$model_root/receiver-${mutation:-none}
mutation_ready=${mutation_ready:-$receiver_prefix.ready}
mutation_go=${mutation_go:-$receiver_prefix.go}
mutation_done=${mutation_done:-$receiver_prefix.done}
mutation_finish=${mutation_finish:-$receiver_prefix.finish}
remote_path=${protocol[0]:-}
secure_path=/tmp/beta-recovery-probe-secure-${protocol[2]:-}
export BETA_SEMANTIC_REMOTE_PATH="$remote_path"
export BETA_SEMANTIC_SECURE_PATH="$secure_path"
printf '%s\n' "$secure_path" >"$model_root/secure-path"
run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@"
  fi
}
run_remote_body() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_UID=$(id -u) SUDO_GID=$(id -g) \
      BETA_SEMANTIC_MUTATION="$mutation" \
      BETA_SEMANTIC_RECEIVER_READY="$mutation_ready" \
      BETA_SEMANTIC_RECEIVER_GO="$mutation_go" \
      BETA_SEMANTIC_RECEIVER_DONE="$mutation_done" \
      BETA_SEMANTIC_MUTATION_FINISH="$mutation_finish" \
      BETA_SEMANTIC_FIND_COUNTER="${BETA_SEMANTIC_FIND_COUNTER:-}" \
      bash -s -- "$@"
  else
    remote_env=("PATH=$PATH")
    for name in FAKE_RUNTIME_PROBE FAKE_DOCKER_STATE FAKE_DOCKER_ROOT \
      FAKE_RECOVERY_ID FAKE_RECOVERY_EVENT_LOG FAKE_DATABASE_PROOF \
      FAKE_DATABASE_DUMP FAKE_UPLOADS_ARCHIVE FAKE_MEDIA_REFERENCE POSTGRES_IMAGE \
      BETA_SEMANTIC_MUTATION BETA_SEMANTIC_RECEIVER_READY \
      BETA_SEMANTIC_RECEIVER_GO BETA_SEMANTIC_RECEIVER_DONE \
      BETA_SEMANTIC_MUTATION_FINISH BETA_SEMANTIC_FIND_COUNTER \
      BETA_SEMANTIC_REMOTE_PATH \
      BETA_SEMANTIC_SECURE_PATH; do
      [ "${!name+x}" = x ] && remote_env+=("$name=${!name}")
    done
    sudo -n env "${remote_env[@]}" bash -s -- "$@"
  fi
}
case "${#protocol[@]}" in
  4)
    printf '%s\n' remote-create >>"${BETA_SEMANTIC_EVENTS:?}"
    printf '%s-remote-create\n' "${protocol[3]}" >>"${BETA_SEMANTIC_EVENTS:?}"
    printf '%s\n' "${protocol[0]}" >"$model_root/remote-path"
    run_remote_body "${protocol[@]}" <<<"$body"
    ;;
  14)
    case "$mutation" in
      marker-drift|directory-replacement|foreign-file|foreign-directory|foreign-symlink)
        [ -n "$mutation_ready" ] || exit 2
        : >"$mutation_ready"
        for attempt in $(seq 1 500); do
          : "$attempt"
          [ -e "$mutation_go" ] && break
          sleep 0.01
        done
        [ -e "$mutation_go" ]
        case "$mutation" in
          marker-drift)
            printf '%s\n' foreign-marker >"$remote_path/.meet-beta-recovery-owner" ;;
          directory-replacement)
            rm -r -- "$remote_path"
            mkdir -- "$remote_path"
            chmod 700 -- "$remote_path" ;;
          foreign-file)
            printf '%s\n' foreign-state >"$remote_path/foreign-survivor" ;;
          foreign-directory)
            mkdir -- "$remote_path/foreign-directory"
            printf '%s\n' foreign-state >"$remote_path/foreign-directory/state" ;;
          foreign-symlink)
            ln -s -- /tmp/foreign-target "$remote_path/foreign-symlink" ;;
        esac
        : >"$mutation_done"
        for attempt in $(seq 1 500); do
          : "$attempt"
          [ -e "$mutation_finish" ] && break
          sleep 0.01
        done
        [ -e "$mutation_finish" ]
        ;;
    esac
    if [ -n "${BETA_SEMANTIC_MUTATION_READY:-}" ] &&
      [ "$mutation" != marker-drift ] && [ "$mutation" != directory-replacement ] &&
      [ "$mutation" != foreign-file ] && [ "$mutation" != foreign-directory ] &&
      [ "$mutation" != foreign-symlink ]; then
      : >"$BETA_SEMANTIC_MUTATION_READY"
      for attempt in $(seq 1 500); do
        : "$attempt"
        [ -e "${BETA_SEMANTIC_MUTATION_GO:?}" ] && break
        sleep 0.01
      done
      [ -e "${BETA_SEMANTIC_MUTATION_GO:?}" ]
    fi
    printf '%s\n' remote-run >>"${BETA_SEMANTIC_EVENTS:?}"
    printf '%s-remote-run\n' "${protocol[4]}" >>"${BETA_SEMANTIC_EVENTS:?}"
    if [ "${FAKE_RUNTIME_PROBE:-}" = 1 ]; then
      runtime_root=$model_root/runtime-docker-root
      runtime_state=$model_root/runtime-docker-state
      if (
        export FAKE_RUNTIME_PROBE=1 FAKE_DOCKER_ROOT="$runtime_root"
        export FAKE_DOCKER_STATE="$runtime_state"
        run_remote_body "${protocol[@]}" <<<"$body"
      ); then
        remote_status=0
      else
        remote_status=$?
      fi
      [ ! -e "$runtime_root" ] || run_as_root rm -r -- "$runtime_root"
      [ ! -e "$runtime_state" ] || run_as_root rm -r -- "$runtime_state"
      exit "$remote_status"
    fi
    run_remote_body "${protocol[@]}" <<<"$body"
    ;;
  5)
    printf '%s\n' remote-cleanup >>"${BETA_SEMANTIC_EVENTS:?}"
    printf '%s-remote-cleanup\n' "${protocol[4]}" >>"${BETA_SEMANTIC_EVENTS:?}"
    if [ "$mutation" = cleanup-ambiguity ]; then
      [ -n "$mutation_ready" ] || exit 2
      : >"$mutation_ready"
      for attempt in $(seq 1 500); do
        : "$attempt"
        [ -e "$mutation_go" ] && break
        sleep 0.01
      done
      [ -e "$mutation_go" ]
      : >"$mutation_done"
      if [ -n "$mutation_finish" ]; then
        for attempt in $(seq 1 500); do
          : "$attempt"
          [ -e "$mutation_finish" ] && break
          sleep 0.01
        done
        [ -e "$mutation_finish" ]
      fi
      exit 88
    fi
    run_remote_body "${protocol[@]}" <<<"$body"
    ;;
  *) printf 'unsupported semantic SSH protocol\n' >&2; exit 2 ;;
esac
EOF
  cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
headers=
write=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -D) headers=$2; shift 2 ;;
    -w) write=$2; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  https://api.whysoezzy.online/meetings)
    if [ "${BETA_SEMANTIC_MUTATION:-}" = probe-failure ]; then
      : >"${BETA_SEMANTIC_RECEIVER_READY:?}"
      for attempt in $(seq 1 500); do
        : "$attempt"
        [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ] && break
        sleep 0.01
      done
      [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ]
      : >"${BETA_SEMANTIC_RECEIVER_DONE:?}"
      exit 77
    fi
    [ -z "$output" ] || printf '[]\n' >"$output"
    [ "$write" = '%{http_code}' ] && printf '200' ;;
  https://api.whysoezzy.online/actuator)
    [ "$write" = '%{http_code}' ] && printf '404' ;;
  http://api.whysoezzy.online/meetings)
    [ -z "$headers" ] || printf 'HTTP/1.1 301 Moved Permanently\nLocation: https://api.whysoezzy.online/meetings\n\n' >"$headers" ;;
  *) exit 2 ;;
esac
EOF
  cat >"$bin/base64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real_base64=${BETA_SEMANTIC_REAL_BASE64:-/usr/bin/base64}
mode=${BETA_SEMANTIC_MUTATION:-}
if [[ "$*" == *--decode* ]] &&
  [[ "$mode" = base64-corruption || "$mode" = base64-truncation ||
    "$mode" = signal-HUP || "$mode" = signal-INT || "$mode" = signal-TERM ]]; then
  input=$(cat)
  ready=${BETA_SEMANTIC_RECEIVER_READY:?}
  go=${BETA_SEMANTIC_RECEIVER_GO:?}
  done_file=${BETA_SEMANTIC_RECEIVER_DONE:?}
  : >"$ready"
  for attempt in $(seq 1 500); do
    : "$attempt"
    [ -e "$go" ] && break
    sleep 0.01
  done
  [ -e "$go" ]
  case "$mode" in
    base64-corruption)
      set +e
      printf '%s' 'not-valid-base64!' | "$real_base64" --decode
      status=$?
      set -e
      ;;
    base64-truncation)
      set +e
      printf '%s' "${input:0:${#input}-4}" | "$real_base64" --decode
      status=$?
      set -e
      ;;
    signal-*)
      : >"$done_file"
      kill "-${mode#signal-}" "$PPID"
      sleep 1
      status=0
      ;;
  esac
  : >"$done_file"
  exit "$status"
fi
exec "$real_base64" "$@"
EOF
  cat >"$bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real_sha256sum=${BETA_SEMANTIC_REAL_SHA256SUM:-/usr/bin/sha256sum}
target=${@: -1}
if [ "${BETA_SEMANTIC_MUTATION:-}" = checksum-drift ] &&
  [ -n "${BETA_SEMANTIC_SECURE_PATH:-}" ] &&
  [ "$target" = "${BETA_SEMANTIC_SECURE_PATH}/probe-test-vps-recovery-runtime.sh" ] &&
  [ "$(basename -- "$target")" = probe-test-vps-recovery-runtime.sh ]; then
  : >"${BETA_SEMANTIC_RECEIVER_READY:?}"
  for attempt in $(seq 1 500); do
    : "$attempt"
    [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ] && break
    sleep 0.01
  done
  [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ]
  printf '%s\n' corrupted-receiver-state >"$target"
  : >"${BETA_SEMANTIC_RECEIVER_DONE:?}"
fi
exec "$real_sha256sum" "$@"
EOF
  cat >"$bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real_stat=${BETA_SEMANTIC_REAL_STAT:-/usr/bin/stat}
args=("$@")
target=${args[${#args[@]}-1]:-}
if [ "${BETA_SEMANTIC_MUTATION:-}" = mode-drift ] &&
  [ -n "${BETA_SEMANTIC_SECURE_PATH:-}" ] &&
  [ "$target" = "${BETA_SEMANTIC_SECURE_PATH}/probe-test-vps-recovery-runtime.sh" ] &&
  [ "$(basename -- "$target")" = probe-test-vps-recovery-runtime.sh ] &&
  [[ "$*" == *'%a:%u:%g:%h'* ]]; then
  : >"${BETA_SEMANTIC_RECEIVER_READY:?}"
  for attempt in $(seq 1 500); do
    : "$attempt"
    [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ] && break
    sleep 0.01
  done
  [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ]
  chmod 644 -- "$target"
  : >"${BETA_SEMANTIC_RECEIVER_DONE:?}"
fi
exec "$real_stat" "$@"
EOF
  cat >"$bin/ln" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real_ln=${BETA_SEMANTIC_REAL_LN:-/usr/bin/ln}
args=("$@")
target=${args[${#args[@]}-1]:-}
"$real_ln" "$@"
if [ -n "${BETA_SEMANTIC_SECURE_PATH:-}" ] &&
  [ "$target" = "${BETA_SEMANTIC_SECURE_PATH}/probe-test-vps-recovery-runtime.sh" ] &&
  [ "$(basename -- "$target")" = probe-test-vps-recovery-runtime.sh ] &&
  [[ "${BETA_SEMANTIC_MUTATION:-}" = type-drift || "${BETA_SEMANTIC_MUTATION:-}" = link-drift ]]; then
  : >"${BETA_SEMANTIC_RECEIVER_READY:?}"
  for attempt in $(seq 1 500); do
    : "$attempt"
    [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ] && break
    sleep 0.01
  done
  [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ]
  rm -f -- "$target"
  if [ "${BETA_SEMANTIC_MUTATION:-}" = type-drift ]; then
    mkdir -- "$target"
  else
    "$real_ln" -s -- /tmp/foreign-probe-target "$target"
  fi
  : >"${BETA_SEMANTIC_RECEIVER_DONE:?}"
fi
EOF
  cat >"$bin/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real_flock=${BETA_SEMANTIC_REAL_FLOCK:-/usr/bin/flock}
if [ "${BETA_SEMANTIC_MUTATION:-}" = lock-failure ]; then
  : >"${BETA_SEMANTIC_RECEIVER_READY:?}"
  for attempt in $(seq 1 500); do
    : "$attempt"
    [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ] && break
    sleep 0.01
  done
  [ -e "${BETA_SEMANTIC_RECEIVER_GO:?}" ]
  : >"${BETA_SEMANTIC_RECEIVER_DONE:?}"
  exit 89
fi
exec "$real_flock" "$@"
EOF
  cat >"$bin/find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real_find=${BETA_SEMANTIC_REAL_FIND:-/usr/bin/find}
mode=${BETA_SEMANTIC_MUTATION:-}
if [ -n "${BETA_SEMANTIC_SECURE_PATH:-}" ] &&
  [[ "$mode" = cleanup-secure-marker-drift || "$mode" = cleanup-secure-directory-drift ||
  "$mode" = cleanup-outer-marker-drift ]]; then
  counter=${BETA_SEMANTIC_FIND_COUNTER:?}
  count=0
  [ -f "$counter" ] && count=$(<"$counter")
  [[ "$count" =~ ^[0-9]+$ ]]
  count=$((count + 1))
  printf '%s\n' "$count" >"$counter"
  if [ "$count" -eq 2 ]; then
    ready=${BETA_SEMANTIC_RECEIVER_READY:?}
    go=${BETA_SEMANTIC_RECEIVER_GO:?}
    done_file=${BETA_SEMANTIC_RECEIVER_DONE:?}
    finish=${BETA_SEMANTIC_MUTATION_FINISH:?}
    : >"$ready"
    for attempt in $(seq 1 500); do
      : "$attempt"
      [ -e "$go" ] && break
      sleep 0.01
    done
    [ -e "$go" ]
    case "$mode" in
      cleanup-secure-marker-drift)
        secure=${BETA_SEMANTIC_SECURE_PATH:?}
        rm -f -- "$secure/.meet-beta-recovery-secure"
        printf '%s\n' foreign-secure-marker >"$secure/.meet-beta-recovery-secure" ;;
      cleanup-secure-directory-drift)
        secure=${BETA_SEMANTIC_SECURE_PATH:?}
        mv -- "$secure" "$secure.foreign"
        mkdir -- "$secure"
        chmod 700 -- "$secure"
        printf '%s\n' foreign-secure-state >"$secure/foreign-survivor" ;;
      cleanup-outer-marker-drift)
        remote=${BETA_SEMANTIC_REMOTE_PATH:?}
        rm -f -- "$remote/.meet-beta-recovery-owner"
        printf '%s\n' foreign-outer-marker >"$remote/.meet-beta-recovery-owner" ;;
    esac
    : >"$done_file"
    for attempt in $(seq 1 500); do
      : "$attempt"
      [ -e "$finish" ] && break
      sleep 0.01
    done
    [ -e "$finish" ]
  fi
fi
exec "$real_find" "$@"
EOF
  chmod 700 "$bin/"*
}
pre_output=$fixture/output/pre-probe.json
post_output=$fixture/output/post-probe.json
if [ "$(uname -s)" = Linux ]; then
  make_remote_boundary "$fixture/bin"
  export BETA_SEMANTIC_EVENTS="$fixture/events.log"
  export BETA_SEMANTIC_MODEL_ROOT="$fixture/remote-model"
  export RUNNER_TEMP="$fixture"
  export SSH_PRIVATE_KEY=fixture-private-key
  run_probe() {
    local phase=$1 output=$2
    FAKE_RUNTIME_PROBE=1 BETA_SEMANTIC_PHASE="$phase" PATH="$fixture/bin:$PATH" HOST=fixture.example.test \
      "$helper" --phase "$phase" --host fixture.example.test --port 22 \
      --ssh-user fixture-user --host-fingerprint "$BETA_SEMANTIC_FINGERPRINT" \
      --release-root "$fixture/release" --public-url https://api.whysoezzy.online \
      --source-sha "$source_sha" --recovery-id "$recovery_id" --output "$output" \
      > /dev/null
  }
  printf '%s\n' pre-probe-start >>"$fixture/events.log"
  run_probe pre "$pre_output"
  printf '%s\n' pre-probe-complete >>"$fixture/events.log"
else
  fail "semantic route requires Linux remote-filesystem semantics"
fi
BETA_SEMANTIC_GATE=run-admission RUNNER_TEMP="$fixture/admission-runner" \
  GITHUB_OUTPUT="$fixture/admission-output" PATH="$fixture/bin:$PATH" \
  "$admit" --artifact-id "$ARTIFACT_ID" --recovery-id "$recovery_id" \
  --source-sha "$source_sha" --repository "$repository" \
  --workflow-path "$RECOVERY_WORKFLOW" \
  --destination "$fixture/admission-runner/artifact" \
  --zip-path "$fixture/admission-runner/artifact.zip"
admitted_artifact=$fixture/admission-runner/artifact
[ -d "$admitted_artifact" ] || fail "run admission did not publish an artifact"
cmp -- "$selected_artifact/postgres.dump.age" "$admitted_artifact/postgres.dump.age"
cmp -- "$selected_artifact/uploads.tar.gz.age" "$admitted_artifact/uploads.tar.gz.age"
printf '%s\n' run-admission-admitted >>"$fixture/events.log"
run_restore
printf '%s\n' post-probe-start >>"$fixture/events.log"
run_probe post "$post_output"
printf '%s\n' post-probe-complete >>"$fixture/events.log"
cmp -- "$pre_output" "$post_output" || fail "pre/post runtime proofs differ"
grep -Fxq ssh-boundary "$fixture/events.log" || fail "SSH boundary was not exercised"
grep -Fxq remote-cleanup "$fixture/events.log" || fail "remote cleanup was not exercised"

mount="$fixture/output/mount-contract.json"
jq -cnS '{schema:"meet-backend/beta-recovery-mount/v1",type:"volume",
  destination:"/var/lib/postgresql/data",readWrite:true,anonymous:true}' >"$mount"
admitted_database_proof="$fixture/output/admitted-database-proof.json"
admitted_media_proof="$fixture/output/admitted-media-proof.json"
jq -cS '.databaseProof' "$admitted_artifact/recovery-point.json" >"$admitted_database_proof"
jq -cS '.mediaProof' "$admitted_artifact/recovery-point.json" >"$admitted_media_proof"
"$evidence" final --recovery-id "$recovery_id" --source-sha "$source_sha" \
  --repository "$repository" --run-id "$run_id" --artifact-id "$ARTIFACT_ID" \
  --artifact-name "$(jq -er '.artifactName' "$admitted_artifact/recovery-point.json")" \
  --manifest "$admitted_artifact/recovery-point.json" --database-proof \
  "$admitted_database_proof" --media-proof "$admitted_media_proof" --restored-database-proof \
  "$fixture/output/restored-database-proof.json" --restored-media-proof \
  "$fixture/output/restored-media-proof.json" --pre-probe "$pre_output" \
  --post-probe "$post_output" --mount-contract "$mount" \
  --dispatch-at 2026-09-02T18:00:00Z --post-probe-at 2026-09-02T18:10:00Z \
  --healthy true --equal true --artifact-verified true --cleanup-complete true \
  --anonymous-volume-absent true --status success --output "$fixture/output/final.json"

printf '%s\n' evidence-final >>"$fixture/events.log"

event_line() {
  awk -v event="$1" '$0 == event { print NR; exit }' "$fixture/events.log"
}
assert_event_order() {
  local previous=0 current event
  for event in "$@"; do
    current=$(event_line "$event")
    [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -gt "$previous" ] ||
      fail "event ordering is invalid at $event"
    previous=$current
  done
}
assert_event_order age-install age-keygen age-encrypt-database age-encrypt-uploads \
  restore-select-artifact-api restore-select-run-api \
  restore-select-artifact-transfer restore-select-admitted \
  pre-probe-start pre-remote-create pre-remote-run pre-probe-complete \
  run-admission-artifact-api run-admission-run-api \
  run-admission-artifact-transfer run-admission-admitted \
  age-identity-access docker-pull restore-cleanup post-probe-start \
  post-remote-create post-remote-run post-probe-complete evidence-final

assert_failure() {
  local name=$1
  shift
  if "$@"; then fail "injected failure unexpectedly succeeded: $name"; fi
}
run_gate_failure() {
  local mode=$1 runner="$fixture/gate-failure-$1"
  mkdir -p -- "$runner"
  chmod 700 -- "$runner"
  : >"$runner/events.log"
  if BETA_SEMANTIC_GATE="failure-$mode" BETA_SEMANTIC_GH_MODE="$mode" \
    BETA_SEMANTIC_EVENTS="$runner/events.log" BETA_SEMANTIC_SOURCE_SHA="$source_sha" \
    RUNNER_TEMP="$runner" \
    GITHUB_OUTPUT="$runner/output" PATH="$fixture/bin:$PATH" \
    "$admit" --artifact-id "$ARTIFACT_ID" --recovery-id "$recovery_id" \
    --source-sha "$source_sha" --repository "$repository" \
    --workflow-path "$RECOVERY_WORKFLOW" \
    --destination "$runner/artifact" --zip-path "$runner/artifact.zip"; then
    fail "restore-select accepted injected gate drift: $mode"
  fi
  [ ! -e "$runner/artifact" ] && [ ! -L "$runner/artifact" ] ||
    fail "restore-select left failed artifact state: $mode"
  [ ! -e "$runner/artifact.zip" ] || fail "restore-select left failed ZIP state: $mode"
  [ -z "$(find "$runner" -maxdepth 1 -name '.beta-recovery-*' -print -quit)" ] ||
    fail "restore-select left private staging state: $mode"
  ! grep -Eq 'pre-probe-start|age-identity-access|docker-pull' "$runner/events.log" ||
    fail "restore-select crossed a prohibited boundary: $mode"
}
run_admission_failure() {
  local mode=$1 runner="$fixture/admission-failure-$1" residue_path='' residue_metadata=''
  mkdir -p -- "$runner"
  chmod 700 -- "$runner"
  : >"$runner/events.log"
  case "$mode" in
    residue-file|residue-directory)
      residue_path=$runner/residue
      residue_metadata=$runner/residue.metadata
      ;;
  esac
  if BETA_SEMANTIC_GATE="admission-failure-$mode" BETA_SEMANTIC_GH_MODE="$mode" \
    BETA_SEMANTIC_EVENTS="$runner/events.log" BETA_SEMANTIC_SOURCE_SHA="$source_sha" \
    BETA_SEMANTIC_RESIDUE_PATH="$residue_path" \
    BETA_SEMANTIC_RESIDUE_METADATA="$residue_metadata" \
    RUNNER_TEMP="$runner" \
    GITHUB_OUTPUT="$runner/output" PATH="$fixture/bin:$PATH" \
    "$admit" --artifact-id "$ARTIFACT_ID" --recovery-id "$recovery_id" \
    --source-sha "$source_sha" --repository "$repository" \
    --workflow-path "$RECOVERY_WORKFLOW" \
    --destination "$runner/artifact" --zip-path "$runner/artifact.zip"; then
    fail "run admission accepted injected drift: $mode"
  fi
  [ ! -e "$runner/artifact" ] && [ ! -L "$runner/artifact" ] ||
    fail "run admission left failed artifact state: $mode"
  [ ! -e "$runner/artifact.zip" ] || fail "run admission left failed ZIP state: $mode"
  [ -z "$(find "$runner" -maxdepth 1 -name '.beta-recovery-*' -print -quit)" ] ||
    fail "run admission left private staging state: $mode"
  case "$mode" in
    residue-file)
      [ -f "$residue_path" ] && [ ! -L "$residue_path" ] ||
        fail "regular residue was not preserved: $mode"
      [ "$(stat -c '%F:%a:%u:%g:%h:%s' -- "$residue_path")" = \
        "$(sed -n '1p' "$residue_metadata")" ] &&
        [ "$(sha256sum "$residue_path")" = \
          "$(sed -n '2p' "$residue_metadata")" ] ||
        fail "regular residue bytes changed: $mode" ;;
    residue-directory)
      [ -d "$residue_path" ] && [ ! -L "$residue_path" ] ||
        fail "directory residue was not preserved: $mode"
      [ "$(stat -c '%F:%a:%u:%g:%h:%s' -- "$residue_path")" = \
        "$(sed -n '1p' "$residue_metadata")" ] &&
        [ "$(stat -c '%F:%a:%u:%g:%h:%s' -- "$residue_path/entry")" = \
          "$(sed -n '2p' "$residue_metadata")" ] &&
        [ "$(sha256sum "$residue_path/entry")" = \
          "$(sed -n '3p' "$residue_metadata")" ] ||
        fail "directory residue bytes changed: $mode" ;;
  esac
  ! grep -Eq 'age-identity-access|docker-pull' "$runner/events.log" ||
    fail "run admission crossed a prohibited boundary: $mode"
}
for gate_failure in artifact-id artifact-name retention expiry size run-status run-conclusion run-event \
  run-branch run-source run-workflow run-title run-title-wrong-recovery artifact-identity transfer-failure zip-corruption \
  zip-extraction; do
  run_gate_failure "$gate_failure"
done
for admission_failure in artifact-id artifact-name retention expiry size run-status \
  run-conclusion run-event run-branch run-source run-workflow run-title run-title-wrong-recovery \
  artifact-identity transfer-failure zip-corruption zip-extraction \
  manifest-source manifest-repository manifest-recovery manifest-run \
  manifest-name manifest-ciphertext residue-file residue-directory; do
  run_admission_failure "$admission_failure"
done
publication_race_bin=$fixture/publication-race-bin
real_mv=$(command -v mv)
mkdir -- "$publication_race_bin"
chmod 700 -- "$publication_race_bin"
cat >"$publication_race_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
destination=${args[${#args[@]}-1]}
case "${BETA_SEMANTIC_PUBLICATION_RACE_MODE:-}" in
  file)
    printf 'foreign publication survivor\n' >"$destination" ;;
  directory)
    mkdir -- "$destination" ;;
  symlink)
    ln -s -- "${BETA_SEMANTIC_PUBLICATION_RACE_TARGET:?}" "$destination" ;;
  *)
    exec "${BETA_SEMANTIC_REAL_MV:?}" "$@" ;;
esac
exec "${BETA_SEMANTIC_REAL_MV:?}" "$@"
EOF
chmod 700 -- "$publication_race_bin/mv"
run_publication_race() {
  local mode=$1 runner="$fixture/publication-race-$1" target="$fixture/publication-race-target-$1"
  mkdir -- "$runner"
  chmod 700 -- "$runner"
  mkdir -- "$target"
  printf 'outside survivor\n' >"$target/entry"
  if BETA_SEMANTIC_GATE="publication-race-$mode" \
    BETA_SEMANTIC_GH_MODE=success BETA_SEMANTIC_EVENTS="$runner/events.log" \
    BETA_SEMANTIC_SOURCE_SHA="$source_sha" RUNNER_TEMP="$runner" \
    GITHUB_OUTPUT="$runner/output" PATH="$publication_race_bin:$fixture/bin:$PATH" \
    BETA_SEMANTIC_PUBLICATION_RACE_MODE="$mode" \
    BETA_SEMANTIC_PUBLICATION_RACE_TARGET="$target" \
    BETA_SEMANTIC_REAL_MV="$real_mv" \
    "$admit" --artifact-id "$ARTIFACT_ID" --recovery-id "$recovery_id" \
    --source-sha "$source_sha" --repository "$repository" \
    --workflow-path "$RECOVERY_WORKFLOW" \
    --destination "$runner/artifact" --zip-path "$runner/artifact.zip"; then
    fail "publication race unexpectedly succeeded: $mode"
  fi
  case "$mode" in
    file)
      [ -f "$runner/artifact" ] && [ ! -L "$runner/artifact" ] ||
        fail "regular publication survivor was not preserved" ;;
    directory)
      [ -d "$runner/artifact" ] && [ ! -L "$runner/artifact" ] ||
        fail "directory publication survivor was not preserved" ;;
    symlink)
      [ -L "$runner/artifact" ] ||
        fail "symlink publication survivor was not preserved" ;;
  esac
  printf 'outside survivor\n' | cmp -- "$target/entry" - ||
    fail "publication race changed the foreign target"
  [ ! -e "$runner/artifact.zip" ] || fail "publication race left a ZIP"
  [ -z "$(find "$runner" -maxdepth 1 -name '.beta-recovery-*' -print -quit)" ] ||
    fail "publication race left private staging"
}
run_publication_race file
run_publication_race directory
run_publication_race symlink
if [ "$(uname -s)" = Linux ]; then
  assert_failure restore-injected env FAKE_DOCKER_FAIL_RESTORE=1 \
    PATH="$fixture/age-bin:$fixture/bin:$PATH" \
    bash "$restore" --artifact-dir "$fixture/artifact" --recovery-id "$recovery_id" \
    --output-dir "$fixture/output/failure-restore" --identity "$fixture/failure-identity" \
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
[ "$foreign_digest" = "$(sha256sum "$fixture/foreign.json" | awk '{print $1}')" ] ||
  fail "foreign state changed during the remote replacement race"
snapshot_tree() {
  local root_path=$1 snapshot=$2 path relative metadata payload
  snapshot_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
      "$@"
    else
      sudo -n "$@"
    fi
  }
  : >"$snapshot"
  printf '.|%s\n' "$(snapshot_as_root stat -c '%F:%a:%u:%g:%h:%s' -- "$root_path")" >>"$snapshot"
  while IFS= read -r -d '' path; do
    relative=${path#"$root_path"/}
    metadata=$(snapshot_as_root stat -c '%F:%a:%u:%g:%h:%s' -- "$path")
    if [ "$(snapshot_as_root stat -c '%F' -- "$path")" = "symbolic link" ]; then
      payload="link:$(snapshot_as_root readlink -- "$path")"
    elif [ "$(snapshot_as_root stat -c '%F' -- "$path")" = "regular file" ]; then
      payload="sha:$(snapshot_as_root sha256sum -- "$path" | awk '{print $1}')"
    else
      payload=directory
    fi
    printf '%s|%s|%s\n' "$relative" "$metadata" "$payload" >>"$snapshot"
  done < <(snapshot_as_root find "$root_path" -mindepth 1 -print0 | sort -z)
}
remote_failure() {
  local mutation=$1 output remote_path original_snapshot expected_snapshot
  local mutation_ready mutation_go mutation_done mutation_finish
  output=$fixture/output/failure-$mutation.json
  mutation_ready=$fixture/remote-model/$mutation.ready
  mutation_go=$fixture/remote-model/$mutation.go
  mutation_done=$fixture/remote-model/$mutation.done
  mutation_finish=$fixture/remote-model/$mutation.finish
  original_snapshot=$fixture/remote-model/$mutation.before
  expected_snapshot=$fixture/remote-model/$mutation.snapshot
  rm -f -- "$mutation_ready" "$mutation_go" "$mutation_done" "$mutation_finish" \
    "$original_snapshot" "$expected_snapshot"
  BETA_SEMANTIC_MUTATION=$mutation BETA_SEMANTIC_MUTATION_READY="$mutation_ready" \
    BETA_SEMANTIC_MUTATION_GO="$mutation_go" BETA_SEMANTIC_MUTATION_DONE="$mutation_done" \
    BETA_SEMANTIC_MUTATION_FINISH="$mutation_finish" PATH="$fixture/bin:$PATH" \
    run_probe pre "$output" &
  probe_pid=$!
  for attempt in $(seq 1 500); do
    : "$attempt"
    [ -e "$mutation_ready" ] && break
    sleep 0.01
  done
  [ -e "$mutation_ready" ] || fail "remote mutation did not reach synchronized boundary: $mutation"
  remote_path=$(cat "$fixture/remote-model/remote-path")
  snapshot_tree "$remote_path" "$original_snapshot"
  : >"$mutation_go"
  for attempt in $(seq 1 500); do
    : "$attempt"
    [ -e "$mutation_done" ] && break
    sleep 0.01
  done
  [ -e "$mutation_done" ] || fail "remote mutation did not complete: $mutation"
  snapshot_tree "$remote_path" "$expected_snapshot"
  : >"$mutation_finish"
  if wait "$probe_pid"; then
    fail "remote mutation unexpectedly succeeded: $mutation"
  fi
  [ -e "$remote_path" ] || [ -L "$remote_path" ] ||
    fail "foreign remote survivor was not preserved: $mutation"
  snapshot_tree "$remote_path" "$fixture/remote-model/$mutation.after"
  cmp -- "$expected_snapshot" "$fixture/remote-model/$mutation.after" ||
    fail "foreign remote bytes or metadata changed: $mutation"
  remove_remote_path() {
    if [ "$(id -u)" -eq 0 ]; then
      rm -r -- "$1"
    else
      sudo -n rm -r -- "$1"
    fi
  }
  remove_remote_path "$remote_path"
}
remote_failure marker-drift
remote_failure directory-replacement
remote_failure foreign-file
remote_failure foreign-directory
remote_failure foreign-symlink

receiver_failure() {
  local mutation=$1 case_dir="$fixture/receiver-failure-$1"
  local runner="$case_dir/runner" output="$case_dir/output.json"
  local ready="$fixture/remote-model/receiver-$1.ready"
  local go="$fixture/remote-model/receiver-$1.go"
  local done_file="$fixture/remote-model/receiver-$1.done"
  local finish="$fixture/remote-model/receiver-$1.finish" pid remote secure
  mkdir -p -- "$runner"
  chmod 700 -- "$case_dir" "$runner"
  : >"$case_dir/events.log"
  printf '0\n' >"$case_dir/find.count"
  chmod 600 -- "$case_dir/find.count"
  (
    export BETA_SEMANTIC_MUTATION="$mutation"
    export BETA_SEMANTIC_RECEIVER_READY="$ready"
    export BETA_SEMANTIC_RECEIVER_GO="$go"
    export BETA_SEMANTIC_RECEIVER_DONE="$done_file"
    export BETA_SEMANTIC_MUTATION_FINISH="$finish"
    export BETA_SEMANTIC_FIND_COUNTER="$case_dir/find.count"
    export BETA_SEMANTIC_EVENTS="$case_dir/events.log"
    export RUNNER_TEMP="$runner"
    run_probe pre "$output"
  ) &
  pid=$!
  for attempt in $(seq 1 500); do
    : "$attempt"
    [ -e "$ready" ] && break
    sleep 0.01
  done
  [ -e "$ready" ] || fail "receiver mutation did not reach synchronized boundary: $mutation"
  remote=$(cat "$fixture/remote-model/remote-path")
  secure=$(cat "$fixture/remote-model/secure-path")
  : >"$go"
  for attempt in $(seq 1 500); do
    : "$attempt"
    [ -e "$done_file" ] && break
    sleep 0.01
  done
  [ -e "$done_file" ] || fail "receiver mutation did not complete: $mutation"
  if [[ "$mutation" = cleanup-* ]]; then
    if [[ "$mutation" = cleanup-secure-marker-drift ||
      "$mutation" = cleanup-secure-directory-drift ||
      "$mutation" = cleanup-outer-marker-drift ]]; then
      [ -f "$case_dir/find.count" ] ||
        fail "receiver cleanup did not publish a find counter: $mutation"
      [ "$(cat "$case_dir/find.count")" = 2 ] ||
        fail "receiver cleanup did not synchronize at counted find 2: $mutation"
      kill -0 "$pid" 2>/dev/null ||
        fail "receiver continued past the cleanup mutation before finish: $mutation"
      [ "$(cat "$case_dir/find.count")" = 2 ] ||
        fail "receiver cleanup advanced past counted find 2 before finish: $mutation"
    fi
    snapshot_tree "$remote" "$case_dir/remote.expected"
    case "$mutation" in
      cleanup-secure-marker-drift)
        snapshot_tree "$secure" "$case_dir/secure.expected" ;;
      cleanup-secure-directory-drift)
        snapshot_tree "$secure" "$case_dir/secure.expected"
        snapshot_tree "$secure.foreign" "$case_dir/secure-foreign.expected" ;;
      cleanup-outer-marker-drift)
        [ -e "$secure" ] || [ -L "$secure" ] ||
          fail "outer marker mutation removed secure state before finish" ;;
    esac
    : >"$finish"
  fi
  if wait "$pid"; then
    fail "receiver mutation unexpectedly succeeded: $mutation"
  fi
  [ ! -e "$output" ] && [ ! -L "$output" ] ||
    fail "receiver mutation published output: $mutation"
  if [[ "$mutation" = cleanup-* ]]; then
    case "$mutation" in
      cleanup-secure-marker-drift|cleanup-secure-directory-drift)
        [ "$(cat "$case_dir/find.count")" = 2 ] ||
          fail "secure cleanup mutation reached an unexpected find count: $mutation" ;;
      cleanup-outer-marker-drift)
        [ "$(cat "$case_dir/find.count")" = 3 ] ||
          fail "outer marker cleanup mutation reached an unexpected find count: $mutation" ;;
    esac
    snapshot_tree "$remote" "$case_dir/remote.after"
    cmp -- "$case_dir/remote.expected" "$case_dir/remote.after" ||
      fail "cleanup mutation changed remote survivor: $mutation"
    if [ "$mutation" = cleanup-secure-marker-drift ] ||
      [ "$mutation" = cleanup-secure-directory-drift ]; then
      snapshot_tree "$secure" "$case_dir/secure.after"
      cmp -- "$case_dir/secure.expected" "$case_dir/secure.after" ||
        fail "cleanup mutation changed secure survivor: $mutation"
    fi
    if [ "$mutation" = cleanup-secure-directory-drift ]; then
      snapshot_tree "$secure.foreign" "$case_dir/secure-foreign.after"
      cmp -- "$case_dir/secure-foreign.expected" "$case_dir/secure-foreign.after" ||
        fail "cleanup mutation changed foreign secure survivor: $mutation"
    fi
    if [ "$mutation" = cleanup-outer-marker-drift ]; then
      [ ! -e "$secure" ] && [ ! -L "$secure" ] ||
        fail "outer marker cleanup left authenticated secure state: $mutation"
    fi
  else
    [ ! -e "$remote" ] && [ ! -L "$remote" ] ||
      fail "receiver failure left remote staging: $mutation"
    [ ! -e "$secure" ] && [ ! -L "$secure" ] ||
      fail "receiver failure left secure staging: $mutation"
  fi
  grep -Fxq remote-run "$case_dir/events.log" ||
    fail "receiver failure did not execute the remote receiver: $mutation"
  grep -Fxq remote-cleanup "$case_dir/events.log" ||
    fail "receiver failure did not execute authenticated cleanup: $mutation"
  ! grep -Eq 'age-identity-access|docker-pull' "$case_dir/events.log" ||
    fail "receiver failure crossed the protected boundary: $mutation"
}

for receiver_mutation in base64-corruption base64-truncation checksum-drift mode-drift \
  type-drift link-drift lock-failure probe-failure signal-HUP signal-INT signal-TERM \
  cleanup-ambiguity cleanup-secure-marker-drift cleanup-secure-directory-drift \
  cleanup-outer-marker-drift; do
  receiver_failure "$receiver_mutation"
done
[ ! -e "$fixture/identity" ] && [ ! -e "$fixture/failure-identity" ] ||
  fail "age identity was not removed during restore cleanup"

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
  'assertions=age-v1.3.1-boundary,github-artifact-zip-ssh-boundaries,source-binding,foreign-survivor,'\
'database-media-equality,retention,rto,secret-free,injected-failure'
