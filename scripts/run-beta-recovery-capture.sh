#!/usr/bin/env bash
set -euo pipefail
usage(){ echo "usage: $0 [reconcile] --recovery-id ID --root PATH --output-dir PATH --recipient AGE-RECIPIENT --public-url https://HOST [--age-binary PATH --age-sha256 SHA256 --age-version VERSION --age-os OS --age-arch ARCH]" >&2; exit 2; }
fail(){ echo "beta recovery capture failed: $*" >&2; exit 1; }
mode=capture; recovery_id='' root='' output='' recipient='' public_url=''
age_binary='' age_sha256='' age_version='' age_os='' age_arch=''
state_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}; compose=''; backup=''; probe=''; current_runtime=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    reconcile) mode=reconcile; shift;;
    --recovery-id) recovery_id=$2; shift 2;; --root) root=$2; shift 2;;
    --output-dir|--output) output=$2; shift 2;; --recipient) recipient=$2; shift 2;;
    --public-url) public_url=$2; shift 2;; --state-root) state_root=$2; shift 2;;
    --age-binary) age_binary=$2; shift 2;; --age-sha256) age_sha256=$2; shift 2;;
    --age-version) age_version=$2; shift 2;; --age-os) age_os=$2; shift 2;;
    --age-arch) age_arch=$2; shift 2;;
    --compose-script) compose=$2; shift 2;; --backup-script) backup=$2; shift 2;;
    --probe-script) probe=$2; shift 2;; --current-runtime) current_runtime=$2; shift 2;;
    *) usage;;
  esac
done
validate_release_root(){
  [ -d "$root" ] && [ ! -L "$root" ] ||
    fail "release root is unsafe"
  [ -f "$root/.env.production" ] && [ ! -L "$root/.env.production" ] &&
    [ -s "$root/.env.production" ] ||
    fail "release configuration is unavailable"
}
validate_release_root
export PRODUCTION_ROOT="$root"
if [ "$mode" = capture ]; then
  [[ "$recovery_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || usage
  [[ "$recipient" =~ ^age1[0-9a-z]+$ ]] || fail "recipient malformed"
  [ -n "$output" ] && [ -d "$output" ] && [ ! -L "$output" ] || usage
  [ -n "$age_binary" ] && [ -n "$age_sha256" ] && [ -n "$age_version" ] &&
    [ -n "$age_os" ] && [ -n "$age_arch" ] || usage
fi
[[ "$public_url" =~ ^https://[^/]+$ ]] || fail "public HTTPS URL is required"
for tool in docker flock jq stat find mktemp; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
if [ "$mode" = capture ]; then
  for tool in realpath sha256sum uname; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compose=${compose:-${PRODUCTION_COMPOSE_SCRIPT:-"$script_dir/production-compose.sh"}}
backup=${backup:-${BETA_BACKUP_SCRIPT:-"$script_dir/backup-production.sh"}}
probe=${probe:-${RECOVERY_PROBE_SCRIPT:-"$script_dir/probe-test-vps-recovery-runtime.sh"}}
[ -x "$compose" ] && [ -x "$backup" ] && [ -x "$probe" ] || fail "reviewed tooling unavailable"
database_proof=${BETA_DATABASE_PROOF_SCRIPT:-"$script_dir/beta-recovery-database-proof.sql"}
media_proof=${BETA_MEDIA_PROOF_SCRIPT:-"$script_dir/beta-recovery-media-proof.sh"}
[ -f "$database_proof" ] && [ -x "$media_proof" ] || fail "capture proof tooling is unavailable"
[ -z "$current_runtime" ] || { [ -f "$current_runtime" ] && [ ! -L "$current_runtime" ]; } || fail "current runtime proof is unsafe"
reconcile_output=''; [ "$mode" = reconcile ] && { [ -n "$output" ] && [ ! -e "$output" ] && [ -d "$(dirname "$output")" ] || usage; reconcile_output=$output; }
if [ "$mode" = capture ]; then
  case "$output" in /*) ;; *) fail "capture output path must be absolute";; esac
  case "$age_binary" in /*) ;; *) fail "age binary path must be absolute";; esac
  canonical_output=$(realpath -e -- "$output") || fail "capture output path is unavailable"
  canonical_age=$(realpath -e -- "$age_binary") || fail "age binary path is unavailable"
  [ "$canonical_output" = "$output" ] || fail "capture output path is not canonical"
  [ "$canonical_age" = "$output/age" ] || fail "age binary path is not the staged file"
  [ -d "$output" ] && [ ! -L "$output" ] || fail "capture output root is unsafe"
  [ "$(stat -c '%a' "$output")" = 700 ] || fail "capture output root mode differs"
  expected_uid=${SUDO_UID:-$(id -u)}; expected_gid=${SUDO_GID:-$(id -g)}
  [ "$(stat -c '%u' "$output")" = "$expected_uid" ] &&
    [ "$(stat -c '%g' "$output")" = "$expected_gid" ] || fail "capture output owner differs"
  [ -f "$age_binary" ] && [ ! -L "$age_binary" ] && [ -s "$age_binary" ] &&
    [ -x "$age_binary" ] || fail "age binary is unsafe"
  [ "$(stat -c '%a' "$age_binary")" = 755 ] || fail "age binary mode differs"
  [ "$(stat -c '%u' "$age_binary")" = "$expected_uid" ] &&
    [ "$(stat -c '%g' "$age_binary")" = "$expected_gid" ] || fail "age binary owner differs"
  [[ "$age_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "age digest is malformed"
  [ "$(sha256sum "$age_binary" | awk '{print $1}')" = "$age_sha256" ] ||
    fail "age digest differs"
  [[ "$age_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "age version is malformed"
  [[ "$age_os" =~ ^[A-Za-z0-9._-]+$ ]] || fail "age OS is malformed"
  [[ "$age_arch" =~ ^[A-Za-z0-9._-]+$ ]] || fail "age architecture is malformed"
  [ "$(uname -s)" = "$age_os" ] || fail "age OS differs"
  [ "$(uname -m)" = "$age_arch" ] || fail "age architecture differs"
  [ "$("$age_binary" --version)" = "$age_version" ] || fail "age version differs"
fi
install -d -m 700 "$state_root"; [ ! -L "$state_root" ] || fail "state root is unsafe"
exec 9>"$state_root/.deploy.lock"; flock -n 9 || fail "deploy lock is busy"
probe_runtime(){
  local destination=$1 backend mount
  "$probe" --root "$root" --compose-script "$compose" --output "$destination" --public-url "$public_url" || fail "runtime probe failed"
  jq -e '.schema=="meet-backend/test-vps-recovery-runtime/v1" and .healthy==true and .runtime.health=="healthy" and
    (.runtime.imageId|test("^sha256:[0-9a-f]{64}$")) and (.runtime.configHash|test("^[0-9a-f]{64}$")) and
    .runtime.uploadsMount=="volume" and .https.meetingsStatus=="200" and .https.meetingsJson==true and
    .https.actuatorStatus=="404" and .https.httpRedirectHttps==true' "$destination" >/dev/null ||
    fail "runtime or HTTPS safety proof is incomplete"
  backend=$("$compose" ps -q backend); [ -n "$backend" ] || fail "backend unavailable during runtime proof"
  mount=$(docker inspect "$backend" --format '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s" .Type .Name}}{{end}}{{end}}')
  [ "$mount" = "volume|meet-production_uploads_data" ] || fail "active uploads volume differs"
}
owned='["private/capture-runtime.json","private/post-capture.json","private/capture-result.json","private/capture-database-proof.json","private/capture-media-proof.json","private/postgres.dump.age","private/uploads.tar.gz.age","staging"]'
validate_journal(){
  jq -e --argjson owned "$owned" 'type=="object" and
    (keys|sort)==["capturedContainerId","capturedContainerSafe","capturedImageId","capturedRuntimeDigest","currentRuntimeHealthy","ownedPaths","phase","recoveryId","schema","state"] and
    .schema=="meet-backend/beta-recovery-journal/v1" and (.recoveryId|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$")) and
    (((.state=="nonterminal") and (.phase=="pre_stop" or .phase=="snapshot_complete" or .phase=="runtime_verified")) or
     ((.state=="terminal") and (.phase=="incident_resolved" or .phase=="superseded"))) and
    (.capturedContainerId|test("^[0-9a-f]{12,64}$")) and (.capturedImageId|test("^sha256:[0-9a-f]{64}$")) and
    (.capturedRuntimeDigest|test("^[0-9a-f]{64}$")) and (.currentRuntimeHealthy==true) and
    (.capturedContainerSafe==true) and .ownedPaths==$owned' "$1" >/dev/null
}
clean_owned(){
  local state=$1 path
  while IFS= read -r path; do
    path=${path%$'\r'}
    case "$path" in
      private/*) rm -f -- "$state/$path";;
      staging) [ ! -e "$state/staging" ] || { [ ! -L "$state/staging" ] && rm -r -- "$state/staging"; };;
      *) return 1;;
    esac
  done < <(jq -r '.ownedPaths[]' "$state/journal.json")
  [ ! -e "$state/private" ] || [ -z "$(find "$state/private" -mindepth 1 -print -quit)" ] || return 1
  [ ! -e "$state/staging" ] || return 1
}
inspect_captured_container(){
  local container=$1 response=$2 errors
  errors=$(mktemp "$state_root/.inspect-error.XXXXXX")
  if docker inspect "$container" >"$response" 2>"$errors"; then
    if jq -e 'type=="array" and length==1 and (.[0]|type=="object")' "$response" >/dev/null; then
      rm -f -- "$errors"
      return 0
    fi
    rm -f -- "$errors" "$response"
    return 2
  fi
  if grep -Eq '^(Error: |Error response from daemon: )No such (container|object): [^[:space:]]' "$errors"; then
    rm -f -- "$errors" "$response"
    return 1
  fi
  rm -f -- "$errors" "$response"
  return 2
}
terminalize(){
  local state=$1 status=$2 journal incident tmp
  journal=$state/journal.json; incident=$state/incident.json; tmp=$incident.tmp.$$
  jq -cnS --arg id "$(jq -er .recoveryId "$journal")" --arg status "$status" '{schema:"meet-backend/beta-recovery-incident/v1",recoveryId:$id,status:$status,sanitized:true}' >"$tmp"
  chmod 600 "$tmp"
  if [ -e "$incident" ]; then cmp -- "$tmp" "$incident" >/dev/null || { rm -f "$tmp"; return 1; }; rm -f "$tmp"; else mv -- "$tmp" "$incident"; fi
  tmp=$journal.tmp.$$
  jq --arg phase "$status" '.state="terminal"|.phase=$phase|.currentRuntimeHealthy=true|.capturedContainerSafe=true' "$journal" >"$tmp"
  chmod 600 "$tmp"; mv -- "$tmp" "$journal"
}
validate_incident(){
  local incident=$1 expected_id=$2 expected_status=$3
  jq -e --arg id "$expected_id" --arg status "$expected_status" '
    type=="object" and (keys|sort)==["recoveryId","sanitized","schema","status"] and
    .schema=="meet-backend/beta-recovery-incident/v1" and .recoveryId==$id and
    .status==$status and ($status=="incident_resolved" or $status=="superseded") and
    .sanitized==true
  ' "$incident" >/dev/null
}
reconcile_states(){
  local state state_id journal current expected image running mount fresh hash count=0 summary terminal_phase
  summary=$(mktemp "$state_root/.reconcile.XXXXXX")
  trap 'rm -f -- "${summary:-}"' RETURN
  for state in "$state_root"/beta-recovery-*; do
    [ -d "$state" ] && [ ! -L "$state" ] || continue
    state_id=${state##*/beta-recovery-}; journal=$state/journal.json
    [ -f "$journal" ] && [ ! -L "$journal" ] || fail "malformed recovery state"
    find "$state" -type l -print -quit | grep -q . && fail "recovery state contains a symlink" || true
    validate_journal "$journal" || fail "malformed capture journal"
    [ "$(jq -er .recoveryId "$journal")" = "$state_id" ] || fail "recovery state identity differs"
    if [ "$(jq -er .state "$journal")" = terminal ]; then
      [ -f "$state/incident.json" ] && [ ! -L "$state/incident.json" ] || fail "terminal incident missing"
      terminal_phase=$(jq -er .phase "$journal")
      validate_incident "$state/incident.json" "$state_id" "$terminal_phase" ||
        fail "terminal incident is malformed"
      clean_owned "$state" || fail "terminal capture state is not clean"; continue
    fi
    expected=$(jq -er .capturedContainerId "$journal"); image=$(jq -er .capturedImageId "$journal")
    current=$("$compose" ps -q backend) || fail "backend lookup failed"; [ -n "$current" ] || fail "current backend unavailable"
    if [ "$current" = "$expected" ]; then
      [ "$(docker inspect "$expected" --format '{{.Image}}')" = "$image" ] || fail "captured image differs"
      mount=$(docker inspect "$expected" --format '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s" .Type .Name}}{{end}}{{end}}')
      [ "$mount" = "volume|meet-production_uploads_data" ] || fail "captured uploads mount differs"
      running=$(docker inspect "$expected" --format '{{.State.Running}}')
      [ "$running" = true ] || docker start "$expected" >/dev/null || fail "captured backend restart failed"
      fresh=$(mktemp "$state_root/.runtime.XXXXXX"); probe_runtime "$fresh"; hash=$(jq -er .runtime.configHash "$fresh")
      [ "$hash" = "$(jq -er .capturedRuntimeDigest "$journal")" ] || fail "captured runtime differs"; rm -f -- "$fresh"; status=incident_resolved
    else
      docker info >/dev/null 2>&1 || fail "Docker state unavailable"
      inspected=$(mktemp "$state_root/.inspect.XXXXXX")
      if inspect_captured_container "$expected" "$inspected"; then
        [ "$(jq -er '.[0].State.Running' "$inspected")" = false ] ||
          { rm -f -- "$inspected"; fail "superseded container is running"; }
        [ "$(jq -er '.[0].Image' "$inspected")" = "$image" ] ||
          { rm -f -- "$inspected"; fail "superseded image differs"; }
        rm -f -- "$inspected"
      else
        inspect_status=$?
        rm -f -- "$inspected"
        [ "$inspect_status" = 1 ] || fail "captured container inspection is ambiguous"
      fi
      fresh=$(mktemp "$state_root/.runtime.XXXXXX"); probe_runtime "$fresh"
      [ -z "$current_runtime" ] || cmp -- "$current_runtime" "$fresh" || fail "current runtime differs"
      rm -f -- "$fresh"; status=superseded
    fi
    terminalize "$state" "$status" || fail "terminal state publication failed"; clean_owned "$state" || fail "capture-owned state cleanup failed"; count=$((count+1))
  done
  jq -cnS --argjson count "$count" '{schema:"meet-backend/beta-recovery-reconcile/v1",reconciled:$count}' >"$summary"
  if [ -n "$reconcile_output" ]; then mv -- "$summary" "$reconcile_output"; chmod 600 "$reconcile_output"; else rm -f -- "$summary"; fi
  trap - RETURN
}
smtp_pointer="$state_root/.smtp-transaction.current"
[ ! -e "$smtp_pointer" ] && [ ! -L "$smtp_pointer" ] ||
  fail "SMTP transaction pointer is present"
reconcile_states
[ "$mode" = reconcile ] && exit 0
[ ! -e "$smtp_pointer" ] && [ ! -L "$smtp_pointer" ] ||
  fail "SMTP transaction pointer appeared during reconciliation"
[ ! -e "$state_root/beta-recovery-$recovery_id" ] || fail "recovery ID already exists"
published=(); pre_tmp=''
cleanup_staged(){
  local file status=0
  case "$script_dir" in /tmp/beta-recovery-*|/var/tmp/beta-recovery-*)
    for file in run-beta-recovery-capture.sh backup-production.sh probe-test-vps-recovery-runtime.sh production-compose.sh beta-recovery-database-proof.sql beta-recovery-media-proof.sh age; do
      [ ! -e "$script_dir/$file" ] || rm -f -- "$script_dir/$file" || status=1
      [ ! -e "$script_dir/$file" ] || status=1
    done;; esac
  if [ "$mode" = capture ] && [ "$age_binary" = "$output/age" ]; then
    if [ -e "$age_binary" ]; then
      rm -f -- "$age_binary" || status=1
    fi
    [ ! -e "$age_binary" ] || status=1
  fi
  return "$status"
}
cleanup(){
  local status=$? file; trap - EXIT HUP INT TERM
  [ -z "$pre_tmp" ] || rm -f -- "$pre_tmp" || status=1
  if [ "$status" -ne 0 ]; then for file in "${published[@]}"; do rm -f -- "$output/$file" || status=1; done; cleanup_staged || status=1; fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
output_uid=$(stat -c '%u' "$output"); output_gid=$(stat -c '%g' "$output")
expected_uid=${SUDO_UID:-$(id -u)}; expected_gid=${SUDO_GID:-$(id -g)}
[ "$output_uid" = "$expected_uid" ] && [ "$output_gid" = "$expected_gid" ] || fail "output owner differs"
chmod 700 "$output"; pre_tmp=$(mktemp "$state_root/.pre-capture.XXXXXX"); probe_runtime "$pre_tmp"
backend=$("$compose" ps -q backend); [ -n "$backend" ] || fail "backend unavailable"
container_id=$(docker inspect "$backend" --format '{{.Id}}'); image_id=$(docker inspect "$backend" --format '{{.Image}}'); runtime_hash=$(jq -er .runtime.configHash "$pre_tmp")
state=$state_root/beta-recovery-$recovery_id; install -d -m 700 "$state" "$state/private" "$state/staging"; mv -- "$pre_tmp" "$state/private/capture-runtime.json"; pre_tmp=''; journal=$state/journal.json
write_journal(){ local phase=$1 tmp=$journal.tmp.$$; jq -cnS --arg id "$recovery_id" --arg phase "$phase" --arg c "$container_id" --arg i "$image_id" --arg h "$runtime_hash" --argjson owned "$owned" '{schema:"meet-backend/beta-recovery-journal/v1",recoveryId:$id,state:"nonterminal",phase:$phase,capturedContainerId:$c,capturedImageId:$i,capturedRuntimeDigest:$h,currentRuntimeHealthy:true,capturedContainerSafe:true,ownedPaths:$owned}' >"$tmp"; chmod 600 "$tmp"; mv -f -- "$tmp" "$journal"; }
write_journal pre_stop
export AGE_RECIPIENT="$recipient" BACKUP_DIR="$state/private"
production_scripts_dir=$(dirname -- "$compose"); export PRODUCTION_SCRIPTS_DIR="$production_scripts_dir"
export BETA_DATABASE_PROOF_SCRIPT="$database_proof" BETA_MEDIA_PROOF_SCRIPT="$media_proof"
"$backup" --beta --recovery-id "$recovery_id" --output-dir "$state/private" \
  --age-binary "$age_binary" --age-sha256 "$age_sha256" || fail "beta backup failed"
write_journal snapshot_complete
post=$state/private/post-capture.json; probe_runtime "$post"; cmp -- "$state/private/capture-runtime.json" "$post" || fail "runtime or HTTPS changed during capture"; write_journal runtime_verified
for file in postgres.dump.age uploads.tar.gz.age capture-database-proof.json capture-media-proof.json capture-result.json capture-runtime.json post-capture.json; do [ -f "$state/private/$file" ] && [ ! -L "$state/private/$file" ] || fail "capture output incomplete"; done
jq -e --arg id "$recovery_id" '.schema=="meet-backend/beta-recovery-capture/v1" and .recoveryId==$id and
  (.capturedAt|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+Z$")) and
  (.recoveryPointTime|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+Z$")) and
  (.databaseBytes|type=="number" and floor==. and .>=0) and
  (.uploads.files|type=="number" and floor==. and .>=0) and
  (.uploads.bytes|type=="number" and floor==. and .>=0) and
  (.uploads.digest|type=="string" and test("^[0-9a-f]{64}$")) and
  .ciphertexts.database.name=="postgres.dump.age" and .ciphertexts.uploads.name=="uploads.tar.gz.age" and
  (.ciphertexts[] | (.size|type=="number" and floor==. and .>0)) and
  (.ciphertexts[] | (.sha256|type=="string" and test("^[0-9a-f]{64}$"))) and
  .proofs.database.name=="capture-database-proof.json" and .proofs.media.name=="capture-media-proof.json" and
  (.proofs[] | (.sha256|type=="string" and test("^[0-9a-f]{64}$")))' "$state/private/capture-result.json" >/dev/null || fail "capture result malformed"
for proof in capture-database-proof.json capture-media-proof.json; do [ "$(wc -l <"$state/private/$proof" | tr -d '[:space:]')" = 1 ] || fail "capture proof is not compact"; done
jq -e '.schema=="meet-backend/closed-beta-database-proof/v1"' "$state/private/capture-database-proof.json" >/dev/null || fail "database proof malformed"
jq -e '.schema=="meet-backend/beta-recovery-media-proof/v1" and .referencesResolved==true' "$state/private/capture-media-proof.json" >/dev/null || fail "media proof malformed"
publish_file(){ local name=$1 source=$2 tmp; [ ! -e "$output/$name" ] || fail "capture output exists"; tmp=$(mktemp "$output/.capture-output.XXXXXX"); cp -- "$source" "$tmp"; chmod 600 "$tmp"; chown "$expected_uid:$expected_gid" "$tmp"; mv -n -- "$tmp" "$output/$name"; [ ! -e "$tmp" ] || fail "capture output publication raced"; published+=("$name"); }
for file in postgres.dump.age uploads.tar.gz.age capture-database-proof.json capture-media-proof.json capture-result.json capture-runtime.json post-capture.json; do publish_file "$file" "$state/private/$file"; done
rm -r -- "$state" || fail "capture state cleanup failed"; trap - EXIT HUP INT TERM; cleanup_staged || fail "remote staging cleanup failed"
printf 'database=%s\nuploads=%s\n' "$output/postgres.dump.age" "$output/uploads.tar.gz.age"
