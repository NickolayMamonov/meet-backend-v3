#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

contract=$TMP/test-vps-admission-contract.json
baseline_output=$TMP/baseline.json
mutated_output=$TMP/mutated.json
cp -- "$ROOT_DIR/scripts/test-vps-admission-contract.json" "$contract"

run_probe_contract() {
  local output=$1
  TEST_VPS_PROBE_FIXTURE=true bash "$ROOT_DIR/scripts/probe-test-vps-zero-state.sh" \
    --test-admission-contract "$contract" --test-observed-meetings 6 \
    --output "$output"
}

run_probe_contract "$baseline_output"
jq -e '
  .schema == "meet-backend/test-vps-zero-state-probe-fixture/v1" and
  .contractMeetings == 6 and .observedMeetings == 6 and .zeroState == "closed"
' "$baseline_output" >/dev/null

jq '.populated.roots.meetings = 7' "$contract" >"$TMP/mutated-contract.json"
mv -f -- "$TMP/mutated-contract.json" "$contract"
if run_probe_contract "$mutated_output"; then
  echo "probe accepted a changed contract meeting count" >&2
  exit 1
fi
jq -e '
  .schema == "meet-backend/test-vps-zero-state-probe-fixture/v1" and
  .contractMeetings == 7 and .observedMeetings == 6 and .zeroState == "unknown"
' "$mutated_output" >/dev/null
echo "probe contract fixture passed: admission changed from closed to unknown"
