#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --input PATH --root PATH --environment NAME --now EPOCH" >&2
  exit 2
}

input='' root='' environment='' now=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) [ "$#" -ge 2 ] || usage; input=$2; shift 2 ;;
    --root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
    --environment) [ "$#" -ge 2 ] || usage; environment=$2; shift 2 ;;
    --now) [ "$#" -ge 2 ] || usage; now=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$input" = /* && "$root" = /* && "$input" != *..* && "$root" != *..* ]] || usage
[[ "$environment" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || usage
[[ "$now" =~ ^[0-9]+$ ]] || usage
[ -f "$input" ] && [ ! -L "$input" ] || { echo "snapshot input is unavailable" >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-policy.sh
source "$script_dir/beta-backup-policy.sh"
beta_backup_validate_status "$input" "$now" "$environment"

if [ ! -d "$root" ]; then
  mkdir -p "$root"
  chmod 750 "$root"
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
watermark=$root/watermark
new_generation=$(jq -er '.authorityGeneration' "$input")
new_observed=$(jq -er '.observedAt' "$input")
if [ -f "$watermark" ] && [ ! -L "$watermark" ]; then
  IFS=' ' read -r old_generation old_observed <"$watermark" || true
  [[ "${old_generation:-}" =~ ^[0-9]+$ && "${old_observed:-}" =~ ^[0-9]+$ ]] || {
    echo "receiver watermark is invalid" >&2
    exit 1
  }
  (( new_generation >= old_generation && new_observed > old_observed )) || {
    printf 'receiver replay ignored\n'
    exit 0
  }
fi

tmp=$(mktemp "$root/.status.XXXXXX")
trap 'rm -f -- "$tmp"; release_receiver_lock' EXIT
install -m 640 "$input" "$tmp"
mv -f -- "$tmp" "$status"
printf '%s %s\n' "$new_generation" "$new_observed" >"$watermark"
chmod 640 "$watermark"
sync -f "$status" "$watermark" "$root" 2>/dev/null || true
printf 'receiver_status=accepted generation=%s observed_at=%s\n' "$new_generation" "$new_observed"
