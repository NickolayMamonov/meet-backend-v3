#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TRUSTED_DIR=$ROOT_DIR

deny() {
  echo "RETENTION_PROOF_BLOCKED: $1" >&2
  exit 1
}

[[ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ]] ||
  deny "only manual workflow dispatch is admissible"
[[ "${GITHUB_RUN_ATTEMPT:-}" = 1 ]] ||
  deny "only a fresh attempt-1 dispatch is admissible"
[[ "${GITHUB_REF:-}" = refs/heads/master ]] ||
  deny "proof must be dispatched from protected master"
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] ||
  deny "trusted workflow revision is malformed"
[[ "${SOURCE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] ||
  deny "exact source SHA is required"
[[ "${IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  deny "immutable image digest is required"
[[ "${EXPECTED_TUPLE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] ||
  deny "approved tuple digest is required"
[[ -n "${EXPECTED_REGISTRATION:-}" ]] ||
  deny "live registration identity is required"
[[ -d "${SOURCE_CHECKOUT:-}" && ! -L "${SOURCE_CHECKOUT:-}" ]] ||
  deny "exact source checkout is unavailable"
[[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" && ! -L "$RUNNER_TEMP" ]] ||
  deny "private runner temporary directory is unavailable"
command -v git >/dev/null 2>&1 || deny "Git is unavailable"
command -v tar >/dev/null 2>&1 || deny "tar is unavailable"
command -v python3 >/dev/null 2>&1 || deny "Python 3 is unavailable"
command -v timeout >/dev/null 2>&1 || deny "timeout is unavailable"

SOURCE_CHECKOUT=$(cd -- "$SOURCE_CHECKOUT" && pwd -P)
source_head=$(git -C "$SOURCE_CHECKOUT" rev-parse --verify HEAD) ||
  deny "exact source revision cannot be resolved"
[[ "$source_head" = "$SOURCE_SHA" ]] ||
  deny "source checkout differs from requested commit"
source_status=$(git -C "$SOURCE_CHECKOUT" status --porcelain=v1 \
  --untracked-files=all) || deny "source checkout status is unavailable"
[[ -z "$source_status" ]] || deny "source checkout is not clean"

source_lock=$SOURCE_CHECKOUT/scripts/fixtures/retention-proof/toolchain.lock.json
source_dockerfile=$SOURCE_CHECKOUT/scripts/fixtures/retention-proof/Dockerfile
[[ -f "$source_lock" && ! -L "$source_lock" ]] ||
  deny "reviewed toolchain lock is missing"
[[ -f "$source_dockerfile" && ! -L "$source_dockerfile" ]] ||
  deny "reviewed Dockerfile is missing"
toolchain_sha256=$(sha256sum "$source_lock" | cut -d ' ' -f 1) ||
  deny "toolchain lock digest is unavailable"

source_export_root=$(mktemp -d "$RUNNER_TEMP/retention-source.XXXXXX") ||
  deny "private source export directory could not be created"
source_export_identity=$(stat -c '%d:%i:%f:%u:%g' "$source_export_root") ||
  deny "private source export identity is unavailable"
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ -n "${source_export_root:-}" ] &&
    { [ -e "$source_export_root" ] || [ -L "$source_export_root" ]; }; then
    if [ ! -d "$source_export_root" ] || [ -L "$source_export_root" ] ||
      [ "$(stat -c '%d:%i:%f:%u:%g' "$source_export_root" 2>/dev/null || true)" \
        != "$source_export_identity" ]; then
      status=1
    else
      rm -r -- "$source_export_root" || status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
source_export=$source_export_root/source
mkdir -m 700 -- "$source_export"
timeout 60s git -C "$SOURCE_CHECKOUT" archive --format=tar "$SOURCE_SHA" |
  timeout 60s tar --extract --file=- --directory="$source_export" \
    --no-same-owner --no-same-permissions ||
  deny "bounded exact-commit source export failed"

summary_output=$RUNNER_TEMP/retention-proof-summary.json
[[ ! -e "$summary_output" && ! -L "$summary_output" ]] ||
  deny "sanitized summary output already exists"
timeout 600s python3 -B \
  "$TRUSTED_DIR/scripts/retention-proof-supervisor.py" \
  --source-export "$source_export" \
  --source-checkout "$SOURCE_CHECKOUT" \
  --source-sha "$SOURCE_SHA" \
  --image-digest "$IMAGE_DIGEST" \
  --plan-sha256 da21be2bc38466fc8322a1c4fc53cf853130cc50ac3de4ae2950116475479215 \
  --toolchain-lock "$source_lock" \
  --toolchain-sha256 "$toolchain_sha256" \
  --tuple-sha256 "$EXPECTED_TUPLE_SHA256" \
  --output "$summary_output"
[[ -f "$summary_output" && ! -L "$summary_output" ]] ||
  deny "verified sanitized summary was not produced"
python3 -B - "$summary_output" <<'PY'
import json
import re
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
keys = {
    "schemaVersion",
    "outcome",
    "sourceSha",
    "planSha256",
    "imageDigest",
    "toolchainSha256",
    "extractedRetentionBlockSha256",
    "cases",
    "selectiveCleanup",
    "outsideSentinel",
    "containerDestroyed",
}
if (
    not isinstance(value, dict)
    or set(value) != keys
    or value["schemaVersion"] != 1
    or value["outcome"] != "passed"
    or value["containerDestroyed"] is not True
    or value["selectiveCleanup"] is not True
    or value["outsideSentinel"] is not True
    or not re.fullmatch(r"[0-9a-f]{40}", value["sourceSha"])
    or not re.fullmatch(r"[0-9a-f]{64}", value["planSha256"])
    or not re.fullmatch(r"sha256:[0-9a-f]{64}", value["imageDigest"])
    or any(
        not isinstance(value[key], str)
        or not re.fullmatch(r"[0-9a-f]{64}", value[key])
        for key in ("toolchainSha256", "extractedRetentionBlockSha256")
    )
):
    raise SystemExit(1)
encoded = json.dumps(value, sort_keys=True, separators=(",", ":"))
if len(encoded.encode("utf-8")) > 64 * 1024:
    raise SystemExit(1)
print(encoded)
PY
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '\n## Sanitized retention fixture proof summary\n\n```json\n' \
    >>"$GITHUB_STEP_SUMMARY"
  python3 -B - "$summary_output" >>"$GITHUB_STEP_SUMMARY" <<'PY'
import json
import sys
from pathlib import Path

print(json.dumps(
    json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")),
    sort_keys=True,
    indent=2,
))
PY
  printf '```\n' >>"$GITHUB_STEP_SUMMARY"
fi
