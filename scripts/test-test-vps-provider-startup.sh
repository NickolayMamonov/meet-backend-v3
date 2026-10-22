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
done

echo "provider startup fixture passed: real CLI published preparing markers for enabled and disabled provider observations before target-image failure"
