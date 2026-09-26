#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --output DIR --slot UTC_SLOT --captured-at EPOCH --source-revision SHA --runtime-revision SHA --contract-digest DIGEST --proof-digest DIGEST --capture-command PATH --capture-output DIR --age-binary PATH --age-recipient-file PATH [--owner OWNER]" >&2
  exit 2
}

output='' storage_root=${BETA_BACKUP_STORAGE_ROOT:-} slot='' captured_at='' source_revision='' runtime_revision=''
contract_digest='' proof_digest='' capture_command='' capture_output=''
age_binary='' age_recipient_file='' owner=${BETA_BACKUP_OWNER:-capture}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    --storage-root) [ "$#" -ge 2 ] || usage; storage_root=$2; shift 2 ;;
    --slot) [ "$#" -ge 2 ] || usage; slot=$2; shift 2 ;;
    --captured-at) [ "$#" -ge 2 ] || usage; captured_at=$2; shift 2 ;;
    --source-revision) [ "$#" -ge 2 ] || usage; source_revision=$2; shift 2 ;;
    --runtime-revision) [ "$#" -ge 2 ] || usage; runtime_revision=$2; shift 2 ;;
    --contract-digest) [ "$#" -ge 2 ] || usage; contract_digest=$2; shift 2 ;;
    --proof-digest) [ "$#" -ge 2 ] || usage; proof_digest=$2; shift 2 ;;
    --capture-command) [ "$#" -ge 2 ] || usage; capture_command=$2; shift 2 ;;
    --capture-output) [ "$#" -ge 2 ] || usage; capture_output=$2; shift 2 ;;
    --age-binary) [ "$#" -ge 2 ] || usage; age_binary=$2; shift 2 ;;
    --age-recipient-file) [ "$#" -ge 2 ] || usage; age_recipient_file=$2; shift 2 ;;
    --owner) [ "$#" -ge 2 ] || usage; owner=$2; shift 2 ;;
    *) usage ;;
  esac
done

for path in "$output" "$capture_command" "$capture_output" "$age_binary" "$age_recipient_file"; do
  [[ "$path" = /* && "$path" != *..* && "$path" != *$'\n'* ]] || usage
done
[[ "$slot" =~ ^[0-9]{10}$ && "$captured_at" =~ ^[0-9]+$ ]] || usage
[[ "$source_revision" =~ ^[0-9a-f]{40}$ && "$runtime_revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$contract_digest" =~ ^[0-9a-f]{64}$ && "$proof_digest" =~ ^[0-9a-f]{64}$ ]] || usage
[ -x "$capture_command" ] && [ ! -L "$capture_command" ] || {
  echo 'BACKUP_CAPTURE_BLOCKED:capture_command_unavailable' >&2
  exit 1
}
[ -x "$age_binary" ] && [ ! -L "$age_binary" ] || {
  echo 'BACKUP_CAPTURE_BLOCKED:age_binary_unavailable' >&2
  exit 1
}
[ -f "$age_recipient_file" ] && [ ! -L "$age_recipient_file" ] || {
  echo 'BACKUP_CAPTURE_BLOCKED:recipient_unavailable' >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || { echo 'BACKUP_CAPTURE_BLOCKED:jq_unavailable' >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo 'BACKUP_CAPTURE_BLOCKED:timeout_unavailable' >&2; exit 1; }
age_version=$("$age_binary" --version 2>/dev/null) || {
  echo 'BACKUP_CAPTURE_BLOCKED:age_unavailable' >&2
  exit 1
}
[[ "$age_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'BACKUP_CAPTURE_BLOCKED:age_version_invalid' >&2
  exit 1
}
recipient=$(awk 'NR==1 {print; next} NF {exit 1}' "$age_recipient_file") || {
  echo 'BACKUP_CAPTURE_BLOCKED:recipient_invalid' >&2
  exit 1
}
[[ "$recipient" =~ ^age1[0-9a-z]{20,}$ ]] || {
  echo 'BACKUP_CAPTURE_BLOCKED:recipient_invalid' >&2
  exit 1
}

mkdir -p "$output" "$capture_output"
[ ! -L "$output" ] && [ ! -L "$capture_output" ] || {
  echo 'BACKUP_CAPTURE_BLOCKED:capture_output_symlink' >&2
  exit 1
}

source_manifest="$capture_output/capture-result.json"
cleanup_capture() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -f -- "$capture_output/postgres.dump" "$capture_output/uploads.tar.gz" \
    "$source_manifest" "${tmp:-}" || status=1
  if [ "$status" -ne 0 ]; then
    rm -f -- "$output/postgres.dump.age" "$output/uploads.tar.gz.age" \
      "$output/recovery-point.json" "$output/point.json" || status=1
  fi
  exit "$status"
}
trap cleanup_capture EXIT HUP INT TERM
capture_digest=$(sha256sum "$capture_command" | awk '{print $1}')
timeout --foreground --signal=TERM 900s "$capture_command" \
  --output-dir "$capture_output" --slot "$slot" --captured-at "$captured_at"

[ -f "$source_manifest" ] && [ ! -L "$source_manifest" ] || {
  echo 'BACKUP_CAPTURE_BLOCKED:capture_evidence_missing' >&2
  exit 1
}
[ "$(wc -c <"$source_manifest")" -le 65536 ] || {
  echo 'BACKUP_CAPTURE_BLOCKED:capture_evidence_oversize' >&2
  exit 1
}
db_ciphertext="$output/postgres.dump.age"
media_ciphertext="$output/uploads.tar.gz.age"
source_schema=$(jq -er '.schema' "$source_manifest") || {
  echo 'BACKUP_CAPTURE_BLOCKED:capture_evidence_invalid' >&2
  exit 1
}
if [ "$source_schema" = meet-backend/beta-recurring-capture-source/v1 ]; then
  jq -e \
    --arg slot "$slot" --argjson captured "$captured_at" \
    --arg source "$source_revision" --arg command "$capture_digest" '
    type=="object" and
    (keys|sort)==["captureCommandDigest","capturedAt","database","media","schema","slotId","sourceRevision"] and
    .schema=="meet-backend/beta-recurring-capture-source/v1" and
    .slotId==$slot and .capturedAt==$captured and .sourceRevision==$source and
    .captureCommandDigest==$command and
    (.database|type=="object" and (keys|sort)==["length","sha256"] and
      (.length|type=="number" and floor==. and .>0) and
      (.sha256|type=="string" and test("^[0-9a-f]{64}$"))) and
    (.media|type=="object" and (keys|sort)==["length","sha256"] and
      (.length|type=="number" and floor==. and .>0) and
      (.sha256|type=="string" and test("^[0-9a-f]{64}$")))
  ' "$source_manifest" >/dev/null || {
    echo 'BACKUP_CAPTURE_BLOCKED:capture_evidence_invalid' >&2
    exit 1
  }
  for name in postgres.dump uploads.tar.gz; do
    [ -f "$capture_output/$name" ] && [ ! -L "$capture_output/$name" ] &&
      [ -s "$capture_output/$name" ] || {
        echo "BACKUP_CAPTURE_BLOCKED:plaintext_${name}_missing" >&2
        exit 1
      }
  done
  db_length=$(wc -c <"$capture_output/postgres.dump" | tr -d '[:space:]')
  media_length=$(wc -c <"$capture_output/uploads.tar.gz" | tr -d '[:space:]')
  db_sha=$(sha256sum "$capture_output/postgres.dump" | awk '{print $1}')
  media_sha=$(sha256sum "$capture_output/uploads.tar.gz" | awk '{print $1}')
  [ "$db_length" = "$(jq -er '.database.length' "$source_manifest")" ] &&
    [ "$db_sha" = "$(jq -er '.database.sha256' "$source_manifest")" ] &&
    [ "$media_length" = "$(jq -er '.media.length' "$source_manifest")" ] &&
    [ "$media_sha" = "$(jq -er '.media.sha256' "$source_manifest")" ] || {
      echo 'BACKUP_CAPTURE_BLOCKED:plaintext_evidence_mismatch' >&2
      exit 1
    }
  "$age_binary" -r "$recipient" -o "$db_ciphertext" "$capture_output/postgres.dump"
  "$age_binary" -r "$recipient" -o "$media_ciphertext" "$capture_output/uploads.tar.gz"
elif [ "$source_schema" = meet-backend/beta-recovery-capture/v1 ]; then
  jq -e \
    --arg slot "$slot" --argjson captured "$captured_at" --arg command "$capture_digest" '
    type=="object" and
    (keys|sort)==["capturedAt","ciphertexts","proofs","recoveryId","recoveryPointTime","schema"] and
    .schema=="meet-backend/beta-recovery-capture/v1" and
    .recoveryId==("recurring-"+$slot) and .recoveryPointTime==$captured and
    (.capturedAt|type=="string") and
    (.ciphertexts|type=="object" and (keys|sort)==["database","uploads"] and
      all(.[]; (keys|sort)==["name","sha256","size"] and
        .name|type=="string" and .sha256|test("^[0-9a-f]{64}$") and
        .size|type=="number" and floor==. and .>0)) and
    (.proofs|type=="object")
  ' "$source_manifest" >/dev/null || {
    echo 'BACKUP_CAPTURE_BLOCKED:generated_capture_evidence_invalid' >&2
    exit 1
  }
  for name in postgres.dump.age uploads.tar.gz.age; do
    [ -f "$capture_output/$name" ] && [ ! -L "$capture_output/$name" ] &&
      [ -s "$capture_output/$name" ] || {
        echo "BACKUP_CAPTURE_BLOCKED:generated_${name}_missing" >&2
        exit 1
      }
    head -n 1 "$capture_output/$name" | grep -Fxq 'age-encryption.org/v1' || {
      echo 'BACKUP_CAPTURE_BLOCKED:generated_ciphertext_invalid' >&2
      exit 1
    }
  done
  cp -- "$capture_output/postgres.dump.age" "$db_ciphertext"
  cp -- "$capture_output/uploads.tar.gz.age" "$media_ciphertext"
else
  echo 'BACKUP_CAPTURE_BLOCKED:capture_schema_unsupported' >&2
  exit 1
fi
for ciphertext in "$db_ciphertext" "$media_ciphertext"; do
  [ -s "$ciphertext" ] && [ ! -L "$ciphertext" ] || {
    echo 'BACKUP_CAPTURE_BLOCKED:encryption_output_missing' >&2
    exit 1
  }
  head -n 1 "$ciphertext" | grep -Fxq 'age-encryption.org/v1' || {
    echo 'BACKUP_CAPTURE_BLOCKED:encryption_format_invalid' >&2
    exit 1
  }
  chmod 600 "$ciphertext"
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_digest=$(sha256sum "$source_manifest" | awk '{print $1}')
tmp=$(mktemp "$output/.recovery-point.XXXXXX")
trap cleanup_capture EXIT HUP INT TERM
jq -cnS \
  --arg slot "$slot" --arg source "$source_revision" --arg runtime "$runtime_revision" \
  --arg command "$capture_digest" --arg evidence "$source_digest" \
  --argjson captured "$captured_at" --arg contract "$contract_digest" \
  --arg proof "$proof_digest" \
  '{schema:"meet-backend/beta-recovery-point/v2",pointId:("slot-"+$slot),slotId:$slot,
    capture:{capturedAt:$captured,sourceRevision:$source},
    captureCommandDigest:$command,captureEvidenceDigest:$evidence,
    runtimeRevision:$runtime,contractDigest:$contract,proofDigest:$proof}' >"$tmp"
mv -f -- "$tmp" "$output/recovery-point.json"
chmod 600 "$output/recovery-point.json"
for proof in capture-database-proof.json capture-media-proof.json; do
  if [ -f "$capture_output/$proof" ] && [ ! -L "$capture_output/$proof" ]; then
    cp -- "$capture_output/$proof" "$output/$proof"
    chmod 600 "$output/$proof"
  fi
done
publish_args=(
  publish --source "$output" --point-id "slot-$slot" --slot "$slot"
  --captured-at "$captured_at" --owner "$owner"
)
[ -n "$storage_root" ] && publish_args+=(--storage-root "$storage_root")
"$script_dir/run-beta-backup-storage.sh" "${publish_args[@]}"
rm -rf -- "$capture_output" "$output"
trap - EXIT HUP INT TERM
printf 'recurring_capture=committed point_id=slot-%s encrypted=true source_digest=%s durable=true\n' \
  "$slot" "$source_digest"
