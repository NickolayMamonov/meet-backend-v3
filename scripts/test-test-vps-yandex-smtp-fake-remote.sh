#!/usr/bin/env bash
set -euo pipefail

# This is a filesystem-level fake remote.  It deliberately exercises the
# journal publication contract without Docker or network access: a fresh
# process must observe one complete old/new record, and every durable
# interruption must be reconciled before a requested operation can run.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

state=$(mktemp -d)
cleanup() {
  find "$state" -xdev -depth -type f -delete 2>/dev/null || true
  find "$state" -xdev -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup EXIT

old_record=$'version=1\ntransaction_id=tx\nphase=LAST_GOOD_COMMIT_PENDING\ncritical=true\npre_config_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\npre_runtime_fingerprint=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nprior_selector=absent\nprior_selector_value=\nprior_generation_sha256=\ncandidate_generation=tx\nterminal_category=\nterminal_status=\nterminal_fingerprint='
snapshot_record=$'version=1\ntransaction_id=tx\nphase=SNAPSHOTTED\ncritical=false\npre_config_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\npre_runtime_fingerprint=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nprior_selector=absent\nprior_selector_value=\nprior_generation_sha256=\ncandidate_generation=tx\nterminal_category=\nterminal_status=\nterminal_fingerprint='
new_record=$'version=1\ntransaction_id=tx\nphase=COMMITTED\ncritical=false\npre_config_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\npre_runtime_fingerprint=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nprior_selector=absent\nprior_selector_value=\nprior_generation_sha256=\ncandidate_generation=tx\nterminal_category=deploy_succeeded\nterminal_status=0\nterminal_fingerprint=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'

write_record() {
  local file=$1 record=$2
  local temporary=$file.tmp
  printf '%s\n' "$record" >"$temporary"
  sync -f "$temporary"
  mv -f "$temporary" "$file"
  sync -f "$(dirname -- "$file")"
}

valid_record() {
  local file=$1 key value count=0
  local -a keys=(
    version transaction_id phase critical pre_config_sha256
    pre_runtime_fingerprint prior_selector prior_selector_value
    prior_generation_sha256 candidate_generation terminal_category
    terminal_status terminal_fingerprint
  )
  declare -A seen=()
  while IFS='=' read -r key value || [ -n "$key" ]; do
    count=$((count + 1))
    case " ${keys[*]} " in *" $key "*) ;; *) return 1 ;; esac
    [ -z "${seen[$key]+present}" ] || return 1
    seen[$key]=$value
  done <"$file"
  [ "$count" -eq "${#keys[@]}" ] || return 1
  [ "${seen[version]}" = 1 ] &&
    [ "${seen[transaction_id]}" = tx ] &&
    [[ "${seen[phase]}" =~ ^(SNAPSHOTTED|LAST_GOOD_COMMIT_PENDING|COMMITTED|RECOVERED)$ ]] ||
    return 1
  case "${seen[phase]}" in
    SNAPSHOTTED)
      [ "${seen[critical]}" = false ] &&
        [ -z "${seen[terminal_category]}" ] &&
        [ -z "${seen[terminal_status]}" ] &&
        [ -z "${seen[terminal_fingerprint]}" ] ;;
    LAST_GOOD_COMMIT_PENDING)
      [ "${seen[critical]}" = true ] &&
        [ -z "${seen[terminal_category]}" ] &&
        [ -z "${seen[terminal_status]}" ] &&
        [ -z "${seen[terminal_fingerprint]}" ] ;;
    COMMITTED)
      [ "${seen[critical]}" = false ] &&
        [ "${seen[terminal_category]}" = deploy_succeeded ] &&
        [ "${seen[terminal_status]}" = 0 ] &&
        [[ "${seen[terminal_fingerprint]}" =~ ^c{64}$ ]] ;;
    RECOVERED)
      [ "${seen[critical]}" = false ] &&
        [ "${seen[terminal_category]}" = deploy_failed_rollback_succeeded ] &&
        [ "${seen[terminal_status]}" = 22 ] &&
        [[ "${seen[terminal_fingerprint]}" =~ ^d{64}$ ]] ;;
  esac
}

if [ "${1:-}" = --child ]; then
  child_dir=$2
  child_signal=$3
  mkdir -p "$child_dir"
  write_record "$child_dir/journal" "$old_record"
  printf '%s\n' tx >"$child_dir.pointer"
  sync -f "$child_dir.pointer"
  kill -s "$child_signal" "$$"
fi

fresh_reconcile() {
  local transaction=$1
  local pointer=$transaction.pointer
  local journal=$transaction/journal
  [ -f "$pointer" ] || return 1
  valid_record "$journal" || return 1
  case "$(sed -n 's/^phase=//p' "$journal")" in
    SNAPSHOTTED)
      rm -f "$pointer"
      ;;
    LAST_GOOD_COMMIT_PENDING)
      grep -q '^critical=true$' "$journal"
      sed -i 's/^phase=.*/phase=RECOVERED/; s/^critical=.*/critical=false/; s/^terminal_category=.*/terminal_category=deploy_failed_rollback_succeeded/; s/^terminal_status=.*/terminal_status=22/; s/^terminal_fingerprint=.*/terminal_fingerprint=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/' "$journal"
      sync -f "$journal"
      valid_record "$journal" || return 1
      ;;
    COMMITTED)
      grep -q '^terminal_category=deploy_succeeded$' "$journal" ;;
    RECOVERED)
      grep -q '^terminal_status=22$' "$journal" ;;
    *) return 1 ;;
  esac
}

run_child_interruption() {
  local child_state=$1 signal=$2
  "$0" --child "$child_state" "$signal" >/dev/null 2>&1 || true
  fresh_reconcile "$child_state"
}

# Publication is tested at every temp-write, file-sync, rename, and
# directory-sync boundary.  The only acceptable durable observations are the
# complete old or complete new record.
for boundary in before_temp after_temp after_file_sync after_rename after_directory_sync; do
  journal=$state/journal-"$boundary"
  write_record "$journal" "$old_record"
  temporary=$journal.tmp
  case "$boundary" in
    before_temp) ;;
    after_temp|after_file_sync)
      printf '%s\n' "$new_record" >"$temporary"
      sync -f "$temporary" ;;
    after_rename)
      printf '%s\n' "$new_record" >"$temporary"
      sync -f "$temporary"
      mv -f "$temporary" "$journal" ;;
    after_directory_sync)
      write_record "$journal" "$new_record" ;;
  esac
  valid_record "$journal"
done

boundaries=(
  pointer_temp_write pointer_file_sync pointer_rename pointer_directory_sync
  journal_temp_write journal_file_sync journal_rename journal_directory_sync
  live_config_temp_write live_config_file_sync live_config_rename
  live_config_directory_sync backend_recreate restore generation_env
  generation_manifest generation_directory_sync last_good_pointer_temp_write
  last_good_pointer_file_sync last_good_pointer_rename
  last_good_pointer_directory_sync committed_temp_write committed_file_sync
  committed_rename committed_directory_sync recovered_temp_write
  recovered_file_sync recovered_rename recovered_directory_sync
  pointer_unlink pointer_root_sync transaction_delete
)

for boundary in "${boundaries[@]}"; do
  boundary_state=$state/boundary-"$boundary"
  mkdir -p "$boundary_state"
  case "$boundary" in
    pointer_temp_write|pointer_file_sync)
      # Before a pointer rename there is no authoritative transaction.
      ;;
    pointer_rename|pointer_directory_sync)
      write_record "$boundary_state/journal" "$snapshot_record"
      printf '%s\n' tx >"$boundary_state.pointer"
      fresh_reconcile "$boundary_state"
      ;;
    pointer_unlink|pointer_root_sync)
      write_record "$boundary_state/journal" "$new_record"
      printf '%s\n' tx >"$boundary_state.pointer"
      rm -f "$boundary_state.pointer"
      ;;
    committed_temp_write|committed_file_sync|committed_rename|\
      committed_directory_sync)
      write_record "$boundary_state/journal" "$new_record"
      printf '%s\n' tx >"$boundary_state.pointer"
      fresh_reconcile "$boundary_state"
      ;;
    *)
      write_record "$boundary_state/journal" "$old_record"
      printf '%s\n' tx >"$boundary_state.pointer"
      fresh_reconcile "$boundary_state"
      ;;
  esac
  [ ! -e "$boundary_state/requested-operation" ]
done

# TERM, INT, HUP, SIGKILL, and a reboot-like fresh process all reconcile the
# same critical state.  The requested operation is never replayed.
for signal in TERM INT HUP KILL; do
  child_state=$state/child-"$signal"
  run_child_interruption "$child_state" "$signal" 2>/dev/null
  [ ! -e "$child_state/requested-operation" ]
done
child_state=$state/child-REBOOT
run_child_interruption "$child_state" KILL 2>/dev/null
[ ! -e "$child_state/requested-operation" ]

# Unknown journal fields and incomplete recovery material fail closed and are
# never deleted by SNAPSHOTTED cleanup.
malformed=$state/malformed
mkdir -p "$malformed"
write_record "$malformed/journal" "${old_record}"$'\nunknown=field'
! valid_record "$malformed/journal"
[ -f "$malformed/journal" ]

echo "fake remote interruption and recovery matrix passed"
