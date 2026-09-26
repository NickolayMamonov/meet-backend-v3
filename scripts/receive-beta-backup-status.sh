#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --input PATH --root PATH --environment NAME --now EPOCH [--owner-uid UID --owner-gid GID]" >&2
  exit 2
}

input='' root='' environment='' now='' owner_uid=$(id -u) owner_gid=$(id -g)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) [ "$#" -ge 2 ] || usage; input=$2; shift 2 ;;
    --root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
    --environment) [ "$#" -ge 2 ] || usage; environment=$2; shift 2 ;;
    --now) [ "$#" -ge 2 ] || usage; now=$2; shift 2 ;;
    --owner-uid) [ "$#" -ge 2 ] || usage; owner_uid=$2; shift 2 ;;
    --owner-gid) [ "$#" -ge 2 ] || usage; owner_gid=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$input" = /* && "$root" = /* && "$input" != *..* && "$root" != *..* ]] || usage
[[ "$environment" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || usage
[[ "$now" =~ ^[0-9]+$ ]] || usage
[[ "$owner_uid" =~ ^[0-9]+$ && "$owner_gid" =~ ^[0-9]+$ ]] || usage
[ -f "$input" ] && [ ! -L "$input" ] || { echo "snapshot input is unavailable" >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-policy.sh
source "$script_dir/beta-backup-policy.sh"
beta_backup_validate_status "$input" "$now" "$environment"

if [ ! -d "$root" ]; then
  if [ "$(uname -s)" = Linux ]; then
    install -d -m 750 "$root"
  else
    mkdir -p "$root"
    chmod 750 "$root" 2>/dev/null || true
  fi
  if [ "$(id -u)" = 0 ]; then
    chown "$owner_uid:$owner_gid" "$root"
  elif [ "$(id -u):$(id -g)" != "$owner_uid:$owner_gid" ]; then
    echo "receiver root ownership cannot be established" >&2
    exit 1
  fi
fi
[ ! -L "$root" ] || { echo "receiver root is a symlink" >&2; exit 1; }
if [ "$(uname -s)" = Linux ]; then
  [ "$(stat -c '%a' "$root")" = 750 ] ||
    { echo "receiver root mode is invalid" >&2; exit 1; }
  [ "$(stat -c '%u:%g' "$root")" = "$owner_uid:$owner_gid" ] ||
    { echo "receiver root ownership is invalid" >&2; exit 1; }
fi
lock=$root/.receiver.lock
if command -v flock >/dev/null 2>&1; then
  exec 9>"$lock"
  flock -n 9 || { echo "receiver busy" >&2; exit 1; }
else
  # Git Bash on the Kent control plane has no Linux flock. This bounded
  # launcher fallback is never used by the Ubuntu receiver or runtime proof.
  lock_dir="$lock.d"
  mkdir "$lock_dir" 2>/dev/null || { echo "receiver busy" >&2; exit 1; }
fi
release_receiver_lock() {
  [ -z "${lock_dir:-}" ] || rmdir "$lock_dir" 2>/dev/null || true
}
trap release_receiver_lock EXIT

status=$root/status.json
watermark=$root/watermark.json
new_generation=$(jq -er '.authorityGeneration' "$input")
new_observed=$(jq -er '.observedAt' "$input")
new_digest=$(sha256sum "$input" | awk '{print $1}')
if [ -f "$watermark" ] && [ ! -L "$watermark" ]; then
  old_generation=$(jq -er '.authorityGeneration' "$watermark") || old_generation=
  old_observed=$(jq -er '.observedAt' "$watermark") || old_observed=
  old_digest=$(jq -er '.statusDigest' "$watermark") || old_digest=
  [[ "$old_generation" =~ ^[0-9]+$ && "$old_observed" =~ ^[0-9]+$ &&
    "$old_digest" =~ ^[0-9a-f]{64}$ ]] || {
    echo "receiver watermark is invalid" >&2
    exit 1
  }
  if [ "$new_generation" = "$old_generation" ] &&
    [ "$new_observed" = "$old_observed" ] &&
    [ "$new_digest" = "$old_digest" ]; then
    printf 'receiver replay ignored\n'
    exit 0
  fi
  (( new_generation > old_generation ||
    (new_generation == old_generation && new_observed > old_observed) )) || {
      echo "receiver watermark regressed" >&2
      exit 1
    }
fi

tmp=$(mktemp "$root/.status.XXXXXX")
watermark_tmp=$(mktemp "$root/.watermark.XXXXXX")
trap 'rm -f -- "$tmp" "$watermark_tmp"; release_receiver_lock' EXIT
install -m 640 "$input" "$tmp"
chown "$owner_uid:$owner_gid" "$tmp" 2>/dev/null || true
chmod 640 "$tmp"
jq -cnS --arg statusDigest "$new_digest" --argjson generation "$new_generation" \
  --argjson observed "$new_observed" \
  '{schema:"meet-backend/beta-backup-watermark/v1",authorityGeneration:$generation,
    observedAt:$observed,statusDigest:$statusDigest}' >"$watermark_tmp"
chown "$owner_uid:$owner_gid" "$watermark_tmp" 2>/dev/null || true
chmod 640 "$watermark_tmp"
if [ "$(uname -s)" = Linux ]; then
  sync -f "$tmp" "$watermark_tmp" "$root"
else
  sync -f "$tmp" "$watermark_tmp" "$root" 2>/dev/null || true
fi
# The two renames deliberately publish a mismatched pair during the crash
# window. The Kotlin reader and shell policy reject that pair until a complete
# newer publication is present.
mv -f -- "$tmp" "$status"
if [ "$(uname -s)" = Linux ]; then sync -f "$status" "$root"; else sync -f "$status" "$root" 2>/dev/null || true; fi
mv -f -- "$watermark_tmp" "$watermark"
if [ "$(uname -s)" = Linux ]; then sync -f "$watermark" "$root"; else sync -f "$watermark" "$root" 2>/dev/null || true; fi
printf 'receiver_status=accepted generation=%s observed_at=%s\n' "$new_generation" "$new_observed"
