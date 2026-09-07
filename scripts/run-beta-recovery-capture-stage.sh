#!/usr/bin/env bash
set -euo pipefail
[ "$PUBLIC_URL" = https://api.whysoezzy.online ]
age_bin="$RUNNER_TEMP/beta-recovery-age-v1.3.1/bin"
scripts/install-beta-recovery-age.sh "$age_bin"
age_install_root=$(dirname -- "$age_bin")
age_path=$(realpath -e -- "$age_bin/age")
age_sha256=$(sha256sum "$age_path" | awk '{print $1}')
age_version=$("$age_path" --version)
age_os=$(uname -s)
age_arch=$(uname -m)
[[ "$age_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$age_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[ "$age_os" = Linux ] && [ "$age_arch" = x86_64 ]
owner_token=$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')
[[ "$owner_token" =~ ^[0-9a-f]{64}$ ]]
LC_ALL=C
frame_stdin() {
  local header=$1 header_length prefix
  header_length=${#header}
  (( header_length >= 1 && header_length <= 4096 ))
  printf -v prefix '%08x' "$header_length"
  printf '%s%s' "$prefix" "$header"
}
create_program=$(cat <<'REMOTE_CREATE_PROGRAM'
set -euo pipefail
LC_ALL=C
umask 077
scratch=$(mktemp -d)
cleanup_parser_and_eof_probe() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -rf -- "$scratch" || status=1
  exit "$status"
}
trap cleanup_parser_and_eof_probe EXIT HUP INT TERM
read_frame() {
  local prefix_file="$scratch/prefix" header_file="$scratch/header"
  local header_body="$scratch/header-body" prefix_hex prefix_text header_hex header_body_hex
  local header_length byte byte_value i newline_count
  install -m 600 /dev/null "$prefix_file"
  dd iflag=fullblock bs=1 count=8 status=none of="$prefix_file"
  [ "$(stat -c '%s' -- "$prefix_file")" -eq 8 ]
  prefix_hex=$(od -An -v -tx1 "$prefix_file" | tr -d '[:space:]')
  [ "${#prefix_hex}" -eq 16 ]
  for ((i=0; i<${#prefix_hex}; i+=2)); do
    byte=${prefix_hex:i:2}
    byte_value=$((16#$byte))
    (( (byte_value >= 48 && byte_value <= 57) ||
       (byte_value >= 97 && byte_value <= 102) ))
  done
  prefix_text=$(head -c 8 "$prefix_file")
  [[ "$prefix_text" =~ ^[0-9a-f]{8}$ ]]
  header_length=$((16#$prefix_text))
  (( header_length >= 1 && header_length <= 4096 ))
  install -m 600 /dev/null "$header_file"
  dd iflag=fullblock bs=1 count="$header_length" status=none of="$header_file"
  [ "$(stat -c '%s' -- "$header_file")" -eq "$header_length" ]
  header_hex=$(od -An -v -tx1 "$header_file" | tr -d '[:space:]')
  [ "${#header_hex}" -eq "$((header_length * 2))" ]
  newline_count=0
  for ((i=0; i<${#header_hex}; i+=2)); do
    byte=${header_hex:i:2}
    byte_value=$((16#$byte))
    (( byte_value == 10 || (byte_value >= 32 && byte_value <= 126) ))
    [ "$byte" = 0a ] && newline_count=$((newline_count + 1))
  done
  header_body_hex=${header_hex:0:${#header_hex}-2}
  [[ "$header_body_hex" != *0a* ]] || return 1
  [ "$newline_count" -eq 1 ] && [[ "$header_hex" == *0a ]] || return 1
  head -c "$((header_length - 1))" "$header_file" >"$header_body"
  header=$(<"$header_body")
  IFS='|' read -r -a fields <<<"$header"
  [ "${#fields[@]}" -eq 3 ]
  [ "${fields[0]}" = meet-backend/beta-recovery-create/v1 ]
  remote=${fields[1]}
  token=${fields[2]}
  [[ "$remote" =~ ^/tmp/beta-recovery-[A-Za-z0-9._-]{8,128}$ ]]
  [[ "$token" =~ ^[0-9a-f]{64}$ ]]
  probe="$scratch/eof-probe"
  install -m 600 /dev/null "$probe"
  dd iflag=fullblock bs=1 count=1 status=none of="$probe"
  test ! -s "$probe"
}
read_frame
owner_uid=${SUDO_UID:?SUDO_UID is required}
owner_gid=${SUDO_GID:?SUDO_GID is required}
marker="$remote/.meet-beta-recovery-owner"
expected="$scratch/expected"
created=false
marker_published=false
cleanup_create() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$created" = true ] && [ "$marker_published" = false ] &&
    [ -d "$remote" ] && [ ! -L "$remote" ] &&
    [ "$(stat -c '%a:%u:%g' "$remote")" = "700:$owner_uid:$owner_gid" ]; then
    rm -r -- "$remote" || status=1
  fi
  rm -rf -- "$scratch" || status=1
  exit "$status"
}
trap cleanup_create EXIT HUP INT TERM
printf 'meet-backend/beta-recovery-owner/v1:%s\n' "$token" >"$expected"
if [ -e "$remote" ] || [ -L "$remote" ]; then
  [ -d "$remote" ] && [ ! -L "$remote" ]
  [ "$(stat -c '%a:%u:%g' "$remote")" = "700:$owner_uid:$owner_gid" ]
  [ -f "$marker" ] && [ ! -L "$marker" ]
  [ "$(stat -c '%a:%u:%g:%h' "$marker")" = "600:$owner_uid:$owner_gid:1" ]
  cmp -- "$expected" "$marker" >/dev/null
else
  mkdir -- "$remote"
  chmod 700 "$remote"
  chown "$owner_uid:$owner_gid" "$remote"
  created=true
  marker_tmp=$(mktemp "$remote/.meet-beta-recovery-owner.XXXXXX")
  chmod 600 "$marker_tmp"
  chown "$owner_uid:$owner_gid" "$marker_tmp"
  cat "$expected" >"$marker_tmp"
  mv -T -- "$marker_tmp" "$marker"
  marker_published=true
fi
trap - EXIT HUP INT TERM
rm -rf -- "$scratch"
REMOTE_CREATE_PROGRAM
)
receive_program=$(cat <<'REMOTE_RECEIVE_PROGRAM'
set -euo pipefail
LC_ALL=C
umask 077
scratch=$(mktemp -d)
temp=
published=false
cleanup_receiver() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$published" = false ] && [ -n "$temp" ] && [ -e "$temp" ]; then
    rm -f -- "$temp" || status=1
  fi
  rm -rf -- "$scratch" || status=1
  exit "$status"
}
trap cleanup_receiver EXIT HUP INT TERM
read_frame() {
  local prefix_file="$scratch/prefix" header_file="$scratch/header"
  local header_body="$scratch/header-body" prefix_hex prefix_text header_hex header_body_hex
  local header_length byte byte_value i newline_count
  install -m 600 /dev/null "$prefix_file"
  dd iflag=fullblock bs=1 count=8 status=none of="$prefix_file"
  [ "$(stat -c '%s' -- "$prefix_file")" -eq 8 ]
  prefix_hex=$(od -An -v -tx1 "$prefix_file" | tr -d '[:space:]')
  [ "${#prefix_hex}" -eq 16 ]
  for ((i=0; i<${#prefix_hex}; i+=2)); do
    byte=${prefix_hex:i:2}
    byte_value=$((16#$byte))
    (( (byte_value >= 48 && byte_value <= 57) ||
       (byte_value >= 97 && byte_value <= 102) ))
  done
  prefix_text=$(head -c 8 "$prefix_file")
  [[ "$prefix_text" =~ ^[0-9a-f]{8}$ ]]
  header_length=$((16#$prefix_text))
  (( header_length >= 1 && header_length <= 4096 ))
  install -m 600 /dev/null "$header_file"
  dd iflag=fullblock bs=1 count="$header_length" status=none of="$header_file"
  [ "$(stat -c '%s' -- "$header_file")" -eq "$header_length" ]
  header_hex=$(od -An -v -tx1 "$header_file" | tr -d '[:space:]')
  [ "${#header_hex}" -eq "$((header_length * 2))" ]
  newline_count=0
  for ((i=0; i<${#header_hex}; i+=2)); do
    byte=${header_hex:i:2}
    byte_value=$((16#$byte))
    (( byte_value == 10 || (byte_value >= 32 && byte_value <= 126) ))
    [ "$byte" = 0a ] && newline_count=$((newline_count + 1))
  done
  header_body_hex=${header_hex:0:${#header_hex}-2}
  [[ "$header_body_hex" != *0a* ]] || return 1
  [ "$newline_count" -eq 1 ] && [[ "$header_hex" == *0a ]] || return 1
  head -c "$((header_length - 1))" "$header_file" >"$header_body"
  header=$(<"$header_body")
  IFS='|' read -r -a fields <<<"$header"
  [ "${#fields[@]}" -eq 8 ]
  [ "${fields[0]}" = meet-backend/beta-recovery-file/v1 ]
  remote=${fields[1]}
  remote_identity=${fields[2]}
  token=${fields[3]}
  name=${fields[4]}
  expected_sha=${fields[5]}
  expected_mode=${fields[6]}
  expected_length=${fields[7]}
  [[ "$remote" =~ ^/tmp/beta-recovery-[A-Za-z0-9._-]{8,128}$ ]]
  [[ "$remote_identity" =~ ^[0-9]+:[0-9]+$ ]]
  [[ "$token" =~ ^[0-9a-f]{64}$ ]]
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]]
  [[ "$expected_mode" =~ ^[0-7]{3,4}$ ]]
  case "$name" in
    run-beta-recovery-capture.sh|backup-production.sh|probe-test-vps-recovery-runtime.sh|\
    production-compose.sh|beta-recovery-database-proof.sql|beta-recovery-media-proof.sh|\
    age|age-recipient) ;;
    *) exit 1 ;;
  esac
  [[ "$expected_length" =~ ^[0-9]+$ ]]
  (( expected_length > 0 && expected_length <= 9223372036854775806 ))
}
read_frame
owner_uid=${SUDO_UID:?SUDO_UID is required}
owner_gid=${SUDO_GID:?SUDO_GID is required}
marker="$remote/.meet-beta-recovery-owner"
expected="$scratch/expected"
printf 'meet-backend/beta-recovery-owner/v1:%s\n' "$token" >"$expected"
exec {remote_fd}<"$remote"
[ "$(stat -Lc '%d:%i' -- "/proc/$$/fd/$remote_fd")" = "$remote_identity" ]
[ "$(stat -c '%a:%u:%g' -- "$remote")" = "700:$owner_uid:$owner_gid" ]
[ -f "$marker" ] && [ ! -L "$marker" ]
[ "$(stat -c '%a:%u:%g:%h' -- "$marker")" = "600:$owner_uid:$owner_gid:1" ]
cmp -- "$expected" "$marker" >/dev/null
target="/proc/$$/fd/$remote_fd/$name"
[ ! -e "$target" ] && [ ! -L "$target" ]
temp=$(mktemp "/proc/$$/fd/$remote_fd/.$name.XXXXXX")
dd iflag=fullblock bs=1 count="$((expected_length + 1))" status=none of="$temp"
test -s "$temp"
[ "$(stat -c '%s' -- "$temp")" -eq "$expected_length" ]
[ "$(sha256sum -- "$temp" | awk '{print $1}')" = "$expected_sha" ]
[ -f "$temp" ] && [ ! -L "$temp" ] && [ "$(stat -c '%h' -- "$temp")" -eq 1 ]
chmod "$expected_mode" -- "$temp"
chown "$owner_uid:$owner_gid" -- "$temp"
[ "$(stat -c '%a:%u:%g:%h' -- "$temp")" = "$expected_mode:$owner_uid:$owner_gid:1" ]
temp_identity=$(stat -Lc '%d:%i' -- "$temp")
ln -T -- "$temp" "$target"
published=true
rm -f -- "$temp"
final_identity=$(stat -Lc '%d:%i' -- "$target")
if [ "$final_identity" != "$temp_identity" ]; then
  echo 'remote staging publication identity changed' >&2
  exit 1
fi
[ -f "$target" ] && [ ! -L "$target" ] && [ "$(stat -c '%h' -- "$target")" -eq 1 ]
[ "$(stat -c '%s' -- "$target")" -eq "$expected_length" ]
[ "$(sha256sum -- "$target" | awk '{print $1}')" = "$expected_sha" ]
[ "$(stat -c '%a:%u:%g:%h' -- "$target")" = "$expected_mode:$owner_uid:$owner_gid:1" ]
REMOTE_RECEIVE_PROGRAM
)
cleanup_program=$(cat <<'REMOTE_CLEANUP_PROGRAM'
set -euo pipefail
LC_ALL=C
umask 077
scratch=$(mktemp -d)
cleanup_parser_and_eof_probe() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -rf -- "$scratch" || status=1
  exit "$status"
}
trap cleanup_parser_and_eof_probe EXIT HUP INT TERM
prefix_file="$scratch/prefix"
header_file="$scratch/header"
header_body="$scratch/header-body"
probe="$scratch/eof-probe"
install -m 600 /dev/null "$prefix_file"
dd iflag=fullblock bs=1 count=8 status=none of="$prefix_file"
[ "$(stat -c '%s' -- "$prefix_file")" -eq 8 ]
prefix_hex=$(od -An -v -tx1 "$prefix_file" | tr -d '[:space:]')
[ "${#prefix_hex}" -eq 16 ]
for ((i=0; i<${#prefix_hex}; i+=2)); do
  byte=${prefix_hex:i:2}
  byte_value=$((16#$byte))
  (( (byte_value >= 48 && byte_value <= 57) ||
     (byte_value >= 97 && byte_value <= 102) ))
done
prefix_text=$(head -c 8 "$prefix_file")
[[ "$prefix_text" =~ ^[0-9a-f]{8}$ ]]
header_length=$((16#$prefix_text))
(( header_length >= 1 && header_length <= 4096 ))
install -m 600 /dev/null "$header_file"
dd iflag=fullblock bs=1 count="$header_length" status=none of="$header_file"
[ "$(stat -c '%s' -- "$header_file")" -eq "$header_length" ]
header_hex=$(od -An -v -tx1 "$header_file" | tr -d '[:space:]')
[ "${#header_hex}" -eq "$((header_length * 2))" ]
newline_count=0
for ((i=0; i<${#header_hex}; i+=2)); do
  byte=${header_hex:i:2}
  byte_value=$((16#$byte))
  (( byte_value == 10 || (byte_value >= 32 && byte_value <= 126) ))
  [ "$byte" = 0a ] && newline_count=$((newline_count + 1))
done
header_body_hex=${header_hex:0:${#header_hex}-2}
[[ "$header_body_hex" != *0a* ]] || exit 1
[ "$newline_count" -eq 1 ] && [[ "$header_hex" == *0a ]] || exit 1
head -c "$((header_length - 1))" "$header_file" >"$header_body"
header=$(<"$header_body")
IFS='|' read -r -a fields <<<"$header"
[ "${#fields[@]}" -eq 3 ]
[ "${fields[0]}" = meet-backend/beta-recovery-cleanup/v1 ]
remote=${fields[1]}
token=${fields[2]}
[[ "$remote" =~ ^/tmp/beta-recovery-[A-Za-z0-9._-]{8,128}$ ]]
[[ "$token" =~ ^[0-9a-f]{64}$ ]]
install -m 600 /dev/null "$probe"
dd iflag=fullblock bs=1 count=1 status=none of="$probe"
test ! -s "$probe"
owner_uid=${SUDO_UID:?SUDO_UID is required}
owner_gid=${SUDO_GID:?SUDO_GID is required}
if [ ! -e "$remote" ] && [ ! -L "$remote" ]; then
  exit 0
fi
[ -d "$remote" ] && [ ! -L "$remote" ]
[ "$(stat -c '%a:%u:%g' "$remote")" = "700:$owner_uid:$owner_gid" ]
marker="$remote/.meet-beta-recovery-owner"
[ -f "$marker" ] && [ ! -L "$marker" ]
[ "$(stat -c '%a:%u:%g:%h' "$marker")" = "600:$owner_uid:$owner_gid:1" ]
expected="$scratch/expected"
printf 'meet-backend/beta-recovery-owner/v1:%s\n' "$token" >"$expected"
cmp -- "$expected" "$marker" >/dev/null
rm -r -- "$remote"
[ ! -e "$remote" ] && [ ! -L "$remote" ]
REMOTE_CLEANUP_PROGRAM
)
create_program_b64=$(printf '%s' "$create_program" | base64 --wrap=0)
receive_program_b64=$(printf '%s' "$receive_program" | base64 --wrap=0)
cleanup_program_b64=$(printf '%s' "$cleanup_program" | base64 --wrap=0)
create_remote_cmd=(sudo bash -c 'exec bash <(printf "%s" "$1" | base64 --decode)' -- "$create_program_b64")
receive_remote_cmd=(sudo bash -c 'exec bash <(printf "%s" "$1" | base64 --decode)' -- "$receive_program_b64")
cleanup_remote_cmd=(sudo bash -c 'exec bash <(printf "%s" "$1" | base64 --decode)' -- "$cleanup_program_b64")
ssh_dir=
recipient_file=
remote_create_attempted=false
remote_cleanup_done=false
cleanup_remote() {
  [ "$remote_cleanup_done" = false ] || return 0
  remote_cleanup_done=true
  cleanup_header=
  printf -v cleanup_header 'meet-backend/beta-recovery-cleanup/v1|%s|%s\n' \
    "$remote" "$owner_token"
  frame_stdin "$cleanup_header" |
    ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" "${cleanup_remote_cmd[@]}"
}
cleanup_capture() {
  local status=$1
  trap - EXIT HUP INT TERM
  if [ "$remote_create_attempted" = true ] && ! cleanup_remote; then
    echo "remote staging cleanup failed" >&2
    status=1
  fi
  [ -z "$recipient_file" ] || rm -f -- "$recipient_file" || status=1
  rm -r -- "$ssh_dir" || status=1
  [ ! -e "$age_install_root" ] || rm -r -- "$age_install_root" || status=1
  exit "$status"
}
ssh_dir=$(mktemp -d "$RUNNER_TEMP/beta-recovery-ssh.XXXXXX")
trap 'cleanup_capture "$?"' EXIT
trap 'cleanup_capture 129' HUP
trap 'cleanup_capture 130' INT
trap 'cleanup_capture 143' TERM
key="$ssh_dir/private_key"
known="$ssh_dir/known_hosts"
config="$ssh_dir/ssh_config"
recipient_file="$RUNNER_TEMP/age-recipient"
remote="/tmp/beta-recovery-$RECOVERY_ID"
chmod 700 "$ssh_dir"
install -m 600 /dev/null "$config"
scripts/materialize-beta-recovery-known-hosts.sh \
  --host "$HOST" --port "$PORT" --expected-fingerprint "$HOST_FINGERPRINT" \
  --output "$known"
install -m 600 /dev/null "$key"
printf '%s\n' "$SSH_PRIVATE_KEY" >"$key"
ssh_opts=(-F "$config" -i "$key" -p "$PORT" -o BatchMode=yes
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known"
  -o GlobalKnownHostsFile=/dev/null -o KnownHostsCommand=none)
install -m 600 /dev/null "$recipient_file"
printf '%s\n' "$AGE_RECIPIENT" >"$recipient_file"
remote_create_attempted=true
create_header=
printf -v create_header 'meet-backend/beta-recovery-create/v1|%s|%s\n' \
  "$remote" "$owner_token"
frame_stdin "$create_header" |
  ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" "${create_remote_cmd[@]}"
remote_identity=$(ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" sudo bash -s -- \
  "$remote" <<'REMOTE_IDENTITY'
set -euo pipefail
remote=$1
[[ "$remote" =~ ^/tmp/beta-recovery-[A-Za-z0-9._-]{8,128}$ ]]
stat -c '%d:%i' -- "$remote"
REMOTE_IDENTITY
)
[[ "$remote_identity" =~ ^[0-9]+:[0-9]+$ ]]
send_capture_file() {
  local source=$1 name=$2 mode digest payload_length receive_header
  [ -f "$source" ] && [ ! -L "$source" ] && [ -r "$source" ]
  case "$name" in
    run-beta-recovery-capture.sh|backup-production.sh|probe-test-vps-recovery-runtime.sh|\
    production-compose.sh|beta-recovery-database-proof.sql|beta-recovery-media-proof.sh|\
    age|age-recipient) ;;
    *) return 1 ;;
  esac
  mode=$(stat -c '%a' -- "$source")
  digest=$(sha256sum -- "$source" | awk '{print $1}')
  payload_length=$(stat -c '%s' -- "$source")
  [[ "$payload_length" =~ ^[0-9]+$ ]] && (( payload_length > 0 ))
  (( payload_length <= 9223372036854775806 ))
  printf -v receive_header \
    'meet-backend/beta-recovery-file/v1|%s|%s|%s|%s|%s|%s|%s\n' \
    "$remote" "$remote_identity" "$owner_token" "$name" "$digest" "$mode" \
    "$payload_length"
  {
    frame_stdin "$receive_header"
    cat -- "$source"
  } | ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" "${receive_remote_cmd[@]}"
}
send_capture_file scripts/run-beta-recovery-capture.sh run-beta-recovery-capture.sh
send_capture_file scripts/backup-production.sh backup-production.sh
send_capture_file scripts/probe-test-vps-recovery-runtime.sh probe-test-vps-recovery-runtime.sh
send_capture_file scripts/production-compose.sh production-compose.sh
send_capture_file scripts/beta-recovery-database-proof.sql beta-recovery-database-proof.sql
send_capture_file scripts/beta-recovery-media-proof.sh beta-recovery-media-proof.sh
send_capture_file "$age_path" age
send_capture_file "$recipient_file" age-recipient
ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" sudo bash -s -- \
  "$remote" "$RECOVERY_ID" "$PUBLIC_URL" "$PATH_ON_HOST" \
  "$age_sha256" "$age_version" "$age_os" "$age_arch" <<'REMOTE'
set -euo pipefail
remote=$1
recovery_id=$2
public_url=$3
root=$4
recipient=$(<"$remote/age-recipient")
export AGE_RECIPIENT="$recipient"
export PRODUCTION_COMPOSE_SCRIPT="$remote/production-compose.sh"
export BETA_BACKUP_SCRIPT="$remote/backup-production.sh"
export RECOVERY_PROBE_SCRIPT="$remote/probe-test-vps-recovery-runtime.sh"
export TEST_VPS_STATE_ROOT=/var/lib/meet-test-vps-deploy
export PRODUCTION_ROOT="$root"
bash "$remote/run-beta-recovery-capture.sh" --recovery-id "$recovery_id" \
  --root "$root" --output-dir "$remote" --recipient "$recipient" \
  --public-url "$public_url" --age-binary "$remote/age" \
  --age-sha256 "$5" --age-version "$6" --age-os "$7" --age-arch "$8"
REMOTE
rm -f -- "$recipient_file"
ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" "sudo cat '$remote/postgres.dump.age'" \
  >"$RUNNER_TEMP/postgres.dump.age"
ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" "sudo cat '$remote/uploads.tar.gz.age'" \
  >"$RUNNER_TEMP/uploads.tar.gz.age"
ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" "sudo cat '$remote/capture-runtime.json'" \
  >"$RUNNER_TEMP/capture-runtime.json"
ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" "sudo cat '$remote/capture-database-proof.json'" \
  >"$RUNNER_TEMP/database-proof.json"
ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" "sudo cat '$remote/capture-media-proof.json'" \
  >"$RUNNER_TEMP/media-proof.json"
capture_result="$RUNNER_TEMP/capture-result.json"
ssh "${ssh_opts[@]}" "$SSH_USER@$HOST" "sudo cat '$remote/capture-result.json'" \
  >"$capture_result"
jq -e '
  type=="object" and
  (keys|sort)==["capturedAt","ciphertexts","databaseBytes","proofs","recoveryId","recoveryPointTime","schema","uploads"] and
  .schema=="meet-backend/beta-recovery-capture/v1" and
  (.databaseBytes|type=="number" and floor==. and .>0) and
  (.uploads|type=="object" and (keys|sort)==["bytes","digest","files"]) and
  (.uploads.files|type=="number" and floor==. and .>=0) and
  (.uploads.bytes|type=="number" and floor==. and .>=0) and
  (.uploads.digest|test("^[0-9a-f]{64}$")) and
  (.ciphertexts|type=="object" and (keys|sort)==["database","uploads"]) and
  all(.ciphertexts[]; (keys|sort)==["name","sha256","size"] and
    (.size|type=="number" and floor==. and .>0) and
    (.sha256|type=="string" and test("^[0-9a-f]{64}$"))) and
  (.proofs|type=="object" and (keys|sort)==["database","media"]) and
  all(.proofs[];
    (keys | map(select(. != "sha256")) | sort)==["name"] and
    (.name|type=="string")) and
  (.recoveryId==$id) and (.capturedAt==.recoveryPointTime)
' --arg id "$RECOVERY_ID" "$capture_result" >/dev/null
db_bytes=$(jq -er '.databaseBytes' "$capture_result")
uploads_files=$(jq -er '.uploads.files' "$capture_result")
uploads_bytes=$(jq -er '.uploads.bytes' "$capture_result")
uploads_digest=$(jq -er '.uploads.digest' "$capture_result")
db_cipher_size=$(wc -c <"$RUNNER_TEMP/postgres.dump.age" | tr -d '[:space:]')
db_cipher_sha=$(sha256sum "$RUNNER_TEMP/postgres.dump.age" | awk '{print $1}')
uploads_cipher_size=$(wc -c <"$RUNNER_TEMP/uploads.tar.gz.age" | tr -d '[:space:]')
uploads_cipher_sha=$(sha256sum "$RUNNER_TEMP/uploads.tar.gz.age" | awk '{print $1}')
[ "$db_cipher_size" = "$(jq -er '.ciphertexts.database.size' "$capture_result")" ] &&
  [ "$db_cipher_sha" = "$(jq -er '.ciphertexts.database.sha256' "$capture_result")" ] &&
  [ "$uploads_cipher_size" = "$(jq -er '.ciphertexts.uploads.size' "$capture_result")" ] &&
  [ "$uploads_cipher_sha" = "$(jq -er '.ciphertexts.uploads.sha256' "$capture_result")" ] ||
  { echo "transferred ciphertext differs from quiesced capture result" >&2; exit 1; }
if ! database_proof_actual_sha=$(sha256sum "$RUNNER_TEMP/database-proof.json" |
  awk '{print $1}'); then
  echo "database proof hash failed" >&2
  exit 1
fi
if ! database_proof_expected_sha=$(jq -er \
  '.proofs.database.sha256 // empty' "$capture_result" 2>/dev/null); then
  echo "database proof expected digest is missing or malformed" >&2
  exit 1
fi
if ! media_proof_actual_sha=$(sha256sum "$RUNNER_TEMP/media-proof.json" |
  awk '{print $1}'); then
  echo "media proof hash failed" >&2
  exit 1
fi
if ! media_proof_expected_sha=$(jq -er \
  '.proofs.media.sha256 // empty' "$capture_result" 2>/dev/null); then
  echo "media proof expected digest is missing or malformed" >&2
  exit 1
fi
[[ "$database_proof_actual_sha" =~ ^[0-9a-f]{64}$ ]] ||
  { echo "database proof digest is invalid" >&2; exit 1; }
[[ "$database_proof_expected_sha" =~ ^[0-9a-f]{64}$ ]] ||
  { echo "database proof expected digest is invalid" >&2; exit 1; }
[[ "$media_proof_actual_sha" =~ ^[0-9a-f]{64}$ ]] ||
  { echo "media proof digest is invalid" >&2; exit 1; }
[[ "$media_proof_expected_sha" =~ ^[0-9a-f]{64}$ ]] ||
  { echo "media proof expected digest is invalid" >&2; exit 1; }
[ "$database_proof_actual_sha" = "$database_proof_expected_sha" ] ||
  { echo "database proof differs from quiesced capture result" >&2; exit 1; }
[ "$media_proof_actual_sha" = "$media_proof_expected_sha" ] ||
  { echo "media proof differs from quiesced capture result" >&2; exit 1; }
[ "$uploads_files" = "$(jq -er '.files' "$RUNNER_TEMP/media-proof.json")" ] &&
  [ "$uploads_bytes" = "$(jq -er '.bytes' "$RUNNER_TEMP/media-proof.json")" ] &&
  [ "$uploads_digest" = "$(jq -er '.canonicalDigest' "$RUNNER_TEMP/media-proof.json")" ] ||
  { echo "transferred media proof differs from quiesced capture result" >&2; exit 1; }
point_time=$(jq -er '.recoveryPointTime' "$capture_result")
captured_at=$(jq -er '.capturedAt' "$capture_result")
point_epoch=$(date -u -d "$point_time" +%s)
observed_epoch=$(date -u +%s)
[ "$observed_epoch" -ge "$point_epoch" ] || { echo "recovery point is in the future" >&2; exit 1; }
observed_age=$((observed_epoch - point_epoch))
chmod 600 "$RUNNER_TEMP/"*.age "$RUNNER_TEMP/"*.json
cleanup_remote || { echo "remote staging cleanup failed" >&2; exit 1; }
mkdir "$RUNNER_TEMP/artifact"
tooling_digest=$(for file in scripts/authorize-beta-recovery.sh \
    scripts/run-beta-recovery-capture-stage.sh scripts/run-beta-recovery-capture.sh \
    scripts/run-beta-recovery-restore.sh \
    scripts/build-beta-recovery-evidence.sh scripts/run-beta-recovery-remote-probe.sh \
    scripts/production-compose.sh scripts/probe-test-vps-recovery-runtime.sh \
    scripts/backup-production.sh scripts/beta-recovery-database-proof.sql \
    scripts/beta-recovery-media-proof.sh scripts/install-beta-recovery-age.sh \
    scripts/materialize-beta-recovery-known-hosts.sh \
    scripts/validate-beta-recovery-artifact-retention.sh \
    scripts/admit-beta-recovery-artifact.sh; do sha256sum "$file"; done |
    sort | sha256sum | awk '{print $1}')
scripts/build-beta-recovery-evidence.sh manifest \
  --recovery-id "$RECOVERY_ID" --source-sha "$SOURCE_SHA" \
  --repository "$GITHUB_REPOSITORY" --run-id "$GITHUB_RUN_ID" \
  --artifact-name "beta-recovery-$RECOVERY_ID-$GITHUB_RUN_ID" \
  --tooling-digest "$tooling_digest" \
  --workflow-digest "$(sha256sum "$RECOVERY_WORKFLOW" | awk '{print $1}')" \
  --database-digest "$(sha256sum scripts/beta-recovery-database-proof.sql | awk '{print $1}')" \
  --media-digest "$(sha256sum scripts/beta-recovery-media-proof.sh | awk '{print $1}')" \
  --captured-at "$captured_at" \
  --point-time "$point_time" --observed-age-seconds "$observed_age" \
  --database-bytes "$db_bytes" \
  --uploads-files "$uploads_files" \
  --uploads-bytes "$uploads_bytes" \
  --uploads-digest "$uploads_digest" \
  --database-proof "$RUNNER_TEMP/database-proof.json" --media-proof "$RUNNER_TEMP/media-proof.json" \
  --runtime-proof "$RUNNER_TEMP/capture-runtime.json" \
  --database-ciphertext "$RUNNER_TEMP/postgres.dump.age" \
  --uploads-ciphertext "$RUNNER_TEMP/uploads.tar.gz.age" \
  --output "$RUNNER_TEMP/recovery-point.json"
cp -- "$RUNNER_TEMP/"{postgres.dump.age,uploads.tar.gz.age,recovery-point.json} \
  "$RUNNER_TEMP/artifact/"
scripts/build-beta-recovery-evidence.sh validate-artifact \
  --artifact-dir "$RUNNER_TEMP/artifact" --recovery-id "$RECOVERY_ID" \
  --source-sha "$SOURCE_SHA" --repository "$GITHUB_REPOSITORY" \
  --run-id "$GITHUB_RUN_ID"
