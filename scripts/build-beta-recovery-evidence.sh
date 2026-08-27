#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 manifest|validate-artifact|final|incident [options]" >&2
  exit 2
}
fail() {
  echo "beta recovery evidence failed: $*" >&2
  exit 1
}
regular() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]
}
sha40() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
sha64() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
bool() { [ "$1" = true ] || [ "$1" = false ]; }
timestamp() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+Z$ ]]; }
safe_path() { [ -n "$1" ] && [ ! -L "$1" ] && [ -d "$(dirname -- "$1")" ]; }
publish() {
  local source=$1 destination=$2
  [ ! -e "$destination" ] || fail "evidence output already exists: $destination"
  mv -- "$source" "$destination" || fail "evidence publication failed"
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
kind=${1:-}
shift || usage
case "$kind" in
  manifest|validate-artifact|validate-runtime|final|incident) ;;
  *) usage ;;
esac

id='' sha='' repo='' run='' artifact='' name='' td='' wd='' dd='' md=''
captured='' point='' db='' files='' bytes='' ud='' dbp='' mp='' runtime=''
database_ciphertext='' uploads_ciphertext=''
pre='' post='' mount='' dispatch='' completed='' status='' failure=''
output='' artifact_dir='' manifest='' restored_db='' restored_media=''
healthy=false equal=false verified=false cleanup=false absent=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --recovery-id) [ "$#" -ge 2 ] || usage; id=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] || usage; sha=$2; shift 2 ;;
    --repository) [ "$#" -ge 2 ] || usage; repo=$2; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage; run=$2; shift 2 ;;
    --artifact-id) [ "$#" -ge 2 ] || usage; artifact=$2; shift 2 ;;
    --artifact-name) [ "$#" -ge 2 ] || usage; name=$2; shift 2 ;;
    --tooling-digest) [ "$#" -ge 2 ] || usage; td=$2; shift 2 ;;
    --workflow-digest) [ "$#" -ge 2 ] || usage; wd=$2; shift 2 ;;
    --database-digest) [ "$#" -ge 2 ] || usage; dd=$2; shift 2 ;;
    --media-digest) [ "$#" -ge 2 ] || usage; md=$2; shift 2 ;;
    --captured-at) [ "$#" -ge 2 ] || usage; captured=$2; shift 2 ;;
    --point-time) [ "$#" -ge 2 ] || usage; point=$2; shift 2 ;;
    --database-bytes) [ "$#" -ge 2 ] || usage; db=$2; shift 2 ;;
    --uploads-files) [ "$#" -ge 2 ] || usage; files=$2; shift 2 ;;
    --uploads-bytes) [ "$#" -ge 2 ] || usage; bytes=$2; shift 2 ;;
    --uploads-digest) [ "$#" -ge 2 ] || usage; ud=$2; shift 2 ;;
    --database-proof) [ "$#" -ge 2 ] || usage; dbp=$2; shift 2 ;;
    --media-proof) [ "$#" -ge 2 ] || usage; mp=$2; shift 2 ;;
    --runtime-proof) [ "$#" -ge 2 ] || usage; runtime=$2; shift 2 ;;
    --database-ciphertext) [ "$#" -ge 2 ] || usage; database_ciphertext=$2; shift 2 ;;
    --uploads-ciphertext) [ "$#" -ge 2 ] || usage; uploads_ciphertext=$2; shift 2 ;;
    --pre-probe) [ "$#" -ge 2 ] || usage; pre=$2; shift 2 ;;
    --post-probe) [ "$#" -ge 2 ] || usage; post=$2; shift 2 ;;
    --mount-contract) [ "$#" -ge 2 ] || usage; mount=$2; shift 2 ;;
    --dispatch-at) [ "$#" -ge 2 ] || usage; dispatch=$2; shift 2 ;;
    --post-probe-at) [ "$#" -ge 2 ] || usage; completed=$2; shift 2 ;;
    --status) [ "$#" -ge 2 ] || usage; status=$2; shift 2 ;;
    --failure-class) [ "$#" -ge 2 ] || usage; failure=$2; shift 2 ;;
    --healthy) [ "$#" -ge 2 ] || usage; healthy=$2; shift 2 ;;
    --equal) [ "$#" -ge 2 ] || usage; equal=$2; shift 2 ;;
    --artifact-verified) [ "$#" -ge 2 ] || usage; verified=$2; shift 2 ;;
    --cleanup-complete) [ "$#" -ge 2 ] || usage; cleanup=$2; shift 2 ;;
    --anonymous-volume-absent) [ "$#" -ge 2 ] || usage; absent=$2; shift 2 ;;
    --artifact-dir) [ "$#" -ge 2 ] || usage; artifact_dir=$2; shift 2 ;;
    --manifest) [ "$#" -ge 2 ] || usage; manifest=$2; shift 2 ;;
    --restored-database-proof) [ "$#" -ge 2 ] || usage; restored_db=$2; shift 2 ;;
    --restored-media-proof) [ "$#" -ge 2 ] || usage; restored_media=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done

safe_json() {
  local file=$1
  regular "$file" || fail "evidence input unavailable: $file"
  jq -e '
    type == "object" and
    ([
      .. | objects | keys[] |
      select(test("(?i)(password|secret|private.?key|credential|api.?key|access.?token|authorization)"))
    ] | length) == 0 and
    ([
      .. | strings |
      select(test("(?i)(postgres(ql)?://|-----BEGIN .*PRIVATE KEY-----|password[=:]|secret[=:]|token[=:])"))
    ] | length) == 0
  ' "$file" >/dev/null || fail "evidence is not secret-safe: $file"
}

validate_database_proof() {
  safe_json "$1"
  jq -e '.schema == "meet-backend/closed-beta-database-proof/v1"' "$1" >/dev/null ||
    fail "database proof schema is invalid"
}

validate_media_proof() {
  safe_json "$1"
  jq -e '
    (keys | sort) == ["bytes","canonicalDigest","files","referencesResolved","referencesTotal","schema"] and
    .schema == "meet-backend/beta-recovery-media-proof/v1" and
    (.files | type == "number" and floor == . and . >= 0) and
    (.bytes | type == "number" and floor == . and . >= 0) and
    (.canonicalDigest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.referencesTotal | type == "number" and floor == . and . >= 0) and
    (.referencesResolved | type == "boolean")
  ' "$1" >/dev/null || fail "media proof contract is invalid"
}

validate_runtime_proof() {
  safe_json "$1"
  jq -e '
    (keys | sort) == ["healthy","https","runtime","schema"] and
    .schema == "meet-backend/test-vps-recovery-runtime/v1" and
    .healthy == true and
    (.runtime | (keys | sort) == ["configHash","health","imageId","uploadsMount"]) and
    (.runtime.configHash | type == "string" and test("^[0-9a-f]{64}$")) and
    .runtime.health == "healthy" and .runtime.uploadsMount == "volume" and
    (.https | (keys | sort) == ["actuatorStatus","httpRedirectHttps","meetingsJson","meetingsStatus"]) and
    .https.meetingsStatus == "200" and .https.actuatorStatus == "404" and
    .https.httpRedirectHttps == true and .https.meetingsJson == true
  ' "$1" >/dev/null || fail "runtime probe is not strictly healthy"
}

validate_manifest_shape() {
  local file=$1 expected_id=$2 expected_sha=$3 expected_repo=$4 expected_run=$5
  safe_json "$file"
  jq -e \
    --arg id "$expected_id" --arg sha "$expected_sha" --arg repo "$expected_repo" --argjson run "$expected_run" '
      (keys | sort) == [
        "artifactFiles","artifactId","artifactName","captureRuntime","capturedAt",
        "contracts","databaseProof","mediaProof","recoveryId","recoveryPointTime",
        "repository","retentionDays","runId","schema","source","sourceSha"
      ] and
      .schema == "meet-backend/beta-recovery-manifest/v1" and
      .recoveryId == $id and .sourceSha == $sha and .repository == $repo and
      .runId == $run and .retentionDays == 30 and
      (.artifactId == null) and
      (.artifactName == ("beta-recovery-" + $id + "-" + ($run|tostring))) and
      (.contracts | (keys | sort) == ["database","media","tooling","workflow"]) and
      (all(.contracts[]; type == "string" and test("^[0-9a-f]{64}$"))) and
      (.artifactFiles | type == "array" and length == 5 and
        map(.path) == [
          "capture-runtime.json","database-proof.json","media-proof.json",
          "postgres.dump.age","uploads.tar.gz.age"
        ] and
        all(.[]; (keys | sort) == ["path","sha256","size"] and
          (.size | type == "number" and floor == . and . > 0) and
          (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))))
    ' "$file" >/dev/null || fail "manifest contract is invalid or unbound"
  timestamp "$(jq -er .capturedAt "$file")" || fail "manifest capture time is invalid"
  timestamp "$(jq -er .recoveryPointTime "$file")" || fail "manifest point time is invalid"
}

artifact_files_json() {
  local artifact_dir=$1
  local path size digest
  for path in capture-runtime.json database-proof.json media-proof.json \
    postgres.dump.age uploads.tar.gz.age; do
    regular "$artifact_dir/$path" || fail "artifact file missing: $path"
    size=$(wc -c <"$artifact_dir/$path" | tr -d '[:space:]')
    digest=$(sha256sum -- "$artifact_dir/$path" | awk '{print $1}')
    [[ "$size" =~ ^[1-9][0-9]*$ ]] || fail "artifact byte count is invalid: $path"
    sha64 "$digest" || fail "artifact digest is invalid: $path"
    jq -cnS --arg path "$path" --arg digest "$digest" --argjson size "$size" \
      '{path:$path,size:$size,sha256:$digest}'
  done | jq -s 'sort_by(.path)'
}

case "$kind" in
  validate-runtime)
    validate_runtime_proof "$runtime"
    ;;
  manifest)
    safe_path "$output" || usage
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || fail "recovery ID malformed"
    sha40 "$sha" || fail "source SHA malformed"
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "repository malformed"
    [[ "$run" =~ ^[1-9][0-9]*$ ]] || fail "run ID malformed"
    [ -z "$artifact" ] || [[ "$artifact" =~ ^[1-9][0-9]*$ ]] || fail "artifact malformed"
    [[ "$name" = "beta-recovery-$id-$run" ]] || fail "artifact name is not source-bound"
    for d in "$td" "$wd" "$dd" "$md"; do sha64 "$d" || fail "contract digest malformed"; done
    timestamp "$captured" || fail "capture time is malformed"
    timestamp "$point" || fail "point time is malformed"
    [[ "$db" =~ ^[0-9]+$ && "$files" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] ||
      fail "aggregate malformed"
    sha64 "$ud" || fail "uploads digest malformed"
    validate_database_proof "$dbp"
    validate_media_proof "$mp"
    validate_runtime_proof "$runtime"
    regular "$database_ciphertext" 2>/dev/null || true
    [ -n "${database_ciphertext:-}" ] && regular "$database_ciphertext" || fail "database ciphertext unavailable"
    [ -n "${uploads_ciphertext:-}" ] && regular "$uploads_ciphertext" || fail "uploads ciphertext unavailable"
    db_cipher_size=$(wc -c <"$database_ciphertext" | tr -d '[:space:]')
    db_cipher_sha=$(sha256sum -- "$database_ciphertext" | awk '{print $1}')
    uploads_cipher_size=$(wc -c <"$uploads_ciphertext" | tr -d '[:space:]')
    uploads_cipher_sha=$(sha256sum -- "$uploads_ciphertext" | awk '{print $1}')
    runtime_size=$(wc -c <"$runtime" | tr -d '[:space:]')
    runtime_sha=$(sha256sum -- "$runtime" | awk '{print $1}')
    dbp_size=$(wc -c <"$dbp" | tr -d '[:space:]')
    dbp_sha=$(sha256sum -- "$dbp" | awk '{print $1}')
    mp_size=$(wc -c <"$mp" | tr -d '[:space:]')
    mp_sha=$(sha256sum -- "$mp" | awk '{print $1}')
    artifact_files=$(jq -cnS \
      --arg rsha "$runtime_sha" --arg dsha "$dbp_sha" --arg msha "$mp_sha" \
      --arg csha "$db_cipher_sha" --arg usha "$uploads_cipher_sha" \
      --argjson rsize "$runtime_size" --argjson dsize "$dbp_size" --argjson msize "$mp_size" \
      --argjson csize "$db_cipher_size" --argjson usize "$uploads_cipher_size" '
      [
        {path:"capture-runtime.json",size:$rsize,sha256:$rsha},
        {path:"database-proof.json",size:$dsize,sha256:$dsha},
        {path:"media-proof.json",size:$msize,sha256:$msha},
        {path:"postgres.dump.age",size:$csize,sha256:$csha},
        {path:"uploads.tar.gz.age",size:$usize,sha256:$usha}
      ]')
    tmp=$output.tmp.$$
    trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
    jq -cnS --arg id "$id" --arg sha "$sha" --arg repo "$repo" --arg run "$run" \
      --arg name "$name" --arg captured "$captured" --arg point "$point" \
      --arg td "$td" --arg wd "$wd" --arg dd "$dd" --arg md "$md" \
      --argjson artifact "${artifact:-null}" --arg artifact_files "$artifact_files" \
      --arg dbp "$(jq -cS . "$dbp")" \
      --arg mp "$(jq -cS . "$mp")" --arg runtime "$(jq -cS . "$runtime")" \
      '{schema:"meet-backend/beta-recovery-manifest/v1",recoveryId:$id,
        repository:$repo,sourceSha:$sha,runId:($run|tonumber),artifactId:$artifact,
        artifactName:$name,retentionDays:30,capturedAt:$captured,
        recoveryPointTime:$point,contracts:{tooling:$td,workflow:$wd,database:$dd,media:$md},
        artifactFiles:($artifact_files|fromjson),databaseProof:($dbp|fromjson),mediaProof:($mp|fromjson),
        captureRuntime:($runtime|fromjson)}' >"$tmp"
    jq --argjson db "$db" --argjson files "$files" --argjson bytes "$bytes" --arg ud "$ud" \
      --arg dbname "$(basename -- "$database_ciphertext")" --arg dsha "$db_cipher_sha" \
      --arg uname "$(basename -- "$uploads_ciphertext")" --arg usha "$uploads_cipher_sha" \
      --argjson dsize "$db_cipher_size" --argjson usize "$uploads_cipher_size" \
      '.source={postgresDatabaseBytes:$db,uploads:{files:$files,bytes:$bytes,digest:$ud},
        ciphertexts:{database:{name:$dbname,size:$dsize,sha256:$dsha},
        uploads:{name:$uname,size:$usize,sha256:$usha}}}' "$tmp" >"$tmp.source"
    mv -f -- "$tmp.source" "$tmp"
    chmod 600 "$tmp"; publish "$tmp" "$output"
    trap - EXIT HUP INT TERM
    ;;
  validate-artifact)
    [ -d "$artifact_dir" ] && [ ! -L "$artifact_dir" ] || usage
    regular "$artifact_dir/recovery-point.json" || fail "manifest missing"
    [ "$(find "$artifact_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" = '' ] ||
      fail "artifact contains a non-file entry"
    [ "$(find "$artifact_dir" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" = 6 ] ||
      fail "artifact shape is not exact"
    validate_manifest_shape "$artifact_dir/recovery-point.json" "$id" "$sha" "$repo" "$run"
    expected=$(jq -cS '.artifactFiles' "$artifact_dir/recovery-point.json")
    actual=$(artifact_files_json "$artifact_dir" | jq -cS .)
    [ "$expected" = "$actual" ] || fail "artifact exact-byte contract mismatch"
    validate_database_proof "$artifact_dir/database-proof.json"
    validate_media_proof "$artifact_dir/media-proof.json"
    validate_runtime_proof "$artifact_dir/capture-runtime.json"
    ;;
  final)
    safe_path "$output" || usage
    [ -n "$manifest" ] || fail "manifest is required"
    manifest_run=$(jq -er '.runId' "$manifest") || fail "manifest run ID is unavailable"
    validate_manifest_shape "$manifest" "$id" "$sha" "$repo" "$manifest_run"
    [[ "$run" =~ ^[1-9][0-9]*$ ]] || fail "drill run ID malformed"
    validate_database_proof "$dbp"; validate_media_proof "$mp"
    validate_database_proof "$restored_db"; validate_media_proof "$restored_media"
    jq -e --slurpfile dbproof "$dbp" --slurpfile mproof "$mp" \
      --slurpfile runtime "$manifest" '
      .databaseProof == $dbproof[0] and .mediaProof == $mproof[0] and
      .captureRuntime == $runtime[0].captureRuntime
    ' "$manifest" >/dev/null || fail "final proofs are not manifest-bound"
    validate_runtime_proof "$pre"; validate_runtime_proof "$post"
    safe_json "$mount"
    jq -e '
      (keys | sort) == ["anonymous","destination","readWrite","schema","type","volumeName"] and
      .schema == "meet-backend/beta-recovery-mount/v1" and .type == "volume" and
      .destination == "/var/lib/postgresql/data" and .readWrite == true and
      .anonymous == true and (.volumeName | type == "string" and length > 0) and
      .volumeName != "meet-production_postgres_data"
    ' "$mount" >/dev/null || fail "mount contract is invalid"
    cmp -- "$pre" "$post" || fail "restore probes are not exactly equal"
    for b in "$healthy" "$equal" "$verified" "$cleanup" "$absent"; do bool "$b" || fail "boolean malformed"; done
    [ "$healthy" = true ] && [ "$equal" = true ] && [ "$verified" = true ] &&
      [ "$cleanup" = true ] && [ "$absent" = true ] || fail "final evidence is not successful"
    timestamp "$dispatch" || fail "dispatch time is malformed"
    timestamp "$completed" || fail "post-probe time is malformed"
    rto=$(jq -nr --arg a "$dispatch" --arg b "$completed" \
      '($b|fromdateiso8601)-($a|fromdateiso8601)') || fail "RTO is not parseable"
    [[ "$rto" =~ ^[0-9]+$ ]] && [ "$rto" -ge 0 ] && [ "$rto" -le 7200 ] ||
      fail "RTO exceeds two hours"
    manifest_artifact=$(jq -r '.artifactName' "$manifest")
    [ "$name" = "$manifest_artifact" ] || fail "artifact name is not manifest-bound"
    [[ "$artifact" =~ ^[1-9][0-9]*$ ]] || fail "artifact ID is required"
    tmp=$output.tmp.$$
    trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
    jq -cnS --arg id "$id" --arg sha "$sha" --arg repo "$repo" --arg run "$run" \
      --arg name "$name" --arg captured "$(jq -r .capturedAt "$manifest")" \
      --arg point "$(jq -r .recoveryPointTime "$manifest")" --arg dispatch "$dispatch" \
      --arg completed "$completed" --arg status "$status" --arg failure "$failure" \
      --arg td "$(jq -r .contracts.tooling "$manifest")" --arg wd "$(jq -r .contracts.workflow "$manifest")" \
      --arg dd "$(jq -r .contracts.database "$manifest")" --arg md "$(jq -r .contracts.media "$manifest")" \
      --argjson artifact "$artifact" --argjson source "$(jq -cS .source "$manifest")" \
      --argjson contract "$(jq -cS .artifactFiles "$manifest")" \
      --argjson healthy "$healthy" --argjson equal "$equal" --argjson verified "$verified" \
      --argjson cleanup "$cleanup" --argjson absent "$absent" \
      --arg pre "$(jq -cS . "$pre")" --arg post "$(jq -cS . "$post")" \
      --arg mount "$(jq -cS . "$mount")" --arg dbp "$(jq -cS . "$dbp")" \
      --arg mp "$(jq -cS . "$mp")" --arg rdb "$(jq -cS . "$restored_db")" \
      --arg rmp "$(jq -cS . "$restored_media")" --argjson rto "$rto" \
      '{schema:"meet-backend/beta-recovery-drill/v1",recoveryId:$id,repository:$repo,
        sourceSha:$sha,runId:($run|tonumber),
        artifact:{id:$artifact,name:$name,retentionDays:30,files:$contract},
        capturedAt:$captured,recoveryPointTime:$point,contracts:{tooling:$td,workflow:$wd,database:$dd,media:$md},
        source:$source,databaseProof:($dbp|fromjson),mediaProof:($mp|fromjson),
        restore:{healthy:$healthy,equal:$equal,cleanupComplete:$cleanup,
          anonymousVolumeAbsent:$absent,mountContract:($mount|fromjson),
          restoredDatabaseProof:($rdb|fromjson),restoredMediaProof:($rmp|fromjson)},
        preProbe:($pre|fromjson),postProbe:($post|fromjson),
        timing:{dispatchAt:$dispatch,postProbeAt:$completed,dispatchToPostProbeSeconds:$rto},
        artifactVerified:$verified,status:$status,
        failureClass:(if $failure == "" then null else $failure end)}' >"$tmp"
    safe_json "$tmp"
    chmod 600 "$tmp"; publish "$tmp" "$output"; trap - EXIT INT TERM
    ;;
  incident)
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || fail "recovery ID malformed"
    case "$failure" in authorizationFailed|artifactInvalid|preProbeFailed|restoreFailed|postProbeFailed|cleanupFailure|evidenceValidationFailed) ;; *) fail "failure class is not allowlisted" ;; esac
    case "${status:-incident}" in incident|failed) ;; *) fail "incident status is invalid" ;; esac
    safe_path "$output" || usage
    tmp=$output.tmp.$$
    trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
    jq -cnS --arg id "$id" --arg status "${status:-incident}" --arg failure "$failure" \
      '{schema:"meet-backend/beta-recovery-incident/v1",recoveryId:$id,
        status:$status,failureClass:$failure,sanitized:true}' >"$tmp"
    safe_json "$tmp"
    chmod 600 "$tmp"; publish "$tmp" "$output"; trap - EXIT HUP INT TERM
    ;;
esac
