#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --source DIR --destination DIR --manifest PATH [--storage-root DIR|--remote] --restore-command PATH --restore-output DIR --identity-file PATH --capture-revision SHA --restore-revision SHA --proof-output PATH" >&2
  exit 2
}

source_dir='' destination_dir='' manifest='' storage_root=''
restore_command='' restore_output='' identity='' capture_revision=''
restore_revision='' proof_output=''
remote=false
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
[ -x "$restore_command" ] && [ ! -L "$restore_command" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_command_unavailable' >&2; exit 1;
}
[ -f "$identity" ] && [ ! -L "$identity" ] && [ -s "$identity" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_identity_unavailable' >&2; exit 1;
}
command -v jq >/dev/null 2>&1 || exit 1
command -v timeout >/dev/null 2>&1 || exit 1

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
[ "$remote" = true ] && beta_storage_require_config ||
  beta_storage_require_local_root "$storage_root" >/dev/null
beta_storage_validate_point "$manifest" || {
  echo 'BACKUP_STORAGE_BLOCKED:manifest_invalid' >&2; exit 1;
}

manifest_digest=$(sha256sum "$manifest" | awk '{print $1}')
point_id=$(jq -er '.pointId' "$manifest")
slot=$(jq -er '.slotId' "$manifest")
captured_at=$(jq -er '.capture.capturedAt' "$manifest")
[ "$capture_revision" = "$(jq -er '.capture.sourceRevision' "$manifest")" ] || {
  echo 'BACKUP_STORAGE_BLOCKED:capture_provenance_changed' >&2; exit 1;
}

for object in postgres.dump.age uploads.tar.gz.age; do
  [ -f "$source_dir/$object" ] && [ ! -L "$source_dir/$object" ] &&
    [ -s "$source_dir/$object" ] || {
      echo 'BACKUP_STORAGE_BLOCKED:source_ciphertext_missing' >&2; exit 1;
    }
done
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
else
  echo 'BACKUP_STORAGE_BLOCKED:source_restore_proofs_required' >&2
  exit 1
fi
source_db_sha=$(sha256sum "$source_dir/postgres.dump.age" | awk '{print $1}')
source_media_sha=$(sha256sum "$source_dir/uploads.tar.gz.age" | awk '{print $1}')
source_manifest_sha=$manifest_digest

# The local adapter is deterministic; remote mode commits through the same
# manifest-last provider publish path and then retrieves exact versions again.
if [ "$remote" = true ]; then
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
cp -- "$manifest" "$destination_dir/recovery-point.json"
chmod 600 "$destination_dir"/*

publish_args=(publish --source "$destination_dir" --point-id "$point_id" --slot "$slot"
  --captured-at "$captured_at" --owner migration)
[ "$remote" = true ] || publish_args+=(--storage-root "$storage_root")
"$script_dir/run-beta-backup-storage.sh" "${publish_args[@]}"
if [ "$remote" = true ]; then
  remote_scratch=$(mktemp -d "$destination_dir/.remote-migration.XXXXXX")
  beta_storage_remote_get_json "points/$point_id/point.json" \
    "$remote_scratch/descriptor.json"
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
  for proof in capture-database-proof.json capture-media-proof.json; do
    proof_version=$(beta_storage_remote_latest_version "points/$point_id/$proof")
    beta_storage_provider_get '' "points/$point_id/$proof" "$proof_version" \
      "$destination_point/$proof" >/dev/null
  done
  destination_descriptor=$(sha256sum "$destination_point/point.json" | awk '{print $1}')
else
  destination_point="$storage_root/points/$point_id"
  beta_storage_local_validate_point_dir "$destination_point" "$point_id" || {
    echo 'BACKUP_STORAGE_BLOCKED:destination_integrity_failed' >&2; exit 1;
  }
  destination_descriptor=$(sha256sum "$destination_point/point.json" | awk '{print $1}')
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
  .preFingerprint==.postFingerprint
' "$proof_output" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_proof_invalid' >&2; exit 1;
}
[ "$source_manifest_sha" = "$(sha256sum "$manifest" | awk '{print $1}')" ] &&
  [ "$source_db_sha" = "$(sha256sum "$source_dir/postgres.dump.age" | awk '{print $1}')" ] &&
  [ "$source_media_sha" = "$(sha256sum "$source_dir/uploads.tar.gz.age" | awk '{print $1}')" ] ||
  { echo 'BACKUP_STORAGE_BLOCKED:source_changed_during_migration' >&2; exit 1; }

printf 'migration_status=verified destination_point_id=%s destination_descriptor=%s original_capture_at=%s source_preserved=true\n' \
  "$point_id" "$destination_descriptor" "$captured_at"
