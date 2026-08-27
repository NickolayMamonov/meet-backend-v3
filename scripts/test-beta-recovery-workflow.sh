#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workflow=$root/.github/workflows/prove-beta-backup-restore.yml
[ -f "$workflow" ] || exit 1
command -v jq >/dev/null 2>&1
grep -Fq 'workflow_dispatch:' "$workflow"
if grep -Eq '^[[:space:]]+(push|pull_request|schedule):' "$workflow"; then exit 1; fi
grep -Fq 'cancel-in-progress: false' "$workflow"
grep -Fq 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' "$workflow"
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$workflow"
grep -Fq 'retention-days: 30' "$workflow"
grep -Fq 'closed-beta-restore' "$workflow"
grep -Fq 'restore-pre-probe' "$workflow"
grep -Fq 'restore-post-probe' "$workflow"
grep -Fq 'run-beta-recovery-restore.sh' "$workflow"
grep -Fq 'BETA_RECOVERY_AGE_IDENTITY' "$workflow"
if awk '/restore-isolated:/{flag=1} /restore-post-probe:/{flag=0} flag' "$workflow" |
  grep -Eq 'TEST_VPS|SSH_PRIVATE_KEY|TEST_VPS_HOST'; then
  echo "isolated restore job has VPS custody" >&2
  exit 1
fi
if awk '/restore-pre-probe:/{flag=1} /restore-isolated:/{flag=0} flag' "$workflow" |
  grep -F 'BETA_RECOVERY_AGE_IDENTITY'; then
  echo "pre-probe job has age identity" >&2
  exit 1
fi
if awk '/restore-post-probe:/{flag=1} /evidence:/{flag=0} flag' "$workflow" |
  grep -F 'BETA_RECOVERY_AGE_IDENTITY'; then
  echo "post-probe job has age identity" >&2
  exit 1
fi
echo "beta recovery workflow fixture passed"
