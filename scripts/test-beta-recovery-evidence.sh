#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
builder=$root/scripts/build-beta-recovery-evidence.sh
tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM
hash=$(printf x | sha256sum | awk '{print $1}')
cat >"$tmp/proof.json" <<'EOF'
{"schema":"proof","successful":true}
EOF
bash "$builder" manifest --recovery-id recovery-0001 --source-sha 0123456789abcdef0123456789abcdef01234567 \
  --repository NickolayMamonov/meet-backend-v3 --run-id 1 --artifact-name artifact \
  --tooling-digest "$hash" --workflow-digest "$hash" --database-digest "$hash" --media-digest "$hash" \
  --database-bytes 1 --uploads-files 1 --uploads-bytes 1 --uploads-digest "$hash" \
  --database-proof "$tmp/proof.json" --media-proof "$tmp/proof.json" \
  --output "$tmp/manifest.json"
jq -e '.schema == "meet-backend/beta-recovery-manifest/v1" and .retentionDays == 30' "$tmp/manifest.json" >/dev/null
bash "$builder" incident --recovery-id recovery-0001 --source-sha 0123456789abcdef0123456789abcdef01234567 \
  --repository NickolayMamonov/meet-backend-v3 --run-id 1 --tooling-digest "$hash" \
  --workflow-digest "$hash" --database-digest "$hash" --media-digest "$hash" \
  --failure-class cleanupFailure --output "$tmp/incident.json"
jq -e '.sanitized == true and .failureClass == "cleanupFailure"' "$tmp/incident.json" >/dev/null
if grep -Eiq 'password|token|secret|postgresql://' "$tmp/"*.json; then exit 1; fi
echo "beta recovery evidence fixture passed"
