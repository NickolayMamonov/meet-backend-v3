#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-immutable-release-policy.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
cat >"$TMP/credential.json" <<'EOF'
{"schema":"meet-backend/credential/v1","repository":"FixtureOwner/repo","authority":"github-app-installation","permissions":{"administration":"read","metadata":"read"},"configurableWritePermissions":[]}
EOF
jq -n '{enabled:true}' >"$TMP/enabled.json"
jq -n '{enabled:false}' >"$TMP/disabled.json"
"$VERIFY" --repository FixtureOwner/repo --policy-file "$TMP/enabled.json" \
  --credential-proof "$TMP/credential.json" >/dev/null
if "$VERIFY" --repository FixtureOwner/repo --policy-file "$TMP/disabled.json" \
  --credential-proof "$TMP/credential.json" >/dev/null 2>&1; then
  echo "disabled immutable policy unexpectedly passed" >&2
  exit 1
fi
for method in PUT PATCH DELETE; do
  if (
    # shellcheck source=verify-immutable-release-policy.sh
    # shellcheck disable=SC1090
    source "$VERIFY"
    api_request "$method" https://api.github.com/forbidden token "$TMP/out"
  ) >/dev/null 2>&1; then
    echo "$method unexpectedly passed local GET-only guard" >&2
    exit 1
  fi
done
echo "immutable release policy fixtures passed"
