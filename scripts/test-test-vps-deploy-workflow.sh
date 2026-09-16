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
# shellcheck source=scripts/deploy-test-vps-release.sh
source "$deploy"

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
require 'is_supported_test_vps_version "$version"' "$deploy_text" \
  "test VPS target floor"
require 'is_supported_test_vps_version "$previous_version"' "$deploy_text" \
  "test VPS predecessor floor"

tmp=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$tmp"
  exit "$status"
}
trap cleanup EXIT

for version in 1.2.0 1.2.1 1.10.0 2.0.0; do
  is_supported_test_vps_version "$version" ||
    fail "supported numeric version was rejected: $version"
done
for version in 1.0.1 1.1.0 1.1.99 01.2.0 1.2; do
  if is_supported_test_vps_version "$version"; then
    fail "unsupported or malformed numeric version was accepted: $version"
  fi
done

invalid_state_root=$tmp/invalid-target-state
if TEST_VPS_STATE_ROOT="$invalid_state_root" bash "$deploy" \
  --root /missing-root \
  --base-compose /missing-compose.yml \
  --image ghcr.io/nickolaymamonov/meet-backend-v3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --revision 0123456789abcdef0123456789abcdef01234567 \
  --version 1.1.99 \
  --run-key invalid-target \
  --mode deploy >"$tmp/invalid-target.stdout" 2>"$tmp/invalid-target.stderr"; then
  fail "pre-floor target was accepted"
fi
grep -Fq 'target version must be at least v1.2.0' "$tmp/invalid-target.stderr" ||
  fail "pre-floor target did not fail at the numeric floor gate"
[ ! -e "$invalid_state_root" ] ||
  fail "pre-floor target created deployment state before rejection"

state_writer_line=$(awk '/install -d -m 700 "\$state_root"/{print NR; exit}' "$deploy")
mutation_line=$(awk '/mutation_started=true/{print NR; exit}' "$deploy")
target_line=$(awk '/is_supported_test_vps_version "\$version"/{print NR; exit}' "$deploy")
predecessor_line=$(awk '/is_supported_test_vps_version "\$previous_version"/{print NR; exit}' "$deploy")
predecessor_state_line=$(awk '/previous-image"/{print NR; exit}' "$deploy")
compose_write_line=$(awk '/install -m 600 "\$base_compose"/{print NR; exit}' "$deploy")
update_line=$(awk '/"\$update_script" "\$image"/{print NR; exit}' "$deploy")
[ "$target_line" -lt "$state_writer_line" ] &&
  [ "$target_line" -lt "$mutation_line" ] &&
  [ "$predecessor_line" -lt "$predecessor_state_line" ] &&
  [ "$predecessor_line" -lt "$mutation_line" ] &&
  [ "$predecessor_line" -lt "$compose_write_line" ] &&
  [ "$predecessor_line" -lt "$update_line" ] ||
  fail "deployment floor checks are ordered after a protected writer"

require 'runtime_check=network' "$runtime_text" "shared runtime helper"

case "$workflow_text"$'\n'"$deploy_text" in
  *'rm -rf'*) echo "test VPS deployment must not recursively delete host state" >&2; exit 1 ;;
esac

cleanup_line=$(awk '/name: Apply bounded test-VPS deployment retention/{print NR; exit}' "$workflow")
evidence_line=$(awk '/name: Capture runtime and public HTTPS evidence/{print NR; exit}' "$workflow")
[ "$evidence_line" -lt "$cleanup_line" ]

echo "test VPS deploy workflow fixture passed"
