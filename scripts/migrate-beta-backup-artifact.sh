#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --source DIR --destination DIR --manifest PATH [--storage-root DIR|--remote] --restore-command PATH --restore-output DIR --identity-file PATH --capture-revision SHA --restore-revision SHA --proof-output PATH" >&2
  exit 2
}

source_dir='' destination_dir='' manifest='' storage_root=''
restore_command='' restore_output='' identity='' capture_revision=''
restore_revision='' proof_output='' source_artifact_id='' source_run_id=''
remote=false
source_tmp=''
remote_scratch=''
cleanup_source_auth() {
  local status=$?
  trap - EXIT HUP INT TERM
  [ -z "$source_tmp" ] || rm -rf -- "$source_tmp" || status=1
  [ -z "$remote_scratch" ] || rm -rf -- "$remote_scratch" || status=1
  [ -z "$identity" ] || rm -f -- "$identity" || status=1
  exit "$status"
}
trap cleanup_source_auth EXIT HUP INT TERM
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] || usage; source_dir=$2; shift 2 ;;
    --destination) [ "$#" -ge 2 ] || usage; destination_dir=$2; shift 2 ;;
    --manifest) [ "$#" -ge 2 ] || usage; manifest=$2; shift 2 ;;
    --storage-root) [ "$#" -ge 2 ] || usage; storage_root=$2; shift 2 ;;
    --restore-command) [ "$#" -ge 2 ] || usage; restore_command=$2; shift 2 ;;
    --restore-output) [ "$#" -ge 2 ] || usage; restore_output=$2; shift 2 ;;
    --identity-file) [ "$#" -ge 2 ] || usage; identity=$2; shift 2 ;;
    --capture-revision) [ "$#" -ge 2 ] || usage; capture_revision=$2; shift 2 ;;
    --restore-revision) [ "$#" -ge 2 ] || usage; restore_revision=$2; shift 2 ;;
    --proof-output) [ "$#" -ge 2 ] || usage; proof_output=$2; shift 2 ;;
    --source-artifact-id) [ "$#" -ge 2 ] || usage; source_artifact_id=$2; shift 2 ;;
    --source-run-id) [ "$#" -ge 2 ] || usage; source_run_id=$2; shift 2 ;;
    --remote) remote=true; shift ;;
    *) usage ;;
  esac
done

for path in "$source_dir" "$destination_dir" "$manifest" \
  "$restore_command" "$restore_output" "$identity" "$proof_output"; do
  [[ "$path" = /* && "$path" != *..* && "$path" != *$'\n'* ]] || usage
done
[ "$remote" = true ] || {
  [[ "$storage_root" = /* && "$storage_root" != *..* && "$storage_root" != *$'\n'* ]] || usage
}
[[ "$capture_revision" =~ ^[0-9a-f]{40}$ &&
  "$restore_revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$source_artifact_id" =~ ^[1-9][0-9]*$ &&
  "$source_run_id" =~ ^[1-9][0-9]*$ ]] || usage

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
command -v curl >/dev/null 2>&1 || exit 1
command -v unzip >/dev/null 2>&1 || exit 1
[ -d "$source_dir" ] && [ ! -L "$source_dir" ] || {
  echo 'BACKUP_STORAGE_BLOCKED:source_unavailable' >&2; exit 1;
}
[ -d "$destination_dir" ] && [ ! -L "$destination_dir" ] || {
  echo 'BACKUP_STORAGE_BLOCKED:destination_unavailable' >&2; exit 1;
}
[ -z "$(find "$destination_dir" -mindepth 1 -print -quit)" ] || {
  echo 'BACKUP_STORAGE_BLOCKED:destination_not_empty' >&2; exit 1;
}
[ -f "$manifest" ] && [ ! -L "$manifest" ] || {
  echo 'BACKUP_STORAGE_BLOCKED:manifest_unavailable' >&2; exit 1;
}
[ -f "$source_dir/recovery-point.json" ] && [ ! -L "$source_dir/recovery-point.json" ] &&
  cmp -s "$manifest" "$source_dir/recovery-point.json" || {
    echo 'BACKUP_STORAGE_BLOCKED:manifest_source_mismatch' >&2; exit 1;
  }
[ -x "$restore_command" ] && [ ! -L "$restore_command" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_command_unavailable' >&2; exit 1;
}
[ -f "$identity" ] && [ ! -L "$identity" ] && [ -s "$identity" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_identity_unavailable' >&2; exit 1;
}
command -v jq >/dev/null 2>&1 || exit 1
command -v timeout >/dev/null 2>&1 || exit 1

source_tmp=$(mktemp -d)
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
api=${GITHUB_API_URL:-https://api.github.com}
[ "$api" = https://api.github.com ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:source_api_origin_invalid' >&2
  exit 1
}
api_get() {
  local name=$1 path=$2
  timeout --foreground 30s curl --fail --silent --show-error \
    --connect-timeout 5 --max-time 30 --max-filesize 1048576 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api$path" >"$source_tmp/$name" ||
    { echo 'BACKUP_CUSTODY_BLOCKED:source_api_unavailable' >&2; exit 1; }
  [ "$(wc -c <"$source_tmp/$name")" -le 1048576 ] || {
    echo 'BACKUP_CUSTODY_BLOCKED:source_api_oversize' >&2; exit 1;
  }
  jq -e . "$source_tmp/$name" >/dev/null ||
    { echo 'BACKUP_CUSTODY_BLOCKED:source_api_invalid' >&2; exit 1; }
}
api_get source-run "/repos/$GITHUB_REPOSITORY/actions/runs/$source_run_id"
api_get source-artifact.json "/repos/$GITHUB_REPOSITORY/actions/artifacts/$source_artifact_id"
jq -e --arg repo "$GITHUB_REPOSITORY" --argjson run "$source_run_id" \
  --arg capture "$capture_revision" '
  .id==$run and .repository.full_name==$repo and
  .path==".github/workflows/prove-beta-backup-restore.yml" and
  .head_sha==$capture and .status=="completed" and .conclusion=="success"
' "$source_tmp/source-run" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:source_run_binding_invalid' >&2; exit 1;
}
jq -e --argjson artifact "$source_artifact_id" --argjson run "$source_run_id" '
  .id==$artifact and .expired==false and
  .workflow_run.id==$run and .size_in_bytes>0 and
  (.digest|type=="string" and test("^sha256:[0-9a-f]{64}$")) and
  (.created_at|type=="string" and length>0) and
  (.expires_at|type=="string" and length>0)
' "$source_tmp/source-artifact.json" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_binding_invalid' >&2; exit 1;
}
artifact_headers="$source_tmp/source.headers"
if ! artifact_status=$(timeout --foreground 60s curl --silent --show-error \
  --max-redirs 0 --connect-timeout 5 --max-time 60 \
  --max-filesize 67108864 --dump-header "$artifact_headers" \
  --output "$source_tmp/source.zip" --write-out '%{http_code}' \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$api/repos/$GITHUB_REPOSITORY/actions/artifacts/$source_artifact_id/zip"); then
  echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_unavailable' >&2; exit 1
fi
case "$artifact_status" in
  2[0-9][0-9]) ;;
  3[0-9][0-9])
    artifact_location=$(awk 'BEGIN { IGNORECASE=1 }
      /^Location:[[:space:]]*/ {
        sub(/^[^:]*:[[:space:]]*/, ""); print; exit
      }' "$artifact_headers" | tr -d '\r')
    [[ "$artifact_location" =~ ^https://([A-Za-z0-9.-]+\.blob\.core\.windows\.net|pipelines\.actions\.githubusercontent\.com)/[^[:space:]]+$ ]] ||
      { echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_redirect_invalid' >&2; exit 1; }
    curl --fail --silent --show-error --max-redirs 0 \
      --connect-timeout 5 --max-time 60 --max-filesize 67108864 \
      "$artifact_location" >"$source_tmp/source.zip" 2>"$source_tmp/source.zip.error" ||
      { echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_unavailable' >&2; exit 1; }
    ;;
  *) echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_unavailable' >&2; exit 1 ;;
esac
[ "$(wc -c <"$source_tmp/source.zip")" -le 67108864 ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_oversize' >&2; exit 1;
}
downloaded_digest=$(sha256sum "$source_tmp/source.zip" | awk '{print $1}')
expected_digest=$(jq -er '.digest' "$source_tmp/source-artifact.json")
[ "sha256:$downloaded_digest" = "$expected_digest" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_digest_mismatch' >&2; exit 1;
}
mkdir "$source_tmp/source-artifact"
chmod 700 "$source_tmp/source-artifact" 2>/dev/null || true
unzip -q -o "$source_tmp/source.zip" -d "$source_tmp/source-artifact"
[ -z "$(find "$source_dir" -type l -print -quit)" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:source_symlink_present' >&2; exit 1;
}
[ -z "$(find "$source_tmp/source-artifact" -type l -print -quit)" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_symlink_present' >&2; exit 1;
}
source_files=$(find "$source_dir" -type f -printf '%P\n' | sort)
artifact_files=$(find "$source_tmp/source-artifact" -type f -printf '%P\n' | sort)
[ "$source_files" = "$artifact_files" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_files_mismatch' >&2; exit 1;
}
while IFS= read -r source_file; do
  cmp -s "$source_dir/$source_file" "$source_tmp/source-artifact/$source_file" || {
    echo 'BACKUP_CUSTODY_BLOCKED:source_artifact_content_mismatch' >&2; exit 1;
  }
done <<<"$source_files"
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
if [ "$remote" = true ]; then
  beta_storage_require_config
else
  [ "${BETA_BACKUP_TEST_FIXTURE:-false}" = true ] || {
    echo 'BACKUP_STORAGE_BLOCKED:local_authority_fixture_only' >&2
    exit 1
  }
  beta_storage_require_local_root "$storage_root" >/dev/null
fi
source_manifest=$manifest
source_manifest_sha=$(sha256sum "$source_manifest" | awk '{print $1}')
manifest_schema=$(jq -er '.schema' "$source_manifest") || {
  echo 'BACKUP_STORAGE_BLOCKED:manifest_invalid' >&2; exit 1;
}
if [ "$manifest_schema" = meet-backend/beta-recovery-manifest/v1 ]; then
  beta_storage_validate_v1_import "$source_manifest" "$source_run_id" \
    "$GITHUB_REPOSITORY" "$capture_revision" || {
      echo 'BACKUP_STORAGE_BLOCKED:v1_import_invalid' >&2; exit 1;
    }
  point_id=$(jq -er '.recoveryId' "$source_manifest")
  captured_at=$(date -u -d "$(jq -er '.recoveryPointTime' "$source_manifest")" +%s) || {
    echo 'BACKUP_STORAGE_BLOCKED:v1_capture_time_invalid' >&2; exit 1;
  }
  [[ "$captured_at" =~ ^[0-9]+$ ]] || {
    echo 'BACKUP_STORAGE_BLOCKED:v1_capture_time_invalid' >&2; exit 1;
  }
  slot=$(printf '%010d' "$captured_at")
  [[ "$slot" =~ ^[0-9]{10}$ ]] || {
    echo 'BACKUP_STORAGE_BLOCKED:v1_slot_invalid' >&2; exit 1;
  }
  runtime_digest=$(jq -cS '.captureRuntime' "$source_manifest" |
    sha256sum | awk '{print $1}')
  contract_digest=$(jq -cS '.contracts' "$source_manifest" |
    sha256sum | awk '{print $1}')
  proof_digest=$(jq -cnS --argjson database \
      "$(jq -cS '.databaseProof' "$source_manifest")" \
      --argjson media "$(jq -cS '.mediaProof' "$source_manifest")" \
      '{database:$database,media:$media}' |
    sha256sum | awk '{print $1}')
  jq -cnS --arg point "$point_id" --arg slot "$slot" \
    --arg source "$capture_revision" --arg runtime "$capture_revision" \
    --arg command "$(jq -er '.contracts.tooling' "$source_manifest")" \
    --arg evidence "$source_manifest_sha" --arg runtimeDigest "$runtime_digest" \
    --arg contract "$contract_digest" --arg proof "$proof_digest" \
    --argjson captured "$captured_at" \
    '{schema:"meet-backend/beta-recovery-point/v2",pointId:$point,slotId:$slot,
      capture:{capturedAt:$captured,sourceRevision:$source},
      captureCommandDigest:$command,captureEvidenceDigest:$evidence,
      captureRuntimeDigest:$runtimeDigest,runtimeRevision:$runtime,
      contractDigest:$contract,proofDigest:$proof}' \
    >"$destination_dir/recovery-point.json"
  jq -cS '.databaseProof' "$source_manifest" \
    >"$destination_dir/capture-database-proof.json"
  jq -cS '.mediaProof' "$source_manifest" \
    >"$destination_dir/capture-media-proof.json"
  manifest="$destination_dir/recovery-point.json"
else
  beta_storage_validate_point "$source_manifest" || {
    echo 'BACKUP_STORAGE_BLOCKED:manifest_invalid' >&2; exit 1;
  }
  point_id=$(jq -er '.pointId' "$source_manifest")
  slot=$(jq -er '.slotId' "$source_manifest")
  captured_at=$(jq -er '.capture.capturedAt' "$source_manifest")
  [ "$capture_revision" = "$(jq -er '.capture.sourceRevision' "$source_manifest")" ] || {
    echo 'BACKUP_STORAGE_BLOCKED:capture_provenance_changed' >&2; exit 1;
  }
fi
[ "$capture_revision" = "$(jq -er '.capture.sourceRevision' "$manifest")" ] || {
  echo 'BACKUP_STORAGE_BLOCKED:capture_provenance_changed' >&2; exit 1;
}

for object in postgres.dump.age uploads.tar.gz.age; do
  [ -f "$source_dir/$object" ] && [ ! -L "$source_dir/$object" ] &&
    [ -s "$source_dir/$object" ] || {
      echo 'BACKUP_STORAGE_BLOCKED:source_ciphertext_missing' >&2; exit 1;
    }
  if [ "$manifest_schema" = meet-backend/beta-recovery-manifest/v1 ]; then
    artifact_binding=$(jq -er --arg path "$object" \
      '.artifactFiles[] | select(.path==$path) | [.size,.sha256] | @tsv' \
      "$source_manifest") || {
        echo 'BACKUP_STORAGE_BLOCKED:v1_artifact_binding_missing' >&2; exit 1;
      }
    IFS=$'\t' read -r expected_size expected_sha <<<"$artifact_binding"
    [ "$expected_size" = "$(wc -c <"$source_dir/$object" | tr -d '[:space:]')" ] &&
      [ "$expected_sha" = "$(sha256sum "$source_dir/$object" | awk '{print $1}')" ] || {
        echo 'BACKUP_STORAGE_BLOCKED:v1_ciphertext_binding_mismatch' >&2
        exit 1
      }
    source_binding=$(jq -er --arg name "$object" '
      if $name=="postgres.dump.age" then .source.ciphertexts.database
      else .source.ciphertexts.uploads end |
      [.name,.size,.sha256] | @tsv' "$source_manifest") || {
        echo 'BACKUP_STORAGE_BLOCKED:v1_source_binding_missing' >&2; exit 1;
      }
    IFS=$'\t' read -r source_name source_size source_sha <<<"$source_binding"
    [ "$source_name" = "$object" ] &&
      [ "$source_size" = "$(wc -c <"$source_dir/$object" | tr -d '[:space:]')" ] &&
      [ "$source_sha" = "$(sha256sum "$source_dir/$object" | awk '{print $1}')" ] || {
        echo 'BACKUP_STORAGE_BLOCKED:v1_source_ciphertext_binding_mismatch' >&2
        exit 1
      }
  fi
done
if [ "$manifest_schema" != meet-backend/beta-recovery-manifest/v1 ]; then
  if [ -e "$source_dir/capture-database-proof.json" ] ||
    [ -e "$source_dir/capture-media-proof.json" ]; then
    [ -s "$source_dir/capture-database-proof.json" ] &&
      [ -s "$source_dir/capture-media-proof.json" ] || {
        echo 'BACKUP_STORAGE_BLOCKED:source_proof_pair_incomplete' >&2; exit 1;
      }
    beta_storage_validate_capture_proof database "$source_dir/capture-database-proof.json" || {
      echo 'BACKUP_STORAGE_BLOCKED:source_database_proof_invalid' >&2; exit 1;
    }
    beta_storage_validate_capture_proof media "$source_dir/capture-media-proof.json" || {
      echo 'BACKUP_STORAGE_BLOCKED:source_media_proof_invalid' >&2; exit 1;
    }
    cp -- "$source_dir/capture-database-proof.json" "$destination_dir/"
    cp -- "$source_dir/capture-media-proof.json" "$destination_dir/"
  fi
fi
source_db_sha=$(sha256sum "$source_dir/postgres.dump.age" | awk '{print $1}')
source_media_sha=$(sha256sum "$source_dir/uploads.tar.gz.age" | awk '{print $1}')
# The local adapter is deterministic; remote mode commits through the same
# manifest-last provider publish path and then retrieves exact versions again.
if [ "$remote" = true ]; then
  remote_scratch=$(mktemp -d "$destination_dir/.remote-migration.XXXXXX")
  "$script_dir/run-beta-backup-storage.sh" reconcile >/dev/null
  cp -- "$source_dir/postgres.dump.age" "$destination_dir/postgres.dump.age"
  cp -- "$source_dir/uploads.tar.gz.age" "$destination_dir/uploads.tar.gz.age"
else
  for object in postgres.dump.age uploads.tar.gz.age; do
    key="points/$point_id/$object"
    version_json=$("$script_dir/run-beta-backup-storage.sh" provider-put \
      --storage-root "$storage_root" --key "$key" --file "$source_dir/$object")
    version_json=${version_json#storage_provider_put=}
    version=$(jq -er '.versionId' <<<"$version_json")
    expected_sha=$(jq -er '.sha256' <<<"$version_json")
    "$script_dir/run-beta-backup-storage.sh" provider-get \
      --storage-root "$storage_root" --key "$key" --version "$version" \
      --output "$destination_dir/$object" --sha256 "$expected_sha"
  done
fi
if [ "$manifest" != "$destination_dir/recovery-point.json" ]; then
  cp -- "$manifest" "$destination_dir/recovery-point.json"
fi
chmod 600 "$destination_dir"/*

publish_args=(publish --source "$destination_dir" --point-id "$point_id" --slot "$slot"
  --captured-at "$captured_at" --owner migration)
[ "$remote" = true ] || publish_args+=(--storage-root "$storage_root")
if [ "$remote" = true ]; then
  BETA_STORAGE_DEFER_CAPTURE_HEAD=true \
    "$script_dir/run-beta-backup-storage.sh" "${publish_args[@]}"
else
  "$script_dir/run-beta-backup-storage.sh" "${publish_args[@]}"
fi
if [ "$remote" = true ]; then
  beta_storage_remote_head "points/$point_id/point.json" \
    "$remote_scratch/descriptor.meta"
  beta_storage_remote_get_json "points/$point_id/point.json" \
    "$remote_scratch/descriptor.json" \
    "$(jq -er '.VersionId' "$remote_scratch/descriptor.meta")"
  beta_storage_remote_validate_descriptor "$point_id" \
    "$remote_scratch/descriptor.json" "$remote_scratch" || {
      echo 'BACKUP_STORAGE_BLOCKED:destination_integrity_failed' >&2; exit 1;
    }
  destination_point="$remote_scratch/point"
  mkdir -m 700 "$destination_point"
  cp -- "$remote_scratch/descriptor.json" "$destination_point/point.json"
  cp -- "$remote_scratch/manifest.json" "$destination_point/recovery-point.json"
  cp -- "$remote_scratch/database.age" "$destination_point/postgres.dump.age"
  cp -- "$remote_scratch/uploads.age" "$destination_point/uploads.tar.gz.age"
  if [ "$(jq -er '.proofs|keys|length' "$remote_scratch/descriptor.json")" -eq 2 ]; then
    beta_storage_provider_get '' "points/$point_id/capture-database-proof.json" \
      "$(jq -er '.proofs.database.versionId' "$remote_scratch/descriptor.json")" \
      "$destination_point/capture-database-proof.json" \
      "$(jq -er '.proofs.database.sha256' "$remote_scratch/descriptor.json")" >/dev/null
    beta_storage_provider_get '' "points/$point_id/capture-media-proof.json" \
      "$(jq -er '.proofs.media.versionId' "$remote_scratch/descriptor.json")" \
      "$destination_point/capture-media-proof.json" \
      "$(jq -er '.proofs.media.sha256' "$remote_scratch/descriptor.json")" >/dev/null
  fi
  destination_descriptor=$(beta_storage_descriptor_digest \
    "$destination_point/point.json")
else
  destination_point="$storage_root/points/$point_id"
  beta_storage_local_validate_point_dir "$destination_point" "$point_id" || {
    echo 'BACKUP_STORAGE_BLOCKED:destination_integrity_failed' >&2; exit 1;
  }
  destination_descriptor=$(beta_storage_descriptor_digest \
    "$destination_point/point.json")
fi

mkdir -p "$restore_output" "$(dirname -- "$proof_output")"
[ ! -L "$restore_output" ] && [ ! -L "$(dirname -- "$proof_output")" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_path_symlink' >&2; exit 1;
}
[ -z "$(find "$restore_output" -mindepth 1 -print -quit)" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_output_not_empty' >&2; exit 1;
}
rm -f -- "$proof_output"
timeout --foreground --signal=TERM 1800s "$restore_command" \
  --point-dir "$destination_point" --identity-file "$identity" \
  --output-dir "$restore_output" --capture-revision "$capture_revision" \
  --restore-revision "$restore_revision" --proof-output "$proof_output"
[ -f "$proof_output" ] && [ ! -L "$proof_output" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_proof_missing' >&2; exit 1;
}
[ -z "$(find "$restore_output" -mindepth 1 -print -quit)" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_cleanup_incomplete' >&2; exit 1;
}
jq -e --arg capture "$capture_revision" --arg restore "$restore_revision" \
  --arg descriptor "$destination_descriptor" --argjson captured "$captured_at" '
  type=="object" and
  (keys|sort)==["captureRevision","capturedAt","cleanup","databaseProbe",
    "identityCustody","isolated","mediaProbe","pointDescriptorDigest",
    "postFingerprint","preFingerprint","restoreRevision","schema"] and
  .schema=="meet-backend/beta-backup-migration-proof/v1" and
  .captureRevision==$capture and .restoreRevision==$restore and
  .capturedAt==$captured and .pointDescriptorDigest==$descriptor and
  .identityCustody=="restore-only" and .isolated==true and
  .databaseProbe==true and .mediaProbe==true and .cleanup==true and
  (.preFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  (.postFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  .preFingerprint == .postFingerprint
' "$proof_output" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_proof_invalid' >&2; exit 1;
}
[ "$source_manifest_sha" = "$(sha256sum "$source_manifest" | awk '{print $1}')" ] &&
  [ "$source_db_sha" = "$(sha256sum "$source_dir/postgres.dump.age" | awk '{print $1}')" ] &&
  [ "$source_media_sha" = "$(sha256sum "$source_dir/uploads.tar.gz.age" | awk '{print $1}')" ] ||
  { echo 'BACKUP_STORAGE_BLOCKED:source_changed_during_migration' >&2; exit 1; }
if [ "$remote" = true ]; then
  beta_storage_remote_commit_capture_head "$point_id" "$captured_at" migration
fi

printf 'migration_status=verified destination_point_id=%s destination_descriptor=%s original_capture_at=%s source_preserved=true\n' \
  "$point_id" "$destination_descriptor" "$captured_at"
