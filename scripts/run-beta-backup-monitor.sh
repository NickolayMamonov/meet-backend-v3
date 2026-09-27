#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--storage-root DIR] --environment NAME --now EPOCH [--receiver-root DIR|--receiver-host HOST --receiver-user USER --receiver-ssh-config PATH --receiver-known-hosts PATH] --incident-state PATH|--incident-state-key KEY --incident-command PATH --deadman-url URL" >&2
  exit 2
}

storage_root='' environment='' now='' receiver_root=''
receiver_host='' receiver_user='' receiver_ssh_config='' receiver_known_hosts=''
incident_state='' incident_state_key='' incident_command='' deadman_url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --storage-root) [ "$#" -ge 2 ] || usage; storage_root=$2; shift 2 ;;
    --environment) [ "$#" -ge 2 ] || usage; environment=$2; shift 2 ;;
    --now) [ "$#" -ge 2 ] || usage; now=$2; shift 2 ;;
    --receiver-root) [ "$#" -ge 2 ] || usage; receiver_root=$2; shift 2 ;;
    --receiver-host) [ "$#" -ge 2 ] || usage; receiver_host=$2; shift 2 ;;
    --receiver-user) [ "$#" -ge 2 ] || usage; receiver_user=$2; shift 2 ;;
    --receiver-ssh-config) [ "$#" -ge 2 ] || usage; receiver_ssh_config=$2; shift 2 ;;
    --receiver-known-hosts) [ "$#" -ge 2 ] || usage; receiver_known_hosts=$2; shift 2 ;;
    --incident-state) [ "$#" -ge 2 ] || usage; incident_state=$2; shift 2 ;;
    --incident-state-key) [ "$#" -ge 2 ] || usage; incident_state_key=$2; shift 2 ;;
    --incident-command) [ "$#" -ge 2 ] || usage; incident_command=$2; shift 2 ;;
    --deadman-url) [ "$#" -ge 2 ] || usage; deadman_url=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$environment" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ &&
  "$now" =~ ^[0-9]+$ ]] || usage
[[ "$deadman_url" =~ ^https://[^[:space:]]+$ ]] || usage
for path in "$incident_command" "$incident_state"; do
  [ -z "$path" ] || [[ "$path" = /* && "$path" != *..* && "$path" != *$'\n'* ]] || usage
done
for path in "$receiver_root" "$receiver_ssh_config" "$receiver_known_hosts"; do
  [ -z "$path" ] || [[ "$path" = /* && "$path" != *..* && "$path" != *$'\n'* ]] || usage
done
if [ -n "$storage_root" ]; then
  [[ "$storage_root" = /* && "$storage_root" != *..* && "$storage_root" != *$'\n'* ]] || usage
  [ -z "$incident_state_key" ] || usage
  [ -n "$incident_state" ] || usage
else
  [ -n "$incident_state_key" ] || usage
  [ -z "$incident_state" ] || usage
fi
[ -x "$incident_command" ] && [ ! -L "$incident_command" ] || {
  echo 'BACKUP_INCIDENT_BLOCKED:incident_command_unavailable' >&2
  exit 1
}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [ "${BETA_BACKUP_TEST_FIXTURE:-false}" != true ]; then
  [ "$incident_command" = "$script_dir/send-beta-backup-incident.sh" ] || {
    echo 'BACKUP_INCIDENT_BLOCKED:incident_command_not_checked_in' >&2
    exit 1
  }
fi
for tool in jq sha256sum find curl timeout; do
  command -v "$tool" >/dev/null 2>&1 || exit 1
done
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"

validate_incident_state() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -c <"$file")" -le 65536 ] || return 1
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
  ' "$file" >/dev/null
}

status_tmp=$(mktemp)
event_tmp=$(mktemp)
next_state_tmp=$(mktemp)
remote_state_tmp=$(mktemp)
trap 'rm -f -- "$status_tmp" "$event_tmp" "$next_state_tmp" "$remote_state_tmp"' \
  EXIT HUP INT TERM

if [ -n "$storage_root" ]; then
  beta_storage_require_local_root "$storage_root" >/dev/null
  capture_state=MISSING capture_id=null capture_at=null verified_state=MISSING
  verified_id=null verified_at=null
  point_capture() {
    local point=$1
    beta_storage_local_validate_point_dir "$storage_root/points/$point" "$point" ||
      return 1
    jq -er '.capture.capturedAt' "$storage_root/points/$point/recovery-point.json"
  }
  for kind in capture verified; do
    head="$storage_root/control/$kind-head.json"
    if [ -f "$head" ] && [ ! -L "$head" ]; then
      candidate=$(jq -er '.pointId' "$head") || candidate=
      if [ -n "$candidate" ] && captured=$(point_capture "$candidate"); then
        if [ "$kind" = capture ]; then
          capture_state=VALID; capture_id=$candidate; capture_at=$captured
        else
          verified_state=VALID; verified_id=$candidate; verified_at=$captured
        fi
      elif [ "$kind" = capture ]; then capture_state=INVALID
      else verified_state=INVALID
      fi
    fi
  done
  authority_digest=$(
    for head in "$storage_root/control/capture-head.json" \
      "$storage_root/control/verified-head.json"; do
      if [ -f "$head" ]; then
        sha256sum "$head" | awk '{print $1}'
      fi
    done | sha256sum | awk '{print $1}'
  )
  generation=0
  for head in "$storage_root/control/capture-head.json" \
    "$storage_root/control/verified-head.json"; do
    [ -f "$head" ] || continue
    value=$(jq -er '.generation' "$head") || value=0
    (( value > generation )) && generation=$value
  done
else
  beta_storage_remote_build_status "$status_tmp" "$environment" "$now"
  capture_state=$(jq -er '.capture.state' "$status_tmp")
  capture_id=$(jq -er '.capture.id // "null"' "$status_tmp")
  capture_at=$(jq -er '.capture.capturedAt // null' "$status_tmp")
  verified_state=$(jq -er '.verified.state' "$status_tmp")
  verified_id=$(jq -er '.verified.id // "null"' "$status_tmp")
  verified_at=$(jq -er '.verified.capturedAt // null' "$status_tmp")
  authority_digest=$(jq -er '.authorityDigest' "$status_tmp")
  generation=$(jq -er '.authorityGeneration' "$status_tmp")
fi

if [ ! -s "$status_tmp" ]; then
  jq -cnS --arg environment "$environment" --arg digest "$authority_digest" \
    --arg captureState "$capture_state" --arg verifiedState "$verified_state" \
    --arg captureId "$capture_id" --arg verifiedId "$verified_id" \
    --argjson observed "$now" --argjson generation "$generation" \
    --argjson captureAt "$capture_at" --argjson verifiedAt "$verified_at" \
    '{schema:"meet-backend/beta-backup-status/v1",environment:$environment,
      observedAt:$observed,authorityGeneration:$generation,authorityDigest:$digest,
      capture:{state:$captureState,id:(if $captureId=="null" then null else $captureId end),
        capturedAt:(if $captureAt==null then null else $captureAt end)},
      verified:{state:$verifiedState,id:(if $verifiedId=="null" then null else $verifiedId end),
        capturedAt:(if $verifiedAt==null then null else $verifiedAt end)}}' >"$status_tmp"
fi

reasons=()
[ "$capture_state" = VALID ] || reasons+=(capture_missing_or_invalid)
[ "$capture_state" = VALID ] && (( now - capture_at >= 86400 )) &&
  reasons+=(capture_older_than_24h)
[ "$capture_state" = VALID ] && (( now - capture_at >= 108000 )) &&
  reasons+=(capture_older_than_30h)
[ "$verified_state" = VALID ] || reasons+=(verified_missing_or_invalid)
[ "$verified_state" = VALID ] && (( now - verified_at >= 1209600 )) &&
  reasons+=(verified_older_than_14d)
reason_json=$(printf '%s\n' "${reasons[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')
dedupe_key=$(printf '%s\0%s' "$environment" "$reason_json" |
  sha256sum | awk '{print $1}')

old_state=none
if [ -n "$storage_root" ]; then
  if [ -f "$incident_state" ] && [ ! -L "$incident_state" ]; then
    validate_incident_state "$incident_state" || {
      echo 'BACKUP_INCIDENT_BLOCKED:incident_state_invalid' >&2; exit 1;
    }
    old_state=$(jq -er '.state' "$incident_state")
  fi
else
  if beta_storage_remote_head "$incident_state_key" "$remote_state_tmp"; then
    beta_storage_remote_get_json "$incident_state_key" "$remote_state_tmp.json" \
      "$(jq -er '.VersionId' "$remote_state_tmp")"
    validate_incident_state "$remote_state_tmp.json" || {
      echo 'BACKUP_INCIDENT_BLOCKED:incident_state_invalid' >&2; exit 1;
    }
    old_state=$(jq -er '.state' "$remote_state_tmp.json")
  else
    [ "$?" -eq 1 ] || { echo 'BACKUP_INCIDENT_BLOCKED:incident_state_read_failed' >&2; exit 1; }
  fi
fi

incident_id='' delivery_count=0 recovery_count=0 first_seen=$now event=none
state_file="$incident_state"
if [ "$old_state" != none ]; then
  [ -n "$storage_root" ] || state_file="${remote_state_tmp}.json"
  delivery_count=$(jq -er '.deliveryCount' "$state_file")
  recovery_count=$(jq -er '.recoveryCount' "$state_file")
  first_seen=$(jq -er '.firstSeenAt' "$state_file")
  incident_id=$(jq -er '.incidentId' "$state_file")
fi
if [ "${#reasons[@]}" -gt 0 ]; then
  old_dedupe=
  [ "$old_state" = active ] && old_dedupe=$(jq -er '.dedupeKey' "$state_file") || true
  if [ "$old_state" != active ] || [ "$old_dedupe" != "$dedupe_key" ]; then
    incident_id="incident-$(printf '%s' "$dedupe_key" | cut -c1-32)"
    first_seen=$now
    delivery_count=1
    event=active
  fi
  state=active
else
  [ "$old_state" = active ] && {
    event=recovered; recovery_count=$((recovery_count + 1));
  }
  incident_id=${incident_id:-recovered}
  state=recovered
fi
jq -cnS --arg environment "$environment" --arg state "$state" --arg key "$dedupe_key" \
  --arg id "$incident_id" --argjson first "$first_seen" --argjson last "$now" \
  --argjson deliveries "$delivery_count" --argjson recoveries "$recovery_count" \
  '{schema:"meet-backend/beta-backup-incident/v2",environment:$environment,state:$state,
    incidentId:$id,dedupeKey:$key,firstSeenAt:$first,lastSeenAt:$last,
    deliveryCount:$deliveries,recoveryCount:$recoveries}' >"$next_state_tmp"

if [ "$event" != none ]; then
  jq -cnS --arg event "$event" --arg environment "$environment" \
    --arg id "$incident_id" --arg key "$dedupe_key" --argjson reasons "$reason_json" \
    --argjson at "$now" \
    '{schema:"meet-backend/beta-backup-incident-event/v1",event:$event,
      environment:$environment,incidentId:$id,dedupeKey:$key,reasons:$reasons,
      observedAt:$at,privateDestinationRequired:true}' >"$event_tmp"
  timeout --foreground --signal=TERM 30s "$incident_command" \
    --event-file "$event_tmp" --state-file "$next_state_tmp"
fi

if [ -n "$storage_root" ]; then
  "$script_dir/receive-beta-backup-status.sh" --input "$status_tmp" \
    --root "$receiver_root" --environment "$environment" --now "$now" >/dev/null
  chmod 600 "$next_state_tmp"
  mkdir -p "$(dirname -- "$incident_state")"
  mv -f -- "$next_state_tmp" "$incident_state"
else
  [ -n "$receiver_host" ] && [ -n "$receiver_user" ] &&
    [ -f "$receiver_ssh_config" ] && [ -f "$receiver_known_hosts" ] || {
      echo 'BACKUP_SAFETY_BLOCKED:receiver_transport_missing' >&2; exit 1;
    }
  timeout --foreground --signal=TERM 60s ssh -F "$receiver_ssh_config" \
    -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$receiver_known_hosts" \
    "$receiver_user@$receiver_host" \
    /usr/local/libexec/meet-beta-backup-receive-status \
    --environment "$environment" --now "$now" <"$status_tmp"
  current_etag=''
  if beta_storage_remote_head "$incident_state_key" "$remote_state_tmp"; then
    current_etag=$(jq -er '.ETag' "$remote_state_tmp")
  else
    [ "$?" -eq 1 ] || { echo 'BACKUP_INCIDENT_BLOCKED:incident_state_read_failed' >&2; exit 1; }
  fi
  if [ -n "$current_etag" ]; then
    beta_storage_provider_put_conditional '' "$incident_state_key" "$next_state_tmp" \
      "$current_etag" false >/dev/null
  else
    beta_storage_provider_put_conditional '' "$incident_state_key" "$next_state_tmp" \
      '' true >/dev/null
  fi
fi

curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
  --max-redirs 0 --request POST --data-binary '' "$deadman_url" >/dev/null 2>/dev/null ||
  { echo 'BACKUP_SAFETY_BLOCKED:deadman_failed' >&2; exit 1; }
printf 'monitor_status=delivered incident=%s event=%s heartbeat=sent\n' \
  "$([ "${#reasons[@]}" -gt 0 ] && echo true || echo false)" "$event"
