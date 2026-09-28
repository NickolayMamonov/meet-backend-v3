#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --event-file PATH --state-file PATH" >&2
  exit 2
}

event_file='' state_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event-file) [ "$#" -ge 2 ] || usage; event_file=$2; shift 2 ;;
    --state-file) [ "$#" -ge 2 ] || usage; state_file=$2; shift 2 ;;
    *) usage ;;
  esac
done
for file in "$event_file" "$state_file"; do
  [[ "$file" = /* && "$file" != *..* && "$file" != *$'\n'* ]] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || {
    echo 'BACKUP_INCIDENT_BLOCKED:incident_input_missing' >&2
    exit 1
  }
done
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_API_URL:=https://api.github.com}"
: "${BETA_BACKUP_INCIDENT_REPOSITORY:?BETA_BACKUP_INCIDENT_REPOSITORY is required}"
: "${BETA_BACKUP_INCIDENT_ISSUE_LABEL:?BETA_BACKUP_INCIDENT_ISSUE_LABEL is required}"
[ "$GITHUB_API_URL" = https://api.github.com ] || {
  echo 'BACKUP_INCIDENT_BLOCKED:api_origin_invalid' >&2; exit 1;
}
readonly BETA_BACKUP_INCIDENT_MAX_RESPONSE_BYTES=1048576
readonly BETA_BACKUP_INCIDENT_MAX_ISSUE_BODY_BYTES=65536
readonly BETA_BACKUP_INCIDENT_MAX_PAGE_ITEMS=100
[[ "$BETA_BACKUP_INCIDENT_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo 'BACKUP_INCIDENT_BLOCKED:repository_invalid' >&2; exit 1;
}
[[ "$BETA_BACKUP_INCIDENT_ISSUE_LABEL" =~ ^[A-Za-z0-9_.:-]{1,50}$ ]] || {
  echo 'BACKUP_INCIDENT_BLOCKED:label_invalid' >&2; exit 1;
}
command -v curl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
command -v python3 >/dev/null 2>&1 || exit 1
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
require_unique_json() {
  local file=$1
  [ "$(wc -c <"$file" | tr -d '[:space:]')" -le \
    "$BETA_BACKUP_INCIDENT_MAX_RESPONSE_BYTES" ] || return 1
  timeout --foreground 5s python3 - "$file" <<'PY'
import json
import sys

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

with open(sys.argv[1], encoding="utf-8") as stream:
    json.load(stream, object_pairs_hook=reject_duplicates)
PY
}
validate_repository_response() {
  local file=$1
  jq -e '
    type=="object" and (.full_name|type=="string") and
    (.private|type=="boolean") and (.has_issues|type=="boolean") and
    (.permissions|type=="object") and (.permissions.issues|type=="boolean")
  ' "$file" >/dev/null
}
validate_label_response() {
  local file=$1
  jq -e --argjson max_items "$BETA_BACKUP_INCIDENT_MAX_PAGE_ITEMS" '
    type=="array" and length <= $max_items and
    all(.[]; type=="object" and
      (.name|type=="string" and utf8bytelength>=1 and utf8bytelength<=50))
  ' "$file" >/dev/null
}
validate_issue_page() {
  local file=$1
  if jq -e --argjson max_items "$BETA_BACKUP_INCIDENT_MAX_PAGE_ITEMS" \
    --argjson body_limit "$BETA_BACKUP_INCIDENT_MAX_ISSUE_BODY_BYTES" '
    type=="array" and length <= $max_items and
    all(.[]; type=="object" and
      (.number|type=="number" and floor==. and .>0) and
      (.state|type=="string" and (.=="open" or .=="closed")) and
      (.body==null or (.body|type=="string" and
        utf8bytelength <= $body_limit)) and
      (.labels|type=="array" and length <= $max_items and
        all(.[]; type=="object" and
          (.name|type=="string" and utf8bytelength<=50))) and
      (.pull_request==null or (.pull_request|type=="object")))
  ' "$file" >/dev/null; then
    return 0
  fi
  if jq -e --argjson body_limit "$BETA_BACKUP_INCIDENT_MAX_ISSUE_BODY_BYTES" '
    type=="array" and any(.[]; .body != null and
      (.body|type=="string" and utf8bytelength > $body_limit))
  ' "$file" >/dev/null; then
    echo 'BACKUP_INCIDENT_BLOCKED:issue_body_oversize' >&2
  else
    echo 'BACKUP_INCIDENT_BLOCKED:issue_page_invalid' >&2
  fi
  return 1
}
validate_comment_page() {
  local file=$1
  if jq -e --argjson max_items "$BETA_BACKUP_INCIDENT_MAX_PAGE_ITEMS" \
    --argjson body_limit "$BETA_BACKUP_INCIDENT_MAX_ISSUE_BODY_BYTES" '
    type=="array" and length <= $max_items and
    all(.[]; type=="object" and
      (.body==null or (.body|type=="string" and
        utf8bytelength <= $body_limit)))
  ' "$file" >/dev/null; then
    return 0
  fi
  if jq -e --argjson body_limit "$BETA_BACKUP_INCIDENT_MAX_ISSUE_BODY_BYTES" '
    type=="array" and any(.[]; .body != null and
      (.body|type=="string" and utf8bytelength > $body_limit))
  ' "$file" >/dev/null; then
    echo 'BACKUP_INCIDENT_BLOCKED:comment_body_oversize' >&2
  else
    echo 'BACKUP_INCIDENT_BLOCKED:issue_comments_invalid' >&2
  fi
  return 1
}
require_unique_json "$state_file" || {
  echo 'BACKUP_INCIDENT_BLOCKED:state_ambiguous' >&2; exit 1;
}
require_unique_json "$event_file" || {
  echo 'BACKUP_INCIDENT_BLOCKED:event_ambiguous' >&2; exit 1;
}
jq -e '
  type=="object" and
  (keys|sort)==["dedupeKey","deliveryCount","environment","firstSeenAt",
    "incidentId","lastSeenAt","recoveryCount","schema","state"] and
  .schema=="meet-backend/beta-backup-incident/v2" and
  (.state=="active" or .state=="recovered") and
  (.dedupeKey|type=="string" and test("^[0-9a-f]{64}$")) and
  (.incidentId|type=="string" and test("^[A-Za-z0-9._:-]{1,64}$")) and
  (.environment|type=="string" and test("^[A-Za-z0-9._-]{1,64}$")) and
  (.deliveryCount|type=="number" and floor==. and .>=0) and
  (.recoveryCount|type=="number" and floor==. and .>=0) and
  (.firstSeenAt|type=="number" and floor==. and .>=0) and
  (.lastSeenAt|type=="number" and floor==.) and
  .lastSeenAt >= .firstSeenAt
' "$state_file" >/dev/null || {
  echo 'BACKUP_INCIDENT_BLOCKED:state_invalid' >&2; exit 1;
}
jq -e '
  type=="object" and
  (keys|sort)==["dedupeKey","event","eventId","environment","incidentId",
    "observedAt","privateDestinationRequired","reasons","schema"] and
  .schema=="meet-backend/beta-backup-incident-event/v1" and
  .privateDestinationRequired==true and
  (.event=="active" or .event=="recovered") and
  (.dedupeKey|type=="string" and test("^[0-9a-f]{64}$")) and
  (.eventId|type=="string" and test("^[0-9a-f]{64}$")) and
  (.incidentId|type=="string" and test("^[A-Za-z0-9._:-]{1,64}$")) and
  (.environment|type=="string" and test("^[A-Za-z0-9._-]{1,64}$")) and
  (.reasons|type=="array" and all(.[]; type=="string" and
    test("^[a-z][a-z0-9_]{1,63}$"))) and
  (.observedAt|type=="number" and floor==. and .>=0)
' "$event_file" >/dev/null || {
  echo 'BACKUP_INCIDENT_BLOCKED:event_invalid' >&2; exit 1;
}
repo_url="$GITHUB_API_URL/repos/$BETA_BACKUP_INCIDENT_REPOSITORY"
api() {
  local method=$1 path=$2 data=${3:-} output status
  output=$(mktemp "$tmp/api.XXXXXX")
  if [ -n "$data" ]; then
    if curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
      --max-filesize "$BETA_BACKUP_INCIDENT_MAX_RESPONSE_BYTES" \
      --request "$method" --data-binary "$data" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H 'Accept: application/vnd.github+json' \
      -H 'Content-Type: application/json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' "$repo_url$path" >"$output"; then
      :
    else
      status=$?
      rm -f "$output"
      if [ "$status" -eq 63 ]; then
        echo 'BACKUP_INCIDENT_BLOCKED:github_api_oversize' >&2
      else
        echo 'BACKUP_INCIDENT_BLOCKED:github_api_failed' >&2
      fi
      exit 1
    fi
  else
    if curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
      --max-filesize "$BETA_BACKUP_INCIDENT_MAX_RESPONSE_BYTES" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' "$repo_url$path" >"$output"; then
      :
    else
      status=$?
      rm -f "$output"
      if [ "$status" -eq 63 ]; then
        echo 'BACKUP_INCIDENT_BLOCKED:github_api_oversize' >&2
      else
        echo 'BACKUP_INCIDENT_BLOCKED:github_api_failed' >&2
      fi
      exit 1
    fi
  fi
  [ "$(wc -c <"$output" | tr -d '[:space:]')" -le \
    "$BETA_BACKUP_INCIDENT_MAX_RESPONSE_BYTES" ] || {
    rm -f "$output"
    echo 'BACKUP_INCIDENT_BLOCKED:github_api_oversize' >&2
    exit 1
  }
  require_unique_json "$output" && jq -e . "$output" >/dev/null || {
    rm -f "$output"; echo 'BACKUP_INCIDENT_BLOCKED:github_api_invalid' >&2; exit 1;
  }
  printf '%s\n' "$output"
}
repo=$(api GET '')
validate_repository_response "$repo" || {
  rm -f "$repo"
  echo 'BACKUP_INCIDENT_BLOCKED:repository_response_invalid' >&2
  exit 1
}
jq -e --arg repo "$BETA_BACKUP_INCIDENT_REPOSITORY" '
  .full_name==$repo and .private==true and .has_issues==true and
  .permissions.issues==true
' "$repo" >/dev/null || {
  rm -f "$repo"; echo 'BACKUP_INCIDENT_BLOCKED:private_repository_invalid' >&2; exit 1;
}
label=$(jq -cn --arg name "$BETA_BACKUP_INCIDENT_ISSUE_LABEL" \
  '{name:$name,color:"b60205",description:"closed-beta backup incident"}')
labels=$(api GET '/labels')
validate_label_response "$labels" || {
  rm -f "$labels"
  echo 'BACKUP_INCIDENT_BLOCKED:label_response_invalid' >&2
  exit 1
}
if ! jq -e --arg name "$BETA_BACKUP_INCIDENT_ISSUE_LABEL" \
  'any(.[]; .name==$name)' "$labels" >/dev/null; then
  created_label=$(api POST '/labels' "$label")
  jq -e --arg name "$BETA_BACKUP_INCIDENT_ISSUE_LABEL" \
    '.name==$name and (.id|type=="number" and .>0)' "$created_label" >/dev/null || {
    rm -f "$created_label"
    echo 'BACKUP_INCIDENT_BLOCKED:label_create_invalid' >&2
    exit 1
  }
  rm -f "$created_label"
fi
dedupe=$(jq -er '.dedupeKey' "$event_file")
incident_id=$(jq -er '.incidentId' "$event_file")
issue_page=1
issue_pages=()
while (( issue_page <= 10 )); do
  page_file=$(api GET "/issues?state=all&per_page=100&page=$issue_page")
  validate_issue_page "$page_file" || exit 1
  issue_pages+=("$page_file")
  page_count=$(jq -er 'length' "$page_file")
  (( page_count < 100 )) && break
  issue_page=$((issue_page + 1))
done
(( issue_page <= 10 )) || {
  echo 'BACKUP_INCIDENT_BLOCKED:issue_pagination_limit' >&2; exit 1;
}
issues="$tmp/issues.json"
jq -s 'add' "${issue_pages[@]}" >"$issues"
issue=$(jq -c --arg label "$BETA_BACKUP_INCIDENT_ISSUE_LABEL" \
  --arg incident "$incident_id" --arg dedupe "$dedupe" \
  --arg event_id "$(jq -er '.eventId' "$event_file")" \
  --arg event "$(jq -er '.event' "$event_file")" '
  [.[] | select(.pull_request|not) |
    select(any(.labels[]?; .name==$label)) |
    select(($event=="recovered" or .state=="open") and
      (((.body // "")|contains($incident)) or
       ((.body // "")|contains($dedupe)) or
       ((.body // "")|contains($event_id))))] |
  sort_by(.updated_at,.number) | last // empty
' "$issues")
# Do not copy state or provider responses to an issue. The issue body contains
# only fixed reason codes, opaque IDs and the event's dedupe key.
body=$(jq -r --arg dedupe "$dedupe" --arg event "$(jq -er '.event' "$event_file")" \
  --arg event_id "$(jq -er '.eventId' "$event_file")" \
  --arg environment "$(jq -er '.environment' "$event_file")" \
  --arg id "$(jq -er '.incidentId' "$event_file")" \
  --arg reasons "$(jq -r '.reasons|join(",")' "$event_file")" \
  --arg observed "$(jq -er '.observedAt' "$event_file")" \
  '"Closed-beta backup incident\n\nEnvironment: "+$environment+
   "\nEvent: "+$event+"\nIncident: "+$id+"\nDedupe: "+$dedupe+
   "\nEventId: "+$event_id+
   "\nReasons: "+$reasons+"\nObservedAt: "+$observed' <<<"{}")
payload=$(jq -cn --arg body "$body" --arg label "$BETA_BACKUP_INCIDENT_ISSUE_LABEL" \
  '{title:"Closed-beta backup incident",body:$body,labels:[$label]}')
if [ -n "$issue" ]; then
  number=$(jq -er '.number' <<<"$issue")
  if [ "$(jq -er '.event' "$event_file")" = recovered ]; then
    event_id=$(jq -er '.eventId' "$event_file")
    comment_page=1
    recovery_seen=false
    while (( comment_page <= 10 )); do
      comments=$(api GET \
        "/issues/$number/comments?state=all&per_page=100&page=$comment_page")
      validate_comment_page "$comments" || exit 1
      if jq -e --arg event "$event_id" \
        'any(.[]; (.body // "") | contains($event))' "$comments" >/dev/null; then
        recovery_seen=true
      fi
      comment_count=$(jq -er 'length' "$comments")
      (( comment_count < 100 )) && break
      comment_page=$((comment_page + 1))
    done
    (( comment_page <= 10 )) || {
      echo 'BACKUP_INCIDENT_BLOCKED:issue_comment_pagination_limit' >&2
      exit 1
    }
    if [ "$recovery_seen" = false ]; then
      recovery_comment=$(jq -cn --arg body "$body" \
        '{body:("Closed-beta backup recovery observed.\n\n"+$body)}')
      recovery_response=$(api POST "/issues/$number/comments" "$recovery_comment")
      jq -e '(.id|type=="number" and .>0)' "$recovery_response" >/dev/null || {
        rm -f "$recovery_response"
        echo 'BACKUP_INCIDENT_BLOCKED:recovery_comment_invalid' >&2
        exit 1
      }
      rm -f "$recovery_response"
    fi
    closed=$(api PATCH "/issues/$number" \
      "$(jq -cn --arg body "$body" '{state:"closed",body:$body}')")
    jq -e '.state=="closed" and (.number|type=="number" and .>0)' "$closed" >/dev/null || {
      rm -f "$closed"
      echo 'BACKUP_INCIDENT_BLOCKED:issue_close_invalid' >&2
      exit 1
    }
    rm -f "$closed"
  else
    updated=$(api PATCH "/issues/$number" \
      "$(jq -cn --arg body "$body" '{state:"open",body:$body}')")
    jq -e '.state=="open" and (.number|type=="number" and .>0)' "$updated" >/dev/null || {
      rm -f "$updated"
      echo 'BACKUP_INCIDENT_BLOCKED:issue_update_invalid' >&2
      exit 1
    }
    rm -f "$updated"
  fi
else
  [ "$(jq -er '.event' "$event_file")" = active ] || {
    echo 'BACKUP_INCIDENT_BLOCKED:recovery_issue_missing' >&2
    exit 1
  }
  created_issue=$(api POST '/issues' "$payload")
  jq -e '(.number|type=="number" and .>0)' "$created_issue" >/dev/null || {
    rm -f "$created_issue"
    echo 'BACKUP_INCIDENT_BLOCKED:issue_response_invalid' >&2
    exit 1
  }
  rm -f "$created_issue"
fi
rm -f "$repo" "$labels" "$issues" "${issue_pages[@]}"
printf 'incident_delivery=private_repository_verified event=%s\n' \
  "$(jq -er '.event' "$event_file")"
