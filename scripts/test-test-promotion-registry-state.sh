#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RECORDER="$ROOT_DIR/scripts/record-test-promotion-registry-state.sh"
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

SOURCE=0123456789abcdef0123456789abcdef01234567
RUN_ID=35354750679
RUN_ATTEMPT=2
STATE="$TMP/registry-state.json"
OUTPUT="$TMP/github-output"

fail() {
  echo "test-test-promotion-registry-state: $*" >&2
  exit 1
}

expect_failure() {
  local label=$1
  shift
  if "$@" >/dev/null 2>"$TMP/$label.err"; then
    fail "$label unexpectedly succeeded"
  fi
}

assert_mode_600() {
  local file=$1
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [ "$(stat -c '%a' "$file")" = 600 ] || fail "state is not mode 600"
}

record() {
  bash "$RECORDER" "$@" >/dev/null
}

[ -x "$RECORDER" ] || fail "recorder is not executable"

record init --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT"
assert_mode_600 "$STATE"
jq -e --arg source "$SOURCE" --argjson run "$RUN_ID" \
  --argjson attempt "$RUN_ATTEMPT" '
  (keys | sort) == [
    "attestationWrite","initialAliasState","registryPublication",
    "runAttempt","runId","schema","sourceSha"
  ] and
  .schema == "meet-backend/test-promotion-registry-state/v1" and
  .sourceSha == $source and .runId == $run and .runAttempt == $attempt and
  .initialAliasState == "unknown" and
  .registryPublication == "notStarted" and
  .attestationWrite == "notStarted"
' "$STATE" >/dev/null

expect_failure init-again record init --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT"
expect_failure classify-unknown record classify --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --initial-state unknown

record classify --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --initial-state absent
expect_failure duplicate-classify record classify --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --initial-state reusable

expect_failure cross-run record begin --file "$STATE" --source "$SOURCE" \
  --run-id "$((RUN_ID + 1))" --run-attempt "$RUN_ATTEMPT" --operation publication
expect_failure confirm-before-begin record confirm --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation publication

record begin --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation publication
assert_mode_600 "$STATE"
jq -e '.registryPublication == "startedUnconfirmed" and
  .attestationWrite == "notStarted"' "$STATE" >/dev/null
expect_failure duplicate-publication-begin record begin --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation publication
record confirm --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation publication
expect_failure duplicate-publication-confirm record confirm --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation publication

record begin --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation attestation
record confirm --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation attestation
jq -e '.registryPublication == "confirmed" and
  .attestationWrite == "confirmed"' "$STATE" >/dev/null

: >"$OUTPUT"
bash "$RECORDER" export --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" \
  --github-output "$OUTPUT" >/dev/null
grep -Fxq 'initial_alias_state=absent' "$OUTPUT"
grep -Fxq 'registry_publication=confirmed' "$OUTPUT"
grep -Fxq 'attestation_write=confirmed' "$OUTPUT"
if grep -Eiq '0123456789|35354750679|secret|token|password' "$OUTPUT"; then
  fail "export exposed identity or secret-like content"
fi

PARTIAL="$TMP/partial.json"
record init --file "$PARTIAL" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT"
record classify --file "$PARTIAL" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --initial-state partial
expect_failure partial-publication record begin --file "$PARTIAL" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation publication
expect_failure partial-attestation record begin --file "$PARTIAL" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation attestation

CORRUPT="$TMP/corrupt.json"
printf '%s\n' '{"schema":"not-the-state-schema","registryPublication":"notStarted"}' >"$CORRUPT"
: >"$OUTPUT"
bash "$RECORDER" export --file "$CORRUPT" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" \
  --github-output "$OUTPUT" >/dev/null
grep -Fxq 'initial_alias_state=unknown' "$OUTPUT"
grep -Fxq 'registry_publication=unknown' "$OUTPUT"
grep -Fxq 'attestation_write=unknown' "$OUTPUT"

: >"$OUTPUT"
bash "$RECORDER" export --file "$TMP/lost.json" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" \
  --github-output "$OUTPUT" >/dev/null
grep -Fxq 'initial_alias_state=unknown' "$OUTPUT"
grep -Fxq 'registry_publication=unknown' "$OUTPUT"
grep -Fxq 'attestation_write=unknown' "$OUTPUT"

expect_failure invalid-source record init --file "$TMP/invalid.json" \
  --source 'not-a-source' --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT"
expect_failure invalid-operation record begin --file "$STATE" --source "$SOURCE" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --operation registry

echo "test promotion registry state passed: schema, atomic transitions, quarantine, identity binding, and unknown export"
