#!/usr/bin/env bash
set -euo pipefail

fail() { echo "test-beta-backup-migration.sh: $1" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
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
cat >"$source_dir/recovery-point.json" <<EOF
{"capture":{"capturedAt":1790000000,"sourceRevision":"$source_revision"},"captureCommandDigest":"$capture_command","captureEvidenceDigest":"$evidence_digest","contractDigest":"$contract_digest","pointId":"slot-1790000000","proofDigest":"$proof_digest","runtimeRevision":"$restore_revision","schema":"meet-backend/beta-recovery-point/v2","slotId":"1790000000"}
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
printf 'test-beta-backup-migration.sh: passed\n'
