#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --source DIR --destination DIR --manifest PATH" >&2
  exit 2
}

source_dir='' destination_dir='' manifest=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] || usage; source_dir=$2; shift 2 ;;
    --destination) [ "$#" -ge 2 ] || usage; destination_dir=$2; shift 2 ;;
    --manifest) [ "$#" -ge 2 ] || usage; manifest=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$source_dir" = /* && "$destination_dir" = /* && "$manifest" = /* ]] || usage
[[ "$source_dir" != *..* && "$destination_dir" != *..* && "$manifest" != *..* ]] || usage
[ -d "$source_dir" ] && [ -d "$destination_dir" ] || {
  echo "migration roots are unavailable" >&2; exit 1;
}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
beta_storage_validate_point "$manifest"
for object in postgres.dump.age uploads.tar.gz.age; do
  [ -f "$source_dir/$object" ] && [ ! -L "$source_dir/$object" ] || {
    echo "source ciphertext is unavailable" >&2; exit 1;
  }
  install -m 600 "$source_dir/$object" "$destination_dir/$object"
done
tmp=$(mktemp "$destination_dir/.recovery-point.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
install -m 600 "$manifest" "$tmp"
mv -f -- "$tmp" "$destination_dir/recovery-point.json"
printf 'migration_status=accepted original_manifest_sha256=%s\n' \
  "$(sha256sum "$manifest" | awk '{print $1}')"
