#!/usr/bin/env bash
set -euo pipefail

# This installer deliberately refuses floating/latest downloads. The archive
# tuple must be supplied by the checked-in activation allowlist and then
# independently verified against the same tuple before credentials are used.
: "${AWS_CLI_VERSION:?AWS_CLI_VERSION is required}"
: "${AWS_CLI_ARCHIVE_URL:?AWS_CLI_ARCHIVE_URL is required}"
: "${AWS_CLI_SHA256:?AWS_CLI_SHA256 is required}"
allowlist=${BETA_RECURRING_TOOLING_ALLOWLIST:-}
[ -f "$allowlist" ] && [ ! -L "$allowlist" ] || {
  echo "AWS CLI allowlist is required" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
timeout --foreground 5s python3 - "$allowlist" <<'PY'
import json
import sys

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

with open(sys.argv[1], encoding="utf-8") as stream:
    json.load(stream, object_pairs_hook=reject_duplicates)
PY
jq -e --arg version "$AWS_CLI_VERSION" --arg url "$AWS_CLI_ARCHIVE_URL" \
  --arg sha "$AWS_CLI_SHA256" '
  type=="object" and
  ([.awsCli]|length)==1 and
  .awsCli.version==$version and .awsCli.archiveUrl==$url and
  .awsCli.sha256==$sha and
  (.awsCli.publisher=="amazon-aws") and
  (.awsCli.platform=="linux-x86_64")
' "$allowlist" >/dev/null || {
  echo "AWS CLI tuple is not the reviewed allowlist entry" >&2
  exit 1
}
[[ "$AWS_CLI_VERSION" =~ ^2\.[0-9]+\.[0-9]+$ ]] || { echo "invalid AWS CLI version" >&2; exit 1; }
[[ "$AWS_CLI_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid AWS CLI digest" >&2; exit 1; }
[[ "$AWS_CLI_ARCHIVE_URL" =~ ^https://[^[:space:]]+$ ]] || { echo "archive must use HTTPS" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
target=${AWS_CLI_INSTALL_ROOT:-"$HOME/.local/aws-cli-v$AWS_CLI_VERSION"}
archive=$(mktemp)
trap 'rm -f -- "$archive"' EXIT
curl --fail --silent --show-error --location --connect-timeout 5 --max-time 60 \
  --output "$archive" "$AWS_CLI_ARCHIVE_URL"
printf '%s  %s\n' "$AWS_CLI_SHA256" "$archive" | sha256sum --check --strict
command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 1; }
rm -rf -- "$target"
mkdir -p "$target"
unzip -q "$archive" -d "$target"
test -x "$target/aws/dist/aws"
binary_sha256=$(sha256sum "$target/aws/dist/aws" | awk '{print $1}')
jq -cnS --arg version "$AWS_CLI_VERSION" --arg archive "$AWS_CLI_SHA256" \
  --arg binary "$binary_sha256" \
  '{schema:"meet-backend/beta-backup-aws-install-proof/v1",
    version:$version,archiveSha256:$archive,binarySha256:$binary}' |
  install -m 600 /dev/stdin "$target/aws/dist/meet-backup-install-proof.json"
printf 'aws_cli_installed=true version=%s path=%s\n' "$AWS_CLI_VERSION" "$target/aws/dist/aws"
