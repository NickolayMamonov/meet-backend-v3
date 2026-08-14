#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

usage() {
  printf 'usage: %s inspect|configure-primary|ensure-rollover|configure-rollover\n' "$0" >&2
  printf '       %s verify-primary-renewal|verify-rollover-renewal|drill\n' "$0" >&2
  printf '       %s restore --confirm-restore=RESTORE-PRIMARY\n' "$0" >&2
  exit 64
}

validate_secure_install_root() {
  local path=$1 mode
  while [[ "$path" != / ]]; do
    [[ -d "$path" && ! -L "$path" ]] || return 65
    [[ "$(stat -c '%u:%g' "$path")" = 0:0 ]] || return 65
    mode=$(stat -c '%a' "$path") || return 65
    [[ $((8#$mode & 8#022)) -eq 0 ]] || return 65
    path=${path%/*}
    [[ -n "$path" ]] || path=/
  done
}

[[ "$#" -ge 1 ]] || usage
command=$1
shift
case "$command" in
  inspect|configure-primary|ensure-rollover|configure-rollover|\
  verify-primary-renewal|verify-rollover-renewal|drill|restore) ;;
  *) usage ;;
esac
if [[ "$command" = restore ]]; then
  [[ "$#" = 1 && "$1" = --confirm-restore=RESTORE-PRIMARY ]] || usage
else
  [[ "$#" = 0 ]] || usage
fi
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [[ "${LEAF_SPKI_FIXTURE_ROOT:-}" = "" ]]; then
  [[ "$(id -u)" = 0 ]] || { echo "live mode requires root" >&2; exit 65; }
  [[ "$script_dir/leaf-spki-rollover.sh" = \
    /usr/local/libexec/meet-leaf-spki-rollover/leaf-spki-rollover.sh ]] ||
    { echo "live entry point is not installed at the fixed path" >&2; exit 65; }
  validate_secure_install_root "$script_dir" ||
    { echo "live entry point is outside the trusted root" >&2; exit 65; }
  [[ "$(stat -c '%u:%g:%a:%h' "$script_dir/leaf-spki-rollover.sh")" = 0:0:755:1 ]] ||
    { echo "live entry point metadata is unsafe" >&2; exit 65; }
fi

library=$script_dir/lib/leaf-spki-rollover.sh
[[ -f "$library" && ! -L "$library" ]] || { echo "library is unavailable" >&2; exit 65; }
if [[ "${LEAF_SPKI_FIXTURE_ROOT:-}" = "" ]]; then
  [[ "$(stat -c '%u:%g:%a:%h' "$library")" = 0:0:644:1 ]] ||
    { echo "live library metadata is unsafe" >&2; exit 65; }
fi
# shellcheck source=/dev/null
. "$library"
run_rollover "$command"
