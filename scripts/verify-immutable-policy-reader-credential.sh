#!/usr/bin/env bash
set -euo pipefail

WORK_DIR=

usage() {
  echo "usage: $0 --repository OWNER/REPO [--app-id ID|--app-id-file PATH] [--private-key-file PATH] [--token-file PATH] [--output PATH]" >&2
  exit 2
}
fail() { echo "immutable policy reader credential verification failed: $*" >&2; exit 1; }

api_request() {
  local method=$1 url=$2 authorization=$3 output=$4 status
  case "$method" in
    GET) ;;
    PUT|PATCH|DELETE) fail "repository mutation methods are forbidden" ;;
    *) fail "unsupported API method" ;;
  esac
  status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --proto '=https' --tlsv1.2 --request GET \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: $authorization" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "$output" --write-out '%{http_code}' "$url") ||
    fail "GitHub API transport failed"
  [ "$status" = 200 ] || fail "GitHub API GET returned HTTP $status"
  jq -e . "$output" >/dev/null || fail "GitHub API returned malformed JSON"
}

issue_installation_token() {
  local url=$1 authorization=$2 body=$3 output=$4 status
  [[ "$url" =~ ^https://api\.github\.com/app/installations/[1-9][0-9]*/access_tokens$ ]] ||
    fail "installation token endpoint is invalid"
  status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --proto '=https' --tlsv1.2 --request POST \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: $authorization" \
    --header 'Content-Type: application/json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --data-binary "@$body" --output "$output" \
    --write-out '%{http_code}' "$url") ||
    fail "installation token issuance failed"
  [ "$status" = 201 ] || fail "installation token issuance failed"
  jq -e . "$output" >/dev/null || fail "installation token response is malformed"
}

validate_permissions() {
  local file=$1
  jq -e '
    type == "object" and .administration == "read" and .metadata == "read" and
    (to_entries | all(.[]; .value == "read" or .value == "none")) and
    (to_entries | all(.[]; .value != "write"))
  ' "$file" >/dev/null || fail "effective permissions are not read-only"
}

normalize() {
  local repository=$1 token=$2 permissions=$3 token_file=$4 output_file=$5
  local public proof
  public=$(jq -cS --arg repository "$repository" \
    '{repository:$repository,repositorySelection:"selected",permissions:.}' "$permissions")
  proof=$(jq -cS --arg repository "$repository" '
    {
      schema:"meet-backend/immutable-policy-reader-credential/v1",
      repository:$repository,authority:"github-app-installation",
      repositorySelection:"selected",
      permissions:{administration:.administration,metadata:.metadata},
      configurableWritePermissions:[]
    }
  ' "$permissions")
  if [ -n "$token_file" ]; then
    umask 077; printf '%s\n' "$token" >"$token_file"; chmod 600 "$token_file"
  fi
  if [ -n "$output_file" ]; then
    umask 077; printf '%s\n' "$proof" >"$output_file"; chmod 600 "$output_file"
  else
    printf '%s\n' "$public"
  fi
}

main() {
  local repository=
  local app_id=${IMMUTABLE_POLICY_READER_APP_ID:-}
  local app_id_file=
  local private_key_file=
  local token_file=
  local output_file=
  local private_key=${IMMUTABLE_POLICY_READER_PRIVATE_KEY:-}
  local owner repo now header payload jwt installations installation_id token
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repository) repository=${2:?}; shift 2 ;;
      --app-id) app_id=${2:?}; shift 2 ;;
      --app-id-file) app_id_file=${2:?}; shift 2 ;;
      --private-key-file) private_key_file=${2:?}; shift 2 ;;
      --token-file) token_file=${2:?}; shift 2 ;;
      --output) output_file=${2:?}; shift 2 ;;
      *) usage ;;
    esac
  done
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  command -v openssl >/dev/null 2>&1 || fail "openssl is required"
  command -v base64 >/dev/null 2>&1 || fail "base64 is required"
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
  owner=${repository%%/*}; repo=${repository#*/}
  if [ -n "$app_id_file" ]; then
    [ -f "$app_id_file" ] || fail "App ID input is unavailable"
    app_id=$(tr -d '\r\n' <"$app_id_file")
  fi
  [[ "$app_id" =~ ^[1-9][0-9]*$ ]] || fail "App ID input is missing or invalid"
  if [ -n "$private_key_file" ]; then
    [ -f "$private_key_file" ] || fail "private key input is unavailable"
    [ -s "$private_key_file" ] || fail "private key input is unavailable"
  fi
  [ -n "$private_key_file" ] || [ -n "$private_key" ] ||
    fail "private key input is missing"
  if [ -n "$token_file" ] && [ -n "$output_file" ]; then
    [ "$token_file" != "$output_file" ] ||
      fail "token and proof output paths must be distinct"
  fi
  WORK_DIR=$(mktemp -d 2>/dev/null) ||
    fail "temporary workspace is unavailable"
  trap 'rm -r -- "$WORK_DIR"' EXIT HUP INT TERM
  if [ -n "$private_key_file" ]; then
    cp -- "$private_key_file" "$WORK_DIR/private-key.pem" ||
      fail "private key input is unavailable"
  else
    printf '%s\n' "$private_key" >"$WORK_DIR/private-key.pem" ||
      fail "private key input is unavailable"
  fi
  chmod 600 "$WORK_DIR/private-key.pem"
  openssl pkey -in "$WORK_DIR/private-key.pem" -noout >/dev/null 2>&1 ||
    fail "private key input is invalid"
  now=$(date +%s)
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '\n=' | tr '/+' '_-')
  payload=$(jq -cn --argjson iat "$((now - 60))" --argjson exp "$((now + 540))" \
    --arg iss "$app_id" '{iat:$iat,exp:$exp,iss:$iss}' |
    base64 | tr -d '\n=' | tr '/+' '_-')
  jwt=$(printf '%s.%s' "$header" "$payload" |
    openssl dgst -sha256 -sign "$WORK_DIR/private-key.pem" -binary |
    base64 | tr -d '\n=' | tr '/+' '_-')
  api_request GET https://api.github.com/app/installations \
    "Bearer $jwt" "$WORK_DIR/installations.json"
  installations=$(jq -c --arg owner "$owner" '
    [
      .[] |
      select(
        type == "object" and
        (.account.login | type == "string") and
        ((.account.login | ascii_downcase) == ($owner | ascii_downcase))
      )
    ]
  ' "$WORK_DIR/installations.json") ||
    fail "authenticated installation metadata is malformed"
  [ "$(jq length <<<"$installations")" -eq 1 ] || fail "installation owner is ambiguous"
  jq -e '.[0].id | type == "number" and floor == . and . > 0' \
    <<<"$installations" >/dev/null ||
    fail "authenticated installation metadata is malformed"
  installation_id=$(jq -r '.[0].id' <<<"$installations")
  api_request GET "https://api.github.com/app/installations/$installation_id" \
    "Bearer $jwt" "$WORK_DIR/installation.json"
  jq -e \
    --argjson installation_id "$installation_id" \
    --arg owner "$owner" '
    type == "object" and
    .id == $installation_id and
    .repository_selection == "selected" and
    (.account.login | type == "string") and
    ((.account.login | ascii_downcase) == ($owner | ascii_downcase)) and
    (.permissions | type == "object")
  ' "$WORK_DIR/installation.json" >/dev/null ||
    fail "installation metadata is malformed"
  jq -c '.permissions' "$WORK_DIR/installation.json" \
    >"$WORK_DIR/permissions.json"
  validate_permissions "$WORK_DIR/permissions.json"
  jq -cn --arg repo "$repo" \
    '{repositories:[$repo],permissions:{administration:"read"}}' \
    >"$WORK_DIR/request.json"
  issue_installation_token \
    "https://api.github.com/app/installations/$installation_id/access_tokens" \
    "Bearer $jwt" "$WORK_DIR/request.json" "$WORK_DIR/token.json"
  jq -e --arg repository "$repository" '
    type == "object" and
    (.token | type == "string" and length > 0) and
    (.expires_at | type == "string" and length > 0) and
    (.permissions | type == "object") and
    (.repositories | type == "array" and length == 1) and
    ((.repositories[0].full_name | ascii_downcase) == ($repository | ascii_downcase))
  ' "$WORK_DIR/token.json" >/dev/null ||
    fail "issued token is not repository-scoped"
  token=$(jq -r '.token' "$WORK_DIR/token.json")
  jq -c '.permissions' "$WORK_DIR/token.json" \
    >"$WORK_DIR/effective-permissions.json"
  validate_permissions "$WORK_DIR/effective-permissions.json"
  api_request GET 'https://api.github.com/installation/repositories?per_page=100' \
    "Bearer $token" "$WORK_DIR/repositories.json"
  jq -e --arg repository "$repository" '
    type == "object" and
    .total_count == 1 and
    (.repositories | type == "array" and length == 1) and
    (.repositories[0].id | type == "number" and floor == . and . > 0) and
    ((.repositories[0].full_name | ascii_downcase) == ($repository | ascii_downcase))
  ' "$WORK_DIR/repositories.json" >/dev/null ||
    fail "selected repository is wrong"
  api_request GET "https://api.github.com/repos/$repository" \
    "Bearer $token" "$WORK_DIR/repository.json"
  jq -e --arg repository "$repository" --arg owner "$owner" --arg repo "$repo" '
    type == "object" and
    (.id | type == "number" and floor == . and . > 0) and
    (.full_name | type == "string") and
    ((.full_name | ascii_downcase) == ($repository | ascii_downcase)) and
    (.owner.login | type == "string") and
    ((.owner.login | ascii_downcase) == ($owner | ascii_downcase)) and
    (.name | type == "string") and
    ((.name | ascii_downcase) == ($repo | ascii_downcase))
  ' "$WORK_DIR/repository.json" >/dev/null ||
    fail "repository metadata is wrong"
  normalize "$repository" "$token" "$WORK_DIR/effective-permissions.json" \
    "$token_file" "$output_file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
