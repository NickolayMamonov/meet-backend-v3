#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
workflow=.github/workflows/deploy-test-vps.yml
deploy=scripts/deploy-test-vps-release.sh
runtime=scripts/test-vps-runtime-invariants.sh
provider_deploy=scripts/deploy-test-vps-provider-release.sh
provider_helper=scripts/test-vps-provider-credential.py
provider_tests=scripts/test-test-vps-provider-credential.py
provider_runtime=scripts/test-test-vps-provider-runtime.sh
retention_fixture=scripts/test-test-vps-retention.sh
public_probes=scripts/test-test-vps-public-probes.sh
baseline=6b0bc309eb00c2c3b0628f4fd86f61e60a26d79d

[ -f "$workflow" ] && [ -f "$deploy" ] && [ -f "$runtime" ] &&
  [ -f "$provider_deploy" ] && [ -f "$provider_helper" ] &&
  [ -f "$provider_tests" ] && [ -f "$provider_runtime" ] &&
  [ -f "$retention_fixture" ] && [ -f "$public_probes" ]
workflow_text=$(<"$workflow")
deploy_text=$(<"$deploy")
runtime_text=$(<"$runtime")
provider_deploy_text=$(<"$provider_deploy")
provider_helper_text=$(<"$provider_helper")
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
  'timeout 900s ssh' \
  'timeout 60s scp' \
  'ServerAliveInterval 5' \
  'ServerAliveCountMax 2' \
  'scripts/deploy-test-vps-release.sh' \
  'scripts/test-vps-runtime-invariants.sh' \
  '[ "$status" -eq 86 ]' \
  'rollback=completed previous_image_id=' \
  '--mode deploy' \
  'https://api.whysoezzy.online' \
  '--public-url "$PUBLIC_URL"' \
  'running_containers=$(timeout 30s docker ps -q' \
  'timeout 30s docker inspect "$container"' \
  'timeout 30s python3 "$tooling/scripts/test-vps-provider-credential.py"' \
  'if timeout 1s sh -c' \
  'Apply bounded test-VPS deployment retention' \
  'docker compose --project-directory "$root"' \
  '--protected-path' \
  '--protected-state' \
  'RECOVERY_REQUIRED' \
  'find "$path" -xdev -type f -delete' \
  'index=10' \
  'retention=applied'; do
  require "$text" "$workflow_text" "test VPS workflow"
done

for text in \
  'scripts/deploy-test-vps-provider-release.sh' \
  'scripts/test-vps-provider-credential.py' \
  'python3' \
  'provider_release_main' \
  'APP_PUSH_MAINTENANCE_ENABLED' \
  'credentialMountReadOnly' \
  'verify_public_contract' \
  'verify_production_env_settings' \
  'validate_active_files_before_writers' \
  'verify_predecessor_before_writers' \
  'timeout 10s stat -Lc' \
  'PROVIDER_STATE_INVALID' \
  'RECOVERY_REQUIRED'; do
  require "$text" "$workflow_text$provider_deploy_text$provider_helper_text" \
    "release-first provider lane"
done
if timeout 1s sh -c 'sleep 2' >/dev/null 2>&1; then
  echo "timeout capability fixture unexpectedly completed" >&2
  exit 1
else
  timeout_status=$?
  [ "$timeout_status" -eq 124 ] ||
    { echo "timeout capability fixture returned an unexpected status" >&2; exit 1; }
fi
! grep -Fq '$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-final' "$workflow" ||
  { echo "final deployment uses a noncanonical retention run key" >&2; exit 1; }
tooling_line=$(grep -nF 'tooling_removed=0' "$workflow" | cut -d: -f1 | head -n 1)
helper_line=$(grep -nF 'timeout 30s python3 "$tooling/scripts/test-vps-provider-credential.py"' \
  "$workflow" | cut -d: -f1 | head -n 1)
[ "$helper_line" -lt "$tooling_line" ]
require '_verify_created_publication' "$provider_helper_text" \
  "created credential publication witness"
require 'durable_disposition=$(timeout 5s jq -er' "$provider_deploy_text" \
  "authoritative durable disposition"
require '--state-root "$state_root" --phase predecessor' "$provider_deploy_text" \
  "pre-writer provider revalidation"
case "$provider_deploy_text" in
  *durable_existed=*)
    echo "shell durable existence probe remains authoritative" >&2
    exit 1
    ;;
esac
case "$provider_helper_text" in
  *--filesystem-root*)
    echo "production helper exposes a filesystem-root override" >&2
    exit 1
    ;;
esac
require 'timeout 1s sh -c' "$provider_deploy_text" "timeout capability preflight"
! grep -Fq 'meetings.json' "$workflow" ||
  { echo "raw meetings body capture remains in workflow" >&2; exit 1; }
! grep -Fq '"$REMOTE_TOOLING/scripts/deploy-test-vps-release.sh"' "$workflow" ||
  { echo "workflow still invokes frozen legacy coordinator" >&2; exit 1; }

for frozen in \
  .github/workflows/promote-dev-digest-to-test-vps.yml \
  scripts/deploy-test-vps-release.sh \
  scripts/test-vps-runtime-invariants.sh \
  scripts/production-compose.sh \
  scripts/update-production-release.sh; do
  git diff --quiet "$baseline" -- "$frozen" ||
    { echo "frozen release/promotion file changed: $frozen" >&2; exit 1; }
done

python3 -B "$provider_tests"
timeout 120s bash "$public_probes"

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

# shellcheck source=scripts/deploy-test-vps-provider-release.sh
source "$provider_deploy"
printf '%s\n' \
  'APP_PUSH_PROVIDER_ENABLED=false' \
  'APP_PUSH_PROJECT_ID=meeting-1d258' \
  >"$tmp/valid.env"
verify_production_env_settings "$tmp/valid.env"
printf '%s\n' \
  'APP_PUSH_PROVIDER_ENABLED=false' \
  'APP_PUSH_PROVIDER_ENABLED=false' \
  >"$tmp/duplicate.env"
if verify_production_env_settings "$tmp/duplicate.env"; then
  fail "duplicate relevant environment setting was accepted"
fi
for duplicate_key in \
  APP_PUSH_PROVIDER_ENABLED \
  APP_PUSH_DISCOVERY_ENABLED \
  APP_PUSH_DISPATCH_ENABLED \
  APP_PUSH_DIAGNOSTIC_ENABLED \
  APP_PUSH_MAINTENANCE_ENABLED \
  APP_PUSH_PROJECT_ID \
  APP_PUSH_CREDENTIALS_FILE; do
  printf '%s\n%s\n' \
    "$duplicate_key=first" "$duplicate_key=first" \
    >"$tmp/duplicate-$duplicate_key.env"
  if verify_production_env_settings "$tmp/duplicate-$duplicate_key.env"; then
    fail "same-value duplicate was accepted for $duplicate_key"
  fi
  printf '%s\n%s\n' \
    "$duplicate_key=first" "$duplicate_key=second" \
    >"$tmp/conflicting-$duplicate_key.env"
  if verify_production_env_settings "$tmp/conflicting-$duplicate_key.env"; then
    fail "conflicting duplicate was accepted for $duplicate_key"
  fi
done
printf '%s\n' \
  'APP_PUSH_PROVIDER_ENABLED=false' \
  'SPRING_CONFIG_NAME=evil' \
  >"$tmp/alternate.env"
if verify_production_env_settings "$tmp/alternate.env"; then
  fail "alternate Spring configuration setting was accepted"
fi
printf '%s\n' \
  'APP_PUSH_PROVIDER_ENABLED=false' \
  'JAVA_TOOL_OPTIONS=-Dspring.config.name=evil' \
  >"$tmp/java-alternate.env"
if verify_production_env_settings "$tmp/java-alternate.env"; then
  fail "Java alternate Spring configuration setting was accepted"
fi
if python3 -B "$provider_helper" check --root "$tmp" >/dev/null 2>&1; then
  fail "provider helper filesystem-root override remains exposed"
fi

active_fixture="$tmp/active-runtime"
active_state="$tmp/active-state"
mkdir -p "$active_state"
printf 'predecessor\n' >"$active_fixture"
# shellcheck disable=SC2034
state="$active_state"
active_compose="$active_fixture"
active_runtime="$tmp/unused-runtime"
snapshot_active_file "$active_fixture" compose
validate_active_files_before_writers
printf 'candidate\n' >"$active_state/candidate-compose"
timeout 30s mv -- "$active_state/candidate-compose" "$active_fixture"
record_candidate_active_file "$active_fixture" compose
printf 'unknown\n' >"$active_state/unknown-compose"
timeout 30s mv -- "$active_state/unknown-compose" "$active_fixture"
set +e
(restore_active_file "$active_fixture" compose) >"$tmp/restore-output" 2>&1
restore_status=$?
set -e
[ "$restore_status" -ne 0 ]
grep -Fq 'RECOVERY_REQUIRED' "$tmp/restore-output"
missing_fixture="$tmp/missing-runtime"
missing_state="$tmp/missing-state"
mkdir -p "$missing_state"
printf 'predecessor\n' >"$missing_fixture"
state="$missing_state"
active_compose="$missing_fixture"
active_runtime="$tmp/unused-runtime"
snapshot_active_file "$missing_fixture" compose
rm -f -- "$missing_fixture"
set +e
(restore_active_file "$missing_fixture" compose) >"$tmp/missing-output" 2>&1
missing_status=$?
set -e
[ "$missing_status" -ne 0 ]
grep -Fq 'RECOVERY_REQUIRED' "$tmp/missing-output"
modified_fixture="$tmp/modified-runtime"
modified_state="$tmp/modified-state"
mkdir -p "$modified_state"
printf 'predecessor\n' >"$modified_fixture"
state="$modified_state"
active_compose="$modified_fixture"
active_runtime="$tmp/unused-runtime"
snapshot_active_file "$modified_fixture" compose
printf 'modified\n' >"$modified_fixture"
set +e
(validate_active_files_before_writers) >"$tmp/modified-output" 2>&1
modified_status=$?
set -e
[ "$modified_status" -ne 0 ]
grep -Fq 'PROVIDER_STATE_INVALID' "$tmp/modified-output"
if [ "$(uname -s)" = Linux ]; then
  symlink_fixture="$active_state/symlink"
  ln -s "$active_state/missing" "$symlink_fixture"
  set +e
  (snapshot_active_file "$symlink_fixture" compose) >"$tmp/symlink-output" 2>&1
  symlink_status=$?
  set -e
  [ "$symlink_status" -ne 0 ]
  grep -Fq 'PROVIDER_STATE_INVALID' "$tmp/symlink-output"
fi

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

if [ "$(uname -s)" = Linux ] && [ "$(id -u)" -eq 0 ]; then
  timeout 300s bash "$retention_fixture"
fi

case "$workflow_text"$'\n'"$deploy_text" in
  *'rm -rf'*) echo "test VPS deployment must not recursively delete host state" >&2; exit 1 ;;
esac

cleanup_line=$(awk '/name: Apply bounded test-VPS deployment retention/{print NR; exit}' "$workflow")
evidence_line=$(awk '/name: Capture runtime and public HTTPS evidence/{print NR; exit}' "$workflow")
[ "$evidence_line" -lt "$cleanup_line" ]

echo "test VPS deploy workflow fixture passed"
