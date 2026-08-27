#!/usr/bin/env bash
set -euo pipefail
usage(){ echo "usage: $0 --artifact-dir PATH --recovery-id ID --output-dir PATH --identity PATH [--image IMAGE]" >&2; exit 2; }
fail(){ echo "beta recovery restore failed: $*" >&2; exit 1; }
regular(){ [ -f "$1" ] && [ ! -L "$1" ]; }; image=${POSTGRES_IMAGE:-postgres:16-alpine@sha256:4327b9fd295502f326f44153a1045a7170ddbfffed1c3829798328556cfd09e2}
artifact='' id='' output='' identity='' temp=${RUNNER_TEMP:-/tmp}/beta-recovery docker_root=/var/lib/docker sql='' media='' expected_db='' expected_media=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact-dir) artifact=$2; shift 2;; --recovery-id) id=$2; shift 2;;
    --output-dir) output=$2; shift 2;; --identity) identity=$2; shift 2;;
    --image) image=$2; shift 2;; --temp-root) temp=$2; shift 2;;
    --docker-root) docker_root=$2; shift 2;; --sql-proof) sql=$2; shift 2;;
    --media-script) media=$2; shift 2;; --database-proof) expected_db=$2; shift 2;;
    --media-proof) expected_media=$2; shift 2;; *) usage;;
  esac
done
[[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || usage
[ -d "$artifact" ] && [ -d "$output" ] && [ ! -L "$artifact" ] || usage
for tool in age docker df find jq sha256sum tar; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
for file in postgres.dump.age uploads.tar.gz.age recovery-point.json; do regular "$artifact/$file" || fail "artifact file missing"; done
[ "$(find "$artifact" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" = 3 ] || fail "artifact shape is not exact"
jq -e --arg id "$id" '.recoveryId == $id and .retentionDays == 30' "$artifact/recovery-point.json" >/dev/null || fail "manifest mismatch"
checked_add(){
  local left=$1 right=$2 carry=0 result='' ld='' rd='' digit=''
  [[ "$left" =~ ^[0-9]+$ && "$right" =~ ^[0-9]+$ ]] || return 1
  while [ -n "$left" ] || [ -n "$right" ] || [ "$carry" -gt 0 ]; do
    ld=0; rd=0
    [ -z "$left" ] || ld=${left: -1}
    [ -z "$right" ] || rd=${right: -1}
    digit=$((10#$ld + 10#$rd + carry))
    result=$((digit % 10))${result:-}
    carry=$((digit / 10))
    [ -z "$left" ] || left=${left:0:${#left}-1}
    [ -z "$right" ] || right=${right:0:${#right}-1}
  done
  result=$(printf '%s\n' "$result" | sed 's/^0*//')
  printf '%s\n' "${result:-0}"
}
checked_double(){ checked_add "$1" "$1"; }
pair=$(checked_add "$(wc -c <"$artifact/postgres.dump.age" | tr -d '[:space:]')" \
  "$(wc -c <"$artifact/uploads.tar.gz.age" | tr -d '[:space:]')") || fail "pair size overflow"
db=$(jq -er '.source.postgresDatabaseBytes' "$artifact/recovery-point.json")
uploads=$(jq -er '.source.uploads.bytes' "$artifact/recovery-point.json")
[[ "$pair" =~ ^[0-9]+$ && "$db" =~ ^[0-9]+$ && "$uploads" =~ ^[0-9]+$ ]] || fail "sizes malformed"
temp_required=$(checked_add "$(checked_add "$(checked_double "$pair")" "$db")" \
  "$(checked_add "$uploads" 2147483648)") || fail "temporary capacity arithmetic overflow"
docker_required=$(checked_add "$(checked_double "$(checked_double "$db")")" 5368709120) ||
  fail "Docker capacity arithmetic overflow"
temp_free=$(df -Pk "$temp" | awk 'NR==2 {print $4*1024}')
docker_free=$(df -Pk "$docker_root" | awk 'NR==2 {print $4*1024}')
[[ "$temp_free" =~ ^[0-9]+$ && "$docker_free" =~ ^[0-9]+$ ]] || fail "capacity unknown"
[ "$temp_free" -ge "$temp_required" ] && [ "$docker_free" -ge "$docker_required" ] || fail "capacity gate failed"
[ $((temp_free * 5)) -ge $((temp_required * 6)) ] && [ $((docker_free * 5)) -ge $((docker_required * 6)) ] || fail "20 percent capacity margin failed"
regular "$identity" || fail "age identity unavailable"
mkdir -p "$temp" "$output"; chmod 700 "$temp"
private=$temp/private-$id; mkdir "$private"; chmod 700 "$private"
db_dump=$private/postgres.dump; uploads_archive=$private/uploads.tar.gz
network=beta-recovery-$id; container=beta-recovery-postgres-$id; volume=
cleanup(){
  status=$?; trap - EXIT HUP INT TERM
  rm -f -- "$identity" "$db_dump" "$uploads_archive" "$private/reference-list" 2>/dev/null || true
  docker container rm --force --volumes "$container" >/dev/null 2>&1 || true
  [ -z "$volume" ] || docker volume rm "$volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  [ "$status" -ne 0 ] || { docker container inspect "$container" >/dev/null 2>&1 && status=1 || true; }
  [ "$status" -ne 0 ] || { docker network inspect "$network" >/dev/null 2>&1 && status=1 || true; }
  [ "$status" -ne 0 ] || { [ -z "$volume" ] || docker volume inspect "$volume" >/dev/null 2>&1 && status=1 || true; }
  [ "$status" -ne 0 ] || rm -r -- "$private" "$temp"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
age -d -i "$identity" -o "$db_dump" "$artifact/postgres.dump.age"
age -d -i "$identity" -o "$uploads_archive" "$artifact/uploads.tar.gz.age"
docker image inspect "$image" --format '{{json .Config.Volumes}}' | jq -e 'type=="object" and (keys|sort)==["/var/lib/postgresql/data"]' >/dev/null || fail "image volume declaration differs"
docker network create --internal "$network" >/dev/null
restore_password=$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')
docker create --name "$container" --network "$network" -e POSTGRES_DB=restore_db \
  -e POSTGRES_USER=restore_user -e "POSTGRES_PASSWORD=$restore_password" "$image" >/dev/null
mounts=$(docker inspect "$container" --format '{{json .Mounts}}')
jq -e 'type=="array" and length==1 and .[0].Type=="volume" and .[0].Destination=="/var/lib/postgresql/data" and .[0].RW==true and (.[0].Name|length>0)' <<<"$mounts" >/dev/null || fail "anonymous mount contract failed"
volume=$(jq -er '.[0].Name' <<<"$mounts"); printf '%s\n' "$volume" >"$temp/volume.identity"; chmod 600 "$temp/volume.identity"
docker start "$container" >/dev/null
for _ in $(seq 1 60); do docker exec "$container" pg_isready -U restore_user -d restore_db >/dev/null 2>&1 && break; sleep 1; done
docker exec "$container" pg_isready -U restore_user -d restore_db >/dev/null 2>&1 || fail "postgres did not become ready"
docker cp "$db_dump" "$container:/tmp/postgres.dump"
docker exec "$container" pg_restore --list /tmp/postgres.dump >/dev/null || fail "archive listing failed"
docker exec "$container" pg_restore --no-owner --no-privileges --exit-on-error -d restore_db /tmp/postgres.dump >/dev/null || fail "restore failed"
if [ -n "$sql" ] && [ -n "$expected_db" ]; then
  docker cp "$sql" "$container:/tmp/proof.sql"
  docker exec "$container" psql -X -qAt -U restore_user -d restore_db -f /tmp/proof.sql >"$output/restored-database-proof.json"
  cmp -- "$expected_db" "$output/restored-database-proof.json" || fail "database proof differs"
fi
mkdir "$private/uploads"; tar --extract --gzip --file "$uploads_archive" --directory "$private/uploads"
if [ -n "$media" ] && [ -n "$expected_media" ]; then "$media" --root "$private/uploads" --output "$output/restored-media-proof.json"; cmp -- "$expected_media" "$output/restored-media-proof.json" || fail "media proof differs"; fi
printf 'cleanup_complete=true\n' >"$output/restore-summary"
