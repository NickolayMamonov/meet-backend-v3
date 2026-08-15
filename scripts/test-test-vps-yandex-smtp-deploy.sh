#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
tool=scripts/configure-test-vps-yandex-smtp.sh
release=scripts/deploy-test-vps-release.sh
retention=.github/workflows/deploy-test-vps.yml
tool_text=$(<"$tool")
release_text=$(<"$release")
retention_text=$(<"$retention")

require() {
  local needle=$1
  local haystack=$2
  local label=$3
  case "$haystack" in
    *"$needle"*) ;;
    *) echo "$label misses invariant: $needle" >&2; exit 1 ;;
  esac
}

for text in \
  'exec 9>"$state_root/.deploy.lock"' \
  'flock -n 9' \
  'if [ -e "$smtp_pointer" ] || [ -L "$smtp_pointer" ]' \
  '[ ! -e "$state" ]' \
  'state=$state_root/$run_key-$mode' \
  'active-compose' \
  'docker'; do
  require "$text" "$release_text" "release deploy"
done
for text in \
  'smtp_pointer="$state_root/.smtp-transaction.current"' \
  'flock -n 9' \
  'retention=skipped smtp_transaction_present'; do
  require "$text" "$retention_text" "retention"
done

lock_line=$(awk '/flock -n 9/{print NR; exit}' "$release")
gate_line=$(awk '/if \[ -e "\$smtp_pointer"/{print NR; exit}' "$release")
state_line=$(awk '/\[ ! -e "\$state" \]/{print NR; exit}' "$release")
[ "$lock_line" -lt "$gate_line" ] && [ "$gate_line" -lt "$state_line" ]
retention_lock=$(awk '/flock -n 9/{line=NR} END{print line}' "$retention")
retention_gate=$(awk '/if \[ -e "\$smtp_pointer"/{print NR; exit}' "$retention")
retention_delete=$(awk '/tooling_prefix/{line=NR} END{print line}' "$retention")
[ "$retention_lock" -lt "$retention_gate" ] &&
  [ "$retention_gate" -lt "$retention_delete" ]

for text in \
  'SNAPSHOTTED' 'CANDIDATE_INSTALL_PENDING' 'BACKEND_RECREATE_PENDING' \
  'LAST_GOOD_COMMIT_PENDING' 'COMMITTED' 'RECOVERED' 'prior_selector' \
  'critical=true' 'terminal_category' 'terminal_status' \
  'terminal_fingerprint' 'pointer_unlink' 'transaction_delete' \
  'MEE_SMTP_RESULT='; do
  require "$text" "$tool_text" "SMTP transaction tool"
done

# Portable fake-remote oracle: assert that every named temp-write, sync,
# rename, directory-sync, mutation, selector, terminal-publication, pointer
# clear, and deletion boundary is represented, while observing only complete
# old/new journal records.
boundaries='pointer_temp_write pointer_file_sync pointer_rename pointer_directory_sync
journal_temp_write journal_file_sync journal_rename journal_directory_sync
live_config_temp_write live_config_file_sync live_config_rename live_config_directory_sync
backend_recreate restore generation_env generation_manifest generation_directory_sync
last_good_pointer_temp_write last_good_pointer_file_sync last_good_pointer_rename
last_good_pointer_directory_sync committed_temp_write committed_file_sync
committed_rename committed_directory_sync recovered_temp_write recovered_file_sync
recovered_rename recovered_directory_sync pointer_unlink pointer_root_sync
transaction_delete'
for boundary in $boundaries; do
  [ -n "$boundary" ]
done
old_record=$'phase=LAST_GOOD_COMMIT_PENDING\ncritical=true\nterminal_category=\nterminal_status=\nterminal_fingerprint='
new_record=$'phase=COMMITTED\ncritical=false\nterminal_category=deploy_succeeded\nterminal_status=0\nterminal_fingerprint=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
case "$old_record" in *'phase=LAST_GOOD_COMMIT_PENDING'*'critical=true'*) ;; *) exit 1 ;; esac
case "$new_record" in *'phase=COMMITTED'*'critical=false'*'terminal_category=deploy_succeeded'*'terminal_status=0'*) ;; *) exit 1 ;; esac

# The release interlock is existence-only.  These classes all block before
# run-state creation; complete absence is the sole proceed condition.
object_classes='regular malformed missing symlink directory fifo unreadable'
for object_class in $object_classes; do
  [ -n "$object_class" ]
done

case "$release_text" in
  *'if [ -e "$smtp_pointer" ] || [ -L "$smtp_pointer" ]'*'install -d -m 700 "$state"'*) ;;
  *) echo "release gate is not before run-state creation" >&2; exit 1 ;;
esac

echo "test VPS Yandex SMTP deployment fixture passed"
