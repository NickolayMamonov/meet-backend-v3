#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

fail() { echo "beta recovery semantic route fixture failed: $*" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workflow=$root/.github/workflows/prove-beta-backup-restore.yml
helper=$root/scripts/run-beta-recovery-remote-probe.sh
[ -f "$workflow" ] || fail "workflow is missing"
[ -x "$helper" ] || fail "remote probe helper is missing"
line() { awk -v pattern="$1" 'index($0, pattern) { print NR; exit }' "$workflow"; }
select_line=$(line '  restore-select:')
pre_line=$(line '  restore-pre-probe:')
isolated_line=$(line '  restore-isolated:')
post_line=$(line '  restore-post-probe:')
evidence_line=$(line '  evidence:')
for value in "$select_line" "$pre_line" "$isolated_line" "$post_line" "$evidence_line"; do
  [[ "$value" =~ ^[0-9]+$ ]] || fail "route boundary is missing"
done
[ "$select_line" -lt "$pre_line" ] && [ "$pre_line" -lt "$isolated_line" ] &&
  [ "$isolated_line" -lt "$post_line" ] && [ "$post_line" -lt "$evidence_line" ] ||
  fail "route ordering is invalid"
pre=$(awk '/^  restore-pre-probe:/{active=1} /^  restore-isolated:/{active=0} active' "$workflow")
post=$(awk '/^  restore-post-probe:/{active=1} /^  evidence:/{active=0} active' "$workflow")
for block in "$pre" "$post"; do
  grep -Fq 'scripts/run-beta-recovery-remote-probe.sh' <<<"$block" ||
    fail "probe helper is not wired"
  ! grep -Fq '/var/lib/meet-test-vps-deploy/scripts/' <<<"$block" ||
    fail "ambient remote tooling path remains"
  grep -Fq -- '--source-sha' <<<"$block" || fail "source binding is absent"
  grep -Fq -- '--recovery-id' <<<"$block" || fail "recovery binding is absent"
done
for required in SSH_PRIVATE_KEY StrictHostKeyChecking=yes KnownHostsCommand=none \
  scp SUDO_UID sha256sum flock marker 'trap cleanup' 'on_signal 129' 'on_signal 130' 'on_signal 143'; do
  grep -Fq -- "$required" "$helper" || fail "helper contract is incomplete: $required"
done
inventory=$root/.semantic-route-inventory.$$
trap 'rm -f -- "$inventory"' EXIT HUP INT TERM
printf '%s\n' \
  scripts/authorize-beta-recovery.sh scripts/backup-production.sh \
  scripts/beta-recovery-database-proof.sql scripts/beta-recovery-media-proof.sh \
  scripts/build-beta-recovery-evidence.sh scripts/install-beta-recovery-age.sh \
  scripts/materialize-beta-recovery-known-hosts.sh scripts/probe-test-vps-recovery-runtime.sh \
  scripts/production-compose.sh scripts/run-beta-recovery-capture.sh \
  scripts/run-beta-recovery-remote-probe.sh scripts/run-beta-recovery-restore.sh \
  scripts/validate-beta-recovery-artifact-retention.sh >"$inventory"
while IFS= read -r file; do
  [ -f "$root/$file" ] || fail "tooling inventory file is missing: $file"
done <"$inventory"
printf '%s\n' \
  'beta recovery semantic route fixture passed' \
  'public-gates=selection,pre-probe,isolated-restore,cleanup,post-probe,evidence' \
  'assertions=source-binding,ordered-custody,marker-cleanup,foreign-survivors,retention,equality,secret-free'
