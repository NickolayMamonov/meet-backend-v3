#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<EOF
usage:
  $0 success --input PATH --output PATH
  $0 incident --stage STAGE --failure-class CLASS --mutation-started BOOL --rollback-attempted BOOL --rollback-verified BOOL --output PATH
  $0 authorize-retention --evidence PATH --artifact-uploaded true --output PATH
EOF
  exit 2
}

fail() {
  echo "test promotion evidence construction failed: $1" >&2
  exit 1
}

is_bool() {
  [ "$1" = true ] || [ "$1" = false ]
}

safe_input() {
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] ||
    fail "evidence input is missing or unsafe"
  [ "$(wc -c <"$path" | tr -d ' ')" -le 65536 ] ||
    fail "evidence input exceeds the size limit"
}

publish_output() {
  local candidate=$1 output=$2 temporary
  [ -n "$output" ] || usage
  [ ! -L "$output" ] || fail "output path is unsafe"
  if [ -e "$output" ]; then
    [ -f "$output" ] || fail "output path is unsafe"
  fi
  [ -d "$(dirname -- "$output")" ] ||
    fail "output directory is unavailable"
  temporary=$output.tmp.$$
  trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
  jq -cS . "$candidate" >"$temporary" 2>/dev/null ||
    fail "canonical evidence construction failed"
  chmod 600 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$output" ||
    fail "evidence output publication failed"
  trap - EXIT HUP INT TERM
}

reject_sensitive_content() {
  local path=$1
  jq -e '
    def sensitive_key:
      ascii_downcase |
      test("(^|[^a-z])(authorization|cookie|secret|password|passwd|credential|private.?key|admin.?key|api.?key|otp|jwt|refresh.?token|access.?token|database.?url|smtp|mailbox|provider.?token|response.?body|environment|endpoint)([^a-z]|$)");
    def sensitive_value:
      test(
        "(?i)(authorization[[:space:]]*:|bearer[[:space:]]+[A-Za-z0-9._~+/-]+=*|-----BEGIN [A-Z ]*PRIVATE KEY-----|postgres(ql)?://|jdbc:postgresql:|smtp(s)?://|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]+[.]eyJ[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+|(^|[^A-Za-z0-9_])(PASSWORD|SECRET|TOKEN|ADMIN_KEY|API_KEY|SMTP_[A-Z0-9_]*|DATABASE_URL)=)"
      );
    [
      paths as $path |
      if ($path[-1] | type) == "string" and ($path[-1] | sensitive_key)
      then true
      else (getpath($path) | if type == "string" then sensitive_value else false end)
      end
    ] | any | not
  ' "$path" >/dev/null 2>&1 ||
    fail "evidence contains prohibited sensitive material"
}

validate_success_input() {
  local input=$1
  jq -e '
    def sha: type == "string" and test("^[0-9a-f]{40}$");
    def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
    def hex_digest: type == "string" and test("^[0-9a-f]{64}$");
    def semver:
      type == "string" and
      test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$");
    def exact_keys($keys): (keys | sort) == ($keys | sort);
    def table_names: [
      "ad_block_communities","ad_block_users","ad_blocks",
      "communities","community_subscribers","community_tags",
      "demo_catalog_state","meeting_participants","meeting_tags",
      "meetings","tags","user_interests","user_social_media","users"
    ];
    def probe:
      type == "object" and exact_keys([
        "database","http","image","imageId","phase","runtime",
        "runtimeConfigHash","schema","sourceSha","version",
        "zeroState","zeroStateObserved"
      ]) and
      .schema == "meet-backend/test-vps-zero-state-probe/v1" and
      (.phase == "predecessor" or .phase == "candidate" or
       .phase == "rollback" or .phase == "final") and
      (.image | digest) and (.imageId | digest) and (.sourceSha | sha) and
      (.version | semver) and (.runtimeConfigHash | hex_digest) and
      .zeroState == "closed" and .zeroStateObserved == true and
      (.database | type == "object" and exact_keys(["tables","totalRows"]) and
        (.tables | type == "object" and (keys | sort) == (table_names | sort) and
          all(values[]; type == "number" and . >= 0)) and
        (.totalRows | type == "number") and
        (.totalRows == ([.tables[]] | add)) and
        .totalRows == 0) and
      (.runtime | type == "object" and exact_keys([
        "containerHealthy","hardeningVerified","networks",
        "nonIdleApplicationTransactions","postgresVolumes",
        "postgresWritablePrimary","ports","smtpIdleSamples",
        "topologyVerified","volumes","volumesVerified"
      ]) and
        .containerHealthy == true and .hardeningVerified == true and
        .topologyVerified == true and .volumesVerified == true and
        .postgresWritablePrimary == true and
        .nonIdleApplicationTransactions == 0 and
        .smtpIdleSamples == [0,0] and
        (.volumes | type == "array") and (.postgresVolumes | type == "array")) and
      (.http | type == "object" and exact_keys([
        "actuatorStatus","adminAuthenticatedDisabled404","adminBlankDisabled403",
        "adminKeyConfigured","adminMissingStatus","adminWrongStatus",
        "assetsCount","assetsVerified","httpRedirectHttps","meetingsCount",
        "meetingsJson","meetingsStatus"
      ]) and
        .meetingsStatus == 200 and .meetingsJson == true and .meetingsCount == 0 and
        .actuatorStatus == 404 and .httpRedirectHttps == true and
        .adminMissingStatus == 403 and .adminWrongStatus == 403 and
        (.adminKeyConfigured | type == "boolean") and
        (.adminAuthenticatedDisabled404 | type == "boolean") and
        (.adminBlankDisabled403 | type == "boolean") and
        (if .adminKeyConfigured
         then .adminAuthenticatedDisabled404 == true and .adminBlankDisabled403 == false
         else .adminAuthenticatedDisabled404 == false and .adminBlankDisabled403 == true
         end) and .assetsCount == 13 and .assetsVerified == true);
    def phase($expectedPhase):
      . as $phaseDoc |
      type == "object" and exact_keys([
        "bootstrapControlPresent","bootstrapDisabled","bootstrapMode",
        "bootstrapProofSha256","configDigest","demoZero","healthy",
        "imageDigest","imageId","runtimeDigest","sourceSha","treeId",
        "version","zeroStateProbe"
      ]) and
      (.imageDigest | digest) and (.imageId | digest) and
      (.sourceSha | sha) and (.treeId | sha) and (.version | semver) and
      (.bootstrapProofSha256 | hex_digest) and
      (.configDigest | hex_digest) and (.runtimeDigest | hex_digest) and
      (.bootstrapMode == "declared-false" or
       .bootstrapMode == "legacy-not-applicable") and
      (.bootstrapControlPresent | type == "boolean") and
      (.bootstrapDisabled == null or (.bootstrapDisabled | type == "boolean")) and
      (.healthy | type == "boolean") and (.demoZero | type == "boolean") and
      ($phaseDoc.zeroStateProbe | probe) and
      $phaseDoc.zeroStateProbe.phase == $expectedPhase and
      $phaseDoc.zeroStateProbe.image == $phaseDoc.imageDigest and
      $phaseDoc.zeroStateProbe.imageId == $phaseDoc.imageId and
      $phaseDoc.zeroStateProbe.sourceSha == $phaseDoc.sourceSha and
      $phaseDoc.zeroStateProbe.version == $phaseDoc.version and
      $phaseDoc.zeroStateProbe.runtimeConfigHash == $phaseDoc.runtimeDigest and
      $phaseDoc.healthy == $phaseDoc.zeroStateProbe.runtime.containerHealthy and
      $phaseDoc.demoZero == ($phaseDoc.zeroStateProbe.zeroState == "closed") and
      (if .bootstrapMode == "declared-false"
       then .bootstrapControlPresent == true and .bootstrapDisabled == true
       else .bootstrapControlPresent == false and .bootstrapDisabled == null
       end);
    . as $root |
    ($root.deployment.final.zeroStateProbe) as $finalProbe |
    ($root.deployment) as $deployment |
    ($deployment.runtime) as $runtime |
    ($deployment.probes) as $probes |
    ($deployment.rollback) as $rollback |
    type == "object" and (keys | length) == 5 and exact_keys([
      "control","deployment","image","schema","source"
    ]) and
    .schema == "meet-backend/test-promotion-evidence-input/v1" and
    (.source | type == "object" and exact_keys([
      "authoritySha","sourceSha","treeId","version"
    ]) and
      (.sourceSha | sha) and .authoritySha == .sourceSha and
      (.treeId | sha) and (.version | semver)) and
    (.image | type == "object" and exact_keys([
      "admissionMode","alias","githubAttestation","image","labels",
      "platform","platformDigest","protectedStateEqual","provenance",
      "referrerClosure","rootDigest","sbom"
    ]) and
      .image == "ghcr.io/nickolaymamonov/meet-backend-v3" and
      (.alias | type == "string") and
      .alias == ("test-sha-" + $root.source.sourceSha) and
      (.admissionMode == "published" or .admissionMode == "reused") and
      (.rootDigest | digest) and (.platformDigest | digest) and
      .platform == "linux/amd64" and
      (.labels | type == "object" and exact_keys(["revision","source","version"]) and
        .source == "https://github.com/NickolayMamonov/meet-backend-v3" and
        .revision == $root.source.sourceSha and .version == $root.source.version) and
      .provenance == true and .sbom == true and
      .githubAttestation == true and .referrerClosure == true and
      .protectedStateEqual == true) and
    ($deployment | type == "object") and
    (($deployment | keys | sort) == ([
      "candidate","final","predecessor","probes","rollback","runtime"
    ] | sort)) and
    ($deployment.predecessor | phase("predecessor")) and
    ($deployment.candidate | phase("candidate")) and
    ($deployment.final | phase("final")) and
    $deployment.candidate.bootstrapMode == "declared-false" and
    $deployment.candidate.bootstrapControlPresent == true and
    $deployment.candidate.bootstrapDisabled == true and
    $deployment.candidate.zeroStateProbe.zeroState == "closed" and
    $deployment.candidate.imageDigest == $root.image.rootDigest and
    $deployment.candidate.sourceSha == $root.source.sourceSha and
    $deployment.candidate.treeId == $root.source.treeId and
    $deployment.candidate.version == $root.source.version and
    $deployment.final.bootstrapMode == "declared-false" and
    $deployment.final.bootstrapControlPresent == true and
    $deployment.final.bootstrapDisabled == true and
    $deployment.final.zeroStateProbe.zeroState == "closed" and
    $deployment.final.imageDigest == $root.image.rootDigest and
    $deployment.final.sourceSha == $root.source.sourceSha and
    $deployment.final.treeId == $root.source.treeId and
    $deployment.final.version == $root.source.version and
    ($runtime | type == "object") and
    (($runtime | keys | sort) == ([
      "hardeningVerified","nonIdleApplicationTransactions",
      "postgresWritablePrimary","smtpIdleSamples","topologyVerified",
      "volumes","volumesVerified"
    ] | sort)) and
    $runtime.topologyVerified == $finalProbe.runtime.topologyVerified and
    $runtime.hardeningVerified == $finalProbe.runtime.hardeningVerified and
    $runtime.volumesVerified == $finalProbe.runtime.volumesVerified and
    $runtime.postgresWritablePrimary == $finalProbe.runtime.postgresWritablePrimary and
    $runtime.nonIdleApplicationTransactions ==
      $finalProbe.runtime.nonIdleApplicationTransactions and
    $runtime.smtpIdleSamples == $finalProbe.runtime.smtpIdleSamples and
    $runtime.volumes == (($finalProbe.runtime.volumes +
      $finalProbe.runtime.postgresVolumes) | map(.source) | sort) and
    ($probes | type == "object") and
    (($probes | keys | sort) == ([
      "actuator404","adminAuthenticatedDisabled404","adminBlankDisabled403",
      "adminKeyConfigured","adminMissing403","adminWrong403","assets",
      "httpRedirectHttps","meetings200Json"
    ] | sort)) and
    $probes.actuator404 == ($finalProbe.http.actuatorStatus == 404) and
    $probes.adminAuthenticatedDisabled404 ==
      $finalProbe.http.adminAuthenticatedDisabled404 and
    $probes.adminBlankDisabled403 == $finalProbe.http.adminBlankDisabled403 and
    $probes.adminKeyConfigured == $finalProbe.http.adminKeyConfigured and
    $probes.adminMissing403 == ($finalProbe.http.adminMissingStatus == 403) and
    $probes.adminWrong403 == ($finalProbe.http.adminWrongStatus == 403) and
    $probes.httpRedirectHttps == $finalProbe.http.httpRedirectHttps and
    $probes.meetings200Json == ($finalProbe.http.meetingsStatus == 200 and
      $finalProbe.http.meetingsJson == true and
      $finalProbe.http.meetingsCount == 0) and
    ($probes.assets == {
      count:$finalProbe.http.assetsCount,
      verified:$finalProbe.http.assetsVerified
    }) and
    ($rollback | type == "object") and
    (($rollback | keys | sort) == ([
      "attempted","bootstrapProofSha256","required","restoredImageId",
      "sameDigestRedeploy","verified"
    ] | sort)) and
    ($rollback.bootstrapProofSha256 | hex_digest) and
    ($rollback.required | type == "boolean") and
    ($rollback.attempted | type == "boolean") and
    ($rollback.verified | type == "boolean") and
    ($rollback.sameDigestRedeploy | type == "boolean") and
    ($rollback.restoredImageId == null or ($rollback.restoredImageId | digest)) and
    ($rollback.bootstrapProofSha256 == $deployment.predecessor.bootstrapProofSha256) and
    (if $rollback.required
     then $rollback.attempted and $rollback.verified and
       ($rollback.sameDigestRedeploy | not) and
       $rollback.restoredImageId == $deployment.predecessor.imageId
     else ($rollback.attempted | not) and ($rollback.verified | not) and
       $rollback.sameDigestRedeploy and $rollback.restoredImageId == null
     end) and
    (.control | type == "object" and exact_keys([
      "finalVerified","rollbackPolicySatisfied"
    ]) and .finalVerified == true and .rollbackPolicySatisfied == true)
  ' "$input" >/dev/null ||
    fail "success evidence input does not satisfy the closed schema"
}

validate_success_evidence() {
  local evidence=$1 reconstructed
  jq -e '
    type == "object" and
    .schema == "meet-backend/test-promotion-evidence/v1" and
    .kind == "success" and .evidenceSanitized == true and
    .artifactUploaded == false and .retentionAuthorized == false and
    (.source | type == "object") and (.image | type == "object") and
    (.deployment | type == "object") and
    (.control | type == "object" and .finalVerified == true and
      .rollbackPolicySatisfied == true) and
    (keys | sort) == ([
      "artifactUploaded","control","deployment","evidenceSanitized",
      "image","kind","retentionAuthorized","schema","source"
    ] | sort)
  ' "$evidence" >/dev/null 2>&1 ||
    fail "retention evidence is not an eligible success document"
  reconstructed=$(mktemp)
  jq -cS '
    {
      schema:"meet-backend/test-promotion-evidence-input/v1",
      source:.source,image:.image,
      deployment:{
        predecessor:.deployment.predecessor,
        candidate:.deployment.candidate,
        final:.deployment.final,
        runtime:.deployment.runtime,
        probes:.deployment.probes,
        rollback:.deployment.rollback
      },
      control:.control
    }
  ' "$evidence" >"$reconstructed" 2>/dev/null ||
    { rm -f -- "$reconstructed"; fail "retention evidence is malformed"; }
  validate_success_input "$reconstructed"
  rm -f -- "$reconstructed"
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
[ "$#" -ge 1 ] || usage
operation=$1
shift

case "$operation" in
  success)
    input=
    output=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --input) [ "$#" -ge 2 ] && [ -z "$input" ] || usage; input=$2; shift 2 ;;
        --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$input" ] && [ -n "$output" ] || usage
    safe_input "$input"
    validate_success_input "$input"
    reject_sensitive_content "$input"
    candidate=$(mktemp)
    trap 'rm -f -- "$candidate"' EXIT HUP INT TERM
    jq -cS '
      .deployment.final.zeroStateProbe as $probe |
      def phase($x):
        ($x.zeroStateProbe) as $observed |
        $x + {
          healthy:$observed.runtime.containerHealthy,
          demoZero:($observed.zeroState == "closed")
        };
      {
        schema:"meet-backend/test-promotion-evidence/v1",
        kind:"success",
        source:.source,
        image:.image,
        deployment:{
          predecessor:phase(.deployment.predecessor),
          candidate:phase(.deployment.candidate),
          rollback:.deployment.rollback,
          final:phase(.deployment.final),
          runtime:{
            hardeningVerified:$probe.runtime.hardeningVerified,
            nonIdleApplicationTransactions:$probe.runtime.nonIdleApplicationTransactions,
            postgresWritablePrimary:$probe.runtime.postgresWritablePrimary,
            smtpIdleSamples:$probe.runtime.smtpIdleSamples,
            topologyVerified:$probe.runtime.topologyVerified,
            volumes:(($probe.runtime.volumes + $probe.runtime.postgresVolumes) |
              map(.source) | sort),
            volumesVerified:$probe.runtime.volumesVerified
          },
          probes:{
            actuator404:($probe.http.actuatorStatus == 404),
            adminAuthenticatedDisabled404:$probe.http.adminAuthenticatedDisabled404,
            adminBlankDisabled403:$probe.http.adminBlankDisabled403,
            adminKeyConfigured:$probe.http.adminKeyConfigured,
            adminMissing403:($probe.http.adminMissingStatus == 403),
            adminWrong403:($probe.http.adminWrongStatus == 403),
            assets:{count:$probe.http.assetsCount,verified:$probe.http.assetsVerified},
            httpRedirectHttps:$probe.http.httpRedirectHttps,
            meetings200Json:($probe.http.meetingsStatus == 200 and
              $probe.http.meetingsJson == true and $probe.http.meetingsCount == 0)
          }
        },
        control:.control,
        evidenceSanitized:true,
        artifactUploaded:false,
        retentionAuthorized:false
      }
    ' "$input" >"$candidate" 2>/dev/null ||
      fail "success evidence composition failed"
    reject_sensitive_content "$candidate"
    publish_output "$candidate" "$output"
    rm -f -- "$candidate"
    trap - EXIT HUP INT TERM
    ;;
  incident)
    stage=
    failure_class=
    mutation_started=
    rollback_attempted=
    rollback_verified=
    output=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --stage) [ "$#" -ge 2 ] && [ -z "$stage" ] || usage; stage=$2; shift 2 ;;
        --failure-class) [ "$#" -ge 2 ] && [ -z "$failure_class" ] || usage; failure_class=$2; shift 2 ;;
        --mutation-started) [ "$#" -ge 2 ] && [ -z "$mutation_started" ] || usage; mutation_started=$2; shift 2 ;;
        --rollback-attempted) [ "$#" -ge 2 ] && [ -z "$rollback_attempted" ] || usage; rollback_attempted=$2; shift 2 ;;
        --rollback-verified) [ "$#" -ge 2 ] && [ -z "$rollback_verified" ] || usage; rollback_verified=$2; shift 2 ;;
        --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    case "$stage" in authorization|source|protectedState|admission|registryWrite|attestation|predecessor|candidate|rollback|final|evidence|artifactUpload|retention) ;; *) usage ;; esac
    case "$failure_class" in validationFailed|authorityMoved|protectedDigestCollision|protectedStateDrift|terminalRegistryPartial|mutationFailed|rollbackFailed|finalVerificationFailed|sanitizationFailed|remoteEvidenceInvalid|artifactUploadFailed|internalFailure) ;; *) usage ;; esac
    is_bool "$mutation_started" && is_bool "$rollback_attempted" && is_bool "$rollback_verified" || usage
    [ -n "$output" ] || usage
    [ "$rollback_verified" = false ] || [ "$rollback_attempted" = true ] ||
      fail "rollback verification requires a rollback attempt"
    [ "$rollback_attempted" = false ] || [ "$mutation_started" = true ] ||
      fail "rollback cannot precede mutation"
    candidate=$(mktemp)
    trap 'rm -f -- "$candidate"' EXIT HUP INT TERM
    jq -cnS --arg schema "meet-backend/test-promotion-incident/v1" \
      --arg stage "$stage" --arg failureClass "$failure_class" \
      --argjson mutationStarted "$mutation_started" \
      --argjson rollbackAttempted "$rollback_attempted" \
      --argjson rollbackVerified "$rollback_verified" '
      {schema:$schema,kind:"incident",stage:$stage,failureClass:$failureClass,
       mutationStarted:$mutationStarted,rollbackAttempted:$rollbackAttempted,
       rollbackVerified:$rollbackVerified,evidenceSanitized:true,
       artifactUploaded:false,retentionAuthorized:false}
    ' >"$candidate" || fail "fallback incident construction failed"
    reject_sensitive_content "$candidate"
    publish_output "$candidate" "$output"
    rm -f -- "$candidate"
    trap - EXIT HUP INT TERM
    ;;
  authorize-retention)
    evidence=
    artifact_uploaded=
    output=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --evidence) [ "$#" -ge 2 ] && [ -z "$evidence" ] || usage; evidence=$2; shift 2 ;;
        --artifact-uploaded) [ "$#" -ge 2 ] && [ -z "$artifact_uploaded" ] || usage; artifact_uploaded=$2; shift 2 ;;
        --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$evidence" ] && [ -n "$output" ] || usage
    is_bool "$artifact_uploaded" || usage
    [ "$artifact_uploaded" = true ] || fail "artifact upload did not authorize retention"
    safe_input "$evidence"
    reject_sensitive_content "$evidence"
    validate_success_evidence "$evidence"
    evidence_sha=$(sha256sum "$evidence" 2>/dev/null | awk '{print $1}') ||
      fail "evidence digest calculation failed"
    [[ "$evidence_sha" =~ ^[0-9a-f]{64}$ ]] || fail "evidence digest calculation failed"
    candidate=$(mktemp)
    trap 'rm -f -- "$candidate"' EXIT HUP INT TERM
    jq -cnS --arg schema "meet-backend/test-promotion-retention/v1" \
      --arg evidenceSha256 "$evidence_sha" '
      {schema:$schema,evidenceSha256:$evidenceSha256,artifactUploaded:true,
       evidenceSanitized:true,finalVerified:true,rollbackPolicySatisfied:true,
       retentionAuthorized:true}
    ' >"$candidate" || fail "retention authorization construction failed"
    publish_output "$candidate" "$output"
    rm -f -- "$candidate"
    trap - EXIT HUP INT TERM
    ;;
  *) usage ;;
esac
