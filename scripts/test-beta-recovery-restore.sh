#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/run-beta-recovery-restore.sh
grep -Fq 'postgres:16-alpine@sha256:' "$script"
grep -Fq 'temp_required=' "$script"
grep -Fq 'docker_required=' "$script"
grep -Fq 'docker network create --internal' "$script"
grep -Fq 'docker container rm --force --volumes' "$script"
grep -Fq 'docker volume rm' "$script"
grep -Fq 'volume.identity' "$script"
grep -Fq 'pg_restore --list' "$script"
grep -Fq 'cmp -- "$expected_db"' "$script"
if awk '/restore-isolated:/{flag=1} /restore-post-probe:/{flag=0} flag' \
  "$root/.github/workflows/prove-beta-backup-restore.yml" |
  grep -Eq 'TEST_VPS_HOST|TEST_VPS_SSH_PRIVATE_KEY'; then
  echo "isolated restore job has VPS custody" >&2
  exit 1
fi
echo "beta recovery restore contract passed"
