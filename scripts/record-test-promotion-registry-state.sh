#!/usr/bin/env bash
set -euo pipefail

SCHEMA='meet-backend/test-promotion-registry-state/v1'

usage() {
  cat >&2 <<'EOF'
usage:
  record-test-promotion-registry-state.sh init
    --file PATH --source SHA --run-id ID --run-attempt N
  record-test-promotion-registry-state.sh classify
    --file PATH --source SHA --run-id ID --run-attempt N
    --initial-state unknown|absent|partial|reusable|rejected
  record-test-promotion-registry-state.sh begin
    --file PATH --source SHA --run-id ID --run-attempt N
    --operation publication|attestation
  record-test-promotion-registry-state.sh confirm
    --file PATH --source SHA --run-id ID --run-attempt N
    --operation publication|attestation
  record-test-promotion-registry-state.sh export
    --file PATH --source SHA --run-id ID --run-attempt N
    --github-output PATH
EOF
  exit 2
}

fail() {
  echo "test promotion registry state: $*" >&2
  exit 1
}

usage_fail() {
  echo "test promotion registry state: invalid arguments" >&2
  usage
}

is_source_sha() {
  [[ ${1:-} =~ ^[0-9a-f]{40}$ ]]
}

is_positive_integer() {
  [[ ${1:-} =~ ^[1-9][0-9]*$ ]]
}

is_initial_state() {
  case ${1:-} in
    unknown|absent|partial|reusable|rejected) return 0 ;;
    *) return 1 ;;
  esac
}

is_write_state() {
  case ${1:-} in
    notStarted|startedUnconfirmed|confirmed) return 0 ;;
    *) return 1 ;;
  esac
}

is_operation() {
  [ "${1:-}" = publication ] || [ "${1:-}" = attestation ]
}

safe_parent_directory() {
  local path=$1
  local parent
  parent=$(dirname -- "$path")
  [ -d "$parent" ] && [ ! -L "$parent" ] ||
    fail "state parent directory is unavailable"
}

safe_regular_path() {
  local path=$1
  [ -n "$path" ] && [ ! -L "$path" ] ||
    fail "path is unsafe"
  if [ -e "$path" ]; then
    [ -f "$path" ] || fail "path is not a regular file"
  fi
}

validate_state_file() {
  local file=$1
  local expected_source=$2
  local expected_run_id=$3
  local expected_run_attempt=$4

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  jq -e --arg schema "$SCHEMA" '
    type == "object" and
    (keys | sort) == [
      "attestationWrite",
      "initialAliasState",
      "registryPublication",
      "runAttempt",
      "runId",
      "schema",
      "sourceSha"
    ] and
    .schema == $schema and
    (.sourceSha | type == "string" and test("^[0-9a-f]{40}$")) and
    (.runId | type == "number" and floor == . and . >= 1) and
    (.runAttempt | type == "number" and floor == . and . >= 1) and
    (.initialAliasState as $state |
      ($state | type == "string") and
      (["unknown","absent","partial","reusable","rejected"] |
        index($state) != null)) and
    (.registryPublication as $state |
      ($state | type == "string") and
      (["notStarted","startedUnconfirmed","confirmed"] |
        index($state) != null)) and
    (.attestationWrite as $state |
      ($state | type == "string") and
      (["notStarted","startedUnconfirmed","confirmed"] |
        index($state) != null))
  ' "$file" >/dev/null 2>&1 || return 1
  jq -e --arg source "$expected_source" \
    --argjson runId "$expected_run_id" \
    --argjson runAttempt "$expected_run_attempt" '
    .sourceSha == $source and
    .runId == $runId and
    .runAttempt == $runAttempt
  ' "$file" >/dev/null 2>&1
}

load_state_or_fail() {
  validate_state_file "$FILE" "$SOURCE" "$RUN_ID" "$RUN_ATTEMPT" ||
    fail "state is missing, corrupt, or bound to another run"
}

TEMP_FILE=
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$TEMP_FILE" ]; then
    rm -f -- "$TEMP_FILE"
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

write_state() {
  local initial_state=$1
  local publication=$2
  local attestation=$3

  is_initial_state "$initial_state" || fail "invalid initial alias state"
  is_write_state "$publication" || fail "invalid publication state"
  is_write_state "$attestation" || fail "invalid attestation state"
  safe_parent_directory "$FILE"
  safe_regular_path "$FILE"

  TEMP_FILE=$(mktemp "$(dirname -- "$FILE")/.test-promotion-registry-state.XXXXXX") ||
    fail "cannot create atomic state temporary"
  jq -cnS \
    --arg schema "$SCHEMA" \
    --arg source "$SOURCE" \
    --argjson runId "$RUN_ID" \
    --argjson runAttempt "$RUN_ATTEMPT" \
    --arg initialAliasState "$initial_state" \
    --arg registryPublication "$publication" \
    --arg attestationWrite "$attestation" \
    '{
      schema: $schema,
      sourceSha: $source,
      runId: $runId,
      runAttempt: $runAttempt,
      initialAliasState: $initialAliasState,
      registryPublication: $registryPublication,
      attestationWrite: $attestationWrite
    }' >"$TEMP_FILE" || fail "cannot construct state"
  chmod 600 "$TEMP_FILE" || fail "cannot protect state temporary"
  [ ! -L "$FILE" ] || fail "state path became a symlink"
  mv -f -- "$TEMP_FILE" "$FILE" || fail "cannot atomically replace state"
  TEMP_FILE=
}

export_state() {
  local initial_state=unknown
  local publication=unknown
  local attestation=unknown

  if validate_state_file "$FILE" "$SOURCE" "$RUN_ID" "$RUN_ATTEMPT"; then
    initial_state=$(jq -r '.initialAliasState' "$FILE")
    publication=$(jq -r '.registryPublication' "$FILE")
    attestation=$(jq -r '.attestationWrite' "$FILE")
  fi

  [ -n "$GITHUB_OUTPUT" ] || usage_fail
  [ ! -L "$GITHUB_OUTPUT" ] || fail "github output path is unsafe"
  [ -f "$GITHUB_OUTPUT" ] || fail "github output is unavailable"
  {
    printf 'initial_alias_state=%s\n' "$initial_state"
    printf 'registry_publication=%s\n' "$publication"
    printf 'attestation_write=%s\n' "$attestation"
  } >>"$GITHUB_OUTPUT" || fail "cannot write github output"
  printf 'initial_alias_state=%s\n' "$initial_state"
  printf 'registry_publication=%s\n' "$publication"
  printf 'attestation_write=%s\n' "$attestation"
}

COMMAND=${1:-}
case "$COMMAND" in
  init|classify|begin|confirm|export) ;;
  *) usage_fail ;;
esac
shift

FILE=
SOURCE=
RUN_ID=
RUN_ATTEMPT=
INITIAL_STATE=
OPERATION=
GITHUB_OUTPUT=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)
      [ "$#" -ge 2 ] && [ -z "$FILE" ] || usage_fail
      FILE=$2
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] && [ -z "$SOURCE" ] || usage_fail
      SOURCE=$2
      shift 2
      ;;
    --run-id)
      [ "$#" -ge 2 ] && [ -z "$RUN_ID" ] || usage_fail
      RUN_ID=$2
      shift 2
      ;;
    --run-attempt)
      [ "$#" -ge 2 ] && [ -z "$RUN_ATTEMPT" ] || usage_fail
      RUN_ATTEMPT=$2
      shift 2
      ;;
    --initial-state)
      [ "$#" -ge 2 ] && [ -z "$INITIAL_STATE" ] || usage_fail
      INITIAL_STATE=$2
      shift 2
      ;;
    --operation)
      [ "$#" -ge 2 ] && [ -z "$OPERATION" ] || usage_fail
      OPERATION=$2
      shift 2
      ;;
    --github-output)
      [ "$#" -ge 2 ] && [ -z "$GITHUB_OUTPUT" ] || usage_fail
      GITHUB_OUTPUT=$2
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      usage_fail
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -n "$FILE" ] && [ -n "$SOURCE" ] && [ -n "$RUN_ID" ] && [ -n "$RUN_ATTEMPT" ] ||
  usage_fail
is_source_sha "$SOURCE" || usage_fail
is_positive_integer "$RUN_ID" || usage_fail
is_positive_integer "$RUN_ATTEMPT" || usage_fail
safe_regular_path "$FILE"

case "$COMMAND" in
  init)
    [ -z "$INITIAL_STATE" ] || usage_fail
    [ -z "$OPERATION" ] || usage_fail
    [ -z "$GITHUB_OUTPUT" ] || usage_fail
    [ ! -e "$FILE" ] || fail "state already exists"
    write_state unknown notStarted notStarted
    ;;
  classify)
    [ -n "$INITIAL_STATE" ] && [ -z "$OPERATION" ] && [ -z "$GITHUB_OUTPUT" ] ||
      usage_fail
    is_initial_state "$INITIAL_STATE" || usage_fail
    [ "$INITIAL_STATE" != unknown ] ||
      fail "initial alias classification must be concrete"
    load_state_or_fail
    current_state=$(jq -r '.initialAliasState' "$FILE")
    [ "$current_state" = unknown ] || fail "initial alias state is already classified"
    write_state "$INITIAL_STATE" \
      "$(jq -r '.registryPublication' "$FILE")" \
      "$(jq -r '.attestationWrite' "$FILE")"
    ;;
  begin)
    [ -z "$INITIAL_STATE" ] && [ -n "$OPERATION" ] && [ -z "$GITHUB_OUTPUT" ] ||
      usage_fail
    is_operation "$OPERATION" || usage_fail
    load_state_or_fail
    initial_state=$(jq -r '.initialAliasState' "$FILE")
    [ "$initial_state" = absent ] ||
      fail "writer is not permitted for this initial alias state"
    publication=$(jq -r '.registryPublication' "$FILE")
    attestation=$(jq -r '.attestationWrite' "$FILE")
    if [ "$OPERATION" = publication ]; then
      [ "$publication" = notStarted ] || fail "publication intent already recorded"
      publication=startedUnconfirmed
    else
      [ "$attestation" = notStarted ] || fail "attestation intent already recorded"
      attestation=startedUnconfirmed
    fi
    write_state "$initial_state" "$publication" "$attestation"
    ;;
  confirm)
    [ -z "$INITIAL_STATE" ] && [ -n "$OPERATION" ] && [ -z "$GITHUB_OUTPUT" ] ||
      usage_fail
    is_operation "$OPERATION" || usage_fail
    load_state_or_fail
    initial_state=$(jq -r '.initialAliasState' "$FILE")
    [ "$initial_state" = absent ] ||
      fail "writer confirmation is not permitted for this initial alias state"
    publication=$(jq -r '.registryPublication' "$FILE")
    attestation=$(jq -r '.attestationWrite' "$FILE")
    if [ "$OPERATION" = publication ]; then
      [ "$publication" = startedUnconfirmed ] ||
        fail "publication confirmation has no prior intent"
      publication=confirmed
    else
      [ "$attestation" = startedUnconfirmed ] ||
        fail "attestation confirmation has no prior intent"
      attestation=confirmed
    fi
    write_state "$initial_state" "$publication" "$attestation"
    ;;
  export)
    [ -z "$INITIAL_STATE" ] && [ -z "$OPERATION" ] && [ -n "$GITHUB_OUTPUT" ] ||
      usage_fail
    export_state
    ;;
esac
