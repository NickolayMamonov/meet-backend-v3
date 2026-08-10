#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-ghcr-package-inventory.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PLATFORM=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PROVENANCE=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
SBOM=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
MARKER=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
SOURCE=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
COMMON=(
  --digest "$DIGEST"
  --platform-subject "$PLATFORM"
  --tag v1.0.1
  --version 1.0.1
  --source-sha "$SOURCE"
)

jq -n \
  --arg digest "$DIGEST" \
  --arg platform "$PLATFORM" \
  --arg provenance "$PROVENANCE" \
  --arg sbom "$SBOM" \
  --arg marker "$MARKER" \
  --arg source "$SOURCE" '
  {
    digest: $digest,
    aliases: {
      "v1.0.1": $digest,
      "1.0.1": $digest,
      ("sha-" + $source): $digest
    },
    latest: null,
    versions: [
      {digest:$digest,tags:["v1.0.1","1.0.1",("sha-" + $source)]},
      {digest:$provenance,tags:[],attribution:{verified:true,subject:$digest,kind:"provenance"}},
      {digest:$sbom,tags:[],attribution:{verified:true,subject:$platform,kind:"sbom"}},
      {digest:$marker,tags:[("sha256-" + ($digest | sub("^sha256:";"")))],
        attribution:{verified:true,subject:$digest,kind:"referrer"}}
    ]
  }
' >"$TMP/valid.json"

"$VERIFY" --inventory-file "$TMP/valid.json" "${COMMON[@]}" >/dev/null

expect_failure() {
  local name=$1 filter=$2
  jq "$filter" "$TMP/valid.json" >"$TMP/$name.json"
  if "$VERIFY" --inventory-file "$TMP/$name.json" "${COMMON[@]}" \
      >"$TMP/$name.out" 2>&1; then
    echo "expected GHCR inventory rejection: $name" >&2
    exit 1
  fi
}

expect_failure foreign-tag '.versions[1].tags = ["foreign"]'
expect_failure latest '.latest = .digest'
expect_failure partial-alias 'del(.aliases["1.0.1"])'
expect_failure unverified-referrer '.versions[1].attribution.verified = false'
expect_failure divergent-subject \
  '.versions[2].attribution.subject = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
echo "GHCR package inventory fixtures passed: valid hosted closure and five rejects"
