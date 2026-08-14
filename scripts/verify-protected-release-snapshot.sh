#!/usr/bin/env bash
set -euo pipefail
snapshot=
while [ "$#" -gt 0 ]; do
  case "$1" in --snapshot) snapshot=${2:?}; shift 2 ;; *) exit 2 ;; esac
done
[ -f "$snapshot" ] || { echo "snapshot is missing" >&2; exit 1; }
jq -e '
  type == "object" and .schema == "meet-backend/protected-release-history/v1" and
  (.repository | type == "string" and test("^[^/]+/[^/]+$")) and
  (.image | type == "string" and startswith("ghcr.io/")) and
  .objects.blockedV1_1_0.identity.releaseId == 368531227 and
  .objects.blockedV1_1_0.identity.version == "1.1.0" and
  .objects.immutableV1_0_1.identity.releaseId == 367640510 and
  .objects.immutableV1_0_1.identity.version == "1.0.1"
' "$snapshot" >/dev/null
