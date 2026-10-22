#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
provider_release_script=${PROVIDER_RELEASE_SCRIPT:-$ROOT_DIR/scripts/deploy-test-vps-provider-release.sh}

if [ "$(uname -s)" != Linux ] || [ "$(id -u)" -ne 0 ]; then
  echo "PREREQUISITE_MISSING" >&2
  exit 77
fi

fixture=$(mktemp -d /root/meet-provider-startup.XXXXXX)
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$fixture"
  exit "$status"
}
trap cleanup EXIT

fake_bin=$fixture/bin
mkdir -p "$fake_bin"
cat >"$fake_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$TRACE_FILE"
command_name=${1:-}
image=${3:-}
format=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --format ]; then
    shift
    format=${1:-}
    break
  fi
  shift
done
case "$command_name" in
  image)
    printf 'parsed image=%s format=%s previous=%s id=%s\n' \
      "$image" "$format" "$PREVIOUS_IMAGE" "$PREVIOUS_ID" >>"$TRACE_FILE"
    if [ "$image" = "$PREVIOUS_IMAGE" ]; then
      case "$format" in
        *'.Id'*) printf '%s\n' "$PREVIOUS_ID" ;;
        *) exit 1 ;;
      esac
    else
      # The intentional failure occurs only after provider marker publication.
      exit 1
    fi
    ;;
  inspect)
    case "$format" in
      *'config-hash'*) printf '%s\n' "$RUNTIME_HASH" ;;
      *'Config.Env'*) printf '%s\n' "$PROVIDER_INSPECT" | jq -r '.Config.Env[]' ;;
      *) printf '%s\n' "$PROVIDER_INSPECT" ;;
    esac
    ;;
  *) exit 1 ;;
esac
DOCKER
chmod 700 "$fake_bin/docker"
cat >"$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "unexpected curl invocation in pre-mutation startup fixture" >&2
exit 1
CURL
chmod 700 "$fake_bin/curl"

fixture_fail() {
  local message=$1
  echo "provider startup fixture failed: $message" >&2
  for diagnostic in "$run_dir/stderr" "$run_dir/stdout" "$trace" "$pointer"; do
    if [ -f "$diagnostic" ]; then
      echo "--- $diagnostic" >&2
      sed -n '1,160p' "$diagnostic" >&2
    fi
  done
  echo "--- state root: $state_root" >&2
  find "$state_root" -maxdepth 2 -printf '%M %p\n' >&2
  exit 1
}

previous_image=ghcr.io/nickolaymamonov/meet-backend-v3@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
previous_id=sha256:0000000000000000000000000000000000000000000000000000000000000000
target_image=ghcr.io/nickolaymamonov/meet-backend-v3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
source_sha=0123456789abcdef0123456789abcdef01234567
runtime_hash=1111111111111111111111111111111111111111111111111111111111111111

for provider_enabled in false true; do
  run_dir=$fixture/$provider_enabled
  root=$run_dir/root
  state_root=$run_dir/state
  production_state=$run_dir/active-state
  run_key=920027-1
  pointer=$state_root/.provider-transaction.current
  mkdir -p "$root" "$production_state"
  cat >"$root/.env.production" <<ENV
BACKEND_IMAGE=$previous_image
BACKEND_REVISION=$source_sha
BACKEND_VERSION=1.2.0
APP_PUSH_PROVIDER_ENABLED=$provider_enabled
APP_PUSH_DISCOVERY_ENABLED=false
APP_PUSH_DISPATCH_ENABLED=false
APP_PUSH_DIAGNOSTIC_ENABLED=false
APP_PUSH_MAINTENANCE_ENABLED=false
APP_PUSH_PROJECT_ID=meeting-1d258
APP_PUSH_CREDENTIALS_FILE=$([ "$provider_enabled" = true ] && echo /run/secrets/meet-firebase-service-account.json || true)
ENV
  printf 'services:\n  backend:\n    image: ${BACKEND_IMAGE}\n' >"$root/docker-compose.production.yml"
  printf 'services:\n  backend:\n    image: ${BACKEND_IMAGE}\n' >"$run_dir/target-compose.yml"
  printf 'services: {}\n' >"$production_state/active-compose.yml"
  printf 'services: {}\n' >"$production_state/active-runtime.override.yml"
  trace=$run_dir/docker.log
  provider_inspect=$(
    jq -cn \
      --arg enabled "$provider_enabled" \
      --arg previous_image "$previous_image" \
      --arg source_sha "$source_sha" '
      {
        Config: {
          Env: [
            ("BACKEND_IMAGE=" + $previous_image),
            ("BACKEND_REVISION=" + $source_sha),
            "BACKEND_VERSION=1.2.0",
            ("APP_PUSH_PROVIDER_ENABLED=" + $enabled),
            "APP_PUSH_DISCOVERY_ENABLED=false",
            "APP_PUSH_DISPATCH_ENABLED=false",
            "APP_PUSH_DIAGNOSTIC_ENABLED=false",
            "APP_PUSH_MAINTENANCE_ENABLED=false",
            "APP_PUSH_PROJECT_ID=meeting-1d258",
            (if $enabled == "true"
             then "APP_PUSH_CREDENTIALS_FILE=/run/secrets/meet-firebase-service-account.json"
             else "APP_PUSH_CREDENTIALS_FILE="
             end)
          ]
        },
        Mounts: (
          if $enabled == "true"
          then [{
            Type: "bind",
            Source: "/isolated/fake-provider-credential.json",
            Destination: "/run/secrets/meet-firebase-service-account.json",
            RW: false
          }]
          else []
          end
        )
      }'
  )

  if [ "${SKIP_STARTUP_CASES:-false}" != true ]; then
    set +e
    PATH="$fake_bin:$PATH" \
      TEST_VPS_STATE_ROOT="$state_root" \
      PRODUCTION_STATE_DIR="$production_state" \
      MEE_SMTP_FAKE_REMOTE=true \
      TRACE_FILE="$trace" \
      PREVIOUS_IMAGE="$previous_image" \
      PREVIOUS_ID="$previous_id" \
      PROVIDER_INSPECT="$provider_inspect" \
      RUNTIME_HASH="$runtime_hash" \
      bash "$provider_release_script" \
        --root "$root" \
        --base-compose "$run_dir/target-compose.yml" \
        --image "$target_image" \
        --revision "$source_sha" \
        --version 1.3.0 \
        --run-key "$run_key" \
        --mode deploy \
        --failure-policy manual-stop \
        >"$run_dir/stdout" 2>"$run_dir/stderr"
    status=$?
    set -e

    [ "$status" -eq 1 ] ||
      fixture_fail "expected target-image admission failure with exit 1; got $status"
    grep -Fq 'test VPS deployment failed: PROVIDER_STATE_INVALID' "$run_dir/stderr" ||
      fixture_fail "actual CLI did not reach the intentional target-image failure"
    ! grep -Fq 'command not found' "$run_dir/stderr" ||
      fixture_fail "startup called an undefined coordinator helper"
    [ -f "$pointer" ] && [ ! -L "$pointer" ] ||
      fixture_fail "preparing marker was not published"
    jq -e --arg key "$run_key" --argjson enabled "$provider_enabled" '
      .schemaVersion == 1 and .runKey == $key and
      .phase == "preparing" and .providerEnabled == $enabled and
      .durableDisposition == "none"
    ' "$pointer" >/dev/null ||
      fixture_fail "preparing marker does not contain the expected recovery evidence"
    [ "$(stat -c '%a' "$pointer")" = 600 ] ||
      fixture_fail "preparing marker permissions are not 0600"
    ! grep -Eq '^docker (compose|run|start|stop|rm|volume|network)' "$trace" ||
      fixture_fail "failure injection unexpectedly mutated or stopped the backend"
    [ -d "$state_root/$run_key-final-deploy" ] ||
      fixture_fail "transaction recovery directory was not retained"
  fi
done

signal_bin=$fixture/signal-bin
mkdir -p "$signal_bin"
cat >"$signal_bin/python3" <<'PYTHON'
#!/usr/bin/env bash
set -euo pipefail
printf 'provider_helper command=%s phase=%s\n' "${2:-}" "${8:-}" >>"$TRACE_FILE"
[ "${2:-}" = verify ] && [ "${8:-}" = predecessor ]
[ "$FAIL_PROOF" = false ]
PYTHON
chmod 700 "$signal_bin/python3"

cat >"$fixture/cleanup-signal-harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
source "$PROVIDER_RELEASE_SCRIPT"

compose() {
  printf 'compose %s\n' "$*" >>"$TRACE_FILE"
  [ "$*" = 'ps -q backend' ] || return 1
  printf 'backend-container\n'
}
docker_container_inspect() {
  printf 'docker_inspect %s\n' "$1" >>"$TRACE_FILE"
  printf '{"Config":{"Env":[]}}'
}
runtime_invariants_bounded() {
  echo "runtime_invariants" >>"$TRACE_FILE"
}
runtime_environment_bounded() {
  echo "runtime_environment" >>"$TRACE_FILE"
}
rollback() {
  echo "rollback" >>"$TRACE_FILE"
  return 1
}
provider_finish() {
  printf 'provider_finish outcome=%s\n' "$1" >>"$TRACE_FILE"
  rm -f -- "$provider_pointer"
}

root=/isolated/read-only-proof
script_dir=/isolated/scripts
provider_helper=/isolated/provider-helper.py
run_key=920027-2
state_root=$CASE_STATE_ROOT
provider_pointer=$state_root/.provider-transaction.current
previous_id=sha256:0000000000000000000000000000000000000000000000000000000000000000
previous_revision=0123456789abcdef0123456789abcdef01234567
previous_version=1.2.0
previous_runtime_hash=1111111111111111111111111111111111111111111111111111111111111111
previous_inspect='{"Config":{"Env":[]}}'
public_url=
cleanup_inspect=
mutation_started=false
credential_prepared=true
rollback_complete=false
failure_policy=manual-stop

# Mirror the production signal/exit trap dispatch after preparation but before
# any writer starts. The EXIT handler and predecessor proof remain production
# functions sourced above. Only read-only dependencies and provider_finish are
# stubbed; the earlier CLI cases exercise the real provider credential helper.
trap provider_release_on_exit EXIT
trap 'exit 143' TERM INT HUP
kill -s "$SIGNAL_NAME" "$BASHPID"
HARNESS
chmod 700 "$fixture/cleanup-signal-harness.sh"

for signal_name in TERM INT HUP; do
  for fail_proof in false true; do
    signal_case=$fixture/signal-$signal_name-$fail_proof
    signal_state=$signal_case/state
    signal_trace=$signal_case/trace.log
    run_dir=$signal_case
    trace=$signal_trace
    pointer=$signal_state/.provider-transaction.current
    state_root=$signal_state
    mkdir -p "$signal_state"
    printf '{"phase":"prepared"}\n' >"$signal_state/.provider-transaction.current"
    chmod 600 "$signal_state/.provider-transaction.current"
    set +e
    PATH="$signal_bin:$PATH" \
      PROVIDER_RELEASE_SCRIPT="$provider_release_script" \
      CASE_STATE_ROOT="$signal_state" \
      TRACE_FILE="$signal_trace" \
      SIGNAL_NAME="$signal_name" \
      FAIL_PROOF="$fail_proof" \
      bash "$fixture/cleanup-signal-harness.sh" \
      >"$signal_case/stdout" 2>"$signal_case/stderr"
    status=$?
    set -e

    [ "$status" -eq 143 ] && [ "$fail_proof" = false ] ||
      { [ "$status" -eq 1 ] && [ "$fail_proof" = true ]; } ||
      fixture_fail "signal $signal_name with proof failure=$fail_proof exited $status"
    grep -Fq 'provider_helper command=verify phase=predecessor' "$signal_trace" ||
      fixture_fail "signal $signal_name did not reach predecessor verification"
    [ "$(grep -c '^compose ps -q backend$' "$signal_trace")" -eq 2 ] ||
      fixture_fail "signal $signal_name did not complete both predecessor identity reads"
    [ "$(grep -c '^docker_inspect backend-container$' "$signal_trace")" -eq 2 ] ||
      fixture_fail "signal $signal_name did not inspect the predecessor twice"
    grep -Fq 'runtime_invariants' "$signal_trace" ||
      fixture_fail "signal $signal_name skipped predecessor runtime invariants"
    grep -Fq 'runtime_environment' "$signal_trace" ||
      fixture_fail "signal $signal_name skipped predecessor environment proof"
    ! grep -Eq '^(compose stop|rollback|provider_release_stop_backend)' "$signal_trace" ||
      fixture_fail "signal $signal_name attempted backend stop or rollback"
    ! grep -Fq 'command not found' "$signal_case/stderr" ||
      fixture_fail "signal $signal_name dispatched to an undefined cleanup helper"
    if [ "$fail_proof" = false ]; then
      grep -Fq 'provider_finish outcome=rolled-back' "$signal_trace" ||
        fixture_fail "successful signal cleanup proof did not finish the transaction"
      [ ! -e "$signal_state/.provider-transaction.current" ] ||
        fixture_fail "successful signal cleanup left the transaction marker"
    else
      ! grep -Fq 'provider_finish ' "$signal_trace" ||
        fixture_fail "failed predecessor proof incorrectly finished cleanup"
      [ -f "$signal_state/.provider-transaction.current" ] ||
        fixture_fail "failed predecessor proof did not preserve the recovery marker"
      grep -Fq 'RECOVERY_REQUIRED' "$signal_case/stderr" ||
        fixture_fail "failed predecessor proof did not fail closed"
    fi
  done
done

echo "provider startup fixture passed: CLI startup marker publication and TERM/INT/HUP cleanup dispatch with successful and failed predecessor proofs"
