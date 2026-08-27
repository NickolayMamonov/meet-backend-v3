#!/usr/bin/env bash
set -euo pipefail
usage(){ echo "usage: $0 manifest|final|incident [options]" >&2; exit 2; }
fail(){ echo "beta recovery evidence failed: $*" >&2; exit 1; }
regular(){ [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }
sha40(){ [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }; sha64(){ [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
bool(){ [ "$1" = true ] || [ "$1" = false ]; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
kind=${1:-}; shift || usage; case "$kind" in manifest|final|incident);; *) usage;; esac
id='' sha='' repo='' run='' artifact='' name='' td='' wd='' dd='' md='' captured='' point='' db='' files='' bytes='' ud='' dbp='' mp='' pre='' post='' mount='' dispatch='' completed='' status='' failure='' output='' database_ciphertext='' uploads_ciphertext=''
healthy=false; equal=false; verified=false; cleanup=false; absent=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --recovery-id) id=$2; shift 2;; --source-sha) sha=$2; shift 2;; --repository) repo=$2; shift 2;;
    --run-id) run=$2; shift 2;; --artifact-id) artifact=$2; shift 2;; --artifact-name) name=$2; shift 2;;
    --tooling-digest) td=$2; shift 2;; --workflow-digest) wd=$2; shift 2;; --database-digest) dd=$2; shift 2;;
    --media-digest) md=$2; shift 2;; --captured-at) captured=$2; shift 2;; --point-time) point=$2; shift 2;;
    --database-bytes) db=$2; shift 2;; --uploads-files) files=$2; shift 2;; --uploads-bytes) bytes=$2; shift 2;;
    --uploads-digest) ud=$2; shift 2;; --database-proof) dbp=$2; shift 2;; --media-proof) mp=$2; shift 2;;
    --database-ciphertext) database_ciphertext=$2; shift 2;; --uploads-ciphertext) uploads_ciphertext=$2; shift 2;;
    --pre-probe) pre=$2; shift 2;; --post-probe) post=$2; shift 2;; --mount-contract) mount=$2; shift 2;;
    --dispatch-at) dispatch=$2; shift 2;; --post-probe-at) completed=$2; shift 2;; --status) status=$2; shift 2;;
    --failure-class) failure=$2; shift 2;; --healthy) healthy=$2; shift 2;; --equal) equal=$2; shift 2;;
    --artifact-verified) verified=$2; shift 2;; --cleanup-complete) cleanup=$2; shift 2;;
    --anonymous-volume-absent) absent=$2; shift 2;; --output) output=$2; shift 2;; *) usage;;
  esac
done
[ -n "$output" ] && [ ! -L "$output" ] && [ -d "$(dirname -- "$output")" ] || usage
[[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || fail "recovery ID malformed"
sha40 "$sha" || fail "source SHA malformed"; [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "repository malformed"
[[ "$run" =~ ^[1-9][0-9]*$ ]] || fail "run ID malformed"; [[ -z "$artifact" || "$artifact" =~ ^[1-9][0-9]*$ ]] || fail "artifact malformed"
for d in "$td" "$wd" "$dd" "$md"; do sha64 "$d" || fail "contract digest malformed"; done
tmp=$output.tmp.$$; trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
case "$kind" in
manifest)
  [[ "$db" =~ ^[0-9]+$ && "$files" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || fail "aggregate malformed"
  sha64 "$ud" || fail "uploads digest malformed"
  if ! regular "$dbp" || ! regular "$mp"; then fail "proof unavailable"; fi
  [ -z "$database_ciphertext" ] || regular "$database_ciphertext" || fail "database ciphertext unavailable"
  [ -z "$uploads_ciphertext" ] || regular "$uploads_ciphertext" || fail "uploads ciphertext unavailable"
  db_cipher_size=0; db_cipher_sha=; uploads_cipher_size=0; uploads_cipher_sha=
  if [ -n "$database_ciphertext" ]; then db_cipher_size=$(wc -c <"$database_ciphertext" | tr -d '[:space:]'); db_cipher_sha=$(sha256sum -- "$database_ciphertext" | awk '{print $1}'); fi
  if [ -n "$uploads_ciphertext" ]; then uploads_cipher_size=$(wc -c <"$uploads_ciphertext" | tr -d '[:space:]'); uploads_cipher_sha=$(sha256sum -- "$uploads_ciphertext" | awk '{print $1}'); fi
  jq -cnS --arg id "$id" --arg sha "$sha" --arg repo "$repo" --arg run "$run" --arg name "$name" \
    --arg captured "$captured" --arg point "$point" --arg td "$td" --arg wd "$wd" --arg dd "$dd" --arg md "$md" \
    --argjson artifact "${artifact:-null}" --argjson db "$db" --argjson files "$files" --argjson bytes "$bytes" \
    --arg ud "$ud" --arg dbp "$(jq -cS . "$dbp")" --arg mp "$(jq -cS . "$mp")" \
    --arg dbCipherName "$(basename -- "${database_ciphertext:-postgres.dump.age}")" \
    --arg dbCipherSha "$db_cipher_sha" --arg uploadsCipherName "$(basename -- "${uploads_ciphertext:-uploads.tar.gz.age}")" \
    --arg uploadsCipherSha "$uploads_cipher_sha" --argjson dbCipherSize "$db_cipher_size" \
    --argjson uploadsCipherSize "$uploads_cipher_size" \
    '{schema:"meet-backend/beta-recovery-manifest/v1",recoveryId:$id,repository:$repo,sourceSha:$sha,
      runId:($run|tonumber),artifactId:$artifact,artifactName:$name,retentionDays:30,capturedAt:$captured,
      recoveryPointTime:$point,contracts:{tooling:$td,workflow:$wd,database:$dd,media:$md},
      source:{postgresDatabaseBytes:$db,uploads:{files:$files,bytes:$bytes,digest:$ud},
        ciphertexts:{database:{name:$dbCipherName,size:$dbCipherSize,sha256:$dbCipherSha},
        uploads:{name:$uploadsCipherName,size:$uploadsCipherSize,sha256:$uploadsCipherSha}}},
      databaseProof:($dbp|fromjson),mediaProof:($mp|fromjson)}' >"$tmp";;
final)
  for b in "$healthy" "$equal" "$verified" "$cleanup" "$absent"; do bool "$b" || fail "boolean malformed"; done
  [ "$healthy" = true ] && [ "$equal" = true ] && [ "$verified" = true ] &&
    [ "$cleanup" = true ] && [ "$absent" = true ] || fail "final evidence is not successful"
  if ! regular "$dbp" || ! regular "$mp" || ! regular "$pre" ||
    ! regular "$post" || ! regular "$mount"; then
    fail "final input unavailable"
  fi
  cmp -- "$pre" "$post" || fail "restore probes are not exactly equal"
  [[ "$dispatch" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+Z$ ]] ||
    fail "dispatch time is malformed"
  [[ "$completed" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+Z$ ]] ||
    fail "post-probe time is malformed"
  rto=$(jq -nr --arg dispatch "$dispatch" --arg completed "$completed" \
    '($completed|fromdateiso8601)-($dispatch|fromdateiso8601)') || fail "RTO is not parseable"
  [[ "$rto" =~ ^[0-9]+$ ]] && [ "$rto" -le 7200 ] || fail "RTO exceeds two hours"
  jq -cnS --arg id "$id" --arg sha "$sha" --arg repo "$repo" --arg run "$run" --arg name "$name" \
    --arg captured "$captured" --arg point "$point" --arg dispatch "$dispatch" --arg completed "$completed" \
    --arg status "$status" --arg failure "$failure" --arg td "$td" --arg wd "$wd" --arg dd "$dd" --arg md "$md" \
    --argjson artifact "${artifact:-null}" --argjson db "$db" --argjson files "$files" --argjson bytes "$bytes" \
    --arg ud "$ud" --argjson healthy "$healthy" --argjson equal "$equal" --argjson verified "$verified" \
    --argjson cleanup "$cleanup" --argjson absent "$absent" --arg pre "$(jq -cS . "$pre")" \
    --arg post "$(jq -cS . "$post")" --arg mount "$(jq -cS . "$mount")" \
    --arg dbp "$(jq -cS . "$dbp")" --arg mp "$(jq -cS . "$mp")" \
    '{schema:"meet-backend/beta-recovery-drill/v1",recoveryId:$id,repository:$repo,sourceSha:$sha,
      runId:($run|tonumber),artifactId:$artifact,artifactName:$name,retentionDays:30,capturedAt:$captured,
      recoveryPointTime:$point,contracts:{tooling:$td,workflow:$wd,database:$dd,media:$md},
      source:{postgresDatabaseBytes:$db,uploads:{files:$files,bytes:$bytes,digest:$ud}},
      databaseProof:($dbp|fromjson),mediaProof:($mp|fromjson),
      restore:{healthy:$healthy,equal:$equal,cleanupComplete:$cleanup,anonymousVolumeAbsent:$absent,
        mountContract:($mount|fromjson)},preProbe:($pre|fromjson),postProbe:($post|fromjson),
      timing:{dispatchAt:$dispatch,postProbeAt:$completed,dispatchToPostProbeSeconds:($rto|tonumber)},
      artifactVerified:$verified,status:$status,
      failureClass:(if $failure == "" then null else $failure end)}' >"$tmp";;
incident)
  [ -n "$failure" ] || fail "incident failure class is required"
  jq -cnS --arg id "$id" --arg status "${status:-incident}" --arg failure "$failure" \
    '{schema:"meet-backend/beta-recovery-incident/v1",recoveryId:$id,status:$status,failureClass:$failure,sanitized:true}' >"$tmp";;
esac
chmod 600 "$tmp"; mv -f -- "$tmp" "$output"; trap - EXIT HUP INT TERM
