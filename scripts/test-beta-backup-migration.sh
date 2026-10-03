#!/usr/bin/env bash
set -euo pipefail

fail() { echo "test-beta-backup-migration.sh: $1" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export BETA_BACKUP_TEST_FIXTURE=true
tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM

source_dir="$tmp/source"
destination_dir="$tmp/destination"
storage_root="$tmp/storage"
restore_output="$tmp/restore-output"
proof="$tmp/migration-proof.json"
mkdir -p "$source_dir" "$destination_dir" "$storage_root"
printf 'encrypted database fixture\n' >"$source_dir/postgres.dump.age"
printf 'encrypted uploads fixture\n' >"$source_dir/uploads.tar.gz.age"
source_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
restore_revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
capture_command=$(printf reviewed-capture | sha256sum | awk '{print $1}')
evidence_digest=$(printf reviewed-evidence | sha256sum | awk '{print $1}')
contract_digest=$(printf reviewed-contract | sha256sum | awk '{print $1}')
proof_digest=$(printf reviewed-proof | sha256sum | awk '{print $1}')
runtime_digest=$(printf reviewed-runtime | sha256sum | awk '{print $1}')
cat >"$source_dir/recovery-point.json" <<EOF
{"capture":{"capturedAt":1790000000,"sourceRevision":"$source_revision"},"captureCommandDigest":"$capture_command","captureEvidenceDigest":"$evidence_digest","captureRuntimeDigest":"$runtime_digest","contractDigest":"$contract_digest","pointId":"slot-1790000000","proofDigest":"$proof_digest","runtimeRevision":"$restore_revision","schema":"meet-backend/beta-recovery-point/v2","slotId":"1790000000"}
EOF
cp -- "$source_dir/recovery-point.json" "$tmp/original-manifest.json"
cat >"$tmp/restore-command.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
point='' proof='' output='' capture='' restore=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --point-dir) point=$2; shift 2 ;;
    --identity-file) identity=$2; shift 2 ;;
    --output-dir) output=$2; shift 2 ;;
    --proof-output) proof=$2; shift 2 ;;
    --capture-revision) capture=$2; shift 2 ;;
    --restore-revision) restore=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
[ -s "$identity" ] && [ -d "$output" ] && [ -z "$(find "$output" -mindepth 1 -print -quit)" ]
descriptor=$(jq -cS 'del(.descriptorDigest)' "$point/point.json" |
  sha256sum | awk '{print $1}')
captured=$(jq -er '.capture.capturedAt' "$point/recovery-point.json")
fingerprint=$(printf isolated | sha256sum | awk '{print $1}')
jq -cnS --arg capture "$capture" --arg restore "$restore" \
  --arg descriptor "$descriptor" --argjson captured "$captured" \
  --arg fingerprint "$fingerprint" \
  '{schema:"meet-backend/beta-backup-migration-proof/v1",
    captureRevision:$capture,restoreRevision:$restore,capturedAt:$captured,
    pointDescriptorDigest:$descriptor,identityCustody:"restore-only",
    isolated:true,databaseProbe:true,mediaProbe:true,cleanup:true,
    preFingerprint:$fingerprint,postFingerprint:$fingerprint}' >"$proof"
EOF
chmod 755 "$tmp/restore-command.sh"
printf 'migration identity\n' >"$tmp/identity"
mkdir -p "$tmp/api/repos/test/repository/actions/runs/123" \
  "$tmp/api/repos/test/repository/actions/artifacts/456"
cat >"$tmp/api/run.json" <<EOF
{"id":123,"repository":{"full_name":"test/repository"},"path":".github/workflows/prove-beta-backup-restore.yml",
 "head_sha":"$source_revision","status":"completed","conclusion":"success"}
EOF
cat >"$tmp/api/artifact.json" <<'EOF'
{"id":456,"expired":false,"workflow_run":{"id":123},"size_in_bytes":1,
 "digest":"REPLACE_DIGEST","created_at":"2026-09-27T00:00:00Z","expires_at":"2026-10-27T00:00:00Z"}
EOF
cat >"$tmp/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
headers=''
write_out=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --dump-header) headers=$2; shift 2 ;;
    --write-out) write_out=$2; shift 2 ;;
    --max-redirs) shift 2 ;;
    --location|--fail|--silent|--show-error|--connect-timeout|--max-time|--max-filesize|-H)
      [ "$1" = --location ] || [ "$1" = --fail ] || [ "$1" = --silent ] ||
        [ "$1" = --show-error ] || { [ "$#" -ge 2 ] && shift; }
      shift ;;
    *) url=$1; shift ;;
  esac
done
if [ -n "$headers" ]; then
  printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
fi
response=''
case "$url" in
  */actions/runs/123) response=$CURL_FIXTURE/run.json ;;
  */actions/artifacts/456) response=$CURL_FIXTURE/artifact.json ;;
  */actions/artifacts/456/zip) response=$CURL_FIXTURE/source.zip ;;
  *) exit 1 ;;
esac
if [ -n "$output" ]; then
  cp -- "$response" "$output"
else
  cat "$response"
fi
[ -z "$write_out" ] || printf '200'
EOF
chmod 755 "$tmp/curl"
mkdir -p "$tmp/api/source-files" "$tmp/bin"
cp -- "$source_dir"/* "$tmp/api/source-files/"
printf 'authenticated-source-artifact-fixture\n' >"$tmp/api/source.zip"
cat >"$tmp/bin/unzip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -d ]; then
    destination=$2
    shift 2
  else
    shift
  fi
done
[ -n "$destination" ]
mkdir -p "$destination"
cp -- "$CURL_FIXTURE"/source-files/* "$destination/"
EOF
chmod 755 "$tmp/bin/unzip"
zip_digest=$(sha256sum "$tmp/api/source.zip" | awk '{print $1}')
sed -i "s/REPLACE_DIGEST/sha256:$zip_digest/" "$tmp/api/artifact.json"
export CURL_FIXTURE="$tmp/api"
export GITHUB_TOKEN=fixture
export GITHUB_REPOSITORY=test/repository
export GITHUB_API_URL=https://api.github.com
manifest_before=$(sha256sum "$source_dir/recovery-point.json" | awk '{print $1}')
db_before=$(sha256sum "$source_dir/postgres.dump.age" | awk '{print $1}')
media_before=$(sha256sum "$source_dir/uploads.tar.gz.age" | awk '{print $1}')
if GITHUB_API_URL=https://api.example.test PATH="$tmp:$tmp/bin:$PATH" \
  "$root/scripts/migrate-beta-backup-artifact.sh" \
  --source "$source_dir" --destination "$destination_dir" \
  --manifest "$source_dir/recovery-point.json" --storage-root "$storage_root" \
  --restore-command "$tmp/restore-command.sh" --restore-output "$restore_output" \
  --identity-file "$tmp/identity" --capture-revision "$source_revision" \
  --restore-revision "$restore_revision" --proof-output "$proof" \
  --source-artifact-id 456 --source-run-id 123 >/dev/null 2>&1; then
  fail "migration accepted a non-GitHub API origin"
fi
printf 'migration identity\n' >"$tmp/identity"
PATH="$tmp:$tmp/bin:$PATH" "$root/scripts/migrate-beta-backup-artifact.sh" \
  --source "$source_dir" --destination "$destination_dir" \
  --manifest "$source_dir/recovery-point.json" --storage-root "$storage_root" \
  --restore-command "$tmp/restore-command.sh" --restore-output "$restore_output" \
  --identity-file "$tmp/identity" --capture-revision "$source_revision" \
  --restore-revision "$restore_revision" --proof-output "$proof" \
  --source-artifact-id 456 --source-run-id 123 >/dev/null ||
  fail "destination restore migration was rejected"
cmp -- "$tmp/original-manifest.json" "$source_dir/recovery-point.json" ||
  fail "source manifest changed during migration"
[ ! -e "$tmp/identity" ] || fail "restore identity was not removed after migration"
[ "$manifest_before" = "$(sha256sum "$source_dir/recovery-point.json" | awk '{print $1}')" ] &&
  [ "$db_before" = "$(sha256sum "$source_dir/postgres.dump.age" | awk '{print $1}')" ] &&
  [ "$media_before" = "$(sha256sum "$source_dir/uploads.tar.gz.age" | awk '{print $1}')" ] ||
  fail "source ciphertext/provenance changed during migration"
jq -e '.schema=="meet-backend/beta-backup-migration-proof/v1" and
  .pointDescriptorDigest and .preFingerprint == .postFingerprint' "$proof" >/dev/null ||
  fail "migration proof was not generated by restore"
provider_count=$("$root/scripts/run-beta-backup-storage.sh" provider-list \
  --storage-root "$storage_root" | jq 'length')
[ "$provider_count" -eq 2 ] || fail "versioned provider inventory is incomplete"

# Genuine manual v1 import: the source bytes and manifest remain untouched,
# while migration publishes a storage-neutral v2 point and preserves the
# authenticated proof pair at the destination.
v1_source="$tmp/source-v1"
v1_destination="$tmp/destination-v1"
v1_restore_output="$tmp/restore-output-v1"
v1_proof="$tmp/migration-proof-v1.json"
mkdir -p "$v1_source" "$v1_destination"
printf 'manual v1 database ciphertext\n' >"$v1_source/postgres.dump.age"
printf 'manual v1 uploads ciphertext\n' >"$v1_source/uploads.tar.gz.age"
v1_source_revision=cccccccccccccccccccccccccccccccccccccccc
v1_db_sha=$(sha256sum "$v1_source/postgres.dump.age" | awk '{print $1}')
v1_media_sha=$(sha256sum "$v1_source/uploads.tar.gz.age" | awk '{print $1}')
v1_db_proof="$tmp/v1-database-proof.json"
v1_media_proof="$tmp/v1-media-proof.json"
v1_runtime="$tmp/v1-runtime.json"
jq -cn '
  def obj($keys): reduce $keys[] as $key ({}; .[$key]=0);
  {schema:"meet-backend/closed-beta-database-proof/v1",valid:true,
   authStorage:obj(["blankIdentityRows","duplicateIdentityRows","identityUserOrphans",
     "invalidIdentityRows","invalidOtpRows","invalidRefreshHashes","legacyPlaintextColumnsAbsent"]),
   demoCatalog:obj(["matchingStateRows","ownershipKeyViolations","ownershipTypeViolations",
     "stateCoherent","stateRows"]),
   flyway:{orderedV1ToV9:true,successfulVersionCount:9},
   mediaReferences:obj(["managedReferences","nullRequiredReferences","unsafeManagedReferences"]),
   relationships:obj(["adBlockCommunities","adBlockUsers","communitySubscribers","communityTags",
     "duplicateEdgeRows","duplicateSourceKeys","meetingParticipants","meetingTags","orphanRows",
     "userInterests"]),
   rows:obj(["ad_block_communities","ad_block_users","ad_blocks","auth_identities","communities",
     "community_subscribers","community_tags","demo_catalog_state","ingestion_runs",
     "meeting_participants","meeting_tags","meetings","otp_codes","otp_rate_limit_attempts",
     "refresh_tokens","tags","user_interests","user_social_media","users"]),
   schemaChecks:obj(["exactRequiredTableCount","legacyPlaintextColumnsAbsent",
     "requiredConstraints","requiredIndexes","requiredTableCount","requiredTablesAndColumns",
     "validatedConstraints"]),
   validity:obj(["auth","constraints","demoCatalog","flyway","indexes","mediaReferences",
     "relationships","schema","tables"])}
' >"$v1_db_proof"
v1_media_digest=$(printf 'manual-v1-media-proof\n' | sha256sum | awk '{print $1}')
jq -cn --arg digest "$v1_media_digest" \
  '{schema:"meet-backend/beta-recovery-media-proof/v1",files:1,bytes:1,
    canonicalDigest:$digest,referencesTotal:1,referencesResolved:true}' >"$v1_media_proof"
v1_runtime_hash=$(printf 'manual-v1-runtime\n' | sha256sum | awk '{print $1}')
jq -cn --arg hash "$v1_runtime_hash" '
  {schema:"meet-backend/test-vps-recovery-runtime/v1",healthy:true,
   runtime:{imageId:"sha256:manual-v1",configHash:$hash,health:"healthy",uploadsMount:"volume"},
   https:{meetingsStatus:"200",actuatorStatus:"404",httpRedirectHttps:true,meetingsJson:true}}
' >"$v1_runtime"
v1_manifest="$v1_source/recovery-point.json"
v1_manifest_source_sha=$(printf 'manual-v1-manifest\n' | sha256sum | awk '{print $1}')
jq -cn --arg source "$v1_source_revision" \
  --arg dbsha "$v1_db_sha" --arg mediasha "$v1_media_sha" \
  --arg dbproof "$(jq -cS . "$v1_db_proof")" \
  --arg mediaproof "$(jq -cS . "$v1_media_proof")" \
  --arg runtime "$(jq -cS . "$v1_runtime")" \
  --argjson dbsize "$(wc -c <"$v1_source/postgres.dump.age")" \
  --argjson mediasize "$(wc -c <"$v1_source/uploads.tar.gz.age")" \
  --arg mediaDigest "$v1_media_digest" \
  --arg contract "$v1_manifest_source_sha" '
  {schema:"meet-backend/beta-recovery-manifest/v1",recoveryId:"recovery-v1",
   repository:"test/repository",sourceSha:$source,runId:123,artifactId:null,
   artifactName:"beta-recovery-recovery-v1-123",retentionDays:30,
   capturedAt:"2026-08-27T19:00:00Z",recoveryPointTime:"2026-08-27T19:00:00Z",
   observedAgeSeconds:120,
   contracts:{tooling:$contract,workflow:$contract,database:$contract,media:$contract},
   artifactFiles:[
     {path:"postgres.dump.age",size:$dbsize,sha256:$dbsha},
     {path:"uploads.tar.gz.age",size:$mediasize,sha256:$mediasha}],
   databaseProof:($dbproof|fromjson),mediaProof:($mediaproof|fromjson),
   captureRuntime:($runtime|fromjson),
   source:{postgresDatabaseBytes:1,
     uploads:{files:1,bytes:1,digest:$mediaDigest},
     ciphertexts:{
       database:{name:"postgres.dump.age",size:$dbsize,sha256:$dbsha},
       uploads:{name:"uploads.tar.gz.age",size:$mediasize,sha256:$mediasha}}}}
' >"$v1_manifest"
cp -- "$v1_manifest" "$tmp/original-v1-manifest.json"
rm -rf -- "$CURL_FIXTURE/source-files"
mkdir -p "$CURL_FIXTURE/source-files"
cp -- "$v1_source/"* "$CURL_FIXTURE/source-files/"
printf 'authenticated-v1-source-artifact\n' >"$CURL_FIXTURE/source.zip"
v1_zip_digest=$(sha256sum "$CURL_FIXTURE/source.zip" | awk '{print $1}')
sed -i "s/\"head_sha\":\"[0-9a-f]*\"/\"head_sha\":\"$v1_source_revision\"/" \
  "$CURL_FIXTURE/run.json"
sed -i "s/sha256:[0-9a-f]*/sha256:$v1_zip_digest/" \
  "$CURL_FIXTURE/artifact.json"
printf 'v1 migration identity\n' >"$tmp/identity-v1"
PATH="$tmp:$tmp/bin:$PATH" "$root/scripts/migrate-beta-backup-artifact.sh" \
  --source "$v1_source" --destination "$v1_destination" \
  --manifest "$v1_manifest" --storage-root "$storage_root" \
  --restore-command "$tmp/restore-command.sh" --restore-output "$v1_restore_output" \
  --identity-file "$tmp/identity-v1" --capture-revision "$v1_source_revision" \
  --restore-revision "$restore_revision" --proof-output "$v1_proof" \
  --source-artifact-id 456 --source-run-id 123 >/dev/null ||
  fail "genuine v1 migration was rejected"
cmp -- "$tmp/original-v1-manifest.json" "$v1_manifest" ||
  fail "v1 source manifest changed during migration"
jq -e --arg evidence "$(sha256sum "$v1_manifest" | awk '{print $1}')" '
  .schema=="meet-backend/beta-recovery-point/v2" and
  .pointId=="recovery-v1" and .captureEvidenceDigest==$evidence
' "$storage_root/points/recovery-v1/recovery-point.json" >/dev/null ||
  fail "v1 migration did not publish a source-bound v2 manifest"
[ -s "$storage_root/points/recovery-v1/capture-database-proof.json" ] &&
  [ -s "$storage_root/points/recovery-v1/capture-media-proof.json" ] ||
  fail "v1 proof pair was not retained at the destination"
head_commit_line=$(grep -n 'beta_storage_remote_commit_capture_head' \
  "$root/scripts/migrate-beta-backup-artifact.sh" | tail -1 | cut -d: -f1)
source_check_line=$(grep -n 'source_changed_during_migration' \
  "$root/scripts/migrate-beta-backup-artifact.sh" | tail -1 | cut -d: -f1)
[ "$source_check_line" -lt "$head_commit_line" ] ||
  fail "remote capture head is committed before final source integrity checks"

printf 'test-beta-backup-migration.sh: passed\n'
