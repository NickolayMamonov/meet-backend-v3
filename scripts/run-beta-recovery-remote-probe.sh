#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

usage() {
  echo "usage: $0 --phase pre|post --host HOST --port PORT --ssh-user USER" \
    "--host-fingerprint SHA256:FINGERPRINT --release-root PATH" \
    "--public-url URL --source-sha SHA --recovery-id ID --output PATH" >&2
  exit 2
}

fail() {
  echo "beta recovery remote probe failed: $1" >&2
  exit 1
}

phase=
host=
port=
ssh_user=
host_fingerprint=
release_root=
public_url=
source_sha=
recovery_id=
output=
seen_phase=false
seen_host=false
seen_port=false
seen_ssh_user=false
seen_host_fingerprint=false
seen_release_root=false
seen_public_url=false
seen_source_sha=false
seen_recovery_id=false
seen_output=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase)
      [ "$seen_phase" = false ] && [ "$#" -ge 2 ] || usage
      phase=$2
      seen_phase=true
      shift 2
      ;;
    --host)
      [ "$seen_host" = false ] && [ "$#" -ge 2 ] || usage
      host=$2
      seen_host=true
      shift 2
      ;;
    --port)
      [ "$seen_port" = false ] && [ "$#" -ge 2 ] || usage
      port=$2
      seen_port=true
      shift 2
      ;;
    --ssh-user)
      [ "$seen_ssh_user" = false ] && [ "$#" -ge 2 ] || usage
      ssh_user=$2
      seen_ssh_user=true
      shift 2
      ;;
    --host-fingerprint)
      [ "$seen_host_fingerprint" = false ] && [ "$#" -ge 2 ] || usage
      host_fingerprint=$2
      seen_host_fingerprint=true
      shift 2
      ;;
    --release-root)
      [ "$seen_release_root" = false ] && [ "$#" -ge 2 ] || usage
      release_root=$2
      seen_release_root=true
      shift 2
      ;;
    --public-url)
      [ "$seen_public_url" = false ] && [ "$#" -ge 2 ] || usage
      public_url=$2
      seen_public_url=true
      shift 2
      ;;
    --source-sha)
      [ "$seen_source_sha" = false ] && [ "$#" -ge 2 ] || usage
      source_sha=$2
      seen_source_sha=true
      shift 2
      ;;
    --recovery-id)
      [ "$seen_recovery_id" = false ] && [ "$#" -ge 2 ] || usage
      recovery_id=$2
      seen_recovery_id=true
      shift 2
      ;;
    --output)
      [ "$seen_output" = false ] && [ "$#" -ge 2 ] || usage
      output=$2
      seen_output=true
      shift 2
      ;;
    *) usage ;;
  esac
done

[ "$seen_phase" = true ] && [ "$seen_host" = true ] &&
  [ "$seen_port" = true ] && [ "$seen_ssh_user" = true ] &&
  [ "$seen_host_fingerprint" = true ] && [ "$seen_release_root" = true ] &&
  [ "$seen_public_url" = true ] && [ "$seen_source_sha" = true ] &&
  [ "$seen_recovery_id" = true ] && [ "$seen_output" = true ] || usage

[[ "$phase" = pre || "$phase" = post ]] || fail "phase is invalid"
[[ "$host" =~ ^[A-Za-z0-9](-?[A-Za-z0-9])*(\.[A-Za-z0-9](-?[A-Za-z0-9])*)*$ ]] ||
  fail "host is invalid"
[ "${#host}" -le 253 ] || fail "host is invalid"
[[ "$port" =~ ^(0|[1-9][0-9]*)$ ]] &&
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail "port is invalid"
[[ "$ssh_user" =~ ^[A-Za-z0-9._-]{1,64}$ ]] &&
  [[ "$ssh_user" != -* ]] || fail "SSH user is invalid"
[[ "$host_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] ||
  fail "host fingerprint is invalid"
[[ "$release_root" =~ ^/[A-Za-z0-9._/-]+$ ]] &&
  [[ "$release_root" != *..* ]] || fail "release root is invalid"
[ "$public_url" = https://api.whysoezzy.online ] ||
  fail "reviewed HTTPS URL is required"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail "source SHA is invalid"
[[ "$recovery_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] ||
  fail "recovery ID is invalid"
[[ "$output" = /* ]] && [[ "$output" != *$'\n'* ]] &&
  [[ "$output" != *$'\r'* ]] || fail "output path is invalid"

runner_temp=${RUNNER_TEMP:-}
[ -n "$runner_temp" ] && [ -d "$runner_temp" ] && [ ! -L "$runner_temp" ] ||
  fail "runner temporary directory is invalid"
runner_temp=$(realpath -- "$runner_temp" 2>/dev/null) ||
  fail "runner temporary directory is invalid"
[ -d "$runner_temp" ] && [ ! -L "$runner_temp" ] || fail "runner temporary directory is invalid"

output_parent=${output%/*}
[ "$output_parent" != "$output" ] || fail "output path is invalid"
output_basename=${output##*/}
[ -n "$output_basename" ] && [ "$output_basename" != "." ] &&
  [ "$output_basename" != ".." ] || fail "output path is invalid"
[ -d "$output_parent" ] && [ ! -L "$output_parent" ] ||
  fail "output directory is invalid"
output_parent=$(realpath -- "$output_parent" 2>/dev/null) ||
  fail "output directory is invalid"
[ "$(stat -c '%u' -- "$output_parent" 2>/dev/null)" = "$(id -u)" ] ||
  fail "output directory is unsafe"
output=$output_parent/$output_basename
[ ! -e "$output" ] && [ ! -L "$output" ] || fail "output path is occupied"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) ||
  fail "script directory is unavailable"
probe_source=$script_dir/probe-test-vps-recovery-runtime.sh
compose_source=$script_dir/production-compose.sh
materializer=$script_dir/materialize-beta-recovery-known-hosts.sh
for source_file in "$probe_source" "$compose_source" "$materializer"; do
  [ -f "$source_file" ] && [ ! -L "$source_file" ] ||
    fail "checked-out recovery tooling is unsafe"
done

for tool in awk base64 cat chmod cmp id install ln mktemp od realpath rm sed sha256sum stat tr wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "required local tooling is unavailable"
done
for tool in ssh scp; do
  command -v "$tool" >/dev/null 2>&1 || fail "required SSH tooling is unavailable"
done

[ -n "${SSH_PRIVATE_KEY:-}" ] || fail "SSH_PRIVATE_KEY is absent"
probe_sha=$(sha256sum -- "$probe_source" | awk '{print $1}')
compose_sha=$(sha256sum -- "$compose_source" | awk '{print $1}')
probe_mode=$(stat -c '%a' -- "$probe_source" 2>/dev/null) ||
  fail "probe metadata is unavailable"
compose_mode=$(stat -c '%a' -- "$compose_source" 2>/dev/null) ||
  fail "Compose metadata is unavailable"
[[ "$probe_sha" =~ ^[0-9a-f]{64}$ ]] &&
  [[ "$compose_sha" =~ ^[0-9a-f]{64}$ ]] || fail "tooling checksum is invalid"
[[ "$probe_mode" =~ ^[0-7]{3,4}$ ]] &&
  [[ "$compose_mode" =~ ^[0-7]{3,4}$ ]] || fail "tooling mode is invalid"

ssh_dir=
key=
known=
config=
proof_tmp=
proof_tmp_identity=
create_result_tmp=
create_result_identity=
remote=
owner_token=
ssh_dir_identity=
published_identity=
remote_create_attempted=false
remote_cleanup_required=false
remote_cleanup_done=false
published=false
success=false
remote_identity=

remove_published_output() {
  local current_identity
  [ "$published" = true ] || return 0
  [ -e "$output" ] || [ -L "$output" ] || return 0
  [ ! -L "$output" ] || return 1
  current_identity=$(stat -c '%d:%i' -- "$output" 2>/dev/null) || return 1
  [ "$current_identity" = "$published_identity" ] || return 1
  rm -f -- "$output"
}

remove_proof_tmp() {
  local current_identity
  [ -n "$proof_tmp" ] || return 0
  [ -e "$proof_tmp" ] || [ -L "$proof_tmp" ] || return 0
  [ ! -L "$proof_tmp" ] || return 1
  current_identity=$(stat -c '%d:%i' -- "$proof_tmp" 2>/dev/null) || return 1
  [ "$current_identity" = "$proof_tmp_identity" ] || return 1
  rm -f -- "$proof_tmp"
}

remove_create_result_tmp() {
  local current_identity
  [ -n "$create_result_tmp" ] || return 0
  [ -e "$create_result_tmp" ] || [ -L "$create_result_tmp" ] || return 0
  [ ! -L "$create_result_tmp" ] || return 1
  current_identity=$(stat -c '%d:%i' -- "$create_result_tmp" 2>/dev/null) ||
    return 1
  [ "$current_identity" = "$create_result_identity" ] || return 1
  rm -f -- "$create_result_tmp"
}

cleanup_remote() {
  [ "$remote_create_attempted" = true ] || return 0
  [ "$remote_cleanup_required" = true ] || return 0
  [ "$remote_cleanup_done" = false ] || return 0
  if ssh "${ssh_opts[@]}" "$ssh_user@$host" sudo bash -s -- \
    "$remote" "$remote_identity" "$owner_token" "$source_sha" "$phase" <<'REMOTE_CLEANUP'
set -euo pipefail
remote=$1
remote_identity=$2
token=$3
source_sha=$4
phase=$5
[[ "$remote" =~ ^/tmp/beta-recovery-probe-(pre|post)-[0-9a-f]{32,64}$ ]]
[[ "$remote_identity" =~ ^[0-9]+:[0-9]+$ ]]
[[ "$phase" = pre || "$phase" = post ]]
[[ "$token" =~ ^[0-9a-f]{32,64}$ ]]
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
owner_uid=${SUDO_UID:?SUDO_UID is required}
owner_gid=${SUDO_GID:?SUDO_GID is required}
[[ "$owner_uid" =~ ^[0-9]+$ ]] && [[ "$owner_gid" =~ ^[0-9]+$ ]]
marker="$remote/.meet-beta-recovery-owner"
marker_value="meet-backend/beta-recovery-remote-probe-owner/v1:$token:$source_sha:$phase"
secure="/tmp/beta-recovery-probe-secure-$token"
expected=$(mktemp)
trap 'rm -f -- "$expected"' EXIT HUP INT TERM
secure_marker="$secure/.meet-beta-recovery-secure"
printf '%s\n' "$marker_value" >"$expected"
remove_secure() {
  local secure_identity secure_fd entry name
  if [ ! -e "$secure" ] && [ ! -L "$secure" ]; then
    return 0
  fi
  [ -d "$secure" ] && [ ! -L "$secure" ]
  [ "$(stat -c '%a:%u:%g' -- "$secure")" = "700:0:0" ]
  [ -f "$secure_marker" ] && [ ! -L "$secure_marker" ]
  [ "$(stat -c '%a:%u:%g:%h' -- "$secure_marker")" = "600:0:0:1" ]
  cmp -- "$expected" "$secure_marker" >/dev/null
  secure_identity=$(stat -c '%d:%i' -- "$secure")
  exec {secure_fd}<"$secure"
  [ "$(stat -Lc '%d:%i' -- "/proc/$$/fd/$secure_fd")" = "$secure_identity" ]
  [ "$(stat -Lc '%a:%u:%g' -- "/proc/$$/fd/$secure_fd")" = "700:0:0" ]
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    case "$name" in
      .meet-beta-recovery-secure|probe-test-vps-recovery-runtime.sh|production-compose.sh|runtime-proof.json|runtime-proof.json.response.*|runtime-proof.json.headers.*|runtime-proof.json.tmp.*) ;;
      *) return 1 ;;
    esac
  done < <(find -L "/proc/$$/fd/$secure_fd" -mindepth 1 -maxdepth 1 -print0)
  find -L "/proc/$$/fd/$secure_fd" -mindepth 1 -delete
  [ "$(stat -c '%d:%i' -- "$secure")" = "$secure_identity" ]
  rmdir -- "$secure"
  [ ! -e "$secure" ] && [ ! -L "$secure" ]
}
if [ ! -e "$remote" ] && [ ! -L "$remote" ]; then
  remove_secure
  exit 0
fi
[ -d "$remote" ] && [ ! -L "$remote" ]
[ "$(stat -c '%d:%i' -- "$remote")" = "$remote_identity" ]
[ "$(stat -c '%a:%u:%g' -- "$remote")" = "700:$owner_uid:$owner_gid" ]
[ -f "$marker" ] && [ ! -L "$marker" ]
[ "$(stat -c '%a:%u:%g:%h' -- "$marker")" = "600:$owner_uid:$owner_gid:1" ]
cmp -- "$expected" "$marker" >/dev/null
exec {remote_fd}<"$remote"
[ "$(stat -Lc '%d:%i' -- "/proc/$$/fd/$remote_fd")" = "$remote_identity" ]
remove_secure
find -L "/proc/$$/fd/$remote_fd" -mindepth 1 -delete
[ "$(stat -c '%d:%i' -- "$remote")" = "$remote_identity" ]
rmdir -- "$remote"
[ ! -e "$remote" ] && [ ! -L "$remote" ]
[ ! -e "$secure" ] && [ ! -L "$secure" ]
REMOTE_CLEANUP
  then
    remote_cleanup_done=true
    return 0
  fi
  return 1
}

remove_ssh_dir() {
  local current_identity
  [ -n "$ssh_dir" ] || return 0
  [ -e "$ssh_dir" ] || [ -L "$ssh_dir" ] || return 0
  [ -L "$ssh_dir" ] && return 1
  current_identity=$(stat -c '%d:%i' -- "$ssh_dir" 2>/dev/null) || return 1
  [ "$current_identity" = "$ssh_dir_identity" ] || return 1
  rm -r -- "$ssh_dir"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if ! cleanup_remote; then
    status=1
  fi
  remove_proof_tmp || status=1
  remove_create_result_tmp || status=1
  if ! remove_ssh_dir; then
    status=1
  fi
  if [ "$status" -ne 0 ] || [ "$success" != true ]; then
    remove_published_output || status=1
  fi
  exit "$status"
}

on_signal() {
  local signal_status=$1
  trap - EXIT HUP INT TERM
  cleanup_status=$signal_status
  if ! cleanup_remote; then
    cleanup_status=1
  fi
  remove_proof_tmp || cleanup_status=1
  remove_create_result_tmp || cleanup_status=1
  if ! remove_ssh_dir; then
    cleanup_status=1
  fi
  remove_published_output || cleanup_status=1
  exit "$cleanup_status"
}

trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

ssh_dir=$(mktemp -d "$runner_temp/beta-recovery-ssh.XXXXXX") ||
  fail "SSH staging creation failed"
ssh_dir_identity=$(stat -c '%d:%i' -- "$ssh_dir" 2>/dev/null) ||
  fail "SSH staging setup failed"
chmod 700 -- "$ssh_dir" || fail "SSH staging setup failed"
key=$ssh_dir/private_key
known=$ssh_dir/known_hosts
config=$ssh_dir/ssh_config
install -m 600 /dev/null "$config" || fail "SSH config setup failed"
[ -f "$config" ] && [ ! -L "$config" ] &&
  [ "$(stat -c '%a' -- "$config")" = 600 ] && [ ! -s "$config" ] ||
  fail "SSH config setup failed"
"$materializer" \
  --host "$host" --port "$port" --expected-fingerprint "$host_fingerprint" \
  --output "$known" || fail "known-hosts materialization failed"
install -m 600 /dev/null "$key" || fail "SSH key setup failed"
printf '%s\n' "$SSH_PRIVATE_KEY" >"$key" || fail "SSH key setup failed"
unset SSH_PRIVATE_KEY
[ -f "$key" ] && [ ! -L "$key" ] &&
  [ "$(stat -c '%a' -- "$key")" = 600 ] || fail "SSH key setup failed"

ssh_opts=(-F "$config" -i "$key" -p "$port" -o BatchMode=yes
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known"
  -o GlobalKnownHostsFile=/dev/null -o KnownHostsCommand=none)

owner_token=$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]') ||
  fail "remote staging identity generation failed"
[[ "$owner_token" =~ ^[0-9a-f]{64}$ ]] || fail "remote staging identity is invalid"
remote=/tmp/beta-recovery-probe-$phase-$owner_token
[[ "$remote" =~ ^/tmp/beta-recovery-probe-(pre|post)-[0-9a-f]{32,64}$ ]] ||
  fail "remote staging path is invalid"

remote_create_attempted=true
remote_cleanup_required=true
create_result_tmp=$(mktemp "$ssh_dir/create-result.XXXXXX") ||
  fail "remote staging protocol setup failed"
create_result_identity=$(stat -c '%d:%i' -- "$create_result_tmp" 2>/dev/null) ||
  fail "remote staging protocol setup failed"
if ssh "${ssh_opts[@]}" "$ssh_user@$host" sudo bash -s -- \
  "$remote" "$owner_token" "$source_sha" "$phase" >"$create_result_tmp" <<'REMOTE_CREATE'
set -euo pipefail
remote=$1
token=$2
source_sha=$3
phase=$4
[[ "$remote" =~ ^/tmp/beta-recovery-probe-(pre|post)-[0-9a-f]{32,64}$ ]]
[[ "$token" =~ ^[0-9a-f]{32,64}$ ]]
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$phase" = pre || "$phase" = post ]]
owner_uid=${SUDO_UID:?SUDO_UID is required}
owner_gid=${SUDO_GID:?SUDO_GID is required}
[[ "$owner_uid" =~ ^[0-9]+$ ]] && [[ "$owner_gid" =~ ^[0-9]+$ ]]
marker="$remote/.meet-beta-recovery-owner"
marker_value="meet-backend/beta-recovery-remote-probe-owner/v1:$token:$source_sha:$phase"
created=false
marker_published=false
marker_tmp=
created_identity=
cleanup_create() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$marker_tmp" ] && { [ -e "$marker_tmp" ] || [ -L "$marker_tmp" ]; }; then
    rm -f -- "$marker_tmp" || status=1
  fi
  if [ "$created" = true ] && [ "$marker_published" = false ] &&
    [ -d "$remote" ] && [ ! -L "$remote" ] &&
    [ -n "$created_identity" ] &&
    [ "$(stat -c '%d:%i' -- "$remote")" = "$created_identity" ] &&
    [ "$(stat -c '%a:%u:%g' -- "$remote")" = "700:$owner_uid:$owner_gid" ]; then
    exec {created_fd}<"$remote" || status=1
    [ "$(stat -Lc '%d:%i' -- "/proc/$$/fd/$created_fd")" = "$created_identity" ] ||
      status=1
    find -L "/proc/$$/fd/$created_fd" -mindepth 1 -delete || status=1
    [ "$(stat -c '%d:%i' -- "$remote")" = "$created_identity" ] || status=1
    rmdir -- "$remote" || status=1
  fi
  exit "$status"
}
trap cleanup_create EXIT HUP INT TERM
if [ -e "$remote" ] || [ -L "$remote" ]; then
  printf 'collision\n'
  exit 73
fi
mkdir -- "$remote"
created=true
chmod 700 -- "$remote"
chown "$owner_uid:$owner_gid" -- "$remote"
[ -d "$remote" ] && [ ! -L "$remote" ]
[ "$(stat -c '%a:%u:%g' -- "$remote")" = "700:$owner_uid:$owner_gid" ]
created_identity=$(stat -c '%d:%i' -- "$remote")
marker_tmp=$(mktemp "$remote/.meet-beta-recovery-owner.XXXXXX")
chmod 600 -- "$marker_tmp"
chown "$owner_uid:$owner_gid" -- "$marker_tmp"
printf '%s\n' "$marker_value" >"$marker_tmp"
ln -T -- "$marker_tmp" "$marker"
rm -f -- "$marker_tmp"
marker_tmp=
marker_published=true
[ -f "$marker" ] && [ ! -L "$marker" ]
[ "$(stat -c '%a:%u:%g:%h' -- "$marker")" = "600:$owner_uid:$owner_gid:1" ]
expected=$(mktemp)
trap 'rm -f -- "$expected"' EXIT HUP INT TERM
printf '%s\n' "$marker_value" >"$expected"
cmp -- "$expected" "$marker" >/dev/null
rm -f -- "$expected"
trap - EXIT HUP INT TERM
printf 'created\n'
stat -c '%d:%i' -- "$remote"
REMOTE_CREATE
then
  create_status=0
else
  create_status=$?
fi
create_result=$(sed -n '1p' "$create_result_tmp" 2>/dev/null || true)
remote_identity=$(sed -n '2p' "$create_result_tmp" 2>/dev/null || true)
create_result_lines=$(wc -l <"$create_result_tmp" | tr -d '[:space:]')
if [ "$create_status" -eq 73 ] && [ "$create_result" = collision ]; then
  remote_cleanup_required=false
  fail "remote staging path is already occupied"
fi
[ "$create_status" -eq 0 ] && [ "$create_result" = created ] &&
  [ "$create_result_lines" = 2 ] &&
  [[ "$remote_identity" =~ ^[0-9]+:[0-9]+$ ]] ||
  fail "remote staging creation was ambiguous or failed"
remove_create_result_tmp || fail "remote staging protocol cleanup failed"
create_result_tmp=
create_result_identity=

proof_tmp=$(mktemp "$output_parent/.beta-recovery-probe-output.XXXXXX") ||
  fail "proof staging creation failed"
proof_tmp_identity=$(stat -c '%d:%i' -- "$proof_tmp" 2>/dev/null) ||
  fail "proof staging setup failed"
chmod 600 -- "$proof_tmp" || fail "proof staging setup failed"
probe_payload=$(base64 --wrap=0 -- "$probe_source") ||
  fail "probe receiver payload preparation failed"
compose_payload=$(base64 --wrap=0 -- "$compose_source") ||
  fail "Compose receiver payload preparation failed"
ssh "${ssh_opts[@]}" "$ssh_user@$host" sudo bash -s -- \
  "$remote" "$remote_identity" "$owner_token" "$source_sha" "$phase" \
  "$probe_sha" "$probe_mode" "$compose_sha" "$compose_mode" "$release_root" \
  "$public_url" "$recovery_id" "$probe_payload" "$compose_payload" <<'REMOTE_RUN' \
  >"$proof_tmp"
set -euo pipefail
remote=$1
remote_identity=$2
token=$3
source_sha=$4
phase=$5
probe_sha=$6
probe_mode=$7
compose_sha=$8
compose_mode=$9
release_root=${10}
public_url=${11}
recovery_id=${12}
probe_payload=${13}
compose_payload=${14}
[[ "$remote" =~ ^/tmp/beta-recovery-probe-(pre|post)-[0-9a-f]{32,64}$ ]]
[[ "$remote_identity" =~ ^[0-9]+:[0-9]+$ ]]
[[ "$token" =~ ^[0-9a-f]{32,64}$ ]]
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$phase" = pre || "$phase" = post ]]
[[ "$probe_sha" =~ ^[0-9a-f]{64}$ ]]
[[ "$compose_sha" =~ ^[0-9a-f]{64}$ ]]
[[ "$probe_mode" =~ ^[0-7]{3,4}$ ]]
[[ "$compose_mode" =~ ^[0-7]{3,4}$ ]]
[[ "$release_root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$release_root" != *..* ]]
[ "$public_url" = https://api.whysoezzy.online ]
[[ "$recovery_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]]
owner_uid=${SUDO_UID:?SUDO_UID is required}
owner_gid=${SUDO_GID:?SUDO_GID is required}
[[ "$owner_uid" =~ ^[0-9]+$ ]] && [[ "$owner_gid" =~ ^[0-9]+$ ]]
marker="$remote/.meet-beta-recovery-owner"
marker_value="meet-backend/beta-recovery-remote-probe-owner/v1:$token:$source_sha:$phase"
secure="/tmp/beta-recovery-probe-secure-$token"
expected=$(mktemp)
trap 'rm -f -- "$expected"' EXIT HUP INT TERM
printf '%s\n' "$marker_value" >"$expected"
exec {remote_fd}<"$remote"
[ "$(stat -Lc '%d:%i' -- "/proc/$$/fd/$remote_fd")" = "$remote_identity" ]
[ -d "/proc/$$/fd/$remote_fd" ]
[ "$(stat -c '%a:%u:%g' -- "$remote")" = "700:$owner_uid:$owner_gid" ]
[ -f "$marker" ] && [ ! -L "$marker" ]
[ "$(stat -c '%a:%u:%g:%h' -- "$marker")" = "600:$owner_uid:$owner_gid:1" ]
cmp -- "$expected" "$marker" >/dev/null
if [ -e "$secure" ] || [ -L "$secure" ]; then
  exit 1
fi
mkdir -- "$secure"
secure_identity=$(stat -c '%d:%i' -- "$secure")
chmod 700 -- "$secure"
chown 0:0 -- "$secure"
secure_marker="$secure/.meet-beta-recovery-secure"
secure_marker_tmp=$(mktemp "$secure/.meet-beta-recovery-secure.XXXXXX")
chmod 600 -- "$secure_marker_tmp"
chown 0:0 -- "$secure_marker_tmp"
printf '%s\n' "$marker_value" >"$secure_marker_tmp"
ln -T -- "$secure_marker_tmp" "$secure_marker"
rm -f -- "$secure_marker_tmp"
chmod 600 -- "$secure_marker"
chown 0:0 -- "$secure_marker"
[ "$(stat -c '%d:%i' -- "$secure")" = "$secure_identity" ]
[ "$(stat -c '%a:%u:%g' -- "$secure")" = "700:0:0" ]
[ -f "$secure_marker" ] && [ ! -L "$secure_marker" ]
[ "$(stat -c '%a:%u:%g:%h' -- "$secure_marker")" = "600:0:0:1" ]
cmp -- "$expected" "$secure_marker" >/dev/null
probe_tmp="$secure/.probe.tmp"
compose_tmp="$secure/.compose.tmp"
printf '%s' "$probe_payload" | base64 --decode >"$probe_tmp"
printf '%s' "$compose_payload" | base64 --decode >"$compose_tmp"
chmod 755 -- "$probe_tmp" "$compose_tmp"
chown 0:0 -- "$probe_tmp" "$compose_tmp"
ln -T -- "$probe_tmp" "$secure/probe-test-vps-recovery-runtime.sh"
ln -T -- "$compose_tmp" "$secure/production-compose.sh"
rm -f -- "$probe_tmp" "$compose_tmp"
[ "$(stat -c '%d:%i' -- "$secure")" = "$secure_identity" ]
[ "$(stat -c '%a:%u:%g' -- "$secure")" = "700:0:0" ]
[ -f "$secure_marker" ] && [ ! -L "$secure_marker" ]
[ "$(stat -c '%a:%u:%g:%h' -- "$secure_marker")" = "600:0:0:1" ]
cmp -- "$expected" "$secure_marker" >/dev/null
probe="$secure/probe-test-vps-recovery-runtime.sh"
compose="$secure/production-compose.sh"
for tool in "$probe" "$compose"; do
  [ -f "$tool" ] && [ ! -L "$tool" ]
  [ "$(stat -c '%a:%u:%g:%h' -- "$tool")" = \
    "$([ "$tool" = "$probe" ] && printf '%s' "$probe_mode" || printf '%s' "$compose_mode"):0:0:1" ]
done
[ "$(sha256sum -- "$probe" | awk '{print $1}')" = "$probe_sha" ]
[ "$(sha256sum -- "$compose" | awk '{print $1}')" = "$compose_sha" ]
proof="$secure/runtime-proof.json"
[ ! -e "$proof" ] && [ ! -L "$proof" ]
exec {probe_fd}<"$probe"
exec {compose_fd}<"$compose"
[ "$(stat -Lc '%d:%i' -- "/proc/$$/fd/$probe_fd")" = \
  "$(stat -c '%d:%i' -- "$probe")" ]
[ "$(stat -Lc '%d:%i' -- "/proc/$$/fd/$compose_fd")" = \
  "$(stat -c '%d:%i' -- "$compose")" ]
export PRODUCTION_ROOT="$release_root"
lock_path=/var/lib/meet-test-vps-deploy/.deploy.lock
[ -f "$lock_path" ] && [ ! -L "$lock_path" ]
exec 9>>"$lock_path"
flock -n 9
bash "/proc/$$/fd/$probe_fd" --root "$release_root" \
  --compose-script "/proc/$$/fd/$compose_fd" \
  --output "$proof" --public-url "$public_url"
[ -f "$proof" ] && [ ! -L "$proof" ]
[ "$(stat -c '%a:%h' -- "$proof")" = 600:1 ]
exec {proof_fd}<"$proof"
cat -- "/proc/$$/fd/$proof_fd"
REMOTE_RUN
[ -f "$proof_tmp" ] && [ ! -L "$proof_tmp" ] ||
  fail "runtime proof transfer is unsafe"
[ "$(stat -c '%a' -- "$proof_tmp")" = 600 ] || fail "runtime proof mode is unsafe"
[ -s "$proof_tmp" ] || fail "runtime proof is empty"
published_identity=$(stat -c '%d:%i' -- "$proof_tmp" 2>/dev/null) ||
  fail "runtime proof identity is unavailable"
if ! ln -T -- "$proof_tmp" "$output" 2>/dev/null; then
  fail "output publication collision"
fi
published=true
rm -f -- "$proof_tmp" || fail "runtime proof staging cleanup failed"
proof_tmp=
proof_tmp_identity=
[ "$(stat -c '%d:%i' -- "$output" 2>/dev/null)" = "$published_identity" ] ||
  fail "published runtime proof identity changed"
[ -f "$output" ] && [ ! -L "$output" ] || fail "published runtime proof is unsafe"
success=true
