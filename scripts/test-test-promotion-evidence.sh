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
CONTRACT=$ROOT_DIR/scripts/test-vps-admission-contract.json
RECOVERY_PROOF=$(jq -r '.populated.recoveryProof.sha256' "$CONTRACT")
STABLE_PROOF=$(jq -r '.populated.stableProof.sha256' "$CONTRACT")
POPULATED_MEETINGS=$(jq -r '.populated.roots.meetings' "$CONTRACT")
POPULATED_COMMUNITIES=$(jq -r '.populated.roots.communities' "$CONTRACT")
POPULATED_TAGS=$(jq -r '.populated.roots.tags' "$CONTRACT")
POPULATED_ADS=$(jq -r '.populated.roots.adBlocks' "$CONTRACT")
POPULATED_PUBLIC=9999999999999999999999999999999999999999999999999999999999999999
POPULATED_STATE=8888888888888888888888888888888888888888888888888888888888888888

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
  def probe($digest;$id;$sourceSha;$phase;$runtimeHash):
    {
      schema:"meet-backend/test-vps-zero-state-probe/v2",
      phase:$phase,image:$digest,imageId:$id,sourceSha:$sourceSha,
      version:"1.2.0",runtimeConfigHash:$runtimeHash,
      admission:{mode:"empty-closed",stateSha256:null},
      runtime:{
        containerHealthy:true,hardeningVerified:true,topologyVerified:true,
        volumesVerified:true,postgresWritablePrimary:true,
        nonIdleApplicationTransactions:0,smtpIdleSamples:[0,0],
        volumes:[{type:"volume",source:"meet-production_uploads_data",
          destination:"/data/uploads",read_only:false,propagation:""}],
        postgresVolumes:[{type:"volume",source:"meet-production_postgres_data",
          destination:"/var/lib/postgresql/data",read_only:false,propagation:""}],
        ports:[],networks:[]
      },
      database:{
        tables:{
          ad_block_communities:0,ad_block_users:0,ad_blocks:0,
          communities:0,community_subscribers:0,community_tags:0,
          demo_catalog_state:0,meeting_participants:0,meeting_tags:0,
          meetings:0,tags:0,user_interests:0,user_social_media:0,users:0
        },totalRows:0
      },
      http:{
        actuatorStatus:404,adminAuthenticatedDisabled404:true,
        adminBlankDisabled403:false,adminKeyConfigured:true,
        adminMissingStatus:403,adminWrongStatus:403,assetsCount:13,
        assetsVerified:true,httpRedirectHttps:true,meetingsCount:0,
        meetingsJson:true,meetingsStatus:200
      },
      zeroStateObserved:true,zeroState:"closed"
    };
  def phase($digest;$id;$sourceSha;$treeId;$mode;$present;$disabled;$probePhase):
    probe($digest;$id;$sourceSha;$probePhase;$runtime) as $observed |
    {
      imageDigest:$digest,imageId:$id,sourceSha:$sourceSha,treeId:$treeId,
      version:"1.2.0",bootstrapProofSha256:$proof,
      configDigest:$config,runtimeDigest:$runtime,bootstrapMode:$mode,
      bootstrapControlPresent:$present,bootstrapDisabled:$disabled,
      healthy:$observed.runtime.containerHealthy,
      admissionMode:$observed.admission.mode,
      admissionStateSha256:$observed.admission.stateSha256,
      zeroStateProbe:$observed
    };
  {
    schema:"meet-backend/test-promotion-evidence-input/v2",
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
        "legacy-not-applicable";false;null;"predecessor"
      ),
      candidate:phase(
        $root;$candidateId;$source;$tree;"declared-false";true;true;"candidate"
      ),
      rollback:{
        required:true,attempted:true,verified:true,sameImageRedeploy:false,
        predecessor:{
          stateMode:"empty-closed",stateSha256:null,imageReference:$predecessor,
          imageId:$predecessorId,revision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          version:"1.2.0",runtimeConfigHash:$runtime,
          bootstrapProofSha256:$proof,bootstrapMode:"legacy-not-applicable",
          bootstrapControlPresent:false,bootstrapDisabled:null
        },
        restored:{
          stateMode:"empty-closed",stateSha256:null,imageReference:$predecessor,
          imageId:$predecessorId,revision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          version:"1.2.0",runtimeConfigHash:$runtime,
          bootstrapProofSha256:$proof,bootstrapMode:"legacy-not-applicable",
          bootstrapControlPresent:false,bootstrapDisabled:null
        }
      },
      final:phase(
        $root;$candidateId;$source;$tree;"declared-false";true;true;"final"
      ),
      runtime:{
        topologyVerified:true,hardeningVerified:true,volumesVerified:true,
        volumes:["meet-production_postgres_data","meet-production_uploads_data"],
        postgresWritablePrimary:true,nonIdleApplicationTransactions:0,
        smtpIdleSamples:[0,0]
      },
      probes:{
        meetings200Json:true,actuator404:true,httpRedirectHttps:true,
        adminMissing403:true,adminWrong403:true,
        adminKeyConfigured:true,adminAuthenticatedDisabled404:true,
        adminBlankDisabled403:false,
        assets:{count:13,verified:true}
      }
    },
    control:{finalVerified:true,rollbackPolicySatisfied:true}
  }
' >"$TMP/input.json"

# The populated fixture is derived from the same v2 phase graph so the test
# proves both explicit admission branches without maintaining a second schema.
jq \
  --arg recovery "$RECOVERY_PROOF" \
  --arg stable "$STABLE_PROOF" \
  --arg public "$POPULATED_PUBLIC" \
  --arg state "$POPULATED_STATE" \
  --argjson meetings "$POPULATED_MEETINGS" \
  --argjson communities "$POPULATED_COMMUNITIES" \
  --argjson tags "$POPULATED_TAGS" \
  --argjson ads "$POPULATED_ADS" '
  def populated_probe:
    .admission = {
      mode:"closed-beta-demo",stateSha256:$state,
      catalogName:"closed-beta-demo",manifestVersion:"2026-08-15.v1",
      recoveryProofSha256:$recovery,stableProofSha256:$stable,
      publicProjectionSha256:$public,
      routes:{
        meetings:{status:200,schemaValid:true,count:$meetings,
          projectionSha256:$public,equal:true},
        recommendedCommunities:{status:200,schemaValid:true,count:$communities,
          projectionSha256:$public,equal:true},
        tags:{status:200,schemaValid:true,count:$tags,
          projectionSha256:$public,equal:true},
        ads:{status:200,schemaValid:true,count:$ads,
          projectionSha256:$public,equal:true}
      }
    } |
    .database.tables += {
      tags:$tags,users:6,communities:$communities,meetings:$meetings,
      ad_blocks:$ads,user_interests:12,community_tags:7,
      community_subscribers:9,meeting_tags:12,meeting_participants:18,
      ad_block_communities:3,ad_block_users:4
    } |
    .database.totalRows = ([.database.tables[]] | add) |
    .http.meetingsCount = $meetings;
  def populated_phase:
    .zeroStateProbe |= populated_probe |
    .admissionMode = "closed-beta-demo" |
    .admissionStateSha256 = $state;
  .deployment.predecessor |= populated_phase |
  .deployment.candidate |= populated_phase |
  .deployment.final |= populated_phase |
  .deployment.rollback.predecessor.stateMode = "closed-beta-demo" |
  .deployment.rollback.predecessor.stateSha256 = $state |
  .deployment.rollback.restored.stateMode = "closed-beta-demo" |
  .deployment.rollback.restored.stateSha256 = $state
' "$TMP/input.json" >"$TMP/populated-input.json"

bash "$BUILDER" success --input "$TMP/input.json" --output "$TMP/evidence.json"
bash "$BUILDER" success --input "$TMP/input.json" \
  --output "$TMP/evidence-repeat.json"
cmp "$TMP/evidence.json" "$TMP/evidence-repeat.json"
[ "$(wc -l <"$TMP/evidence.json" | tr -d ' ')" -eq 1 ]
jq -e '
  .schema == "meet-backend/test-promotion-evidence/v2" and
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
  .schema == "meet-backend/test-promotion-retention/v2" and
  .artifactUploaded == true and .evidenceSanitized == true and
  .finalVerified == true and .rollbackPolicySatisfied == true and
  .retentionAuthorized == true and
  (.evidenceSha256 | test("^[0-9a-f]{64}$"))
' "$TMP/retention.json" >/dev/null

bash "$BUILDER" success --input "$TMP/populated-input.json" \
  --output "$TMP/populated-evidence.json"
jq -e --argjson meetings "$POPULATED_MEETINGS" '
  .schema == "meet-backend/test-promotion-evidence/v2" and
  .deployment.predecessor.admissionMode == "closed-beta-demo" and
  .deployment.candidate.admissionMode == "closed-beta-demo" and
  .deployment.final.admissionMode == "closed-beta-demo" and
  .deployment.probes.meetings200Json == true and
  .deployment.final.zeroStateProbe.http.meetingsCount == $meetings
' "$TMP/populated-evidence.json" >/dev/null
bash "$BUILDER" authorize-retention \
  --evidence "$TMP/populated-evidence.json" \
  --artifact-uploaded true \
  --output "$TMP/populated-retention.json"
jq -e '.retentionAuthorized == true' "$TMP/populated-retention.json" >/dev/null

jq '
  .deployment.predecessor.zeroStateProbe.admission = {
    mode:"empty-closed",stateSha256:null
  } |
  .deployment.predecessor.zeroStateProbe.database.tables |=
    with_entries(.value = 0) |
  .deployment.predecessor.zeroStateProbe.database.totalRows = 0 |
  .deployment.predecessor.zeroStateProbe.http.meetingsCount = 0 |
  .deployment.predecessor.admissionMode = "empty-closed" |
  .deployment.predecessor.admissionStateSha256 = null
' "$TMP/populated-input.json" >"$TMP/mixed-mode.json"
expect_failure mixed-mode \
  bash "$BUILDER" success --input "$TMP/mixed-mode.json" \
  --output "$TMP/rejected.json"

jq --arg bad \
  "0000000000000000000000000000000000000000000000000000000000000000" '
  .deployment.final.zeroStateProbe.admission.recoveryProofSha256 = $bad
' "$TMP/populated-input.json" >"$TMP/unbound-recovery-proof.json"
expect_failure unbound-recovery-proof \
  bash "$BUILDER" success --input "$TMP/unbound-recovery-proof.json" \
  --output "$TMP/rejected.json"

jq --argjson meetings "$POPULATED_MEETINGS" '
  .deployment.final.zeroStateProbe.database.tables.meetings = ($meetings - 1) |
  .deployment.final.zeroStateProbe.database.totalRows =
    ([.deployment.final.zeroStateProbe.database.tables[]] | add) |
  .deployment.final.zeroStateProbe.http.meetingsCount = ($meetings - 1)
' "$TMP/populated-input.json" >"$TMP/populated-count-drift.json"
expect_failure populated-count-drift \
  bash "$BUILDER" success --input "$TMP/populated-count-drift.json" \
  --output "$TMP/rejected.json"
expect_failure upload-failed \
  bash "$BUILDER" authorize-retention --evidence "$TMP/evidence.json" \
  --artifact-uploaded false --output "$TMP/rejected.json"

jq '.unexpected = true' "$TMP/input.json" >"$TMP/unknown.json"
expect_failure unknown-field \
  bash "$BUILDER" success --input "$TMP/unknown.json" \
  --output "$TMP/rejected.json"

jq '
  .deployment.final.zeroStateProbe.database.tables.meetings = 1 |
  .deployment.final.zeroStateProbe.database.totalRows = 1 |
  .deployment.final.zeroStateProbe.zeroState = "populated"
' "$TMP/input.json" >"$TMP/non-empty-state.json"
expect_failure non-empty-state \
  bash "$BUILDER" success --input "$TMP/non-empty-state.json" \
  --output "$TMP/rejected.json"

jq '
  .deployment.final.zeroStateProbe.zeroState = "unknown" |
  .deployment.final.zeroStateProbe.zeroStateObserved = false
' "$TMP/input.json" >"$TMP/unknown-state.json"
expect_failure unknown-state \
  bash "$BUILDER" success --input "$TMP/unknown-state.json" \
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
  .deployment.predecessor.bootstrapMode = "declared-false" |
  .deployment.predecessor.bootstrapControlPresent = true |
  .deployment.predecessor.bootstrapDisabled = true |
  .deployment.predecessor.bootstrapProofSha256 =
    "0000000000000000000000000000000000000000000000000000000000000000"
' "$TMP/input.json" >"$TMP/declared-false-predecessor-mismatch.json"
expect_failure declared-false-predecessor-mismatch \
  bash "$BUILDER" success --input "$TMP/declared-false-predecessor-mismatch.json" \
  --output "$TMP/rejected.json"

for rollback_side in predecessor restored; do
  for rollback_field in stateMode stateSha256 imageReference imageId revision \
    version runtimeConfigHash bootstrapProofSha256 bootstrapMode \
    bootstrapControlPresent bootstrapDisabled; do
    rollback_marker="rollback-${rollback_side}-${rollback_field}"
    jq --arg side "$rollback_side" --arg field "$rollback_field" '
      setpath(["deployment","rollback",$side,$field]; "mismatch")
    ' "$TMP/input.json" >"$TMP/$rollback_marker.json"
    expect_failure "$rollback_marker" \
      bash "$BUILDER" success --input "$TMP/$rollback_marker.json" \
      --output "$TMP/rejected.json"
  done
done

jq --arg proof "$PROOF" '
  .deployment.rollback = {
    required:false,attempted:false,verified:false,sameImageRedeploy:true,
    predecessor:null,restored:null
  } |
  .image.admissionMode = "reused"
' "$TMP/input.json" >"$TMP/same-digest.json"
bash "$BUILDER" success --input "$TMP/same-digest.json" \
  --output "$TMP/same-digest-evidence.json"
jq -e '
  .deployment.rollback.sameImageRedeploy == true and
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
  .schema == "meet-backend/test-promotion-incident/v2" and
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
