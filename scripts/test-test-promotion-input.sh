#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FILTER=$ROOT_DIR/scripts/build-test-promotion-input.jq
BUILDER=$ROOT_DIR/scripts/build-test-promotion-evidence.sh
CONTRACT=$ROOT_DIR/scripts/test-vps-admission-contract.json
BASELINE_COMMIT=cb730ea062454a0453010ff4eddeb5f6ccf51171
TMP=$(mktemp -d)
export -n TMP
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

[ -r "$FILTER" ] && [ -x "$BUILDER" ] && [ -r "$CONTRACT" ]
command -v jq >/dev/null 2>&1

BASELINE_FILTER=$TMP/baseline.jq
git show "$BASELINE_COMMIT:.github/workflows/promote-dev-digest-to-test-vps.yml" |
  sed -n '693,831p' | sed 's/^            //' >"$BASELINE_FILTER"
cmp "$BASELINE_FILTER" "$FILTER"

SOURCE=0123456789abcdef0123456789abcdef01234567
TREE=89abcdef0123456789abcdef0123456789abcdef
IMAGE_REPO=ghcr.io/nickolaymamonov/meet-backend-v3
TARGET_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PLATFORM_DIGEST=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OLD_DIGEST=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
OTHER_DIGEST=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
TARGET_ID=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
OLD_ID=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
CONFIG=1111111111111111111111111111111111111111111111111111111111111111
ROOT_DIGEST="sha256:$TARGET_DIGEST"
PLATFORM="sha256:$PLATFORM_DIGEST"

make_case() {
  local mode=$1 branch=$2 case_dir=$3
  local state_sha="$4"
  local target_ref="$IMAGE_REPO@sha256:$TARGET_DIGEST"
  local old_ref="$IMAGE_REPO@sha256:$OLD_DIGEST"
  local predecessor_ref=$target_ref
  local predecessor_id=$TARGET_ID
  local predecessor_revision=$SOURCE
  local predecessor_digest=$TARGET_DIGEST
  local rollback_required=false rollback_attempted=false rollback_verified=false admission_mode=reused
  if [ "$branch" = changed ]; then
    predecessor_ref="$IMAGE_REPO@sha256:$OTHER_DIGEST"
    predecessor_id=$OLD_ID
    predecessor_revision=abcdefabcdefabcdefabcdefabcdefabcdefabcd
    predecessor_digest=$OTHER_DIGEST
    rollback_required=true
    rollback_attempted=true
    rollback_verified=true
    admission_mode=published
  fi

  mkdir -p "$case_dir"
  jq -n \
    --arg mode "$mode" \
    --arg state "$state_sha" \
    --arg source "$SOURCE" \
    --arg tree "$TREE" \
    --arg target "$target_ref" \
    --arg old "$old_ref" \
    --arg predecessor "$predecessor_ref" \
    --arg predecessorId "$predecessor_id" \
    --arg predecessorRevision "$predecessor_revision" \
    --arg predecessorDigest "$predecessor_digest" \
    --arg targetId "$TARGET_ID" \
    --arg oldId "$OLD_ID" \
    --arg config "$CONFIG" \
    --argjson contract "$(cat "$CONTRACT")" '
    def populated:
      {
        mode:"closed-beta-demo",catalogName:"closed-beta-demo",manifestVersion:"2026-08-15.v1",
        stateSha256:$state,
        recoveryProofSha256:$contract.populated.recoveryProof.sha256,
        stableProofSha256:$contract.populated.stableProof.sha256,
        publicProjectionSha256:"9999999999999999999999999999999999999999999999999999999999999999",
        routes:{
          meetings:{status:200,schemaValid:true,count:$contract.populated.roots.meetings,
            projectionSha256:"9999999999999999999999999999999999999999999999999999999999999999",equal:true},
          recommendedCommunities:{status:200,schemaValid:true,count:$contract.populated.roots.communities,
            projectionSha256:"9999999999999999999999999999999999999999999999999999999999999999",equal:true},
          tags:{status:200,schemaValid:true,count:$contract.populated.roots.tags,
            projectionSha256:"9999999999999999999999999999999999999999999999999999999999999999",equal:true},
          ads:{status:200,schemaValid:true,count:$contract.populated.roots.adBlocks,
            projectionSha256:"9999999999999999999999999999999999999999999999999999999999999999",equal:true}
        }
      };
    def tables:
      if $mode == "empty-closed" then
        {ad_block_communities:0,ad_block_users:0,ad_blocks:0,
         communities:0,community_subscribers:0,community_tags:0,
         demo_catalog_state:0,meeting_participants:0,meeting_tags:0,
         meetings:0,tags:0,user_interests:0,user_social_media:0,users:0}
      else
        {ad_block_communities:3,ad_block_users:4,ad_blocks:$contract.populated.roots.adBlocks,
         communities:$contract.populated.roots.communities,
         community_subscribers:9,community_tags:7,demo_catalog_state:0,
         meeting_participants:18,meeting_tags:12,
         meetings:$contract.populated.roots.meetings,tags:$contract.populated.roots.tags,
         user_interests:12,user_social_media:0,users:$contract.populated.roots.users}
      end;
    def probe($phase;$image;$imageId;$revision;$runtime):
      {
        schema:"meet-backend/test-vps-zero-state-probe/v2",phase:$phase,
        image:("sha256:"+$image),imageId:$imageId,sourceSha:$revision,
        version:"1.2.0",runtimeConfigHash:$runtime,
        admission:(if $mode == "empty-closed"
          then {mode:"empty-closed",stateSha256:null}
          else populated
          end),
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
        database:{tables:tables,totalRows:([tables[]] | add)},
        http:{
          actuatorStatus:404,adminAuthenticatedDisabled404:true,
          adminBlankDisabled403:false,adminKeyConfigured:true,
          adminMissingStatus:403,adminWrongStatus:403,assetsCount:13,
          assetsVerified:true,httpRedirectHttps:true,
          meetingsCount:(if $mode == "empty-closed" then 0 else $contract.populated.roots.meetings end),
          meetingsJson:true,meetingsStatus:200
        },
        zeroStateObserved:true,zeroState:"closed"
      };
    def raw($phase;$reference;$imageId;$revision;$digest;$runtime):
      probe($phase;$digest;$imageId;$revision;$runtime) as $probe |
      {image:$reference,imageId:$imageId,revision:$revision,version:"1.2.0",
       runtimeConfigHash:$runtime,zeroStateProbe:$probe};
    def bootstrap($phase;$digest;$imageId;$revision;$runtime;$present):
      {
        bootstrapControlPresent:$present,
        bootstrapMode:(if $present then "declared-false" else "legacy-not-applicable" end),
        effectiveDefault:false,imageDigest:("sha256:"+$digest),imageId:$imageId,
        introductionSha:"1111111111111111111111111111111111111111",
        jarProductionSha256:$runtime,jarPropertiesSha256:$runtime,phase:$phase,
        platform:"linux/amd64",schema:"meet-backend/test-promotion-bootstrap-proof/v1",
        sourceProductionSha256:$runtime,sourcePropertiesSha256:$runtime,
        sourceSha:$revision,strictAncestor:true,treeId:$tree,version:"1.2.0"
      };
    {
      predecessor:[raw("predecessor";$predecessor;$predecessorId;$predecessorRevision;
        $predecessorDigest;$config)],
      candidate:[raw("candidate";$target;$targetId;$source;"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";$config)],
      final:[raw("final";$target;$targetId;$source;"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";$config)],
      rollbackPredecessor:[raw("predecessor";$old;$oldId;
        "abcdefabcdefabcdefabcdefabcdefabcdefabcd";
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";$config)],
      rollback:[raw("rollback";$old;$oldId;
        "abcdefabcdefabcdefabcdefabcdefabcdefabcd";
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";$config)],
      predecessorBootstrap:[bootstrap("predecessor";$predecessorDigest;$predecessorId;
        $predecessorRevision;$config;false)],
      candidateBootstrap:[bootstrap("candidate";
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        $targetId;$source;$config;true)],
      finalBootstrap:[bootstrap("final";
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        $targetId;$source;$config;true)],
      rollbackPredecessorBootstrap:[bootstrap("predecessor";
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        $oldId;"abcdefabcdefabcdefabcdefabcdefabcdefabcd";$config;false)],
      rollbackBootstrap:[bootstrap("rollback";
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        $oldId;"abcdefabcdefabcdefabcdefabcdefabcdefabcd";$config;false)],
      authority:{authoritySha:$source}
    }
  ' >"$case_dir/docs.json"

  for name in predecessor candidate final predecessorBootstrap candidateBootstrap finalBootstrap authority; do
    if [ "$name" = authority ]; then
      jq -c --arg name "$name" '.[$name]' "$case_dir/docs.json" >"$case_dir/$name.json"
    else
      jq -c --arg name "$name" '.[$name][0]' "$case_dir/docs.json" >"$case_dir/$name.json"
    fi
  done
  if [ "$branch" = changed ]; then
    jq -c '.rollbackPredecessor[0]' "$case_dir/docs.json" >"$case_dir/rollbackPredecessor.json"
    jq -c '.rollback[0]' "$case_dir/docs.json" >"$case_dir/rollback.json"
    jq -c '.rollbackPredecessorBootstrap[0]' "$case_dir/docs.json" >"$case_dir/rollbackPredecessorBootstrap.json"
    jq -c '.rollbackBootstrap[0]' "$case_dir/docs.json" >"$case_dir/rollbackBootstrap.json"
  fi

  local pre_hash=9999999999999999999999999999999999999999999999999999999999999999
  local cand_hash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local rollback_pre_hash=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  local rollback_hash=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  local final_hash=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  local rollback_predecessor_args=(--argjson rollbackPredecessor null)
  local rollback_args=(--argjson rollback null)
  local rollback_predecessor_bootstrap_args=(--argjson rollbackPredecessorBootstrap null)
  local rollback_bootstrap_args=(--argjson rollbackBootstrap null)
  if [ "$branch" = changed ]; then
    rollback_predecessor_args=(--slurpfile rollbackPredecessor "$case_dir/rollbackPredecessor.json")
    rollback_args=(--slurpfile rollback "$case_dir/rollback.json")
    rollback_predecessor_bootstrap_args=(--slurpfile rollbackPredecessorBootstrap "$case_dir/rollbackPredecessorBootstrap.json")
    rollback_bootstrap_args=(--slurpfile rollbackBootstrap "$case_dir/rollbackBootstrap.json")
  fi
  local base_args=(
    -n
    --slurpfile predecessor "$case_dir/predecessor.json"
    --slurpfile candidate "$case_dir/candidate.json"
    "${rollback_predecessor_args[@]}"
    "${rollback_args[@]}"
    --slurpfile final "$case_dir/final.json"
    --slurpfile predecessorBootstrap "$case_dir/predecessorBootstrap.json"
    --slurpfile candidateBootstrap "$case_dir/candidateBootstrap.json"
    "${rollback_predecessor_bootstrap_args[@]}"
    --slurpfile finalBootstrap "$case_dir/finalBootstrap.json"
    "${rollback_bootstrap_args[@]}"
    --slurpfile authority "$case_dir/authority.json"
    --arg source "$SOURCE" --arg tree "$TREE" --arg version "1.2.0"
    --arg image "$IMAGE_REPO" --arg alias "test-sha-$SOURCE"
    --arg admissionMode "$admission_mode" --arg root "$ROOT_DIGEST"
    --arg platform "$PLATFORM"
    --arg predecessorProof "$pre_hash" --arg candidateProof "$cand_hash"
    --arg rollbackPredecessorProof "$rollback_pre_hash" --arg rollbackProof "$rollback_hash"
    --arg finalProof "$final_hash" --arg stateMode "$mode"
    --slurpfile admissionContract "$CONTRACT"
    --argjson rollbackRequired "$rollback_required"
    --argjson rollbackAttempted "$rollback_attempted"
    --argjson rollbackVerified "$rollback_verified"
  )
  jq "${base_args[@]}" -f "$BASELINE_FILTER" | jq -S . >"$case_dir/baseline.json"
  jq "${base_args[@]}" -f "$FILTER" | jq -S . >"$case_dir/extracted.json"
  cmp "$case_dir/baseline.json" "$case_dir/extracted.json"

  local output="$case_dir/success.json"
  rm -f -- "$output"
  if [ "$branch" = same ]; then
    bash "$BUILDER" success --input "$case_dir/extracted.json" --output "$output"
    [ -s "$output" ]
    jq -e '.schema == "meet-backend/test-promotion-evidence/v2"' "$output" >/dev/null
  else
    local stdout="$case_dir/rejected.stdout" stderr="$case_dir/rejected.stderr"
    if bash "$BUILDER" success --input "$case_dir/extracted.json" --output "$output" >"$stdout" 2>"$stderr"; then
      echo "changed-image baseline unexpectedly succeeded: $mode" >&2
      exit 1
    fi
    [ ! -s "$stdout" ] && [ -s "$stderr" ] && [ ! -e "$output" ]
    jq -e '
      .deployment.rollback.predecessor.imageReference |
      test("^ghcr[.]io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$")
    ' "$case_dir/extracted.json" >/dev/null
  fi
}

for mode in empty-closed closed-beta-demo; do
  state_sha=null
  if [ "$mode" = closed-beta-demo ]; then
    state_sha=8888888888888888888888888888888888888888888888888888888888888888
  fi
  make_case "$mode" same "$TMP/$mode-same" "$state_sha"
  make_case "$mode" changed "$TMP/$mode-changed" "$state_sha"
done

echo "test promotion input fixtures passed"
