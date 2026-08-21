#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILDER=$ROOT_DIR/scripts/build-test-promotion-evidence.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

SOURCE=0123456789abcdef0123456789abcdef01234567
TREE=89abcdef0123456789abcdef0123456789abcdef
ROOT_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PLATFORM_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PREDECESSOR_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
PREDECESSOR_ID=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
CANDIDATE_ID=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
PROOF=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
CONFIG=1111111111111111111111111111111111111111111111111111111111111111
RUNTIME=2222222222222222222222222222222222222222222222222222222222222222

expect_failure() {
  local marker=$1
  shift
  if "$@" >"$TMP/$marker.stdout" 2>"$TMP/$marker.stderr"; then
    echo "expected evidence rejection: $marker" >&2
    exit 1
  fi
  [ ! -s "$TMP/$marker.stdout" ] ||
    { echo "evidence rejection emitted stdout: $marker" >&2; exit 1; }
  [ -s "$TMP/$marker.stderr" ] ||
    { echo "evidence rejection omitted safe stderr: $marker" >&2; exit 1; }
}

jq -n \
  --arg source "$SOURCE" \
  --arg tree "$TREE" \
  --arg root "$ROOT_DIGEST" \
  --arg platform "$PLATFORM_DIGEST" \
  --arg predecessor "$PREDECESSOR_DIGEST" \
  --arg predecessorId "$PREDECESSOR_ID" \
  --arg candidateId "$CANDIDATE_ID" \
  --arg proof "$PROOF" \
  --arg config "$CONFIG" \
  --arg runtime "$RUNTIME" '
  def phase($digest;$id;$sourceSha;$treeId;$mode;$present;$disabled):
    {
      imageDigest:$digest,imageId:$id,sourceSha:$sourceSha,treeId:$treeId,
      version:"1.2.0",bootstrapProofSha256:$proof,
      configDigest:$config,runtimeDigest:$runtime,bootstrapMode:$mode,
      bootstrapControlPresent:$present,bootstrapDisabled:$disabled,
      healthy:true,demoZero:true
    };
  {
    schema:"meet-backend/test-promotion-evidence-input/v1",
    source:{
      sourceSha:$source,authoritySha:$source,treeId:$tree,version:"1.2.0"
    },
    image:{
      image:"ghcr.io/nickolaymamonov/meet-backend-v3",
      alias:("test-sha-"+$source),admissionMode:"published",
      rootDigest:$root,platformDigest:$platform,platform:"linux/amd64",
      labels:{
        source:"https://github.com/NickolayMamonov/meet-backend-v3",
        revision:$source,version:"1.2.0"
      },
      provenance:true,sbom:true,githubAttestation:true,
      referrerClosure:true,protectedStateEqual:true
    },
    deployment:{
      predecessor:phase(
        $predecessor;$predecessorId;
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        "legacy-not-applicable";false;null
      ),
      candidate:phase(
        $root;$candidateId;$source;$tree;"declared-false";true;true
      ),
      rollback:{
        required:true,attempted:true,verified:true,sameDigestRedeploy:false,
        restoredImageId:$predecessorId
      },
      final:phase(
        $root;$candidateId;$source;$tree;"declared-false";true;true
      ),
      runtime:{
        topologyVerified:true,hardeningVerified:true,volumesVerified:true,
        volumes:[
          "meet-production_postgres_data","meet-production_uploads_data"
        ],
        postgresWritablePrimary:true,nonIdleApplicationTransactions:0,
        smtpIdleSamples:[0,0]
      },
      probes:{
        meetings200Json:true,actuator404:true,httpRedirectHttps:true,
        adminMissing403:true,adminWrong403:true,
        adminAuthenticatedDisabled404:true,
        assets:{count:13,verified:true}
      }
    },
    control:{finalVerified:true,rollbackPolicySatisfied:true}
  }
' >"$TMP/input.json"

bash "$BUILDER" success --input "$TMP/input.json" --output "$TMP/evidence.json"
bash "$BUILDER" success --input "$TMP/input.json" \
  --output "$TMP/evidence-repeat.json"
cmp "$TMP/evidence.json" "$TMP/evidence-repeat.json"
[ "$(wc -l <"$TMP/evidence.json" | tr -d ' ')" -eq 1 ]
jq -e '
  .schema == "meet-backend/test-promotion-evidence/v1" and
  .kind == "success" and .evidenceSanitized == true and
  .artifactUploaded == false and .retentionAuthorized == false and
  .deployment.rollback.required == true and
  .deployment.rollback.verified == true
' "$TMP/evidence.json" >/dev/null

bash "$BUILDER" authorize-retention \
  --evidence "$TMP/evidence.json" \
  --artifact-uploaded true \
  --output "$TMP/retention.json"
jq -e '
  .schema == "meet-backend/test-promotion-retention/v1" and
  .artifactUploaded == true and .evidenceSanitized == true and
  .finalVerified == true and .rollbackPolicySatisfied == true and
  .retentionAuthorized == true and
  (.evidenceSha256 | test("^[0-9a-f]{64}$"))
' "$TMP/retention.json" >/dev/null
expect_failure upload-failed \
  bash "$BUILDER" authorize-retention --evidence "$TMP/evidence.json" \
  --artifact-uploaded false --output "$TMP/rejected.json"

jq '.unexpected = true' "$TMP/input.json" >"$TMP/unknown.json"
expect_failure unknown-field \
  bash "$BUILDER" success --input "$TMP/unknown.json" \
  --output "$TMP/rejected.json"

jq '.deployment.probes.responseBody = "safe-looking"' \
  "$TMP/input.json" >"$TMP/secret-field.json"
expect_failure secret-field \
  bash "$BUILDER" success --input "$TMP/secret-field.json" \
  --output "$TMP/rejected.json"

jq '.image.labels.source = "Authorization: Bearer hidden-value"' \
  "$TMP/input.json" >"$TMP/secret-value.json"
expect_failure secret-value \
  bash "$BUILDER" success --input "$TMP/secret-value.json" \
  --output "$TMP/rejected.json"
! grep -Fq hidden-value "$TMP/secret-value.stderr"

jq '.deployment.rollback.verified = false' \
  "$TMP/input.json" >"$TMP/unproven-rollback.json"
expect_failure unproven-rollback \
  bash "$BUILDER" success --input "$TMP/unproven-rollback.json" \
  --output "$TMP/rejected.json"

jq '
  .deployment.rollback = {
    required:false,attempted:false,verified:false,sameDigestRedeploy:true,
    restoredImageId:null
  } |
  .image.admissionMode = "reused"
' "$TMP/input.json" >"$TMP/same-digest.json"
bash "$BUILDER" success --input "$TMP/same-digest.json" \
  --output "$TMP/same-digest-evidence.json"
jq -e '
  .deployment.rollback.sameDigestRedeploy == true and
  .deployment.rollback.required == false and
  .deployment.rollback.verified == false
' "$TMP/same-digest-evidence.json" >/dev/null

bash "$BUILDER" incident \
  --stage rollback \
  --failure-class rollbackFailed \
  --mutation-started true \
  --rollback-attempted true \
  --rollback-verified false \
  --output "$TMP/incident.json"
jq -e '
  keys == [
    "artifactUploaded","evidenceSanitized","failureClass","kind",
    "mutationStarted","retentionAuthorized","rollbackAttempted",
    "rollbackVerified","schema","stage"
  ] and
  .schema == "meet-backend/test-promotion-incident/v1" and
  .kind == "incident" and .stage == "rollback" and
  .failureClass == "rollbackFailed" and .mutationStarted == true and
  .rollbackAttempted == true and .rollbackVerified == false and
  .evidenceSanitized == true and .artifactUploaded == false and
  .retentionAuthorized == false
' "$TMP/incident.json" >/dev/null

printf 'ADMIN_KEY=must-not-be-retained\n' >"$TMP/raw.log"
if bash "$BUILDER" success --input "$TMP/secret-value.json" \
  --output "$TMP/selected.json" >/dev/null 2>"$TMP/primary.err"; then
  echo "secret-bearing primary evidence was accepted" >&2
  exit 1
else
  bash "$BUILDER" incident \
    --stage evidence \
    --failure-class sanitizationFailed \
    --mutation-started true \
    --rollback-attempted true \
    --rollback-verified true \
    --output "$TMP/selected.json"
fi
bash "$BUILDER" incident \
  --stage evidence \
  --failure-class sanitizationFailed \
  --mutation-started true \
  --rollback-attempted true \
  --rollback-verified true \
  --output "$TMP/selected-repeat.json"
cmp "$TMP/selected.json" "$TMP/selected-repeat.json"
! grep -Fq must-not-be-retained "$TMP/selected.json"
expect_failure incident-retention \
  bash "$BUILDER" authorize-retention --evidence "$TMP/incident.json" \
  --artifact-uploaded true --output "$TMP/rejected.json"
expect_failure impossible-rollback \
  bash "$BUILDER" incident \
  --stage rollback \
  --failure-class rollbackFailed \
  --mutation-started false \
  --rollback-attempted true \
  --rollback-verified false \
  --output "$TMP/rejected.json"

echo "test promotion evidence fixtures passed"
