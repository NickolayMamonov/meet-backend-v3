#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
jq -n '{
  schema:"meet-backend/protected-release-history/v1",
  repository:"FixtureOwner/repo",image:"ghcr.io/fixture/repo",
  objects:{
    blockedV1_1_0:{identity:{releaseId:368531227,version:"1.1.0"}},
    immutableV1_0_1:{identity:{releaseId:367640510,version:"1.0.1"}}
  }
}' >"$TMP/snapshot.json"
"$ROOT_DIR/scripts/verify-protected-release-snapshot.sh" \
  --snapshot "$TMP/snapshot.json"
echo "protected snapshot fixtures passed"
