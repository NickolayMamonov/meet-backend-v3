#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --point-dir DIR --identity-file PATH --output-dir DIR --capture-revision SHA --restore-revision SHA --protection-digest DIGEST --proof-output PATH" >&2
  exit 2
}

point='' identity='' output='' capture_revision='' restore_revision=''
protection_digest='' proof_output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --point-dir) [ "$#" -ge 2 ] || usage; point=$2; shift 2 ;;
    --identity-file) [ "$#" -ge 2 ] || usage; identity=$2; shift 2 ;;
    --output-dir) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    --capture-revision) [ "$#" -ge 2 ] || usage; capture_revision=$2; shift 2 ;;
    --restore-revision) [ "$#" -ge 2 ] || usage; restore_revision=$2; shift 2 ;;
    --protection-digest) [ "$#" -ge 2 ] || usage; protection_digest=$2; shift 2 ;;
    --proof-output) [ "$#" -ge 2 ] || usage; proof_output=$2; shift 2 ;;
    *) usage ;;
  esac
done
for path in "$point" "$identity" "$output" "$proof_output"; do
  [[ "$path" = /* && "$path" != *..* && "$path" != *$'\n'* ]] || usage
done
[[ "$capture_revision" =~ ^[0-9a-f]{40}$ && "$restore_revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$protection_digest" =~ ^[0-9a-f]{64}$ ]] || usage
[ -d "$point" ] && [ ! -L "$point" ] || usage
[ -f "$point/recovery-point.json" ] && [ ! -L "$point/recovery-point.json" ] || usage
[ -f "$point/postgres.dump.age" ] && [ ! -L "$point/postgres.dump.age" ] || usage
[ -f "$point/uploads.tar.gz.age" ] && [ ! -L "$point/uploads.tar.gz.age" ] || usage
[ -f "$point/capture-database-proof.json" ] && [ ! -L "$point/capture-database-proof.json" ] || usage
[ -f "$point/capture-media-proof.json" ] && [ ! -L "$point/capture-media-proof.json" ] || usage

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -rf -- "$tmp" || status=1
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
artifact="$tmp/artifact"
mkdir -m 700 "$artifact"
install -m 600 "$point/postgres.dump.age" "$artifact/postgres.dump.age"
install -m 600 "$point/uploads.tar.gz.age" "$artifact/uploads.tar.gz.age"

captured=$(jq -er '.capture.capturedAt' "$point/recovery-point.json")
source_revision=$(jq -er '.capture.sourceRevision' "$point/recovery-point.json")
[ "$capture_revision" = "$source_revision" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:capture_revision_mismatch' >&2
  exit 1
}
contract_digest=$(jq -er '.contractDigest' "$point/recovery-point.json")
proof_contract_digest=$(jq -er '.proofDigest' "$point/recovery-point.json")
database_proof="$point/capture-database-proof.json"
media_proof="$point/capture-media-proof.json"
db_size=$(wc -c <"$artifact/postgres.dump.age" | tr -d '[:space:]')
media_size=$(wc -c <"$artifact/uploads.tar.gz.age" | tr -d '[:space:]')
db_sha=$(sha256sum "$artifact/postgres.dump.age" | awk '{print $1}')
media_sha=$(sha256sum "$artifact/uploads.tar.gz.age" | awk '{print $1}')
media_files=$(jq -er '.files' "$media_proof")
media_bytes=$(jq -er '.bytes' "$media_proof")
media_digest=$(jq -er '.canonicalDigest' "$media_proof")
db_proof_digest=$(sha256sum "$database_proof" | awk '{print $1}')
media_proof_digest=$(sha256sum "$media_proof" | awk '{print $1}')
workflow_digest=$(sha256sum "$script_dir/../.github/workflows/prove-beta-backup-restore.yml" |
  awk '{print $1}')
tooling_digest=$(for file in \
  scripts/authorize-beta-recovery.sh scripts/run-beta-recovery-capture-stage.sh \
  scripts/run-beta-recovery-capture.sh scripts/run-beta-recovery-restore.sh \
  scripts/build-beta-recovery-evidence.sh scripts/run-beta-recovery-remote-probe.sh \
  scripts/production-compose.sh scripts/probe-test-vps-recovery-runtime.sh \
  scripts/backup-production.sh scripts/beta-recovery-database-proof.sql \
  scripts/beta-recovery-media-proof.sh scripts/install-beta-recovery-age.sh \
  scripts/materialize-beta-recovery-known-hosts.sh \
  scripts/validate-beta-recovery-artifact-retention.sh scripts/admit-beta-recovery-artifact.sh; do
  sha256sum "$script_dir/../$file"
done | sort | sha256sum | awk '{print $1}')
manifest="$artifact/recovery-point.json"
jq -cnS --arg id "recurring-$captured" --arg source "$source_revision" \
  --arg repository "${GITHUB_REPOSITORY:-NickolayMamonov/meet-backend-v3}" \
  --arg tooling "$tooling_digest" --arg workflow "$workflow_digest" \
  --arg database "$contract_digest" --arg media "$proof_contract_digest" \
  --arg captured "$(date -u -d "@$captured" +%Y-%m-%dT%H:%M:%SZ)" \
  --arg dbsha "$db_sha" --arg mediasha "$media_sha" \
  --arg dbproof "$db_proof_digest" --arg mediaproof "$media_proof_digest" \
  --argjson run "$captured" --argjson dbsize "$db_size" --argjson mediasize "$media_size" \
  --argjson files "$media_files" --argjson bytes "$media_bytes" --arg digest "$media_digest" \
  --slurpfile databaseProof "$database_proof" --slurpfile mediaProof "$media_proof" '
  {schema:"meet-backend/beta-recovery-manifest/v1",artifactId:null,
   artifactName:("beta-recovery-recurring-"+($run|tostring)),capturedAt:$captured,
   captureRuntime:{revision:$source},contracts:{database:$database,media:$media,
     tooling:$tooling,workflow:$workflow},databaseProof:$databaseProof[0],
   mediaProof:$mediaProof[0],observedAgeSeconds:0,recoveryId:("recurring-"+($run|tostring)),
   recoveryPointTime:$captured,repository:$repository,retentionDays:30,runId:$run,
   sourceSha:$source,
   artifactFiles:[
     {path:"postgres.dump.age",size:$dbsize,sha256:$dbsha},
     {path:"uploads.tar.gz.age",size:$mediasize,sha256:$mediasha}],
   source:{postgresDatabaseBytes:0,
     uploads:{files:$files,bytes:$bytes,digest:$digest},
     ciphertexts:{
       database:{name:"postgres.dump.age",size:$dbsize,sha256:$dbsha},
       uploads:{name:"uploads.tar.gz.age",size:$mediasize,sha256:$mediasha}}}}
  ' >"$manifest"
chmod 600 "$manifest"

core_output="$tmp/core-output"
mkdir -m 700 "$core_output"
"$script_dir/run-beta-recovery-restore.sh" \
  --artifact-dir "$artifact" --recovery-id "recurring-$captured" \
  --output-dir "$core_output" --identity "$identity" \
  --sql-proof "$script_dir/beta-recovery-database-proof.sql" \
  --media-script "$script_dir/beta-recovery-media-proof.sh" \
  --source-sha "$source_revision" \
  --repository "${GITHUB_REPOSITORY:-NickolayMamonov/meet-backend-v3}" \
  --tooling-digest "$tooling_digest" --workflow-digest "$workflow_digest" \
  --database-digest "$contract_digest" --media-digest "$proof_contract_digest" \
  --temp-root "$tmp"
test -s "$core_output/restored-database-proof.json"
test -s "$core_output/restored-media-proof.json"
fingerprint=$(sha256sum "$core_output/restored-database-proof.json" \
  "$core_output/restored-media-proof.json" | sha256sum | awk '{print $1}')
descriptor_digest=$(sha256sum "$point/point.json" | awk '{print $1}')
captured=$(jq -er '.capture.capturedAt' "$point/recovery-point.json")
jq -cnS --arg capture "$capture_revision" --arg restore "$restore_revision" \
  --arg descriptor "$descriptor_digest" --arg protection "$protection_digest" \
  --arg fingerprint "$fingerprint" --argjson captured "$captured" \
  '{schema:"meet-backend/beta-recurring-restore-proof/v2",
    captureRevision:$capture,restoreRevision:$restore,capturedAt:$captured,
    pointDescriptorDigest:$descriptor,protectionDigest:$protection,
    identityCustody:"restore-only",isolated:true,databaseProbe:true,
    mediaProbe:true,cleanup:true,preFingerprint:$fingerprint,
    postFingerprint:$fingerprint}' >"$proof_output"
chmod 600 "$proof_output"
