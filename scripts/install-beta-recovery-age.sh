#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  echo "usage: $0 INSTALL-BIN-DIR" >&2
  exit 2
}
fail() {
  echo "beta recovery age setup failed: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || usage
install_dir=$1
runner_temp=${RUNNER_TEMP:-}
[ -n "$runner_temp" ] || fail "RUNNER_TEMP is required"
[ -d "$runner_temp" ] && [ ! -L "$runner_temp" ] || fail "RUNNER_TEMP is unsafe"
command -v uname >/dev/null 2>&1 || fail "uname is required"
[ "$(uname -s)" = Linux ] || fail "Linux is required"
[ "$(uname -m)" = x86_64 ] || fail "x86_64 is required"
command -v realpath >/dev/null 2>&1 || fail "realpath is required"
runner_temp=$(realpath -e -- "$runner_temp") || fail "RUNNER_TEMP is unavailable"

case "$install_dir" in
  ''|-*) usage ;;
esac
install_parent=$(dirname -- "$install_dir")
mkdir -p -- "$install_parent"
[ ! -L "$install_parent" ] && [ -d "$install_parent" ] || fail "install parent is unsafe"
install_parent=$(realpath -e -- "$install_parent") || fail "install parent is unavailable"
case "$install_parent/" in
  "$runner_temp/"*) ;;
  *) fail "install directory must be beneath RUNNER_TEMP" ;;
esac
if [ -e "$install_dir" ] || [ -L "$install_dir" ]; then
  [ -d "$install_dir" ] && [ ! -L "$install_dir" ] || fail "install directory is unsafe"
  [ -z "$(find "$install_dir" -mindepth 1 -print -quit)" ] || fail "install directory is not empty"
else
  mkdir -- "$install_dir"
fi

archive_url=https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-amd64.tar.gz
archive_size=10263766
archive_sha256=bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377
staging=$(mktemp -d "$runner_temp/beta-recovery-age.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -r -- "$staging" || status=1
  if [ "$status" -ne 0 ]; then
    rm -r -- "$install_dir" 2>/dev/null || :
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

archive=$staging/age.tar.gz
extract=$staging/extract
mkdir -- "$extract"
curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
  --output "$archive" "$archive_url"
[ "$(wc -c <"$archive" | tr -d '[:space:]')" = "$archive_size" ] ||
  fail "downloaded archive size differs"
printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum --check --strict >/dev/null ||
  fail "downloaded archive checksum differs"

expected_members=(
  age/
  age/LICENSE
  age/age-inspect
  age/age-plugin-batchpass
  age/age
  age/age-keygen
)
mapfile -t actual_members < <(tar -tzf "$archive")
[ "${#actual_members[@]}" -eq "${#expected_members[@]}" ] ||
  fail "archive member count differs"
for index in "${!expected_members[@]}"; do
  [ "${actual_members[$index]}" = "${expected_members[$index]}" ] ||
    fail "archive member allowlist differs"
done
tar --extract --gzip --file "$archive" --directory "$extract" \
  --no-same-owner --no-same-permissions
for binary in age age-keygen; do
  path=$extract/age/$binary
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] ||
    fail "archive binary is not a regular file"
  install -m 0755 -- "$path" "$install_dir/$binary"
  [ -f "$install_dir/$binary" ] && [ ! -L "$install_dir/$binary" ] &&
    [ -x "$install_dir/$binary" ] ||
    fail "installed binary is not a regular file"
  [ "$(stat -c '%a' "$install_dir/$binary")" = 755 ] ||
    fail "installed binary mode differs"
done

age=$install_dir/age
age_keygen=$install_dir/age-keygen
[ "$("$age" --version)" = v1.3.1 ] || fail "age version differs"
[ "$("$age_keygen" --version)" = v1.3.1 ] || fail "age-keygen version differs"
identity=$staging/canary-identity
plaintext=$staging/canary-plaintext
ciphertext=$staging/canary.age
decrypted=$staging/canary-decrypted
"$age_keygen" -o "$identity" >/dev/null 2>&1
recipient=$("$age_keygen" -y "$identity")
printf 'beta recovery age canary\n' >"$plaintext"
"$age" -r "$recipient" -o "$ciphertext" "$plaintext" >/dev/null
"$age" -d -i "$identity" -o "$decrypted" "$ciphertext" >/dev/null
cmp -- "$plaintext" "$decrypted" || fail "age canary differs"
