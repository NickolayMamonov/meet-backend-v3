#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: probe-test-vps-zero-state.sh
  --phase predecessor|candidate|rollback|final
  --state-mode empty-closed|closed-beta-demo
  --root PATH --compose-script PATH --state-dir PATH
  --expected-image IMAGE@sha256:DIGEST --expected-image-id sha256:DIGEST
  --expected-revision SHA --expected-version X.Y.Z --expected-runtime-hash HEX64
  --public-url https://HOST --output PATH
EOF
  exit 2
}

fail() {
  echo "test VPS zero-state probe failed: $*" >&2
  exit 1
}

phase=
root=
compose_script=
state_dir=
expected_image=
expected_image_id=
expected_revision=
expected_version=
expected_runtime_hash=
state_mode=
public_url=
output=
meetings_body=
headers=
admin_config=
temporary=
assets_file=
meetings_status=0
meetings_json='[]'
meetings_json_valid=false
meetings_count=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase) [ "$#" -ge 2 ] || usage; phase=$2; shift 2 ;;
    --state-mode) [ "$#" -ge 2 ] || usage; state_mode=$2; shift 2 ;;
    --root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
    --compose-script) [ "$#" -ge 2 ] || usage; compose_script=$2; shift 2 ;;
    --state-dir) [ "$#" -ge 2 ] || usage; state_dir=$2; shift 2 ;;
    --expected-image) [ "$#" -ge 2 ] || usage; expected_image=$2; shift 2 ;;
    --expected-image-id) [ "$#" -ge 2 ] || usage; expected_image_id=$2; shift 2 ;;
    --expected-revision) [ "$#" -ge 2 ] || usage; expected_revision=$2; shift 2 ;;
    --expected-version) [ "$#" -ge 2 ] || usage; expected_version=$2; shift 2 ;;
    --expected-runtime-hash) [ "$#" -ge 2 ] || usage; expected_runtime_hash=$2; shift 2 ;;
    --public-url) [ "$#" -ge 2 ] || usage; public_url=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done

case "$phase" in predecessor|candidate|rollback|final) ;; *) usage ;; esac
case "$state_mode" in empty-closed|closed-beta-demo) ;; *) usage ;; esac
[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$root" != *..* ]] || usage
[[ "$compose_script" =~ ^/[A-Za-z0-9._/-]+$ ]] &&
  [[ "$compose_script" != *..* ]] || usage
[[ "$state_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$state_dir" != *..* ]] || usage
[[ "$expected_image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
  usage
[[ "$expected_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$expected_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  usage
[[ "$expected_runtime_hash" =~ ^[0-9a-f]{64}$ ]] || usage
[[ "$public_url" =~ ^https://[^/]+$ ]] || usage
[ -n "$output" ] || usage
[ -d "$root" ] && [ -s "$root/.env.production" ] || fail "production root is incomplete"
[ -x "$compose_script" ] || fail "Compose wrapper is unavailable"
[ -d "$state_dir" ] && [ ! -L "$state_dir" ] || fail "state directory is unsafe"
[ ! -L "$output" ] || fail "output path is unsafe"
[ -d "$(dirname -- "$output")" ] || fail "output directory is unavailable"
for command_name in docker curl jq sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name is required"
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$script_dir/test-vps-runtime-invariants.sh"
contract="$script_dir/test-vps-admission-contract.json"
stable_sql="$script_dir/test-vps-beta-demo-stable-proof.sql"
public_sql="$script_dir/test-vps-beta-demo-public-proof.sql"
[ -r "$contract" ] && [ -r "$stable_sql" ] && [ -r "$public_sql" ] ||
  fail "admission proof contract is unavailable"
jq -e '
  .schema == "meet-backend/test-vps-admission-contract/v1" and
  (.stateModes | sort) == ["closed-beta-demo","empty-closed"] and
  .populated.catalogName == "closed-beta-demo" and
  .populated.manifestVersion == "2026-08-15.v1" and
  .populated.stableProof.byteLength == 6867
' "$contract" >/dev/null || fail "admission proof contract is invalid"

backend=$(runtime_compose "$root" "$compose_script" ps -q backend) ||
  fail "backend lookup failed"
postgres=$(runtime_compose "$root" "$compose_script" ps -q postgres) ||
  fail "postgres lookup failed"
[ -n "$backend" ] && [ -n "$postgres" ] ||
  fail "backend or PostgreSQL container is unavailable"

actual_id=$(docker inspect "$backend" --format '{{.Image}}') ||
  fail "backend image identity unavailable"
reference=$(docker inspect "$backend" --format '{{.Config.Image}}') ||
  fail "backend image reference unavailable"
runtime_hash=$(docker inspect "$backend" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') ||
  fail "backend runtime hash unavailable"
[ "$actual_id" = "$expected_image_id" ] || fail "backend image identity differs"
[ "$reference" = "$expected_image" ] || fail "backend image reference differs"
[ "$runtime_hash" = "$expected_runtime_hash" ] ||
  fail "backend runtime hash differs"

container_running=$(docker inspect "$backend" --format '{{.State.Running}}') ||
  fail "backend running state unavailable"
health_status=$(docker inspect "$backend" --format '{{.State.Health.Status}}') ||
  fail "backend health state unavailable"
container_healthy=false
[ "$container_running" = true ] && [ "$health_status" = healthy ] &&
  container_healthy=true

source_label=$(docker inspect "$backend" \
  --format '{{index .Config.Labels "org.opencontainers.image.source"}}')
revision_label=$(docker inspect "$backend" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
version_label=$(docker inspect "$backend" \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}')
[ "$source_label" = "https://github.com/NickolayMamonov/meet-backend-v3" ] ||
  fail "backend source label differs"
[ "$revision_label" = "$expected_revision" ] || fail "backend revision label differs"
[ "$version_label" = "$expected_version" ] || fail "backend version label differs"

volumes=$(runtime_normalized_mounts "$backend")
postgres_volumes=$(runtime_normalized_mounts "$postgres")
volumes_verified=false
if jq -e '
  length == 1 and .[0].type == "volume" and
  .[0].source == "meet-production_uploads_data" and
  .[0].destination == "/data/uploads" and .[0].read_only == false
' <<<"$volumes" >/dev/null &&
  jq -e '
  length == 1 and .[0].type == "volume" and
  .[0].source == "meet-production_postgres_data" and
  .[0].destination == "/var/lib/postgresql/data" and .[0].read_only == false
' <<<"$postgres_volumes" >/dev/null; then
  docker volume inspect meet-production_uploads_data >/dev/null
  docker volume inspect meet-production_postgres_data >/dev/null
  volumes_verified=true
fi

topology_verified=false
ports=$(runtime_normalized_ports "$backend")
networks=$(runtime_normalized_networks "$backend")
binding=$(docker inspect "$backend" --format \
  '{{range $port, $bindings := .NetworkSettings.Ports}}{{if eq $port "8080/tcp"}}{{range $bindings}}{{.HostIp}}:{{.HostPort}}{{println}}{{end}}{{end}}{{end}}')
postgres_binding=$(docker port "$postgres")
compose_address=$(runtime_compose "$root" "$compose_script" port backend 8080)
if [ "$(wc -l <<<"$binding")" -eq 1 ] &&
  [[ "$binding" =~ ^127\.0\.0\.1:[0-9]+$ ]] &&
  [ -z "$postgres_binding" ] &&
  [[ "$compose_address" =~ ^127\.0\.0\.1:[0-9]+$ ]]; then
  topology_verified=true
fi

hardening_verified=false
memory=$(docker inspect "$backend" --format '{{.HostConfig.Memory}}')
if [ "$(docker inspect "$backend" --format '{{.HostConfig.ReadonlyRootfs}}')" = true ] &&
  [ "$(docker inspect "$backend" --format '{{.HostConfig.RestartPolicy.Name}}')" = unless-stopped ] &&
  [ "$(docker inspect "$backend" --format '{{.HostConfig.LogConfig.Type}}')" = local ] &&
  docker inspect "$backend" --format '{{json .HostConfig.CapDrop}}' |
    jq -e 'index("ALL") != null' >/dev/null &&
  docker inspect "$backend" --format '{{json .HostConfig.SecurityOpt}}' |
    jq -e 'index("no-new-privileges:true") != null' >/dev/null &&
  docker inspect "$backend" --format '{{json .HostConfig.Tmpfs}}' |
    jq -e 'has("/tmp")' >/dev/null &&
  [[ "$memory" =~ ^[1-9][0-9]*$ ]] &&
  [ "$(docker exec "$backend" id -u)" = 10001 ] &&
  [ "$(docker exec "$backend" id -g)" = 10001 ]; then
  hardening_verified=true
fi

database_json=$(
  docker exec "$postgres" psql -Atqc "
    SELECT json_build_object(
      'tags',(SELECT count(*) FROM tags),
      'users',(SELECT count(*) FROM users),
      'communities',(SELECT count(*) FROM communities),
      'meetings',(SELECT count(*) FROM meetings),
      'ad_blocks',(SELECT count(*) FROM ad_blocks),
      'user_interests',(SELECT count(*) FROM user_interests),
      'user_social_media',(SELECT count(*) FROM user_social_media),
      'community_tags',(SELECT count(*) FROM community_tags),
      'community_subscribers',(SELECT count(*) FROM community_subscribers),
      'meeting_tags',(SELECT count(*) FROM meeting_tags),
      'meeting_participants',(SELECT count(*) FROM meeting_participants),
      'ad_block_communities',(SELECT count(*) FROM ad_block_communities),
      'ad_block_users',(SELECT count(*) FROM ad_block_users),
      'demo_catalog_state',(SELECT count(*) FROM demo_catalog_state)
    )::text
  " 2>/dev/null
) || fail "database aggregate query failed"
echo "$database_json" | jq -e 'type == "object" and all(values[]; type == "number" and . >= 0)' \
  >/dev/null || fail "database aggregate query was not canonical"
total_rows=$(jq -n --argjson tables "$database_json" '$tables | add')
admission_state_sha256=
admission_database_proof_sha256=
admission_stable_proof_sha256=
admission_public_proof_sha256=
admission_route_summaries='{}'
admission_bundle_a=
admission_bundle_b=
admission_bundle_tmp=
admission_recovery_a=
admission_recovery_b=
admission_stable_a=
admission_stable_b=
admission_public_a=
admission_public_b=
admission_non_idle_a=
admission_non_idle_b=
expected_meetings=
expected_communities=
expected_tags=
expected_ads=
meetings_response=
communities_response=
tags_response=
ads_response=
route_meetings=
route_communities=
route_tags=
route_ads=
cleanup() {
  local path
  for path in "$temporary" "$meetings_body" "$headers" "$admin_config" \
    "$admission_bundle_a" "$admission_bundle_b" "$admission_recovery_a" \
    "$admission_recovery_b" "$admission_stable_a" "$admission_stable_b" \
    "$admission_public_a" "$admission_public_b" "$expected_meetings" \
    "$expected_communities" "$expected_tags" "$expected_ads" \
    "$meetings_response" "$communities_response" "$tags_response" "$ads_response" \
    "$route_meetings" "$route_communities" "$route_tags" "$route_ads" \
    "$admission_bundle_tmp" \
    "$assets_file"; do
    [ -n "$path" ] && rm -f -- "$path"
  done
}
trap cleanup EXIT HUP INT TERM
if [ "$state_mode" = closed-beta-demo ]; then
  fixture="$script_dir/fixtures/test-vps-beta-demo/canonical-stable-proof.json"
  [ -f "$fixture" ] && [ ! -L "$fixture" ] || fail "stable proof fixture is unavailable"
  stable_size=$(jq -er '.populated.stableProof.byteLength' "$contract")
  stable_digest=$(jq -er '.populated.stableProof.sha256' "$contract")
  recovery_digest=$(jq -er '.populated.recoveryProof.sha256' "$contract")
  test "$(wc -c <"$fixture" | tr -d ' ')" = "$stable_size" ||
    fail "stable proof fixture size differs"
  test "$(sha256sum "$fixture" | awk '{print $1}')" = "$stable_digest" ||
    fail "stable proof fixture digest differs"
  capture_admission_bundle() {
    local destination=$1
    admission_bundle_tmp=$(mktemp)
    chmod 600 "$admission_bundle_tmp"
    {
      printf '%s\n' 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;'
      printf '%s\n' '\echo __RECOVERY__'
      cat "$script_dir/beta-recovery-database-proof.sql"
      printf '%s\n' '\echo __STABLE__'
      cat "$stable_sql"
      printf '%s\n' '\echo __PUBLIC__'
      cat "$public_sql"
      printf '%s\n' '\echo __NON_IDLE__'
      printf '%s\n' "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend' AND state <> 'idle';"
      printf '%s\n' 'COMMIT;'
    } >"$admission_bundle_tmp"
    docker exec -i "$postgres" psql -AtqX -v ON_ERROR_STOP=1 \
      <"$admission_bundle_tmp" >"$destination" ||
      fail "populated database snapshot failed"
    rm -f -- "$admission_bundle_tmp"
    admission_bundle_tmp=
    [ -s "$destination" ] || fail "populated database snapshot is empty"
    chmod 600 "$destination"
  }
  extract_snapshot_part() {
    local snapshot=$1 marker=$2 destination=$3 next_marker=$4
    awk -v start="$marker" -v finish="$next_marker" '
      $0 == start { found=1; next }
      $0 == finish { found=0 }
      found { print }
    ' "$snapshot" >"$destination"
    [ -s "$destination" ] || fail "populated snapshot part is missing"
    chmod 600 "$destination"
  }
  validate_snapshot() {
    local snapshot=$1 recovery=$2 stable=$3 public=$4 non_idle=$5
    extract_snapshot_part "$snapshot" __RECOVERY__ "$recovery" __STABLE__
    extract_snapshot_part "$snapshot" __STABLE__ "$stable" __PUBLIC__
    extract_snapshot_part "$snapshot" __PUBLIC__ "$public" __NON_IDLE__
    extract_snapshot_part "$snapshot" __NON_IDLE__ "$non_idle" __NO_MARKER__
    [[ "$(tr -d '[:space:]' <"$non_idle")" =~ ^[0-9]+$ ]] ||
      fail "populated snapshot transaction count is not numeric"
    jq -e 'type == "object" and
      (keys | sort) == ["ads","meetings","recommendedCommunities","tags"]' \
      "$public" >/dev/null || fail "public database projection is invalid"
  }
  admission_bundle_a=$(mktemp)
  admission_recovery_a=$(mktemp)
  admission_stable_a=$(mktemp)
  admission_public_a=$(mktemp)
  admission_non_idle_a=$(mktemp)
  capture_admission_bundle "$admission_bundle_a"
  validate_snapshot "$admission_bundle_a" "$admission_recovery_a" \
    "$admission_stable_a" "$admission_public_a" "$admission_non_idle_a"
  admission_stable_proof_sha256=$(sha256sum "$admission_stable_a" | awk '{print $1}')
  admission_database_proof_sha256=$(sha256sum "$admission_recovery_a" | awk '{print $1}')
  admission_public_proof_sha256=$(sha256sum "$admission_public_a" | awk '{print $1}')
  test "$admission_stable_proof_sha256" = "$stable_digest" ||
    fail "stable database proof digest differs"
  test "$admission_database_proof_sha256" = "$recovery_digest" ||
    fail "recovery database proof digest differs"
  cmp -- "$fixture" "$admission_stable_a" ||
    fail "stable database proof differs from canonical fixture"
  [ "$(tr -d '[:space:]' <"$admission_non_idle_a")" = 0 ] ||
    fail "non-idle client transaction observed in snapshot A"

  canonicalize_route() {
    local route=$1 input=$2 output=$3
    case "$route" in
      meetings)
        jq -cS '
          type == "array" and
          all(.[]; type == "object" and
            all(["id","imageUrl","title","description","time","date","address",
              "capacity","tags","personHost","communityHost","participants",
              "meetingStatus","isUserInParticipants","source","externalUrl","isOnline"][];
              has(.)) and
            (.address | type == "object" and
              all(["address","latitude","longitude"][]; has(.))) and
            (.tags | type == "array" and all(.[]; type == "object" and
              all(["id","text"][]; has(.)))) and
            (.personHost == null or (.personHost | type == "object" and
              all(["id","name","surname","description","imageUrl"][]; has(.)))) and
            (.communityHost == null or (.communityHost | type == "object" and
              all(["id","title","description","imageUrl","meetingsInfo"][]; has(.)) and
              (.meetingsInfo | type == "array" and all(.[]; type == "object" and
                all(["id","title","imageUrl","date"][]; has(.)))))) and
            (.participants | type == "array" and all(.[]; type == "object" and
              all(["id","name","surname","imageUrl"][]; has(.)))))
          | map({
            id,imageUrl,title,description,time,date,
            address:{address:.address.address,latitude:.address.latitude,longitude:.address.longitude},
            capacity,tags:(.tags | sort_by(.id)),
            personHost:(if .personHost == null then null else
              {id:.personHost.id,name:.personHost.name,surname:.personHost.surname,
               description:.personHost.description,imageUrl:.personHost.imageUrl} end),
            communityHost:(if .communityHost == null then null else
              {id:.communityHost.id,title:.communityHost.title,description:.communityHost.description,
               imageUrl:.communityHost.imageUrl,
               meetingsInfo:(.communityHost.meetingsInfo | sort_by(.id))} end),
            participants:(.participants | sort_by(.id)),
            meetingStatus,isUserInParticipants,source,externalUrl,isOnline
          }) | sort_by(.id)
        ' "$input" >"$output" || fail "meetings public projection is invalid"
        ;;
      communities)
        jq -cS '
          type == "array" and
          all(.[]; type == "object" and
            all(["id","name","description","imageUrl","subscribersCount","isSubscribed","tags"][];
              has(.)) and
            (.tags | type == "array" and all(.[]; type == "object" and
              all(["id","text"][]; has(.)))))
          | map({id,name,description,imageUrl,subscribersCount,isSubscribed,
            tags:(.tags | sort_by(.id))}) | sort_by(.id)
        ' "$input" >"$output" || fail "communities public projection is invalid"
        ;;
      tags)
        jq -cS '
          type == "object" and
          all(["success","data","message","error"][]; has(.)) and
          (.success | type == "boolean") and (.data | type == "array" and
            all(.[]; type == "object" and all(["id","text"][]; has(.)))) |
          {success,data:(.data | sort_by(.id)),message,error}
        ' "$input" >"$output" || fail "tags public projection is invalid"
        ;;
      ads)
        jq -cS '
          type == "array" and
          all(.[]; type == "object" and
            all(["type","id","isActive","title","description","communities",
              "actionText","actionUrl","users"][]; has(.)) and
            (.communities == null or (.communities | type == "array" and
              all(.[]; type == "object" and
                all(["id","name","description","imageUrl","subscribersCount"][]; has(.))))) and
            (.users == null or (.users | type == "array" and all(.[]; type == "object" and
              all(["id","name","surname","avatarUrl","bio","role"][]; has(.))))))
          | map({type,id,isActive,title,description,
            communities:(if .communities == null then null else .communities | sort_by(.id) end),
            actionText,actionUrl,
            users:(if .users == null then null else .users | sort_by(.id) end)}) | sort_by(.id)
        ' "$input" >"$output" || fail "ads public projection is invalid"
        ;;
      *) fail "unknown public route" ;;
    esac
  }
  expected_meetings=$(mktemp); expected_communities=$(mktemp)
  expected_tags=$(mktemp); expected_ads=$(mktemp)
  jq -cS '.meetings' "$admission_public_a" >"$expected_meetings"
  jq -cS '.recommendedCommunities' "$admission_public_a" >"$expected_communities"
  jq -cS '.tags' "$admission_public_a" >"$expected_tags"
  jq -cS '.ads' "$admission_public_a" >"$expected_ads"
  meetings_response=$(mktemp); communities_response=$(mktemp)
  tags_response=$(mktemp); ads_response=$(mktemp)
  route_meetings=$(mktemp); route_communities=$(mktemp)
  route_tags=$(mktemp); route_ads=$(mktemp)
  meetings_status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --output "$meetings_response" --write-out '%{http_code}' --proto '=https' \
    --tlsv1.2 "$public_url/meetings?page=0&limit=100") ||
    fail "meetings HTTP probe failed"
  communities_status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --output "$communities_response" --write-out '%{http_code}' --proto '=https' \
    --tlsv1.2 "$public_url/communities/recommended") ||
    fail "recommended communities HTTP probe failed"
  tags_status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --output "$tags_response" --write-out '%{http_code}' --proto '=https' \
    --tlsv1.2 "$public_url/api/v1/tags") ||
    fail "tags HTTP probe failed"
  ads_status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --output "$ads_response" --write-out '%{http_code}' --proto '=https' \
    --tlsv1.2 "$public_url/api/ads") ||
    fail "ads HTTP probe failed"
  [ "$meetings_status" = 200 ] && [ "$communities_status" = 200 ] &&
    [ "$tags_status" = 200 ] && [ "$ads_status" = 200 ] ||
    fail "a required public route did not return HTTP 200"
  canonicalize_route meetings "$meetings_response" "$route_meetings"
  canonicalize_route communities "$communities_response" "$route_communities"
  canonicalize_route tags "$tags_response" "$route_tags"
  canonicalize_route ads "$ads_response" "$route_ads"
  cmp -- "$expected_meetings" "$route_meetings" ||
    fail "meetings public projection differs from database"
  cmp -- "$expected_communities" "$route_communities" ||
    fail "recommended communities projection differs from database"
  cmp -- "$expected_tags" "$route_tags" ||
    fail "tags public projection differs from database"
  cmp -- "$expected_ads" "$route_ads" ||
    fail "ads public projection differs from database"
  meetings_count=$(jq 'length' "$route_meetings")
  meetings_json_valid=true
  admission_route_summaries=$(jq -cnS \
    --arg hash "$admission_public_proof_sha256" \
    --argjson meetings "$(cat "$route_meetings")" \
    --argjson communities "$(cat "$route_communities")" \
    --argjson tags "$(cat "$route_tags")" \
    --argjson ads "$(cat "$route_ads")" '
    {meetings:{status:200,schemaValid:true,count:($meetings|length),projectionSha256:$hash,equal:true},
     recommendedCommunities:{status:200,schemaValid:true,count:($communities|length),projectionSha256:$hash,equal:true},
     tags:{status:200,schemaValid:true,count:($tags.data|length),projectionSha256:$hash,equal:true},
     ads:{status:200,schemaValid:true,count:($ads|length),projectionSha256:$hash,equal:true}}
  ')
  admission_bundle_b=$(mktemp)
  admission_recovery_b=$(mktemp)
  admission_stable_b=$(mktemp)
  admission_public_b=$(mktemp)
  admission_non_idle_b=$(mktemp)
  capture_admission_bundle "$admission_bundle_b"
  validate_snapshot "$admission_bundle_b" "$admission_recovery_b" \
    "$admission_stable_b" "$admission_public_b" "$admission_non_idle_b"
  [ "$(tr -d '[:space:]' <"$admission_non_idle_b")" = 0 ] ||
    fail "non-idle client transaction observed in snapshot B"
  cmp -- "$admission_recovery_a" "$admission_recovery_b" ||
    fail "recovery proof changed between snapshots"
  cmp -- "$admission_stable_a" "$admission_stable_b" ||
    fail "stable proof changed between snapshots"
  cmp -- "$admission_public_a" "$admission_public_b" ||
    fail "public database projection changed between snapshots"
  admission_state_sha256=$(jq -cnS \
    --arg mode "$state_mode" --arg recovery "$admission_database_proof_sha256" \
    --arg stable "$admission_stable_proof_sha256" --arg public "$admission_public_proof_sha256" \
    --arg meetings "$admission_public_proof_sha256" --arg communities "$admission_public_proof_sha256" \
    --arg tags "$admission_public_proof_sha256" --arg ads "$admission_public_proof_sha256" \
    --argjson roots "$(jq -c '.populated.roots' "$contract")" \
    --argjson relationships "$(jq -c '.populated.relationships' "$contract")" \
    '{mode:$mode,recoveryProofSha256:$recovery,stableProofSha256:$stable,
      publicProjectionSha256:$public,
      routeProjectionSha256:{
        meetings:$meetings,recommendedCommunities:$communities,tags:$tags,ads:$ads
      },roots:$roots,relationships:$relationships}' | sha256sum | awk '{print $1}')
fi

query_metric() {
  local sql=$1
  docker exec "$postgres" psql -Atqc "$sql" 2>/dev/null |
    tr -d '[:space:]'
}
non_idle_transactions=$(query_metric \
  "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend' AND state <> 'idle'") ||
  fail "transaction probe failed"
[[ "$non_idle_transactions" =~ ^[0-9]+$ ]] ||
  fail "transaction probe was not numeric"
smtp_sample_one=$(query_metric \
  "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND backend_type = 'client backend' AND state <> 'idle' AND application_name ILIKE '%smtp%'") ||
  fail "SMTP probe failed"
sleep 1
smtp_sample_two=$(query_metric \
  "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND backend_type = 'client backend' AND state <> 'idle' AND application_name ILIKE '%smtp%'") ||
  fail "SMTP probe failed"
[[ "$smtp_sample_one" =~ ^[0-9]+$ ]] && [[ "$smtp_sample_two" =~ ^[0-9]+$ ]] ||
  fail "SMTP probe was not numeric"
postgres_writable_primary=$(query_metric \
  "SELECT CASE WHEN pg_is_in_recovery() THEN 0 ELSE 1 END") ||
  fail "PostgreSQL primary probe failed"
[ "$postgres_writable_primary" = 1 ] ||
  fail "PostgreSQL is not a writable primary"

if [ "$state_mode" = empty-closed ]; then
  meetings_body=$(mktemp)
  meetings_status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --output "$meetings_body" \
    --write-out '%{http_code}' --proto '=https' --tlsv1.2 "$public_url/meetings") ||
    fail "meetings HTTP probe failed"
  [ "$meetings_status" = 200 ] || fail "meetings HTTP status was not 200"
  meetings_json=$(jq -c 'if type == "array" then . else error("not an array") end' \
    "$meetings_body") || fail "meetings response was not a JSON array"
  meetings_json_valid=true
  meetings_count=$(jq 'length' <<<"$meetings_json")
fi
actuator_status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
  --output /dev/null \
  --write-out '%{http_code}' --proto '=https' --tlsv1.2 "$public_url/actuator")
headers=$(mktemp)
curl --silent --show-error --connect-timeout 10 --proto '=http' --max-time 10 \
  -D "$headers" -o /dev/null "${public_url/https:\/\//http://}/meetings" ||
  fail "HTTP redirect probe failed"
http_redirect_https=false
grep -Eiq '^location: https://' "$headers" && http_redirect_https=true
missing_admin=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
  --output /dev/null \
  --write-out '%{http_code}' -X POST "$public_url/admin/demo-catalog/bootstrap" \
  -H 'Content-Type: application/json' --data '{}')
wrong_admin=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
  --output /dev/null \
  --write-out '%{http_code}' -X POST "$public_url/admin/demo-catalog/bootstrap" \
  -H 'X-Admin-Key: wrong' -H 'Content-Type: application/json' --data '{}')
admin_key_configured=false
admin_authenticated_disabled_404=false
admin_blank_disabled_403=false
[ "$(grep -c '^ADMIN_API_KEY=' "$root/.env.production")" -eq 1 ] ||
  fail "admin key setting is unavailable"
admin_key=$(sed -n 's/^ADMIN_API_KEY=//p' "$root/.env.production")
case "$admin_key" in *[[:space:]]*) fail "configured admin key is malformed" ;; esac
if [ -n "$admin_key" ]; then
  admin_config=$(mktemp)
  chmod 600 "$admin_config"
  printf 'header = "X-Admin-Key: %s"\n' "$admin_key" >"$admin_config"
  unset admin_key
  authenticated_admin=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --output /dev/null \
    --write-out '%{http_code}' -X POST --config "$admin_config" \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'Content-Type: application/json' --data '{}')
  rm -f -- "$admin_config"
  admin_config=
  [ "$authenticated_admin" = 404 ] ||
    fail "authenticated disabled admin endpoint is not absent"
  admin_key_configured=true
  admin_authenticated_disabled_404=true
else
  admin_blank_disabled_403=true
fi

assets_file=$(mktemp)
chmod 600 "$assets_file"
"$script_dir/verify-test-vps-assets.sh" --public-url "$public_url" \
  --output "$assets_file" >/dev/null || fail "frozen assets probe failed"
assets_count=$(jq -r '.assets | length // .count // 0' "$assets_file" 2>/dev/null ||
  jq -r '.count // 0' "$assets_file")
assets_verified=$(jq -er '.verified | select(type == "boolean")' "$assets_file")
[ "$assets_count" = 13 ] || fail "frozen asset count differs"

populated_database_valid=false
if jq -e --argjson tables "$database_json" --slurpfile contract "$contract" '
  ($contract[0].populated.roots) as $roots |
  ($contract[0].populated.relationships) as $relationships |
  $tables.tags == $roots.tags and
  $tables.users == $roots.users and
  $tables.communities == $roots.communities and
  $tables.meetings == $roots.meetings and
  $tables.ad_blocks == $roots.adBlocks and
  $tables.user_interests == $relationships.userInterests and
  $tables.community_tags == $relationships.communityTags and
  $tables.community_subscribers == $relationships.communitySubscribers and
  $tables.meeting_tags == $relationships.meetingTags and
  $tables.meeting_participants == $relationships.meetingParticipants and
  $tables.ad_block_communities == $relationships.adBlockCommunities and
  $tables.ad_block_users == $relationships.adBlockUsers and
  $tables.user_social_media == 0 and
  $tables.demo_catalog_state == 1
' >/dev/null; then
  populated_database_valid=true
fi
zero_state=unknown
if [ "$state_mode" = empty-closed ] &&
  [ "$total_rows" -eq 0 ] && [ "$meetings_count" -eq 0 ] &&
  [ "$container_healthy" = true ] &&
  [ "$topology_verified" = true ] &&
  [ "$hardening_verified" = true ] &&
  [ "$volumes_verified" = true ] &&
  [ "$non_idle_transactions" = 0 ] &&
  [ "$smtp_sample_one" = 0 ] && [ "$smtp_sample_two" = 0 ] &&
  [ "$meetings_status" = 200 ] && [ "$meetings_count" = 0 ] &&
  [ "$actuator_status" = 404 ] && [ "$http_redirect_https" = true ] &&
  [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] &&
  [ "$postgres_writable_primary" = 1 ] &&
  [ "$assets_verified" = true ]; then
  zero_state=closed
elif [ "$state_mode" = closed-beta-demo ] &&
  [ "$container_healthy" = true ] &&
  [ "$topology_verified" = true ] &&
  [ "$hardening_verified" = true ] &&
  [ "$volumes_verified" = true ] &&
  [ "$non_idle_transactions" = 0 ] &&
  [ "$smtp_sample_one" = 0 ] && [ "$smtp_sample_two" = 0 ] &&
  [ "$meetings_status" = 200 ] && [ "$meetings_count" -eq 6 ] &&
  [ "$actuator_status" = 404 ] && [ "$http_redirect_https" = true ] &&
  [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] &&
  [ "$postgres_writable_primary" = 1 ] &&
  [ "$assets_verified" = true ] &&
  [ "$populated_database_valid" = true ]; then
  zero_state=closed
fi

temporary="$output.tmp.$$"
trap cleanup EXIT HUP INT TERM
jq -cnS \
  --arg schema "meet-backend/test-vps-zero-state-probe/v2" \
  --arg phase "$phase" --arg image "${expected_image##*@}" --arg imageId "$expected_image_id" \
  --arg sourceSha "$expected_revision" --arg version "$expected_version" \
  --arg runtimeHash "$expected_runtime_hash" --arg zeroState "$zero_state" \
  --arg stateMode "$state_mode" --arg admissionStateSha256 "$admission_state_sha256" \
  --arg admissionDatabaseProofSha256 "$admission_database_proof_sha256" \
  --arg admissionStableProofSha256 "$admission_stable_proof_sha256" \
  --arg admissionPublicProofSha256 "$admission_public_proof_sha256" \
  --argjson admissionRoutes "$admission_route_summaries" \
  --argjson containerHealthy "$container_healthy" \
  --argjson topologyVerified "$topology_verified" \
  --argjson hardeningVerified "$hardening_verified" \
  --argjson volumesVerified "$volumes_verified" \
  --argjson postgresWritablePrimary "$([ "$postgres_writable_primary" = 1 ] && echo true || echo false)" \
  --argjson nonIdle "$non_idle_transactions" \
  --argjson smtpSamples "[$smtp_sample_one,$smtp_sample_two]" \
  --argjson database "$database_json" --argjson totalRows "$total_rows" \
  --argjson meetingsStatus "$meetings_status" --argjson meetingsCount "$meetings_count" \
  --argjson meetingsJson "$meetings_json_valid" \
  --argjson actuatorStatus "$actuator_status" --argjson httpRedirectHttps "$http_redirect_https" \
  --argjson missingAdmin "$missing_admin" --argjson wrongAdmin "$wrong_admin" \
  --argjson adminKeyConfigured "$admin_key_configured" \
  --argjson adminAuthenticatedDisabled404 "$admin_authenticated_disabled_404" \
  --argjson adminBlankDisabled403 "$admin_blank_disabled_403" \
  --argjson assetsCount "$assets_count" --argjson assetsVerified "$assets_verified" \
  --argjson volumes "$volumes" --argjson postgresVolumes "$postgres_volumes" \
  --argjson ports "$ports" --argjson networks "$networks" '
  {
    schema:$schema,phase:$phase,image:$image,imageId:$imageId,
    sourceSha:$sourceSha,version:$version,runtimeConfigHash:$runtimeHash,
    admission:(if $stateMode == "empty-closed"
      then {mode:$stateMode,stateSha256:null}
      else {mode:$stateMode,stateSha256:$admissionStateSha256,
        catalogName:"closed-beta-demo",manifestVersion:"2026-08-15.v1",
        recoveryProofSha256:$admissionDatabaseProofSha256,
        stableProofSha256:$admissionStableProofSha256,
        publicProjectionSha256:$admissionPublicProofSha256,routes:$admissionRoutes}
      end),
    runtime:{
      containerHealthy:$containerHealthy,topologyVerified:$topologyVerified,
      hardeningVerified:$hardeningVerified,volumesVerified:$volumesVerified,
      volumes:$volumes,postgresVolumes:$postgresVolumes,
      ports:$ports,networks:$networks,
      postgresWritablePrimary:$postgresWritablePrimary,
      nonIdleApplicationTransactions:$nonIdle,
      smtpIdleSamples:$smtpSamples
    },
    database:{tables:$database,totalRows:$totalRows},
    http:{
      meetingsStatus:$meetingsStatus,meetingsJson:$meetingsJson,meetingsCount:$meetingsCount,
      actuatorStatus:$actuatorStatus,httpRedirectHttps:$httpRedirectHttps,
      adminMissingStatus:$missingAdmin,adminWrongStatus:$wrongAdmin,
      adminKeyConfigured:$adminKeyConfigured,
      adminAuthenticatedDisabled404:$adminAuthenticatedDisabled404,
      adminBlankDisabled403:$adminBlankDisabled403,
      assetsCount:$assetsCount,assetsVerified:$assetsVerified
    },
    zeroStateObserved:true,zeroState:$zeroState
  }
' >"$temporary" || fail "zero-state evidence construction failed"
chmod 600 "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || fail "zero-state evidence publication failed"

if [ "$zero_state" != closed ]; then
  if [ "$state_mode" = empty-closed ]; then
    fail "empty-closed admission observed populated or unsafe state"
  fi
  fail "closed-beta-demo admission did not prove the canonical populated state"
fi
