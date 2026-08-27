#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage(){ echo "usage: $0 --artifact-dir PATH --recovery-id ID --output-dir PATH [--identity PATH] --sql-proof PATH --media-script PATH [--database-proof PATH --media-proof PATH] --source-sha SHA --repository OWNER/REPO --tooling-digest SHA --workflow-digest SHA --database-digest SHA --media-digest SHA [--image IMAGE]" >&2; exit 2; }
fail(){ echo "beta recovery restore failed: $*" >&2; exit 1; }
regular(){ [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }
identity=''
preflight_cleanup(){
  local status=$?
  trap - EXIT HUP INT TERM
  [ -z "$identity" ] || rm -f -- "$identity" || status=1
  exit "$status"
}
trap preflight_cleanup EXIT HUP INT TERM
decimal(){ [[ "$1" =~ ^[0-9]+$ ]]; }
normalize(){ local v=$1; v=$(printf '%s\n' "$v" | sed 's/^0*//'); printf '%s\n' "${v:-0}"; }
decimal_ge(){
  local a b
  decimal "$1" && decimal "$2" || return 1
  a=$(normalize "$1"); b=$(normalize "$2")
  [ "${#a}" -gt "${#b}" ] || { [ "${#a}" -eq "${#b}" ] && [[ "$a" > "$b" || "$a" = "$b" ]]; }
}
add(){
  local a b c=0 r='' x y d; decimal "$1" && decimal "$2" || return 1
  a=$(normalize "$1"); b=$(normalize "$2")
  while [ -n "$a" ] || [ -n "$b" ] || [ "$c" -gt 0 ]; do
    x=0; y=0; [ -z "$a" ] || x=${a: -1}; [ -z "$b" ] || y=${b: -1}
    d=$((10#$x + 10#$y + c)); r=$((d % 10))$r; c=$((d / 10))
    [ -z "$a" ] || a=${a:0:${#a}-1}; [ -z "$b" ] || b=${b:0:${#b}-1}
  done
  printf '%s\n' "${r:-0}"
}
mul_small(){
  local a c=0 r='' x d; decimal "$1" && [[ "$2" =~ ^[0-9]+$ ]] || return 1
  a=$(normalize "$1")
  while [ -n "$a" ] || [ "$c" -gt 0 ]; do
    x=0; [ -z "$a" ] || x=${a: -1}; d=$((10#$x * 10#$2 + c))
    r=$((d % 10))$r; c=$((d / 10)); [ -z "$a" ] || a=${a:0:${#a}-1}
  done
  printf '%s\n' "${r:-0}"
}
capacity_ok(){ decimal_ge "$1" "$2" && decimal_ge "$(mul_small "$1" 4)" "$(mul_small "$2" 5)"; }
inspect_resource(){
  local kind=$1 name=$2 response
  if response=$(docker "$kind" inspect "$name" 2>&1); then INSPECT_JSON=$response; return 0; fi
  case "$response" in *"No such"*|*"not found"*) return 1;; esac
  echo "Docker $kind inspection failed for $name: $response" >&2; return 2
}
volume_provenance(){
  local json=$1 volume=$2 root=$3 expected
  expected=${root%/}/volumes/$volume/_data
  jq -e --arg volume "$volume" --arg expected "$expected" '
    type=="array" and length==1 and .[0].Name==$volume and .[0].Driver=="local" and
    .[0].Mountpoint==$expected and
    ((.[0].Labels==null) or (.[0].Labels|type=="object" and length==0)) and
    ((.[0].Options==null) or (.[0].Options|type=="object" and length==0))
  ' <<<"$json" >/dev/null
}
container_mount_provenance(){
  local json=$1 volume=$2 root=$3 expected
  expected=${root%/}/volumes/$volume/_data
  jq -e --arg volume "$volume" --arg expected "$expected" '
    type=="array" and length==1 and
    ((.[0].HostConfig.Binds==null) or (.[0].HostConfig.Binds|type=="array" and length==0)) and
    ((.[0].HostConfig.Mounts==null) or (.[0].HostConfig.Mounts|type=="array" and length==0)) and
    (.[0].Mounts|type=="array" and length==1 and .[0].Type=="volume" and
      .[0].Name==$volume and .[0].Destination=="/var/lib/postgresql/data" and
      .[0].RW==true and .[0].Source==$expected)
  ' <<<"$json" >/dev/null
}
validate_upload_archive(){
  local archive=$1 work=$2 names="$2/names" details="$2/details" entry detail expected index
  tar --list --gzip --quoting-style=escape --file "$archive" >"$names" || fail "uploads archive listing failed"
  tar --list --verbose --gzip --quoting-style=escape --file "$archive" >"$details" || fail "uploads archive typed listing failed"
  mapfile -t entries <"$names"; mapfile -t typed <"$details"
  [ "${#entries[@]}" -gt 0 ] && [ "${#entries[@]}" -eq "${#typed[@]}" ] || fail "uploads archive listing is incomplete"
  declare -A seen=(); has_root=false; has_avatars=false; has_meetings=false; has_communities=false
  for index in "${!entries[@]}"; do
    entry=${entries[$index]}; detail=${typed[$index]}
    case "$entry" in
      *\\*|*$'\t'*|*$'\n'*|*$'\r'*|*/../*|*/..|*/./*|*//*)
        fail "uploads archive path contains unsafe components" ;;
      ./|.) expected=d; has_root=true ;;
      ./avatars|./avatars/) expected=d; has_avatars=true ;;
      ./meetings|./meetings/) expected=d; has_meetings=true ;;
      ./communities|./communities/) expected=d; has_communities=true ;;
      ./avatars/*|./meetings/*|./communities/*)
        if [[ "$entry" == */ ]]; then expected=d; else expected=-; fi ;;
      *) fail "uploads archive contains a path outside its approved root" ;;
    esac
    [ -z "${seen[$entry]+x}" ] || fail "uploads archive contains a duplicate path"
    seen["$entry"]=1
    [ "${detail:0:1}" = "$expected" ] || fail "uploads archive entry type differs from its approved path type"
  done
  [ "$has_root" = true ] && [ "$has_avatars" = true ] && [ "$has_meetings" = true ] && [ "$has_communities" = true ] ||
    fail "uploads archive is missing an approved root directory"
}
if [ "${1:-}" = --validate-uploads-archive ]; then
  shift; archive=''; work=''
  while [ "$#" -gt 0 ]; do case "$1" in --archive) archive=$2; shift 2;; --work-dir) work=$2; shift 2;; *) usage;; esac; done
  regular "$archive" || fail "uploads archive unavailable"; [ -d "$work" ] || usage
  command -v tar >/dev/null 2>&1 || fail "tar is required"; validate_upload_archive "$archive" "$work"; exit 0
fi
if [ "${1:-}" = --cleanup-survivors ]; then
  shift; c=''; n=''; v=''; marker=''; rid=''; root=''
  while [ "$#" -gt 0 ]; do case "$1" in
    --container) c=$2; shift 2;; --network) n=$2; shift 2;; --volume) v=$2; shift 2;;
    --volume-identity) marker=$2; shift 2;; --recovery-id) rid=$2; shift 2;;
    --docker-root) root=$2; shift 2;; *) usage;;
  esac; done
  [[ "$rid" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] && [ "$c" = "beta-recovery-postgres-$rid" ] &&
    [ "$n" = "beta-recovery-$rid" ] && [ -n "$root" ] || fail "cleanup ownership names are invalid"
  volumes=()
  if [ -n "$v" ]; then
    [[ "$v" =~ ^[0-9a-f]{64}$ ]] || fail "cleanup volume identity is invalid"
    regular "$marker" || fail "cleanup volume marker is unavailable"
  fi
  if regular "$marker"; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      [[ "$candidate" =~ ^[0-9a-f]{64}$ ]] || fail "cleanup volume marker is invalid"
      volumes+=("$candidate")
    done <"$marker"
  fi
  [ "${#volumes[@]}" -gt 0 ] || [ -z "$v" ] || fail "cleanup volume identity is missing"
  if [ -n "$v" ]; then
    printf '%s\n' "${volumes[@]}" | grep -Fxq "$v" || fail "cleanup volume identity differs"
  fi
  docker info >/dev/null 2>&1 || fail "cleanup cannot contact Docker"
  for attempt in 1 2 3; do
    if inspect_resource container "$c"; then
      jq -e --arg id "$rid" '.[0].Config.Labels["com.meet-backend.beta-recovery/owner"]=="restore" and .[0].Config.Labels["com.meet-backend.beta-recovery/recovery-id"]==$id' <<<"$INSPECT_JSON" >/dev/null || fail "unowned container survivor"
      if [ -n "$v" ]; then
        container_mount_provenance "$INSPECT_JSON" "$v" "$root" || fail "volume/container association is invalid"
        docker container rm --force --volumes "$c" ||
          fail "cleanup could not remove container $c"
      else
        docker container rm --force "$c" ||
          fail "cleanup could not remove container $c"
      fi
    else
      container_status=$?
      [ "$container_status" -eq 2 ] && fail "container inspection failed"
    fi
    for volume in "${volumes[@]}"; do
      if inspect_resource volume "$volume"; then
        volume_provenance "$INSPECT_JSON" "$volume" "$root" || fail "invalid volume survivor provenance"
        docker volume rm "$volume" || fail "cleanup could not remove volume $volume"
      else
        volume_status=$?
        [ "$volume_status" -eq 2 ] && fail "volume inspection failed"
      fi
    done
    if inspect_resource network "$n"; then
      jq -e --arg id "$rid" '.[0].Labels["com.meet-backend.beta-recovery/owner"]=="restore" and .[0].Labels["com.meet-backend.beta-recovery/recovery-id"]==$id' <<<"$INSPECT_JSON" >/dev/null || fail "unowned network survivor"
      docker network rm "$n" || fail "cleanup could not remove network $n"
    else
      network_status=$?
      [ "$network_status" -eq 2 ] && fail "network inspection failed"
    fi
    if inspect_resource container "$c"; then cs=0; else cs=$?; fi
    if inspect_resource network "$n"; then ns=0; else ns=$?; fi
    vs=1
    for volume in "${volumes[@]}"; do
      if inspect_resource volume "$volume"; then vs=0; else volume_status=$?; [ "$volume_status" -eq 2 ] && vs=2; fi
    done
    [ "$cs" -eq 2 ] || [ "$ns" -eq 2 ] || [ "$vs" -eq 2 ] && fail "cleanup inspection failed"
    if [ "$cs" -eq 1 ] && [ "$ns" -eq 1 ] && [ "$vs" -eq 1 ]; then
      exit 0
    fi
    [ "$attempt" -lt 3 ] && sleep 1
  done
  fail "cleanup survivors remain"
fi

image=${POSTGRES_IMAGE:-postgres:16-alpine@sha256:4327b9fd295502f326f44153a1045a7170ddbfffed1c3829798328556cfd09e2}
artifact='' id='' output='' identity='' temp=${RUNNER_TEMP:-/tmp}/beta-recovery docker_root=''
sql='' media='' expected_db='' expected_media='' source_sha='' repository='' tooling='' workflow='' database_digest='' media_digest='' capacity_only=false
while [ "$#" -gt 0 ]; do case "$1" in
  --artifact-dir) artifact=$2; shift 2;; --recovery-id) id=$2; shift 2;; --output-dir) output=$2; shift 2;;
  --identity) identity=$2; shift 2;; --image) image=$2; shift 2;; --temp-root) temp=$2; shift 2;;
  --docker-root) docker_root=$2; shift 2;; --sql-proof) sql=$2; shift 2;; --media-script) media=$2; shift 2;;
  --database-proof) expected_db=$2; shift 2;; --media-proof) expected_media=$2; shift 2;;
  --source-sha) source_sha=$2; shift 2;; --repository) repository=$2; shift 2;; --tooling-digest) tooling=$2; shift 2;;
  --workflow-digest) workflow=$2; shift 2;; --database-digest) database_digest=$2; shift 2;; --media-digest) media_digest=$2; shift 2;;
  --capacity-only) capacity_only=true; shift ;;
  *) usage;;
esac; done
[[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || usage
[ -d "$artifact" ] && [ ! -L "$artifact" ] && [ -d "$output" ] && [ ! -L "$output" ] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail "source SHA is required"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "repository is required"
for value in "$tooling" "$workflow" "$database_digest" "$media_digest"; do [[ "$value" =~ ^[0-9a-f]{64}$ ]] || fail "contract digest is required"; done
regular "$sql" || fail "database proof SQL unavailable"; regular "$media" || fail "media proof script unavailable"; [ -x "$media" ] || fail "media proof script is not executable"
[[ "$image" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || fail "PostgreSQL image must be pinned by digest"
for tool in age docker df find jq sha256sum tar; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
actual_database_digest=$(sha256sum "$sql" | awk '{print $1}')
actual_media_digest=$(sha256sum "$media" | awk '{print $1}')
[ "$actual_database_digest" = "$database_digest" ] || fail "database proof contract digest differs"
[ "$actual_media_digest" = "$media_digest" ] || fail "media proof contract digest differs"
workflow_file=.github/workflows/prove-beta-backup-restore.yml
[ -f "$workflow_file" ] || fail "workflow contract file is unavailable"
[ "$(sha256sum "$workflow_file" | awk '{print $1}')" = "$workflow" ] ||
  fail "workflow contract digest differs"
actual_tooling=$(for file in scripts/authorize-beta-recovery.sh scripts/run-beta-recovery-capture.sh \
  scripts/run-beta-recovery-restore.sh scripts/build-beta-recovery-evidence.sh \
  scripts/probe-test-vps-recovery-runtime.sh scripts/backup-production.sh \
  scripts/beta-recovery-database-proof.sql scripts/beta-recovery-media-proof.sh; do
  sha256sum "$file"
done | sort | sha256sum | awk '{print $1}')
[ "$actual_tooling" = "$tooling" ] || fail "tooling contract digest differs"
regular "$artifact/recovery-point.json" || fail "artifact file missing: recovery-point.json"
for file in postgres.dump.age uploads.tar.gz.age; do regular "$artifact/$file" || fail "artifact file missing: $file"; done
[ "$(find "$artifact" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" = '' ] || fail "artifact contains a non-file entry"
[ "$(find "$artifact" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" = 3 ] || fail "artifact shape is not exact"
manifest=$artifact/recovery-point.json
jq -e --arg id "$id" --arg sha "$source_sha" --arg repo "$repository" --arg tooling "$tooling" --arg workflow "$workflow" --arg dbcontract "$database_digest" --arg mediacontract "$media_digest" '
  type=="object" and (keys|sort)==["artifactFiles","artifactId","artifactName","captureRuntime","capturedAt","contracts","databaseProof","mediaProof","recoveryId","recoveryPointTime","repository","retentionDays","runId","schema","source","sourceSha"] and
  .schema=="meet-backend/beta-recovery-manifest/v1" and .recoveryId==$id and .sourceSha==$sha and .repository==$repo and .retentionDays==30 and .artifactId==null and
  (.runId|type=="number" and floor==. and .>0) and
  .artifactName==("beta-recovery-"+$id+"-"+(.runId|tostring)) and
  (.contracts|type=="object" and (keys|sort)==["database","media","tooling","workflow"] and .tooling==$tooling and .workflow==$workflow and .database==$dbcontract and .media==$mediacontract) and
  (.artifactFiles|type=="array" and length==2 and (map(.path)|sort)==["postgres.dump.age","uploads.tar.gz.age"] and all(.[]; (keys|sort)==["path","sha256","size"] and (.size|type=="number" and floor==. and .>0) and (.sha256|test("^[0-9a-f]{64}$")))) and
  (.source|type=="object" and (keys|sort)==["ciphertexts","postgresDatabaseBytes","uploads"] and (.postgresDatabaseBytes|type=="number" and floor==. and .>=0) and (.uploads|type=="object" and (keys|sort)==["bytes","digest","files"] and (.files|type=="number" and floor==. and .>=0) and (.bytes|type=="number" and floor==. and .>=0) and (.digest|test("^[0-9a-f]{64}$")))) and
  (.source.ciphertexts|type=="object" and (keys|sort)==["database","uploads"] and .database.name=="postgres.dump.age" and .uploads.name=="uploads.tar.gz.age" and all(.[]; (keys|sort)==["name","sha256","size"] and (.size|type=="number" and floor==. and .>0) and (.sha256|test("^[0-9a-f]{64}$")))) and
  (.databaseProof|type=="object") and (.mediaProof|type=="object") and .mediaProof.files==.source.uploads.files and .mediaProof.bytes==.source.uploads.bytes and .mediaProof.canonicalDigest==.source.uploads.digest and (.captureRuntime|type=="object")
' "$manifest" >/dev/null || fail "artifact source or contract differs from authorized checkout"
for file in postgres.dump.age uploads.tar.gz.age; do
  size=$(wc -c <"$artifact/$file" | tr -d '[:space:]'); sha=$(sha256sum -- "$artifact/$file" | awk '{print $1}')
  esize=$(jq -er --arg p "$file" '.artifactFiles[]|select(.path==$p)|.size' "$manifest"); esha=$(jq -er --arg p "$file" '.artifactFiles[]|select(.path==$p)|.sha256' "$manifest")
  [ "$size" = "$esize" ] && [ "$sha" = "$esha" ] || fail "artifact file hash or size differs from manifest: $file"
done
if [ -e "$temp" ]; then
  [ -d "$temp" ] && [ ! -L "$temp" ] || fail "temporary restore root is unsafe"
else
  mkdir -p -- "$temp"
fi
db_expected=$temp/expected-database-proof.json
media_expected=$temp/expected-media-proof.json
jq -cS '.databaseProof' "$manifest" >"$db_expected"
jq -cS '.mediaProof' "$manifest" >"$media_expected"
regular "$db_expected" && regular "$media_expected" || fail "manifest proof extraction failed"
[ -n "$expected_db" ] && regular "$expected_db" || expected_db=$db_expected
[ -n "$expected_media" ] && regular "$expected_media" || expected_media=$media_expected
jq -e '.schema=="meet-backend/closed-beta-database-proof/v1"' "$expected_db" >/dev/null || fail "expected database proof contract is invalid"
jq -e '.schema=="meet-backend/beta-recovery-media-proof/v1" and .referencesResolved==true' "$expected_media" >/dev/null || fail "expected media proof contract is invalid"
jq -e --slurpfile d "$expected_db" --slurpfile m "$expected_media" '.databaseProof==$d[0] and .mediaProof==$m[0]' "$manifest" >/dev/null || fail "expected proofs are not bound by artifact manifest"
dbsize=$(wc -c <"$artifact/postgres.dump.age" | tr -d '[:space:]'); usize=$(wc -c <"$artifact/uploads.tar.gz.age" | tr -d '[:space:]')
dbsha=$(sha256sum -- "$artifact/postgres.dump.age" | awk '{print $1}'); usha=$(sha256sum -- "$artifact/uploads.tar.gz.age" | awk '{print $1}')
[ "$dbsize" = "$(jq -er '.source.ciphertexts.database.size' "$manifest")" ] && [ "$dbsha" = "$(jq -er '.source.ciphertexts.database.sha256' "$manifest")" ] && [ "$usize" = "$(jq -er '.source.ciphertexts.uploads.size' "$manifest")" ] && [ "$usha" = "$(jq -er '.source.ciphertexts.uploads.sha256' "$manifest")" ] || fail "ciphertext hash or size differs from artifact manifest"
db=$(jq -er '.source.postgresDatabaseBytes' "$manifest"); uploads=$(jq -er '.source.uploads.bytes' "$manifest")
pair=$(add "$dbsize" "$usize"); temp_required=$(add "$(add "$(mul_small "$pair" 2)" "$db")" "$(add "$uploads" 2147483648)"); docker_required=$(add "$(mul_small "$db" 4)" 5368709120)
if [ -z "$docker_root" ]; then
  docker_root=$(docker info --format '{{.DockerRootDir}}') || fail "Docker root is unknown"
fi
[ -n "$docker_root" ] && [ -d "$docker_root" ] && [ ! -L "$docker_root" ] || fail "Docker root is unsafe"
tempdf=$(df -Pk -- "$temp" | awk 'NR==2{print $1 "\t" $4}')
docker_capacity=$(df -Pk -- "$docker_root" | awk 'NR==2{print $1 "\t" $4}') || fail "Docker capacity is unknown"
td=${tempdf%%$'\t'*}; tf=$(mul_small "${tempdf#*$'\t'}" 1024); dd=${docker_capacity%%$'\t'*}; dfree=$(mul_small "${docker_capacity#*$'\t'}" 1024)
if [ "$td" = "$dd" ]; then shared=$(add "$temp_required" "$docker_required"); capacity_ok "$tf" "$shared" || fail "shared-device capacity gate failed (20 percent margin included)"; else capacity_ok "$tf" "$temp_required" || fail "temporary capacity gate failed (20 percent margin included)"; capacity_ok "$dfree" "$docker_required" || fail "Docker capacity gate failed (20 percent margin included)"; fi
if [ "$capacity_only" = true ]; then
  exit 0
fi
regular "$identity" || fail "age identity unavailable"
private=$temp/private-$id; [ ! -e "$private" ] || fail "private restore directory already exists"; mkdir -- "$private"; chmod 700 "$private"
db_dump=$private/postgres.dump; uploads_archive=$private/uploads.tar.gz; marker=$temp/volume.identity; [ ! -e "$marker" ] || fail "volume identity path is already in use"
network=beta-recovery-$id; container=beta-recovery-postgres-$id; volume=''; marker_owned=0
cleanup(){
  local status=$? c v n cleanup_confirmed=0 candidate; trap - EXIT HUP INT TERM
  rm -f -- "$identity" "$db_dump" "$uploads_archive" "$private/reference-list" || status=1
  if inspect_resource container "$container"; then c=0; else c=$?; fi
  if [ "$c" -eq 0 ]; then
    jq -e --arg id "$id" '.[0].Config.Labels["com.meet-backend.beta-recovery/owner"]=="restore" and .[0].Config.Labels["com.meet-backend.beta-recovery/recovery-id"]==$id' <<<"$INSPECT_JSON" >/dev/null ||
      status=1
    if [ "$status" -eq 0 ]; then
      if [ "$marker_owned" -eq 1 ]; then
        docker container rm --force --volumes "$container" || status=1
      else
        docker container rm --force "$container" || status=1
      fi
    fi
  elif [ "$c" -eq 2 ]; then status=1; fi
  v=1
  if [ "$marker_owned" -eq 1 ]; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if inspect_resource volume "$candidate"; then
        v=0
        volume_provenance "$INSPECT_JSON" "$candidate" "$docker_root" || status=1
        [ "$status" -ne 0 ] || docker volume rm "$candidate" || status=1
      else
        volume_status=$?
        [ "$volume_status" -eq 2 ] && status=1
      fi
    done <"$marker"
  fi
  if inspect_resource network "$network"; then n=0; else n=$?; fi
  if [ "$n" -eq 0 ]; then
    if jq -e --arg id "$id" '.[0].Labels["com.meet-backend.beta-recovery/owner"]=="restore" and .[0].Labels["com.meet-backend.beta-recovery/recovery-id"]==$id' <<<"$INSPECT_JSON" >/dev/null &&
      docker network rm "$network"; then :; else status=1; fi
  elif [ "$n" -eq 2 ]; then status=1; fi
  if inspect_resource container "$container"; then c=0; else c=$?; fi
  if inspect_resource network "$network"; then n=0; else n=$?; fi
  v=1
  if [ "$marker_owned" -eq 1 ]; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if inspect_resource volume "$candidate"; then v=0; else volume_status=$?; [ "$volume_status" -eq 2 ] && v=2; fi
    done <"$marker"
  fi
  if [ "$c" -eq 2 ] || [ "$n" -eq 2 ] || [ "$v" -eq 2 ] || [ "$c" -eq 0 ] || [ "$n" -eq 0 ] || [ "$v" -eq 0 ]; then
    echo "cleanup survivors or inspection failure detected; starting a fresh-process retry" >&2
    if "$0" --cleanup-survivors --container "$container" --network "$network" --volume "${volume:-}" --volume-identity "$marker" --recovery-id "$id" --docker-root "$docker_root"; then
      cleanup_confirmed=1
    else
      status=1
    fi
  else
    cleanup_confirmed=1
  fi
  if [ "$cleanup_confirmed" -eq 1 ]; then
    [ -e "$marker" ] || [ "$marker_owned" -eq 0 ] || status=1
    [ ! -e "$marker" ] || rm -f -- "$marker" || status=1
  elif [ "$marker_owned" -eq 1 ]; then
    chmod 600 "$marker" || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$cleanup_confirmed" -eq 1 ]; then
    printf 'cleanup_complete=true\n' >"$output/restore-summary" || status=1
  else
    rm -f -- "$output/restore-summary" || status=1
  fi
  [ ! -e "$private" ] || rm -r -- "$private" || status=1
  [ "$status" -eq 0 ] || exit "$status"; exit "$status"
}
trap cleanup EXIT HUP INT TERM
if inspect_resource container "$container"; then fail "restore container already exists"; else [ "$?" -eq 1 ] || fail "cannot inspect restore container"; fi
if inspect_resource network "$network"; then fail "restore network already exists"; else [ "$?" -eq 1 ] || fail "cannot inspect restore network"; fi
age -d -i "$identity" -o "$db_dump" "$artifact/postgres.dump.age"; age -d -i "$identity" -o "$uploads_archive" "$artifact/uploads.tar.gz.age"
docker pull --quiet "$image" >/dev/null || fail "pinned image pull failed"
docker image inspect "$image" --format '{{json .RepoDigests}}' | jq -e --arg d "${image##*@}" 'any(.[];endswith($d))' >/dev/null || fail "pinned image provenance differs"
docker image inspect "$image" --format '{{json .Config.Volumes}}' | jq -e 'type=="object" and (keys|sort)==["/var/lib/postgresql/data"]' >/dev/null || fail "image volume declaration differs"
docker network create --internal --label com.meet-backend.beta-recovery/owner=restore --label com.meet-backend.beta-recovery/recovery-id="$id" "$network" >/dev/null
docker create --name "$container" --network "$network" --label com.meet-backend.beta-recovery/owner=restore --label com.meet-backend.beta-recovery/recovery-id="$id" -e POSTGRES_DB=restore_db -e POSTGRES_USER=restore_user -e POSTGRES_PASSWORD="$(od -An -N24 -tx1 /dev/urandom|tr -d '[:space:]')" "$image" >/dev/null
container_json=$(docker container inspect "$container")
volume_names=$(jq -r '.[0].Mounts[]? | select(.Type=="volume") | .Name' <<<"$container_json")
if [ -n "$volume_names" ]; then
  printf '%s\n' "$volume_names" >"$marker"
  chmod 600 "$marker"
  marker_owned=1
  while IFS= read -r candidate; do
    [[ "$candidate" =~ ^[0-9a-f]{64}$ ]] || fail "anonymous volume identity is invalid"
  done <<<"$volume_names"
  volume=$(printf '%s\n' "$volume_names" | head -n 1)
else
  fail "anonymous volume identity is missing"
fi
jq -e '(
  ((.[0].HostConfig.Binds == null) or (.[0].HostConfig.Binds | type == "array" and length == 0)) and
  ((.[0].HostConfig.Mounts == null) or (.[0].HostConfig.Mounts | type == "array" and length == 0)) and
  (.[0].Mounts | type == "array" and length == 1 and .[0].Type == "volume" and
    .[0].Destination == "/var/lib/postgresql/data" and .[0].RW == true and
    (.[0].Name | test("^[0-9a-f]{64}$")) and (.[0].Source | type == "string" and length > 0))
)' <<<"$container_json" >/dev/null || fail "anonymous mount provenance is not exact"
volume_json=$(docker volume inspect "$volume"); volume_provenance "$volume_json" "$volume" "$docker_root" || fail "volume is not anonymous local provenance"
container_mount_provenance "$container_json" "$volume" "$docker_root" || fail "anonymous mount provenance is not exact"
jq -cnS '{schema:"meet-backend/beta-recovery-mount/v1",type:"volume",
  destination:"/var/lib/postgresql/data",readWrite:true,anonymous:true}' \
  >"$output/mount-contract.json"
chmod 600 "$output/mount-contract.json"
docker start "$container" >/dev/null
for _ in $(seq 1 60); do docker exec "$container" pg_isready -U restore_user -d restore_db >/dev/null 2>&1 && break; sleep 1; done
docker exec "$container" pg_isready -U restore_user -d restore_db >/dev/null 2>&1 || fail "postgres did not become ready"
docker cp "$db_dump" "$container:/tmp/postgres.dump"
docker exec "$container" pg_restore --list /tmp/postgres.dump >"$private/postgres.list" || fail "database archive listing failed"
[ -s "$private/postgres.list" ] || fail "database archive listing is empty"
docker exec "$container" pg_restore --no-owner --no-privileges --exit-on-error -d restore_db /tmp/postgres.dump >/dev/null || fail "database restore failed"
docker cp "$sql" "$container:/tmp/proof.sql"
docker exec "$container" psql -X -qAt -U restore_user -d restore_db -f /tmp/proof.sql >"$output/restored-database-proof.json"
cmp -- "$expected_db" "$output/restored-database-proof.json" || fail "database proof differs byte-for-byte"
docker exec "$container" psql -X -qAt -U restore_user -d restore_db -v ON_ERROR_STOP=1 -c \
  "SELECT regexp_replace(image_url, '^https://api[.]whysoezzy[.]online/demo-assets/v1/', '')
     FROM (
       SELECT avatar_url AS image_url FROM users WHERE avatar_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%'
       UNION ALL SELECT image_url FROM communities WHERE image_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%'
       UNION ALL SELECT image_url FROM meetings WHERE image_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%'
     ) media_refs
     ORDER BY 1" >"$private/reference-list"
mkdir -- "$private/uploads"; validate_upload_archive "$uploads_archive" "$private"; tar --extract --gzip --file "$uploads_archive" --directory "$private/uploads" --no-same-owner --no-same-permissions --no-overwrite-dir
"$media" --root "$private/uploads" --reference-list "$private/reference-list" --output "$output/restored-media-proof.json"
cmp -- "$expected_media" "$output/restored-media-proof.json" || fail "media proof differs byte-for-byte"
chmod 600 "$output/restored-database-proof.json" "$output/restored-media-proof.json"
