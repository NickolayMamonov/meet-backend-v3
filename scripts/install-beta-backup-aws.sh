#!/usr/bin/env bash
set -euo pipefail

# This installer deliberately refuses floating/latest downloads. Activation
# supplies the reviewed archive URL and publisher-authenticated digest.
: "${AWS_CLI_VERSION:?AWS_CLI_VERSION is required}"
: "${AWS_CLI_ARCHIVE_URL:?AWS_CLI_ARCHIVE_URL is required}"
: "${AWS_CLI_SHA256:?AWS_CLI_SHA256 is required}"
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
printf 'aws_cli_installed=true version=%s path=%s\n' "$AWS_CLI_VERSION" "$target/aws/dist/aws"
