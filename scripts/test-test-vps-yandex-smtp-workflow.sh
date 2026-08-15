#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
workflow=.github/workflows/configure-test-vps-yandex-smtp.yml
release_workflow=.github/workflows/deploy-test-vps.yml
tool=scripts/configure-test-vps-yandex-smtp.sh
[ -f "$workflow" ] && [ -f "$release_workflow" ] && [ -f "$tool" ]
workflow_text=$(<"$workflow")
tool_text=$(<"$tool")

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
  'workflow_dispatch:' \
  "if: github.ref == 'refs/heads/dev'" \
  'name: test-vps' \
  'contents: read' \
  'TEST_VPS_SSH_PRIVATE_KEY' \
  'TEST_VPS_SMTP_FROM' \
  'TEST_VPS_SMTP_PASSWORD' \
  'smtp.yandex.ru' \
  'printf '\''APP_EMAIL_PROVIDER=smtp\0'\''' \
  'chmod 600 "$payload"' \
  'ssh-keyscan -T 5 -p "$PORT" "$HOST"' \
  'ssh-keygen -lf - -E sha256' \
  'continue-on-error: true' \
  'protocol_valid=false' \
  'SMTP_PROTOCOL_VALID' \
  'MEE_SMTP_RESULT=' \
  'deploy_succeeded:0' \
  'precheck_failed:20' \
  'lock_busy:21' \
  'deploy_failed_rollback_succeeded:22' \
  'deploy_failed_rollback_failed:23' \
  'Safe SMTP summary' \
  'Cleanup SMTP transport' \
  'Enforce transaction result'; do
  require "$text" "$workflow_text" "SMTP workflow"
done

for stale in \
  'PRODUCTION_SSH_PRIVATE_KEY' \
  ':latest' \
  'set -x' \
  'cat "$output"' \
  'echo "$SMTP_PASSWORD"'; do
  case "$workflow_text" in
    *"$stale"*) echo "SMTP workflow contains prohibited secret/log construct: $stale" >&2; exit 1 ;;
  esac
done

preflight_line=$(awk '/Protected SMTP preflight/{print NR; exit}' "$workflow")
network_line=$(awk '/ssh-keyscan -T 5/{print NR; exit}' "$workflow")
[ "$preflight_line" -lt "$network_line" ]

for text in \
  '.smtp-transaction.current' '.smtp-last-good.current' \
  'prior_selector=absent' 'prior_selector=present' 'critical=true' \
  'deploy_failed_rollback_succeeded' 'deploy_failed_rollback_failed' \
  'SNAPSHOTTED' 'LAST_GOOD_COMMIT_PENDING' 'COMMITTED' 'RECOVERED' \
  'pointer_unlink' 'transaction_delete' 'MEE_SMTP_RESULT=' 'lock_busy'; do
  require "$text" "$tool_text" "SMTP transaction tool"
done

echo "test VPS Yandex SMTP workflow fixture passed"
