#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DEPLOY=$ROOT_DIR/scripts/deploy-test-vps-release.sh
PROVIDER_DEPLOY=$ROOT_DIR/scripts/deploy-test-vps-provider-release.sh
PROMOTION=$ROOT_DIR/.github/workflows/promote-dev-digest-to-test-vps.yml

bash -n "$DEPLOY"
bash -n "$PROVIDER_DEPLOY"
[ -f "$ROOT_DIR/scripts/test-vps-provider-credential.py" ]
[ -f "$ROOT_DIR/scripts/test-test-vps-provider-credential.py" ]
[ -f "$ROOT_DIR/scripts/test-test-vps-provider-runtime.sh" ]
[ -f "$PROMOTION" ]
! grep -Fq 'deploy-test-vps-provider-release.sh' "$PROMOTION"
! grep -Fq 'test-vps-provider-credential.py' "$PROMOTION"
! grep -Fq '.provider-transaction.current' "$PROMOTION"
grep -Fq -- '--closed-beta-safety' "$DEPLOY"
grep -Fq 'safety_hook=$script_dir/verify-test-vps-closed-beta-state.sh' "$DEPLOY"
grep -Fq 'run_safety_hook predecessor' "$DEPLOY"
grep -Fq 'run_safety_hook candidate' "$DEPLOY"
grep -Fq 'run_safety_hook rollback' "$DEPLOY"
grep -Fq 'run_safety_hook final' "$DEPLOY"
grep -Fq 'flock -n 9' "$DEPLOY"
grep -Fq 'rollback drill requires a target image distinct from the predecessor' "$DEPLOY"
grep -Fq 'exit 86' "$DEPLOY"
grep -Fq 'mutation_started=false' "$DEPLOY"
! grep -Fq 'gh release' "$DEPLOY"
! grep -Fq 'docker push' "$DEPLOY"
echo "test VPS closed-beta deployment fixture passed: lock, hooks, exact digest, rollback, exit-86, and caller compatibility"
