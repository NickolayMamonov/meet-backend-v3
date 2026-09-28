#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --run-id ID --environment NAME [--reviewer-id ID] [--response-file PATH] --output PATH" >&2
  exit 2
}

run_id='' environment='' reviewer_id='' response_file='' output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id) [ "$#" -ge 2 ] || usage; run_id=$2; shift 2 ;;
    --environment) [ "$#" -ge 2 ] || usage; environment=$2; shift 2 ;;
    --reviewer-id) [ "$#" -ge 2 ] || usage; reviewer_id=$2; shift 2 ;;
    --response-file) [ "$#" -ge 2 ] || usage; response_file=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$run_id" =~ ^[0-9]+$ && "$run_id" -gt 0 ]] || usage
[[ "$environment" = closed-beta-recurring-restore ]] || usage
[[ -z "$reviewer_id" || "$reviewer_id" =~ ^[0-9]+$ ]] || usage
for path in "$response_file" "$output"; do
  [ -z "$path" ] || [[ "$path" = /* && "$path" != *..* && "$path" != *$'\n'* ]] || usage
done
[ -n "$output" ] || usage
command -v jq >/dev/null 2>&1 || exit 1
command -v curl >/dev/null 2>&1 || exit 1
command -v python3 >/dev/null 2>&1 || exit 1

reject_duplicates() {
  local file=$1
  timeout --foreground 5s python3 - "$file" <<'PY'
import json
import sys

def reject(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

with open(sys.argv[1], encoding="utf-8") as stream:
    json.load(stream, object_pairs_hook=reject)
PY
}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
response="$tmp/approvals.json"
if [ -n "$response_file" ]; then
  [ -f "$response_file" ] && [ ! -L "$response_file" ] || {
    echo 'BACKUP_CUSTODY_BLOCKED:approval_response_missing' >&2
    exit 1
  }
  [ "$(wc -c <"$response_file")" -le 1048576 ] || {
    echo 'BACKUP_CUSTODY_BLOCKED:approval_response_oversize' >&2
    exit 1
  }
  cp -- "$response_file" "$response"
else
  : "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  api=${GITHUB_API_URL:-https://api.github.com}
  [ "$api" = https://api.github.com ] || {
    echo 'BACKUP_CUSTODY_BLOCKED:approval_api_origin_invalid' >&2
    exit 1
  }
  timeout --foreground 60s curl --fail --silent --show-error \
    --connect-timeout 5 --max-time 30 --max-filesize 1048576 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api/repos/$GITHUB_REPOSITORY/actions/runs/$run_id/approvals" >"$response" ||
    { echo 'BACKUP_CUSTODY_BLOCKED:approval_api_unavailable' >&2; exit 1; }
fi
reject_duplicates "$response" || {
  echo 'BACKUP_CUSTODY_BLOCKED:approval_response_invalid' >&2
  exit 1
}
jq -e '
  type=="array" and length<=100 and
  all(.[]; type=="object" and
    ((keys - ["id","node_id","user","state","environments","created_at",
      "comment","reviewer"])|length==0) and
    (.state|type=="string") and
    (.user|type=="object" and
      ((keys - ["id","login","node_id","type","site_admin"])|length==0) and
      (.id|type=="number" and floor==. and .>0) and
      (.login|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))) and
    (.environments|type=="array" and length<=32 and
      all(.[]; type=="object" and
        ((keys - ["name","url","html_url","state"])|length==0) and
        (.name|type=="string" and length>0)))
  )
' "$response" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:approval_response_invalid' >&2
  exit 1
}
api_digest=$(jq -cS . "$response" | sha256sum | awk '{print $1}')
selected=$(
  jq -cS --arg environment "$environment" --arg reviewer "$reviewer_id" '
    [.[] | select(.state=="approved" and
      (($reviewer=="" and true) or (.user.id|tostring)==$reviewer)) |
      select(any(.environments[]?; .name==$environment)) |
      {id:(.id // 0),state,userId:.user.id,userLogin:.user.login,
       environment:$environment}] |
    if length == 1 then .[0] else error("approval is not unique") end
  ' "$response"
) || {
  echo 'BACKUP_CUSTODY_BLOCKED:reviewer_approval_missing_or_ambiguous' >&2
  exit 1
}
selected_body="$tmp/selected.json"
jq -cnS --argjson run "$run_id" --arg api "$api_digest" \
  --argjson selected "$selected" '
  {schema:"meet-backend/beta-recurring-approval/v1",runId:$run,
   environment:$selected.environment,reviewerId:$selected.userId,
   reviewerLogin:$selected.userLogin,state:$selected.state,
   approvalApiDigest:$api}
' >"$selected_body"
approval_digest=$(sha256sum "$selected_body" | awk '{print $1}')
jq --arg digest "$approval_digest" '. + {approvalDigest:$digest}' \
  "$selected_body" | install -m 600 /dev/stdin "$output"
