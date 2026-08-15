#!/usr/bin/env bash
set -euo pipefail

fail() { echo "immutable-release policy verification failed: $*" >&2; exit 1; }
api_request() {
  local method=$1 endpoint=$2 output=$3 token=$4 status
  case "$method" in
    GET) ;;
    PUT|PATCH|DELETE) fail "policy helpers are GET-only" ;;
    *) fail "unsupported policy API method" ;;
  esac
  status=$(curl --fail-with-body --silent --show-error \
    --request GET \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer $token" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "$output" --write-out '%{http_code}' "$endpoint") ||
    fail "immutable-release policy GET failed"
  [ "$status" = 200 ] || fail "immutable-release policy GET returned HTTP $status"
  jq -e . "$output" >/dev/null || fail "policy response is malformed JSON"
}
usage() {
  echo "usage: $0 --repository OWNER/REPO [--token TOKEN|--token-file PATH] [--policy-file PATH] [--credential-proof PATH]" >&2
  exit 2
}

repository=${GITHUB_REPOSITORY:-}
token=
token_file=
policy_file=
credential_proof=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository=${2:?}; shift 2 ;;
    --token) token=${2:?}; shift 2 ;;
    --token-file) token_file=${2:?}; shift 2 ;;
    --policy-file) policy_file=${2:?}; shift 2 ;;
    --credential-proof) credential_proof=${2:?}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "repository is invalid"

if [ -n "$credential_proof" ]; then
  jq -e --arg repository "$repository" '
    type == "object" and .repository == $repository and
    .authority == "github-app-installation" and
    .permissions.administration == "read" and
    .permissions.metadata == "read" and
    (.permissions | keys == ["administration","metadata"]) and
    (.permissions | to_entries | all(.[]; .value == "read")) and
    (.configurableWritePermissions | length == 0)
  ' "$credential_proof" >/dev/null ||
    fail "credential proof is absent, mis-scoped, or write-capable"
fi

if [ -n "$policy_file" ]; then
  body=$(jq -c . "$policy_file") || fail "policy fixture is malformed"
else
  [ -n "$token_file" ] || [ -n "$token" ] || fail "read-only token is required"
  if [ -n "$token_file" ]; then token=$(sed -n '1p' "$token_file"); fi
  [ -n "$token" ] || fail "read-only token is empty"
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  response=$(mktemp)
  trap 'rm -f -- "$response"' RETURN
  api_request GET "https://api.github.com/repos/$repository/immutable-releases" \
    "$response" "$token"
  body=$(cat "$response")
fi

jq -e '
  type == "object" and has("enabled") and (.enabled | type == "boolean") and
  .enabled == true
' <<<"$body" >/dev/null || fail "immutable releases are not positively enabled"
jq -n --arg schema "meet-backend/immutable-release-policy/v1" \
  --arg repository "$repository" --argjson enabled "$(jq '.enabled' <<<"$body")" \
  '{schema:$schema,repository:$repository,enabled:$enabled,method:"GET"}'
