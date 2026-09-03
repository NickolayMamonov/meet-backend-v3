#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

usage() {
  echo "usage: $0 --artifact-id ID --recovery-id ID --source-sha SHA" \
    "--repository OWNER/REPO --workflow-path PATH --destination PATH --zip-path PATH" >&2
  exit 2
}

fail() {
  echo "beta recovery artifact admission failed: $1" >&2
  exit 1
}

artifact_id=
recovery_id=
source_sha=
repository=
workflow_path=
destination=
zip_path=
seen_artifact=false
seen_recovery=false
seen_source=false
seen_repository=false
seen_workflow=false
seen_destination=false
seen_zip=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact-id)
      [ "$seen_artifact" = false ] && [ "$#" -ge 2 ] || usage
      artifact_id=$2; seen_artifact=true; shift 2 ;;
    --recovery-id)
      [ "$seen_recovery" = false ] && [ "$#" -ge 2 ] || usage
      recovery_id=$2; seen_recovery=true; shift 2 ;;
    --source-sha)
      [ "$seen_source" = false ] && [ "$#" -ge 2 ] || usage
      source_sha=$2; seen_source=true; shift 2 ;;
    --repository)
      [ "$seen_repository" = false ] && [ "$#" -ge 2 ] || usage
      repository=$2; seen_repository=true; shift 2 ;;
    --workflow-path)
      [ "$seen_workflow" = false ] && [ "$#" -ge 2 ] || usage
      workflow_path=$2; seen_workflow=true; shift 2 ;;
    --destination)
      [ "$seen_destination" = false ] && [ "$#" -ge 2 ] || usage
      destination=$2; seen_destination=true; shift 2 ;;
    --zip-path)
      [ "$seen_zip" = false ] && [ "$#" -ge 2 ] || usage
      zip_path=$2; seen_zip=true; shift 2 ;;
    *) usage ;;
  esac
done

[ "$seen_artifact" = true ] && [ "$seen_recovery" = true ] &&
  [ "$seen_source" = true ] && [ "$seen_repository" = true ] &&
  [ "$seen_workflow" = true ] && [ "$seen_destination" = true ] &&
  [ "$seen_zip" = true ] || usage
[[ "$artifact_id" =~ ^[1-9][0-9]*$ ]] || fail "artifact ID is malformed"
[[ "$recovery_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] ||
  fail "recovery ID is malformed"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail "source SHA is malformed"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  fail "repository is malformed"
[ "$workflow_path" = .github/workflows/prove-beta-backup-restore.yml ] ||
  fail "workflow path is not the reviewed recovery workflow"
[[ "$destination" = /* && "$destination" != *$'\n'* && "$destination" != *$'\r'* ]] ||
  fail "destination is malformed"
[[ "$zip_path" = /* && "$zip_path" != *$'\n'* && "$zip_path" != *$'\r'* ]] ||
  fail "ZIP path is malformed"

for tool in gh jq date find id mktemp mv realpath rm sha256sum stat unzip wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tooling is unavailable"
done
validator=${BETA_RECOVERY_EVIDENCE_VALIDATOR:-}
if [ -z "$validator" ]; then
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  validator=$script_dir/build-beta-recovery-evidence.sh
fi
retention=${BETA_RECOVERY_RETENTION_VALIDATOR:-}
if [ -z "$retention" ]; then
  script_dir=${script_dir:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}
  retention=$script_dir/validate-beta-recovery-artifact-retention.sh
fi
[ -f "$validator" ] && [ ! -L "$validator" ] || fail "evidence validator is unavailable"
[ -x "$retention" ] || fail "retention validator is unavailable"

destination_parent=${destination%/*}
zip_parent=${zip_path%/*}
[ "$destination_parent" != "$destination" ] && [ "$zip_parent" != "$zip_path" ] || usage
[ -d "$destination_parent" ] && [ ! -L "$destination_parent" ] || fail "destination parent is unsafe"
[ -d "$zip_parent" ] && [ ! -L "$zip_parent" ] || fail "ZIP parent is unsafe"
destination_parent=$(realpath -- "$destination_parent") ||
  fail "destination parent is unavailable"
zip_parent=$(realpath -- "$zip_parent") || fail "ZIP parent is unavailable"
[ "$(stat -c '%u' -- "$destination_parent")" = "$(id -u)" ] ||
  fail "destination parent is not owned by the runner"
[ "$(stat -c '%u' -- "$zip_parent")" = "$(id -u)" ] ||
  fail "ZIP parent is not owned by the runner"
destination=$destination_parent/${destination##*/}
zip_path=$zip_parent/${zip_path##*/}
[ ! -e "$destination" ] && [ ! -L "$destination" ] ||
  fail "destination is already occupied"
[ ! -e "$zip_path" ] && [ ! -L "$zip_path" ] ||
  fail "ZIP path is already occupied"

work_root=
zip_owned=false
published=false
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$published" = false ] && [ -n "$work_root" ] &&
    { [ -e "$work_root" ] || [ -L "$work_root" ]; }; then
    rm -r -- "$work_root" || status=1
  fi
  if [ "$zip_owned" = true ] && { [ -e "$zip_path" ] || [ -L "$zip_path" ]; }; then
    [ ! -L "$zip_path" ] && rm -f -- "$zip_path" || status=1
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

work_root=$(mktemp -d "$destination_parent/.beta-recovery-admission.XXXXXX") ||
  fail "private staging creation failed"
chmod 700 -- "$work_root"
artifact_json=$(gh api "repos/$repository/actions/artifacts/$artifact_id") ||
  fail "artifact metadata lookup failed"
jq -e --arg id "$artifact_id" '
  type == "object" and .id == ($id|tonumber) and
  (.expired == false) and
  (.size_in_bytes | type == "number" and floor == . and . > 0) and
  (.workflow_run.id | type == "number" and floor == . and . > 0)
' <<<"$artifact_json" >/dev/null || fail "artifact metadata is invalid"
"$retention" <<<"$artifact_json"
workflow_run_id=$(jq -er '.workflow_run.id' <<<"$artifact_json") ||
  fail "artifact workflow run is unavailable"
run_json=$(gh api "repos/$repository/actions/runs/$workflow_run_id") ||
  fail "workflow run metadata lookup failed"
jq -e --arg sha "$source_sha" --arg workflow "$workflow_path" '
  type == "object" and .id == ($run_id|tonumber) and
  .status == "completed" and .conclusion == "success" and
  .event == "workflow_dispatch" and .head_branch == "dev" and
  .head_sha == $sha and
  ((.path // .workflow_path // "") == $workflow) and
  ((.display_title // "") | startswith("Beta recovery capture "))
' --arg run_id "$workflow_run_id" <<<"$run_json" >/dev/null ||
  fail "workflow run metadata is invalid"

gh api "repos/$repository/actions/artifacts/$artifact_id/zip" >"$zip_path" ||
  fail "artifact ZIP download failed"
zip_owned=true
[ -s "$zip_path" ] || fail "artifact ZIP is empty"
expected_zip=$work_root/expected-zip
printf '%s\n' postgres.dump.age recovery-point.json uploads.tar.gz.age |
  sort >"$expected_zip"
unzip -Z1 "$zip_path" | sort >"$work_root/actual-zip" ||
  fail "artifact ZIP listing failed"
cmp -- "$expected_zip" "$work_root/actual-zip" >/dev/null ||
  fail "artifact ZIP contents are not exact"
extracted=$work_root/extracted
mkdir -- "$extracted"
chmod 700 -- "$extracted"
unzip -q "$zip_path" -d "$extracted" || fail "artifact ZIP extraction failed"
"$validator" validate-artifact --artifact-dir "$extracted" \
  --recovery-id "$recovery_id" --source-sha "$source_sha" \
  --repository "$repository" --run-id "$workflow_run_id"
manifest=$extracted/recovery-point.json
manifest_name=$(jq -er '.artifactName' "$manifest") ||
  fail "manifest artifact name is unavailable"
manifest_run=$(jq -er '.runId' "$manifest") || fail "manifest run ID is unavailable"
jq -e --arg id "$artifact_id" --arg name "$manifest_name" --argjson run "$manifest_run" '
  .id == ($id|tonumber) and .name == $name and
  .workflow_run.id == $run
' <<<"$artifact_json" >/dev/null || fail "artifact metadata is not manifest-bound"
[ "$manifest_run" = "$workflow_run_id" ] || fail "manifest run differs from artifact run"
mv -- "$extracted" "$destination" || fail "artifact publication failed"
published=true
trap - EXIT HUP INT TERM
rm -r -- "$work_root"
