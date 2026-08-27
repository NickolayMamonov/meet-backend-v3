#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = reconcile ]; then
  shift
  state_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
  current='' output=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state-root) state_root=$2; shift 2 ;;
      --current-runtime) current=$2; shift 2 ;;
      --output) output=$2; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -d "$state_root" ] && [ -f "$current" ] && [ -n "$output" ] || exit 2
  command -v jq >/dev/null 2>&1 || exit 1
  current_hash=$(jq -er '.runtime.configHash' "$current") || exit 1
  reconciled=0
  for state in "$state_root"/beta-recovery-*; do
    [ -d "$state" ] && [ ! -L "$state" ] || continue
    journal=$state/journal.json
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    jq -e '
      (keys|sort)==["capturedContainerSafe","capturedRuntimeDigest","currentRuntimeHealthy",
      "ownedPaths","phase","recoveryId","schema","state"] and
      .schema=="meet-backend/beta-recovery-journal/v1" and .state=="nonterminal" and
      (.capturedRuntimeDigest|test("^[0-9a-f]{64}$")) and
      (.ownedPaths|type=="array" and all(.[]; startswith("private/") and (contains("..")|not)))
    ' "$journal" >/dev/null || { echo "malformed capture journal" >&2; exit 1; }
    hash=$(jq -r '.capturedRuntimeDigest' "$journal")
    if [ "$hash" = "$current_hash" ]; then status=incident_resolved
    else
      jq -e '.currentRuntimeHealthy == true and .capturedContainerSafe == true' "$journal" >/dev/null ||
        { echo "replacement is not independently proven" >&2; exit 1; }
      status=superseded
    fi
    while IFS= read -r owned; do [ -n "$owned" ] && rm -f -- "$state/$owned"; done \
      < <(jq -r '.ownedPaths[]' "$journal")
    rm -rf -- "$state/staging"
    jq -cnS --arg id "$(jq -r '.recoveryId' "$journal")" --arg status "$status" \
      '{schema:"meet-backend/beta-recovery-incident/v1",recoveryId:$id,status:$status,sanitized:true}' \
      >"$state/incident.json"
    jq --arg phase "$status" '.state="terminal" | .phase=$phase' "$journal" >"$journal.tmp.$$"
    chmod 600 "$journal.tmp.$$"; mv -f -- "$journal.tmp.$$" "$journal"
    reconciled=$((reconciled + 1))
  done
  jq -cnS --argjson count "$reconciled" \
    '{schema:"meet-backend/beta-recovery-reconcile/v1",reconciled:$count}' >"$output"
  chmod 600 "$output"
  exit 0
fi
usage(){ echo "usage: $0 --recovery-id ID --root PATH --output-dir PATH --recipient AGE-RECIPIENT [--public-url URL]" >&2; exit 2; }
fail(){ echo "beta recovery capture failed: $*" >&2; exit 1; }
recovery_id='' root='' output='' recipient='' public_url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --recovery-id) recovery_id=$2; shift 2;; --root) root=$2; shift 2;;
    --output-dir) output=$2; shift 2;; --recipient) recipient=$2; shift 2;;
    --public-url) public_url=$2; shift 2;; *) usage;;
  esac
done
[[ "$recovery_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || usage
[ -d "$root" ] && [ -d "$output" ] && [ ! -L "$output" ] || usage
[[ "$recipient" =~ ^age1[0-9a-z]+$ ]] || fail "recipient malformed"
for tool in docker flock jq; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compose=${PRODUCTION_COMPOSE_SCRIPT:-"$root/scripts/production-compose.sh"}
backup=${BETA_BACKUP_SCRIPT:-"$script_dir/backup-production.sh"}
probe=${RECOVERY_PROBE_SCRIPT:-"$script_dir/probe-test-vps-recovery-runtime.sh"}
[ -x "$compose" ] && [ -x "$backup" ] && [ -x "$probe" ] || fail "reviewed tooling unavailable"
state_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
install -d -m 700 "$state_root"
exec 9>"$state_root/.deploy.lock"; flock -n 9 || fail "deploy lock is busy"
[ ! -e "$state_root/.smtp-transaction.current" ] || fail "SMTP transaction is active"
state=$state_root/beta-recovery-$recovery_id
[ ! -e "$state" ] || fail "recovery ID already exists"
install -d -m 700 "$state" "$state/private" "$state/staging"
journal=$state/journal.json
write_journal(){
  local phase=$1; local hash=$2; local healthy=$3; local safe=$4; local tmp=$journal.tmp.$$
  jq -cnS --arg id "$recovery_id" --arg phase "$phase" --arg hash "$hash" \
    --argjson healthy "$healthy" --argjson safe "$safe" \
    '{schema:"meet-backend/beta-recovery-journal/v1",recoveryId:$id,state:"nonterminal",
      phase:$phase,capturedRuntimeDigest:$hash,currentRuntimeHealthy:$healthy,
      capturedContainerSafe:$safe,ownedPaths:["private/postgres.dump.age",
      "private/uploads.tar.gz.age","private/capture-runtime.json","staging"]}' >"$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$journal"
}
pre=$state/capture-runtime.json
"$probe" --root "$root" --compose-script "$compose" --output "$pre" \
  ${public_url:+--public-url "$public_url"} || fail "pre-capture probe failed"
runtime_hash=$(jq -er '.runtime.configHash' "$pre") || fail "runtime hash unavailable"
write_journal pre_stop "$runtime_hash" true true
export AGE_RECIPIENT="$recipient" BACKUP_DIR="$state/private" PRODUCTION_ROOT="$root"
"$backup" --beta --recovery-id "$recovery_id" --output-dir "$state/private" ||
  fail "beta backup failed"
write_journal snapshot_complete "$runtime_hash" true true
post=$state/post-capture.json
"$probe" --root "$root" --compose-script "$compose" --output "$post" \
  ${public_url:+--public-url "$public_url"} || fail "post-capture probe failed"
cmp -- "$pre" "$post" || fail "active runtime changed during capture"
write_journal runtime_verified "$runtime_hash" true true
for file in postgres.dump.age uploads.tar.gz.age; do
  [ -s "$state/private/$file" ] || fail "encrypted pair is incomplete"
  mv -- "$state/private/$file" "$output/$file"
done
cp -- "$pre" "$output/capture-runtime.json"
rm -r -- "$state"
