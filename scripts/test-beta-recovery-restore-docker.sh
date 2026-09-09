#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runtime=$root/scripts/run-beta-recovery-restore.sh
fixture=$root/scripts/fixtures/beta-recovery/real-docker-volume-provenance.json
image='postgres:16-alpine@sha256:4327b9fd295502f326f44153a1045a7170ddbfffed1c3829798328556cfd09e2'
command -v docker >/dev/null 2>&1
command -v jq >/dev/null 2>&1
command -v bash >/dev/null 2>&1
command -v stat >/dev/null 2>&1
[ -f "$fixture" ] && [ -x "$runtime" ]
jq -e --arg image "$image" '
  .schema=="meet-backend/beta-recovery-real-docker-volume-provenance/v1" and
  .image==$image and (.volumeIdentity|test("^[0-9a-f]{64}$")) and
  .baseline.accepted==false and .baseline.failedClauses==["labels"] and
  .absence.status==1 and .absence.stdout=="[]\n" and
  .absence.stderr=="Error response from daemon: get <volume>: no such volume\n"
' "$fixture" >/dev/null

suffix="$(date +%s)-$$-${RANDOM}"
recovery_id="evidence-${suffix}"
network="beta-recovery-${recovery_id}"
container="beta-recovery-postgres-${recovery_id}"
owner_token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
work=$(mktemp -d "${TMPDIR:-/tmp}/beta-recovery-docker.XXXXXX")
ownership_marker=$work/restore-ownership.json
volume_marker=$work/volume.identity
volume=''
docker_root=''
container_created=false
network_created=false
collision_container_created=false
collision_network_created=false
collision_container=''
collision_network=''
collision_recovery_id=''
collision_token=''
collision_volume=''
postgres_password=''

write_ownership_marker(){
  local container_attempted=$1 container_was_created=$2
  local network_attempted=$3 network_was_created=$4 tmp
  tmp=$ownership_marker.tmp
  jq -cnS --arg id "$recovery_id" --arg token "$owner_token" \
    --arg container "$container" --arg network "$network" \
    --argjson container_attempted "$container_attempted" \
    --argjson container_created "$container_was_created" \
    --argjson network_attempted "$network_attempted" \
    --argjson network_created "$network_was_created" '
    {schema:"meet-backend/beta-recovery-ownership/v1",recoveryId:$id,
     ownerToken:$token,containerName:$container,networkName:$network,
     containerAttempted:$container_attempted,containerCreated:$container_created,
     networkAttempted:$network_attempted,networkCreated:$network_created}
  ' >"$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$ownership_marker"
}

assert_absent_before_create(){
  local kind=$1 name=$2 status
  if docker "$kind" inspect "$name" >/dev/null 2>&1; then
    echo "real-Docker resource collision: $kind $name" >&2
    return 1
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || {
    echo "real-Docker collision preflight could not inspect $kind $name" >&2
    return 1
  }
}

cleanup_collision_resources(){
  local cleanup_status=0 inspect_status collision_container_authenticated=false
  [ -n "$collision_container" ] && [ -n "$collision_network" ] || return 0
  if [ "$collision_container_created" = true ]; then
    if docker container inspect "$collision_container" >"$work/collision.cleanup.container.json" 2>"$work/collision.cleanup.container.stderr"; then
      if jq -e --arg id "$collision_recovery_id" --arg token "$collision_token" '
        .[0].Config.Labels["com.meet-backend.beta-recovery/owner"]=="collision-fixture" and
        .[0].Config.Labels["com.meet-backend.beta-recovery/recovery-id"]==$id and
        .[0].Config.Labels["com.meet-backend.beta-recovery/owner-token"]==$token
      ' "$work/collision.cleanup.container.json" >/dev/null; then
        collision_container_authenticated=true
        docker container rm --force --volumes "$collision_container" >/dev/null ||
          cleanup_status=1
      else
        cleanup_status=1
      fi
    else
      inspect_status=$?
      if [ "$inspect_status" -eq 1 ]; then
        collision_container_created=false
      else
        cleanup_status=1
      fi
    fi
  fi
  if [ "$collision_container_authenticated" = true ] && [ -n "$collision_volume" ]; then
    if docker volume inspect "$collision_volume" >"$work/collision.cleanup.volume.json" 2>"$work/collision.cleanup.volume.stderr"; then
      docker volume rm "$collision_volume" >/dev/null || cleanup_status=1
    else
      inspect_status=$?
      [ "$inspect_status" -eq 1 ] || cleanup_status=1
    fi
  fi
  if [ "$collision_network_created" = true ]; then
    if docker network inspect "$collision_network" >"$work/collision.cleanup.network.json" 2>"$work/collision.cleanup.network.stderr"; then
      if jq -e --arg id "$collision_recovery_id" --arg token "$collision_token" '
        .[0].Labels["com.meet-backend.beta-recovery/owner"]=="collision-fixture" and
        .[0].Labels["com.meet-backend.beta-recovery/recovery-id"]==$id and
        .[0].Labels["com.meet-backend.beta-recovery/owner-token"]==$token
      ' "$work/collision.cleanup.network.json" >/dev/null; then
        docker network rm "$collision_network" >/dev/null || cleanup_status=1
      else
        cleanup_status=1
      fi
    else
      inspect_status=$?
      if [ "$inspect_status" -eq 1 ]; then
        collision_network_created=false
      else
        cleanup_status=1
      fi
    fi
  fi
  if docker container inspect "$collision_container" >"$work/collision.residue.container.json" 2>/dev/null; then
    cleanup_status=1
  else
    inspect_status=$?
    [ "$inspect_status" -eq 1 ] || cleanup_status=1
  fi
  if docker network inspect "$collision_network" >"$work/collision.residue.network.json" 2>/dev/null; then
    cleanup_status=1
  else
    inspect_status=$?
    [ "$inspect_status" -eq 1 ] || cleanup_status=1
  fi
  if [ -n "$collision_volume" ]; then
    if docker volume inspect "$collision_volume" >"$work/collision.residue.volume.json" 2>/dev/null; then
      cleanup_status=1
    else
      inspect_status=$?
      [ "$inspect_status" -eq 1 ] || cleanup_status=1
    fi
  fi
  [ "$cleanup_status" -eq 0 ]
}

cleanup(){
  local status=$? cleanup_status=0
  trap - EXIT HUP INT TERM
  if [ "$container_created" = true ] || [ "$network_created" = true ] ||
    [ -f "$ownership_marker" ]; then
    [ -f "$ownership_marker" ] || cleanup_status=1
    if bash "$runtime" --cleanup-survivors \
      --container "$container" --network "$network" --volume "$volume" \
      --volume-identity "$volume_marker" --ownership-marker "$ownership_marker" \
      --owner-token "$owner_token" --recovery-id "$recovery_id" \
      --docker-root "$docker_root" >"$work/cleanup.stdout" 2>"$work/cleanup.stderr"; then
      container_created=false
      network_created=false
    else
      cleanup_status=1
    fi
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    echo "authenticated real-Docker cleanup failed" >&2
  fi
  cleanup_collision_resources || cleanup_status=1
  rm -r -- "$work" >/dev/null 2>&1 || cleanup_status=1
  [ "$status" -eq 0 ] || cleanup_status=1
  exit "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

docker pull --quiet "$image" >/dev/null
docker image inspect "$image" --format '{{json .RepoDigests}}' |
  jq -e --arg digest "${image##*@}" 'any(.[]; endswith($digest))' >/dev/null
docker image inspect "$image" --format '{{json .Config.Volumes}}' |
  jq -e 'type=="object" and (keys|sort)==["/var/lib/postgresql/data"]' >/dev/null
docker_root=$(docker info --format '{{.DockerRootDir}}')
[ "$docker_root" = /var/lib/docker ] || {
  echo "unexpected Docker root representation" >&2
  exit 1
}

assert_absent_before_create network "$network"
assert_absent_before_create container "$container"
write_ownership_marker false false false false
docker network create --internal \
  --label com.meet-backend.beta-recovery/owner=restore \
  --label com.meet-backend.beta-recovery/recovery-id="$recovery_id" \
  --label com.meet-backend.beta-recovery/owner-token="$owner_token" \
  "$network" >/dev/null
network_created=true
write_ownership_marker false false true true
postgres_password=$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')
docker create --name "$container" --network "$network" \
  --label com.meet-backend.beta-recovery/owner=restore \
  --label com.meet-backend.beta-recovery/recovery-id="$recovery_id" \
  --label com.meet-backend.beta-recovery/owner-token="$owner_token" \
  -e POSTGRES_DB=restore_db -e POSTGRES_USER=restore_user \
  -e POSTGRES_PASSWORD="$postgres_password" \
  "$image" >/dev/null
container_created=true
write_ownership_marker true true true true

docker container inspect "$container" >"$work/container.raw.json"
volume=$(jq -er '.[0].Mounts | map(select(.Type=="volume" and .Destination=="/var/lib/postgresql/data")) |
  if length==1 and (.[0].Name|test("^[0-9a-f]{64}$")) then .[0].Name else error end' \
  "$work/container.raw.json")
docker volume inspect "$volume" >"$work/volume.raw.json"
fixture_volume=$(jq -er '.volumeIdentity' "$fixture")
sanitized_container="$work/container.json"
sanitized_volume="$work/volume.json"
jq -cS --arg volume "$fixture_volume" '
  .[0] as $c |
  [{
    HostConfig:{
      Binds:$c.HostConfig.Binds,
      Mounts:(if $c.HostConfig.Mounts == null then null else
        $c.HostConfig.Mounts | map({
          Type,Name:$volume,Destination,RW,
          Source:("/var/lib/docker/volumes/"+$volume+"/_data"),Driver
        }) end)
    },
    Mounts:($c.Mounts | map({
      Type,Name:$volume,Destination,RW,
      Source:("/var/lib/docker/volumes/"+$volume+"/_data")
    }))
  }]
' "$work/container.raw.json" >"$sanitized_container"
jq -cS --arg volume "$fixture_volume" '
  .[0] | [{
    Name:$volume,Driver,Mountpoint:("/var/lib/docker/volumes/"+$volume+"/_data"),
    Labels,Options
  }]
' "$work/volume.raw.json" >"$sanitized_volume"
jq -e --arg volume "$fixture_volume" '
  .dockerRootDir=="/var/lib/docker" and .volumeIdentity==$volume and
  .volume == $volume_data[0] and .container == $container_data[0]
' --slurpfile volume_data "$sanitized_volume" --slurpfile container_data "$sanitized_container" \
  "$fixture" >/dev/null || {
  echo "sanitized real-Docker metadata differs from the reviewed fixture" >&2
  exit 1
}

current_report=$(bash "$runtime" --evaluate-provenance \
  --container-inspect "$sanitized_container" --volume-inspect "$sanitized_volume" \
  --volume-identity "$fixture_volume" --docker-root /var/lib/docker)
jq -e '.accepted==true and .failedClauses==[]' <<<"$current_report" >/dev/null
baseline_report=$(bash "$runtime" --evaluate-provenance --baseline \
  --container-inspect "$sanitized_container" --volume-inspect "$sanitized_volume" \
  --volume-identity "$fixture_volume" --docker-root /var/lib/docker)
jq -e '.accepted==false and .failedClauses==["labels"]' <<<"$baseline_report" >/dev/null

printf '%s\n' "$volume" >"$volume_marker.tmp"
chmod 600 "$volume_marker.tmp"
mv -f -- "$volume_marker.tmp" "$volume_marker"
[ "$(stat -c '%a' "$ownership_marker")" = 600 ]
[ "$(stat -c '%a' "$volume_marker")" = 600 ]
jq -e --arg id "$recovery_id" --arg token "$owner_token" \
  --arg container "$container" --arg network "$network" '
  .schema=="meet-backend/beta-recovery-ownership/v1" and
  .recoveryId==$id and .ownerToken==$token and .containerName==$container and
  .networkName==$network and .containerAttempted==true and .containerCreated==true and
  .networkAttempted==true and .networkCreated==true
' "$ownership_marker" >/dev/null

docker start "$container" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$container" pg_isready -U restore_user -d restore_db >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$container" pg_isready -U restore_user -d restore_db >/dev/null 2>&1
docker exec "$container" psql -X -qAt -U restore_user -d restore_db -v ON_ERROR_STOP=1 -c \
  "SELECT jsonb_build_object(
     'rows', jsonb_build_object('users', 1),
     'schema', 'meet-backend/closed-beta-database-proof/v1'
   )::jsonb;" >"$work/postgres-jsonb.raw"
jq -cnS '{schema:"meet-backend/closed-beta-database-proof/v1",rows:{users:1}}' \
  >"$work/postgres-jsonb.expected"
if cmp -- "$work/postgres-jsonb.raw" "$work/postgres-jsonb.expected"; then
  echo "PostgreSQL JSONB text unexpectedly matched canonical bytes" >&2
  exit 1
fi
jq -e -cS -s '
  if length == 1 and
     (.[0] | type) == "object" and
     (.[0].schema | type) == "string" and
     .[0].schema == "meet-backend/closed-beta-database-proof/v1"
  then .[0]
  else error("database proof must be one valid object")
  end
' "$work/postgres-jsonb.raw" >"$work/postgres-jsonb.canonical"
cmp -- "$work/postgres-jsonb.expected" "$work/postgres-jsonb.canonical"
docker exec "$container" psql -X -qAt -U restore_user -d restore_db -v ON_ERROR_STOP=1 -c \
  'CREATE TABLE restore_role_probe (id integer PRIMARY KEY, payload text NOT NULL);
   INSERT INTO restore_role_probe (id, payload) VALUES (1, '\''restore-role-proof'\'');'
MSYS_NO_PATHCONV=1 docker exec "$container" pg_dump -U restore_user -d restore_db \
  --format=custom --schema=public --table=public.restore_role_probe \
  --file=/tmp/restore-role.dump
docker exec "$container" psql -X -qAt -U restore_user -d restore_db -v ON_ERROR_STOP=1 -c \
  'DROP TABLE restore_role_probe;'
MSYS_NO_PATHCONV=1 docker exec "$container" pg_restore --list /tmp/restore-role.dump \
  >"$work/restore-role.list"
grep -Fq restore_role_probe "$work/restore-role.list"

set +e
MSYS_NO_PATHCONV=1 docker exec "$container" pg_restore --no-owner --no-privileges --exit-on-error \
  -d restore_db /tmp/restore-role.dump >"$work/root-restore.stdout" \
  2>"$work/root-restore.stderr"
root_restore_status=$?
set -e
[ "$root_restore_status" -ne 0 ]
grep -Fq 'role "root" does not exist' "$work/root-restore.stderr"

MSYS_NO_PATHCONV=1 docker exec "$container" pg_restore --no-owner --no-privileges --exit-on-error \
  -U restore_user -d restore_db /tmp/restore-role.dump \
  >"$work/restore-user.stdout" 2>"$work/restore-user.stderr"
docker exec "$container" psql -X -qAt -U restore_user -d restore_db -v ON_ERROR_STOP=1 -c \
  'SELECT payload FROM restore_role_probe WHERE id=1;' >"$work/restored-row"
grep -Fxq restore-role-proof "$work/restored-row"

docker container inspect "$container" >"$work/container.before-cleanup.json"
docker network inspect "$network" >"$work/network.before-cleanup.json"
docker volume inspect "$volume" >"$work/volume.before-cleanup.json"
bash "$runtime" --cleanup-survivors \
  --container "$container" --network "$network" --volume "$volume" \
  --volume-identity "$volume_marker" --ownership-marker "$ownership_marker" \
  --owner-token "$owner_token" --recovery-id "$recovery_id" \
  --docker-root "$docker_root"
container_created=false
network_created=false
[ ! -e "$ownership_marker" ] && [ ! -e "$volume_marker" ]

if docker volume inspect "$volume" >"$work/absence.stdout" 2>"$work/absence.stderr"; then
  status=0
else
  status=$?
fi
jq -n --arg stdout "$( <"$work/absence.stdout")" --arg stderr "$( <"$work/absence.stderr")" \
  --arg actual "$volume" --argjson status "$status" '
  {status:$status,stdout:($stdout+"\n"),
   stderr:(($stderr|gsub($actual;"<volume>"))+"\n")}
' >"$work/absence.json"
jq -e --slurpfile expected "$fixture" '. == $expected[0].absence' \
  "$work/absence.json" >/dev/null

for kind in container network volume; do
  case "$kind" in
    container) name=$container ;;
    network) name=$network ;;
    volume) name=$volume ;;
  esac
  if docker "$kind" inspect "$name" >"$work/$kind.stdout" 2>"$work/$kind.stderr"; then
    echo "$kind residue remains after authenticated cleanup" >&2
    exit 1
  fi
done

collision_suffix="${suffix}-collision"
collision_network="beta-recovery-collision-${collision_suffix}"
collision_container="beta-recovery-postgres-collision-${collision_suffix}"
collision_recovery_id="collision-${collision_suffix}"
collision_token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
docker network create --internal \
  --label com.meet-backend.beta-recovery/owner=collision-fixture \
  --label com.meet-backend.beta-recovery/recovery-id="$collision_recovery_id" \
  --label com.meet-backend.beta-recovery/owner-token="$collision_token" \
  "$collision_network" >/dev/null
collision_network_created=true
if [ "${BETA_RECOVERY_INJECT_COLLISION_FAILURE:-0}" = 1 ]; then
  echo "injected collision container creation failure" >&2
  exit 42
fi
docker create --name "$collision_container" --network "$collision_network" \
  --label com.meet-backend.beta-recovery/owner=collision-fixture \
  --label com.meet-backend.beta-recovery/recovery-id="$collision_recovery_id" \
  --label com.meet-backend.beta-recovery/owner-token="$collision_token" \
  "$image" >/dev/null
collision_container_created=true
collision_volume=$(docker container inspect "$collision_container" |
  jq -er '.[0].Mounts | map(select(.Type=="volume")) | if length==1 then .[0].Name else error end')
docker container inspect "$collision_container" >"$work/collision.container.before.json"
docker network inspect "$collision_network" >"$work/collision.network.before.json"
docker volume inspect "$collision_volume" >"$work/collision.volume.before.json"
if assert_absent_before_create container "$collision_container"; then
  echo "container collision preflight unexpectedly accepted an existing resource" >&2
  exit 1
fi
if assert_absent_before_create network "$collision_network"; then
  echo "network collision preflight unexpectedly accepted an existing resource" >&2
  exit 1
fi
docker container inspect "$collision_container" >"$work/collision.container.after.json"
docker network inspect "$collision_network" >"$work/collision.network.after.json"
docker volume inspect "$collision_volume" >"$work/collision.volume.after.json"
cmp -- "$work/collision.container.before.json" "$work/collision.container.after.json"
cmp -- "$work/collision.network.before.json" "$work/collision.network.after.json"
cmp -- "$work/collision.volume.before.json" "$work/collision.volume.after.json"
if [ "$collision_container_created" = true ]; then
  docker container inspect "$collision_container" |
    jq -e --arg id "$collision_recovery_id" --arg token "$collision_token" '
    .[0].Config.Labels["com.meet-backend.beta-recovery/owner"]=="collision-fixture" and
    .[0].Config.Labels["com.meet-backend.beta-recovery/recovery-id"]==$id and
    .[0].Config.Labels["com.meet-backend.beta-recovery/owner-token"]==$token
  ' >/dev/null
  docker container rm --force --volumes "$collision_container" >/dev/null
  collision_container_created=false
fi
if [ "$collision_network_created" = true ]; then
  docker network inspect "$collision_network" |
    jq -e --arg id "$collision_recovery_id" --arg token "$collision_token" '
    .[0].Labels["com.meet-backend.beta-recovery/owner"]=="collision-fixture" and
    .[0].Labels["com.meet-backend.beta-recovery/recovery-id"]==$id and
    .[0].Labels["com.meet-backend.beta-recovery/owner-token"]==$token
  ' >/dev/null
  docker network rm "$collision_network" >/dev/null
  collision_network_created=false
fi
for kind in container network volume; do
  case "$kind" in
    container) name=$collision_container ;;
    network) name=$collision_network ;;
    volume) name=$collision_volume ;;
  esac
  if docker "$kind" inspect "$name" >/dev/null 2>&1; then
    echo "collision fixture residue remains: $kind" >&2
    exit 1
  fi
done

echo "real Docker beta recovery volume provenance and authenticated cleanup passed"
