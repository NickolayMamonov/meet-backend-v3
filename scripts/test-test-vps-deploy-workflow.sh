#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
workflow=.github/workflows/deploy-test-vps.yml
deploy=scripts/deploy-test-vps-release.sh
runtime=scripts/test-vps-runtime-invariants.sh

[ -f "$workflow" ] && [ -f "$deploy" ] && [ -f "$runtime" ]
workflow_text=$(<"$workflow")
deploy_text=$(<"$deploy")
runtime_text=$(<"$runtime")

require() {
  local needle=$1
  local haystack=$2
  local label=$3
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "$label misses invariant: $needle" >&2
      exit 1
      ;;
  esac
}

for text in \
  'workflow_dispatch:' \
  "if: github.ref == 'refs/heads/dev'" \
  'name: test-vps' \
  'scripts/verify-immutable-release-proof.sh' \
  'scripts/verify-release-checksums.sh' \
  '--allow-immutable-v1.2.0-compact' \
  'cmp -s "$release_dir/image-index.json"' \
  'grep -Ec "^Digest:[[:space:]]+$digest$"' \
  'gh attestation verify "oci://$IMAGE@$digest"' \
  'ssh-keyscan -T 5 -p "$PORT" "$HOST"' \
  'ssh-keygen -lf - -E sha256' \
  'scripts/deploy-test-vps-release.sh' \
  'scripts/test-vps-runtime-invariants.sh' \
  '[ "$status" -eq 86 ]' \
  'rollback=completed previous_image_id=' \
  '--mode deploy' \
  'https://api.whysoezzy.online' \
  'Apply bounded test-VPS deployment retention' \
  'find "$path" -xdev -type f -delete' \
  'index=10' \
  'retention=applied'; do
  require "$text" "$workflow_text" "test VPS workflow"
done

for text in \
  'smtp_pointer="$state_root/.smtp-transaction.current"' \
  'if [ -e "$smtp_pointer" ] || [ -L "$smtp_pointer" ]' \
  'retention=skipped smtp_transaction_present'; do
  require "$text" "$workflow_text" "test VPS workflow SMTP interlock"
done

for stale in \
  "refs/heads/master" \
  '      name: production' \
  'backup-production.sh' \
  'PRODUCTION_SSH_PRIVATE_KEY' \
  ':latest'; do
  case "$workflow_text" in
    *"$stale"*)
      echo "test VPS workflow contains prohibited production construct: $stale" >&2
      exit 1
      ;;
  esac
done

verify_line=$(awk '/scripts\/verify-immutable-release-proof\.sh/{print NR; exit}' "$workflow")
ssh_line=$(awk '/ssh-keyscan -T 5/{print NR; exit}' "$workflow")
[ "$verify_line" -lt "$ssh_line" ]

for text in \
  'trap on_exit EXIT' \
  'rollback()' \
  'rollback=completed previous_image_id=' \
  'restored_hash' \
  'previous_runtime_hash' \
  'rollback drill requires a target image distinct from the predecessor' \
  'http://127.0.0.1:8080/meetings' \
  '--no-deps --no-build --pull never --force-recreate' \
  'deployment=completed image_id='; do
  require "$text" "$deploy_text" "test VPS deploy script"
done
require 'runtime_check=network' "$runtime_text" "shared runtime helper"

case "$workflow_text"$'\n'"$deploy_text" in
  *'rm -rf'*) echo "test VPS deployment must not recursively delete host state" >&2; exit 1 ;;
esac

cleanup_line=$(awk '/name: Apply bounded test-VPS deployment retention/{print NR; exit}' "$workflow")
evidence_line=$(awk '/name: Capture runtime and public HTTPS evidence/{print NR; exit}' "$workflow")
[ "$evidence_line" -lt "$cleanup_line" ]

echo "test VPS deploy workflow fixture passed"
