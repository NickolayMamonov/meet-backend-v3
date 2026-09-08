#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runtime=$root/scripts/run-beta-recovery-restore.sh
fixture=$root/scripts/fixtures/beta-recovery/real-docker-volume-provenance.json
image='postgres:16-alpine@sha256:4327b9fd295502f326f44153a1045a7170ddbfffed1c3829798328556cfd09e2'
command -v docker >/dev/null 2>&1
command -v jq >/dev/null 2>&1
command -v bash >/dev/null 2>&1
[ -f "$fixture" ] && [ -x "$runtime" ]
jq -e --arg image "$image" '
  .schema=="meet-backend/beta-recovery-real-docker-volume-provenance/v1" and
  .image==$image and (.volumeIdentity|test("^[0-9a-f]{64}$")) and
  .baseline.accepted==false and .baseline.failedClauses==["labels"] and
  .absence.status==1 and .absence.stdout=="[]\n" and
  .absence.stderr=="Error response from daemon: get <volume>: no such volume\n"
' "$fixture" >/dev/null

suffix="$(date +%s)-$$-${RANDOM}"
network="beta-recovery-evidence-${suffix}"
container="beta-recovery-postgres-evidence-${suffix}"
work=$(mktemp -d "${TMPDIR:-/tmp}/beta-recovery-docker.XXXXXX")
volume=''
cleanup(){
  docker container rm --force --volumes "$container" >/dev/null 2>&1 || :
  docker network rm "$network" >/dev/null 2>&1 || :
  rm -r -- "$work" >/dev/null 2>&1 || :
}
trap cleanup EXIT HUP INT TERM

docker pull --quiet "$image" >/dev/null
docker image inspect "$image" --format '{{json .RepoDigests}}' |
  jq -e --arg digest "${image##*@}" 'any(.[]; endswith($digest))' >/dev/null
docker image inspect "$image" --format '{{json .Config.Volumes}}' |
  jq -e 'type=="object" and (keys|sort)==["/var/lib/postgresql/data"]' >/dev/null
docker network create --internal "$network" >/dev/null
docker create --name "$container" --network "$network" \
  --label com.meet-backend.beta-recovery/owner=restore \
  --label com.meet-backend.beta-recovery/recovery-id=evidence-fixture \
  --label com.meet-backend.beta-recovery/owner-token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$image" >/dev/null

docker_root=$(docker info --format '{{.DockerRootDir}}')
[ "$docker_root" = /var/lib/docker ] || {
  echo "unexpected Docker root representation" >&2
  exit 1
}
docker container inspect "$container" >"$work/container.raw.json"
volume=$(jq -er '.[0].Mounts | map(select(.Type=="volume" and .Destination=="/var/lib/postgresql/data")) |
  if length==1 and (.[0].Name|test("^[0-9a-f]{64}$")) then .[0].Name else error end' "$work/container.raw.json")
docker volume inspect "$volume" >"$work/volume.raw.json"
fixture_volume=$(jq -er '.volumeIdentity' "$fixture")
sanitized_container="$work/container.json"
sanitized_volume="$work/volume.json"
jq -cS --arg volume "$fixture_volume" '
  .[0] | {
    HostConfig:{
      Binds:.HostConfig.Binds,
      Mounts:(if .HostConfig.Mounts == null then null else .HostConfig.Mounts | map({
        Type,Name:$volume,Destination,RW,Source:("/var/lib/docker/volumes/"+$volume+"/_data"),Driver
      }) end)
    },
    Mounts:(.Mounts | map({
      Type,Name:$volume,Destination,RW,Source:("/var/lib/docker/volumes/"+$volume+"/_data")
    }))
  }
' "$work/container.raw.json" >"$sanitized_container"
 jq -cS --arg volume "$fixture_volume" '
  .[0] | {
    Name:$volume,Driver,Mountpoint:("/var/lib/docker/volumes/"+$volume+"/_data"),Labels,Options
  }
' "$work/volume.raw.json" >"$sanitized_volume"
jq -e --arg volume "$fixture_volume" '
  .dockerRootDir=="/var/lib/docker" and .volumeIdentity==$volume and
  .volume == $volume_data[0] and .container == $container_data[0]
' --slurpfile volume_data "$sanitized_volume" --slurpfile container_data "$sanitized_container" \
  "$fixture" >/dev/null || {
  echo "sanitized real-Docker metadata differs from the reviewed fixture" >&2
  jq -cS '{fixture_volume:.volume,fixture_container:.container}' "$fixture" >&2
  jq -cS '{live_volume:$volume_data[0],live_container:$container_data[0]}' \
    --slurpfile volume_data "$sanitized_volume" --slurpfile container_data "$sanitized_container" \
    "$fixture" >&2
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

docker container rm --force --volumes "$container" >/dev/null
docker network rm "$network" >/dev/null
if docker volume inspect "$volume" >"$work/absence.stdout" 2>"$work/absence.stderr"; then
  status=0
else
  status=$?
fi
jq -n --arg stdout "$( <"$work/absence.stdout")" --arg stderr "$( <"$work/absence.stderr")" \
  --arg actual "$volume" --argjson status "$status" '
  {status:$status,stdout:($stdout+"\n"),stderr:(($stderr|gsub($actual;"<volume>"))+"\n")}
' >"$work/absence.json"
jq -e --slurpfile expected "$fixture" '
  . == $expected[0].absence
' "$work/absence.json" >/dev/null || {
  echo "post-removal volume absence tuple differs from the reviewed fixture" >&2
  jq -cS --arg actual "$volume" '. | .stderr |= gsub($actual;"<volume>")' \
    "$work/absence.json" >&2
  exit 1
}
for kind in container network volume; do
  case "$kind" in
    container) name=$container ;;
    network) name=$network ;;
    volume) name=$volume ;;
  esac
  if docker "$kind" inspect "$name" >"$work/$kind.stdout" 2>"$work/$kind.stderr"; then
    echo "$kind residue remains after cleanup" >&2
    exit 1
  fi
done
echo "real Docker beta recovery volume provenance and cleanup passed"
