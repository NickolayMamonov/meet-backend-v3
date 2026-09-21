#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

if [ "$(uname -s)" != Linux ] || [ "$(id -u)" -ne 0 ]; then
  echo "PREREQUISITE_MISSING" >&2
  exit 77
fi

production_state=/var/lib/meet-production
if [ -e "$production_state" ]; then
  echo "PREREQUISITE_MISSING: isolated /var/lib/meet-production is unavailable" >&2
  exit 77
fi

fixture=$(mktemp -d /tmp/meet-closed-beta-fixture.XXXXXX)
created_production=false
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$created_production" = true ] && [ -e "$production_state" ]; then
    rm -r -- "$production_state"
  fi
  rm -r -- "$fixture"
  exit "$status"
}
trap cleanup EXIT

runner_temp=$fixture/runner-temp
remote=$fixture/remote
archive=$runner_temp/test-vps-tooling.tar
fake_bin=$fixture/bin
mkdir -p "$runner_temp" "$remote" "$fake_bin"

promotion=.github/workflows/promote-dev-digest-to-test-vps.yml
stage_script=$fixture/stage.sh
awk '
  /^          stage="\$RUNNER_TEMP\/test-vps-tooling"/ { capture=1 }
  capture { sub(/^          /, ""); print }
  capture && /^tar -C "\$stage" -cf "\$RUNNER_TEMP\/test-vps-tooling\.tar" \.$/ { exit }
' "$promotion" >"$stage_script"
chmod 700 "$stage_script"

export RUNNER_TEMP="$runner_temp"
export GITHUB_WORKSPACE="$ROOT_DIR"
export GITHUB_RUN_ID=920027
export GITHUB_RUN_ATTEMPT=1
export PATH_ON_HOST="$fixture/host"
export IMAGE_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
export VERSION=1.3.0
export STATE_MODE=empty-closed
export SSH_CONFIG="$fixture/ssh-config"
mkdir -p "$PATH_ON_HOST"
printf '%s\n' 'fake ssh config' >"$SSH_CONFIG"
bash "$stage_script"
[ -f "$archive" ]

# Exercise the same archive transfer and unpack side effects with bounded fake
# SSH/SCP adapters. The file list is extracted from the frozen workflow above,
# so this fixture has no second hand-maintained archive inventory.
fake_remote=$remote/test-vps-tooling
ssh_trace=$fixture/ssh-trace.log
mkdir -p "$fake_remote"
cat >"$fake_bin/scp" <<'SCP'
#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
source=${arguments[${#arguments[@]}-2]}
destination=${arguments[${#arguments[@]}-1]#test-vps:}
printf 'scp %s -> %s\n' "$source" "$destination" >>"$FAKE_SSH_TRACE"
mkdir -p "$(dirname -- "$destination")"
cp -- "$source" "$destination"
SCP
cat >"$fake_bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >>"$FAKE_SSH_TRACE"
cat >/dev/null
if [ "${FAKE_SSH_UNPACK:-false}" = true ]; then
  tar -xf "$FAKE_REMOTE_DIR/tooling.tar" -C "$FAKE_REMOTE_DIR"
  chmod 755 "$FAKE_REMOTE_DIR"/scripts/*.sh
fi
SSH
chmod 700 "$fake_bin/scp" "$fake_bin/ssh"
PATH="$fake_bin:$PATH" FAKE_SSH_TRACE="$ssh_trace" \
  ssh -F "$SSH_CONFIG" test-vps bash -s -- "$PATH_ON_HOST" "$fake_remote" <<'REMOTE'
set -euo pipefail
REMOTE
PATH="$fake_bin:$PATH" FAKE_SSH_TRACE="$ssh_trace" \
  scp -F "$SSH_CONFIG" "$archive" "test-vps:$fake_remote/tooling.tar"
PATH="$fake_bin:$PATH" FAKE_SSH_TRACE="$ssh_trace" \
  FAKE_REMOTE_DIR="$fake_remote" FAKE_SSH_UNPACK=true \
  ssh -F "$SSH_CONFIG" test-vps bash -s -- "$fake_remote" <<'REMOTE'
set -euo pipefail
REMOTE
grep -Fq 'scp ' "$ssh_trace"
grep -Fq 'ssh ' "$ssh_trace"
staged=$fake_remote

[ -x "$staged/scripts/deploy-test-vps-release.sh" ]
[ -x "$staged/scripts/production-compose.sh" ]
[ -x "$staged/scripts/update-production-release.sh" ]
[ ! -e "$staged/scripts/deploy-test-vps-provider-release.sh" ]
[ ! -e "$staged/scripts/test-vps-provider-credential.py" ]

trace=$fixture/trace.log
fake_env=$fixture/runtime.env
fake_hash=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
previous_id=sha256:0000000000000000000000000000000000000000000000000000000000000000
target_id=sha256:1111111111111111111111111111111111111111111111111111111111111111
target_image=ghcr.io/nickolaymamonov/meet-backend-v3@sha256:$IMAGE_DIGEST
previous_image=ghcr.io/nickolaymamonov/meet-backend-v3@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\n' \
  "BACKEND_IMAGE=$previous_image" \
  "BACKEND_REVISION=$SOURCE_SHA" \
  'BACKEND_VERSION=1.2.0' >"$fake_env"

cat >"$fake_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$TRACE_FILE"
format=
for argument in "$@"; do
  case "$argument" in
    --format) format=next ;;
    *\{\{*\}\}*)
      [ "$format" = next ] && format=$argument
      ;;
    *) [ "$format" = next ] && format=$argument ;;
  esac
done
case "${1:-}" in
  image)
    image=${3:-}
    case "$format" in
      *'.Id'*) [ "$image" = "$TARGET_IMAGE" ] && printf '%s\n' "$TARGET_ID" || printf '%s\n' "$PREVIOUS_ID" ;;
      *'org.opencontainers.image.revision'*) printf '%s\n' "$SOURCE_SHA" ;;
      *'org.opencontainers.image.version'*) printf '%s\n' "$VERSION" ;;
      *'org.opencontainers.image.source'*) printf '%s\n' 'https://github.com/NickolayMamonov/meet-backend-v3' ;;
      *'.Config.User'*) printf '%s\n' '10001:10001' ;;
      *) printf '%s\n' "$TARGET_ID" ;;
    esac
    ;;
  inspect)
    case "$format" in
      *'Config.Env'*) cat "$FAKE_ENV" ;;
      *'config-hash'*) printf '%s\n' "$FAKE_HASH" ;;
      *) printf '%s\n' "$TARGET_ID" ;;
    esac
    ;;
  *) exit 0 ;;
esac
DOCKER

cat >"$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  case "$argument" in
    -D)
      next=header
      ;;
    *)
      if [ "${next:-}" = header ]; then
        printf 'HTTP/1.1 308 Permanent Redirect\nLocation: https://public.test/meetings\n\n' >"$argument"
        next=
      fi
      ;;
  esac
done
case "$*" in
  *'actuator'*) printf '404' ;;
  *'admin/demo-catalog/bootstrap'*) printf '403' ;;
  *'meetings'*) printf '[]' ;;
  *) printf '[]' ;;
esac
CURL

cat >"$fake_bin/flock" <<'FLOCK'
#!/usr/bin/env bash
exec /usr/bin/flock "$@"
FLOCK

cat >"$fake_bin/verify-test-vps-closed-beta-state.sh" <<'VERIFY'
#!/usr/bin/env bash
set -euo pipefail
phase=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase) phase=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf 'hook phase=%s\n' "$phase" >>"$TRACE_FILE"
printf '{"phase":"%s","fixture":true}\n' "$phase" >"$output"
VERIFY

cat >"$fake_bin/verify-test-vps-assets.sh" <<'ASSETS'
#!/usr/bin/env bash
set -euo pipefail
printf 'assets\n' >>"$TRACE_FILE"
ASSETS

cat >"$fake_bin/probe-test-vps-zero-state.sh" <<'ZERO'
#!/usr/bin/env bash
set -euo pipefail
phase=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase) phase=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"phase":"%s","zeroState":"closed"}\n' "$phase" >"$output"
ZERO
chmod 700 "$fake_bin"/*
cat >"$fake_bin/test-vps-runtime-invariants.sh" <<'RUNTIME'
#!/usr/bin/env bash
set -euo pipefail
runtime_release_field() {
  local root=$1
  local name=$2
  sed -n "s/^${name}=//p" "$root/.env.production"
}
runtime_compose() {
  local root=$1
  local compose_script=$2
  shift 2
  case "$*" in
    "ps -q backend") printf 'backend-container\n' ;;
    "ps -q postgres") printf 'postgres-container\n' ;;
    *) return 0 ;;
  esac
}
runtime_image_id() {
  printf 'sha256:%064d\n' 0
}
verify_runtime_invariants() {
  return 0
}
verify_environment_matches_container() {
  return 0
}
RUNTIME
chmod 700 "$fake_bin/test-vps-runtime-invariants.sh"
cp -- "$fake_bin/test-vps-runtime-invariants.sh" \
  "$staged/scripts/test-vps-runtime-invariants.sh"
chmod 700 "$staged/scripts/test-vps-runtime-invariants.sh"
for side_effect_script in \
  verify-test-vps-closed-beta-state.sh \
  verify-test-vps-assets.sh \
  probe-test-vps-zero-state.sh; do
  cp -- "$fake_bin/$side_effect_script" "$staged/scripts/$side_effect_script"
  chmod 700 "$staged/scripts/$side_effect_script"
done

printf 'predecessor-compose\n' >"$fixture/predecessor-compose"
printf 'predecessor-runtime\n' >"$fixture/predecessor-runtime"

run_legacy() {
  local coordinator=$1
  local label=$2
  local mode=$3
  local root=$fixture/"$label-root"
  local state=$fixture/"$label-state"
  local output=$fixture/"$label-$mode.output"
  for owned_path in "$root" "$state" "$production_state"; do
    [ ! -e "$owned_path" ] || rm -r -- "$owned_path"
  done
  mkdir -p "$root" "$state" "$production_state"
  created_production=true
  printf '%s\n' \
    "BACKEND_IMAGE=$previous_image" \
    "BACKEND_REVISION=$SOURCE_SHA" \
    'BACKEND_VERSION=1.2.0' >"$root/.env.production"
  printf '%s\n' 'services:' '  backend:' '    image: fixture' \
    >"$root/docker-compose.production.yml"
  cp -- "$fixture/predecessor-compose" "$production_state/active-compose.yml"
  cp -- "$fixture/predecessor-runtime" "$production_state/active-runtime.override.yml"
  : >"$trace"
  coordinator_args=(
    --root "$root"
    --base-compose "$staged/docker-compose.production.yml"
    --image "$target_image"
    --revision "$SOURCE_SHA"
    --version "$VERSION"
    --run-key "$label"
    --mode "$mode"
    --closed-beta-safety --state-mode empty-closed
    --public-url https://public.test
  )
  set +e
  PATH="$fake_bin:$PATH" \
    TRACE_FILE="$trace" FAKE_ENV="$fake_env" FAKE_HASH="$fake_hash" \
    PREVIOUS_ID="$previous_id" TARGET_ID="$target_id" TARGET_IMAGE="$target_image" \
    SOURCE_SHA="$SOURCE_SHA" VERSION="$VERSION" \
    MEE_SMTP_FAKE_REMOTE=true TEST_VPS_STATE_ROOT="$state" \
    "$coordinator" "${coordinator_args[@]}" >"$output" 2>&1
  local status=$?
  set -e
  printf '%s\n' "$status" >"$fixture/$label-$mode.status"
  printf '%s\n' "$root" "$state"
}

current_root_state=$(run_legacy "$staged/scripts/deploy-test-vps-release.sh" current rollback-drill)
current_root=$(sed -n '1p' <<<"$current_root_state")
current_state=$(sed -n '2p' <<<"$current_root_state")
current_status=$(<"$fixture/current-rollback-drill.status")
[ "$current_status" -eq 86 ]
grep -Fq 'rollback=completed previous_image_id=' "$fixture/current-rollback-drill.output"
cp -- "$trace" "$fixture/current-rollback.trace"
grep -Fxq "BACKEND_IMAGE=$previous_image" "$current_root/.env.production"
cmp -s "$production_state/active-compose.yml" "$fixture/predecessor-compose"
cmp -s "$production_state/active-runtime.override.yml" "$fixture/predecessor-runtime"
grep -Fxq 'hook phase=predecessor' "$trace"
grep -Fxq 'hook phase=candidate' "$trace"
grep -Fxq 'hook phase=rollback' "$trace"
! find "$current_state" -name '.provider-*' -print -quit | grep -q .
! grep -Eiq 'provider-transaction|test-vps-provider' "$trace"

baseline_dir=$fixture/baseline/scripts
mkdir -p "$baseline_dir"
cp -a -- "$staged/scripts/." "$baseline_dir/"
baseline_coordinator=$baseline_dir/deploy-test-vps-release.sh
if [ -n "${BASELINE_COORDINATOR:-}" ]; then
  cp -- "$BASELINE_COORDINATOR" "$baseline_coordinator"
else
  git_dir=${BASELINE_GIT_DIR:-}
  if [ -n "$git_dir" ]; then
    git --git-dir="$git_dir" show \
      6b0bc309eb00c2c3b0628f4fd86f61e60a26d79d:scripts/deploy-test-vps-release.sh \
      >"$baseline_coordinator"
  else
    git show 6b0bc309eb00c2c3b0628f4fd86f61e60a26d79d:scripts/deploy-test-vps-release.sh \
      >"$baseline_coordinator"
  fi
fi
chmod 700 "$baseline_coordinator"
for side_effect_script in \
  verify-test-vps-closed-beta-state.sh \
  verify-test-vps-assets.sh \
  probe-test-vps-zero-state.sh; do
  cp -- "$fake_bin/$side_effect_script" "$baseline_dir/$side_effect_script"
  chmod 700 "$baseline_dir/$side_effect_script"
done

run_legacy "$baseline_coordinator" baseline rollback-drill >/dev/null
baseline_status=$(<"$fixture/baseline-rollback-drill.status")
[ "$baseline_status" -eq 86 ]
grep -Fq 'rollback=completed previous_image_id=' "$fixture/baseline-rollback-drill.output"
cp -- "$trace" "$fixture/baseline-rollback.trace"
sed -E "s#$fixture/[A-Za-z0-9._/-]+#FIXTURE#g" \
  "$fixture/current-rollback-drill.output" >"$fixture/current.normalized"
sed -E "s#$fixture/[A-Za-z0-9._/-]+#FIXTURE#g" \
  "$fixture/baseline-rollback-drill.output" >"$fixture/baseline.normalized"
cmp -s "$fixture/current.normalized" "$fixture/baseline.normalized"
sed -E "s#$fixture/[A-Za-z0-9._/-]+#FIXTURE#g" \
  "$fixture/current-rollback.trace" >"$fixture/current-rollback.normalized"
sed -E "s#$fixture/[A-Za-z0-9._/-]+#FIXTURE#g" \
  "$fixture/baseline-rollback.trace" >"$fixture/baseline-rollback.normalized"
cmp -s "$fixture/current-rollback.normalized" \
  "$fixture/baseline-rollback.normalized"

current_root_state=$(run_legacy "$staged/scripts/deploy-test-vps-release.sh" current-final deploy)
current_root=$(sed -n '1p' <<<"$current_root_state")
current_state=$(sed -n '2p' <<<"$current_root_state")
current_status=$(<"$fixture/current-final-deploy.status")
[ "$current_status" -eq 0 ]
grep -Fq 'deployment=completed image_id=' "$fixture/current-final-deploy.output"
cp -- "$trace" "$fixture/current-final.trace"
grep -Fxq 'hook phase=predecessor' "$trace"
grep -Fxq 'hook phase=candidate' "$trace"
grep -Fxq 'hook phase=final' "$trace"
! find "$current_state" -name '.provider-*' -print -quit | grep -q .
! grep -Eiq 'provider-transaction|test-vps-provider' "$trace"

run_legacy "$baseline_coordinator" baseline-final deploy >/dev/null
baseline_final_status=$(<"$fixture/baseline-final-deploy.status")
[ "$baseline_final_status" -eq 0 ]
grep -Fq 'deployment=completed image_id=' "$fixture/baseline-final-deploy.output"
cp -- "$trace" "$fixture/baseline-final.trace"
grep -Fxq 'hook phase=predecessor' "$trace"
grep -Fxq 'hook phase=candidate' "$trace"
grep -Fxq 'hook phase=final' "$trace"
! grep -Eiq 'provider-transaction|test-vps-provider' "$trace"
sed -E "s#$fixture/[A-Za-z0-9._/-]+#FIXTURE#g" \
  "$fixture/current-final.trace" >"$fixture/current-final.normalized"
sed -E "s#$fixture/[A-Za-z0-9._/-]+#FIXTURE#g" \
  "$fixture/baseline-final.trace" >"$fixture/baseline-final.normalized"
cmp -s "$fixture/current-final.normalized" "$fixture/baseline-final.normalized"

echo "closed-beta staged archive fixture passed: extracted workflow archive, legacy rollback status 86, final success, baseline trace parity, and provider-lane isolation"
