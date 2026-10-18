#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(pwd -P)
cd "$ROOT_DIR"

fail() {
  echo "ASSERTION_FAIL: $*" >&2
  exit 1
}

assert_empty_directory() {
  local entry
  entry=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit) || return 1
  [ -z "$entry" ]
}

assert_tmpfs() {
  local target
  target=$(readlink -f "$1") || return 1
  awk -v path="$target" '
    $5 == path {
      found = 1
      for (i = 7; i <= NF; i++) {
        if ($i == "-") {
          filesystem = $(i + 1)
          break
        }
      }
    }
    END { exit !(found && filesystem == "tmpfs") }
  ' /proc/self/mountinfo
}

for path in /var/lib /tmp /run /var/run; do
  assert_tmpfs "$path" || {
    echo "fixture did not receive a fresh $path tmpfs" >&2
    exit 1
  }
  assert_empty_directory "$path" || {
    echo "fixture $path is not fresh" >&2
    exit 1
  }
done
[ -z "${DOCKER_HOST:-}" ] || {
  echo "fixture must not use a Docker host" >&2
  exit 1
}
[ ! -S /run/docker.sock ] && [ ! -S /var/run/docker.sock ] || {
  echo "fixture can see a Docker socket" >&2
  exit 1
}
awk 'NR > 1 { exit 1 }' /proc/net/route &&
  awk 'NF { if (NF != 10 || $10 != "lo") bad = 1 } END { exit bad }' /proc/net/ipv6_route || {
  echo "fixture network namespace has a route" >&2
  exit 1
}

controller=scripts/deploy-test-vps-provider-release.sh
[ -f "$controller" ] && [ ! -L "$controller" ] || {
  echo "actual deployment controller is unavailable" >&2
  exit 1
}
bash_path=$(command -v bash)
safe_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fixture_bin=$ROOT_DIR/scripts/fixtures/timepad-controller
runtime_bin=/var/lib/timepad-fixture/bin
state_root=/var/lib/timepad-fixture/state
root=/var/lib/timepad-fixture/root
base_compose=/var/lib/timepad-fixture/compose.yml
docker_log=/var/lib/timepad-fixture/docker.log
install -d -m 700 "$root" "$state_root"
install -m 600 "$fixture_bin/root-env" "$root/.env.production"
install -m 600 "$fixture_bin/compose.yml" "$root/docker-compose.production.yml"
install -m 600 "$root/docker-compose.production.yml" "$base_compose"
install -d -m 700 "$runtime_bin"
install -m 700 "$fixture_bin/docker" "$fixture_bin/curl" "$runtime_bin"
export DOCKER_HOST=
export TIMEPAD_FIXTURE_DOCKER_LOG=$docker_log
export TEST_VPS_STATE_ROOT=$state_root
export TIMEPAD_FIXTURE_ADAPTER_DIR=$fixture_bin
export PATH="$runtime_bin:$safe_path"
export PYTHONDONTWRITEBYTECODE=1
timeout --kill-after=5s 600s python3 -B "$fixture_bin/admission-cancellation.py" bootstrap
timeout --kill-after=5s 360s python3 -B "$fixture_bin/admission-cancellation.py" cancellation
common_args=(
  --root "$root"
  --base-compose "$base_compose"
  --image "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:$(printf '%064d' 0)"
  --revision 0000000000000000000000000000000000000000
  --version 1.4.1
  --run-key fixture-run-1
)

assert_refusal() {
  local reason=$1
  shift
  local output status before
  before=$(if [ -f "$docker_log" ]; then sha256sum "$docker_log" | awk '{print $1}'; fi)
  if output=$(timeout 30s "$bash_path" "$controller" \
    "${common_args[@]}" "$@" 2>&1)
  then
    status=0
  else
    status=$?
  fi
  local after
  after=$(if [ -f "$docker_log" ]; then sha256sum "$docker_log" | awk '{print $1}'; fi)
  [ "$status" -eq 1 ] &&
    { [ "$output" = "test VPS deployment failed: $reason" ] ||
      [ "$output" = "schema_guard=QUIESCENCE_UNCONFIRMED" ]; } &&
    [ "$after" = "$before" ] || {
    fail "controller refusal contract expected=$reason status=$status"
  }
}

assert_usage_refusal() {
  local expected=$1
  shift
  local output status
  if output=$(timeout 30s "$bash_path" "$controller" \
    "${common_args[@]}" "$@" 2>&1)
  then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 2 ] &&
    [ "$output" = "$expected" ] || {
    fail "controller argument refusal expected=$expected status=$status"
  }
}

assert_refusal ROLLBACK_DRILL_UNSAFE \
  --mode rollback-drill --operation deploy \
  --rollout-domain timepad-first-transition --initial-proof-id fixture-proof
assert_refusal BOOTSTRAP_AUTHORITY_REQUIRED \
  --mode deploy --operation bootstrap-guard \
  --initial-proof-id fixture-proof --bootstrap-id fixture-bootstrap
assert_refusal RECOVERY_AUTHORIZATION_REQUIRED \
  --mode deploy --operation forward-recover \
  --recovery-run-key fixture-run-0 \
  --recovery-incident 0123456789abcdef \
  --recovery-epoch 1 \
  --recovery-binding-digest "$(printf '%064d' 0)" \
  --recovery-action retry-exact-candidate
assert_usage_refusal \
  "usage: $controller --root PATH --base-compose PATH --image IMAGE@sha256:DIGEST --revision SHA --version VERSION --run-key KEY --mode deploy|rollback-drill [--operation deploy|bootstrap-guard|forward-recover --rollout-domain initial-domain|timepad-first-transition --initial-proof-id ID --bootstrap-id ID --recovery-run-key KEY --recovery-incident ID --recovery-epoch N --recovery-binding-digest SHA256 --recovery-action retry-exact-candidate] [--closed-beta-safety --state-mode empty-closed|closed-beta-demo] [--public-url https://HOST]" \
  --mode deploy --operation forward-recover \
  --recovery-run-key fixture-run-0 \
  --recovery-incident 0123456789abcdef \
  --recovery-epoch 1 \
  --recovery-binding-digest "$(printf '%064d' 0)" \
  --recovery-action retry-exact-candidate --bootstrap-id conflicting-bootstrap
assert_usage_refusal \
  "usage: $controller --root PATH --base-compose PATH --image IMAGE@sha256:DIGEST --revision SHA --version VERSION --run-key KEY --mode deploy|rollback-drill [--operation deploy|bootstrap-guard|forward-recover --rollout-domain initial-domain|timepad-first-transition --initial-proof-id ID --bootstrap-id ID --recovery-run-key KEY --recovery-incident ID --recovery-epoch N --recovery-binding-digest SHA256 --recovery-action retry-exact-candidate] [--closed-beta-safety --state-mode empty-closed|closed-beta-demo] [--public-url https://HOST]" \
  --mode deploy --operation deploy

[ ! -e "$docker_log" ] || fail "controller attempted to use the Docker boundary during refusal cases"
echo "CONTROLLER_REFUSAL_PASS: unsafe drill, missing bootstrap authority, missing recovery authorization"

echo "CONTROLLER_ARGUMENT_PASS: mixed recovery selectors and missing rollout domain"

recovery_case_number=0
assert_bound_recovery() {
  local phase=$1 fault=$2 expected=$3 starts=$4
  local case_dir output status before after allowed_start
  recovery_case_number=$((recovery_case_number + 1))
  case_dir=/var/lib/timepad-fixture/case-$recovery_case_number
  timeout 30s python3 -B "$fixture_bin/recovery.py" setup "$case_dir" "$phase" "$fault"
  before=$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')
  export TIMEPAD_FIXTURE_CASE=$case_dir
  export TIMEPAD_FIXTURE_DOCKER_LOG=$case_dir/docker.log
  export TEST_VPS_STATE_ROOT=$case_dir/state
  local -a launch=("$bash_path")
  case "$fault" in
    active-child*)
      launch=(python3 -B "$fixture_bin/recovery.py" run-active "$case_dir" "$bash_path")
      ;;
  esac
  local -a recovery_command=("${launch[@]}" \
    "$case_dir/tools/deploy-test-vps-provider-release.sh" \
    --root "$case_dir/root" --base-compose "$case_dir/compose.yml" \
    --image "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:$(printf '1%.0s' {1..64})" \
    --revision "$(printf '3%.0s' {1..40})" --version 1.2.3 \
    --run-key fixture-dispatch --mode deploy --operation forward-recover \
    --recovery-run-key 31885558214-1 \
    --recovery-incident "$(printf 'd%.0s' {1..32})" --recovery-epoch 1 \
    --recovery-binding-digest "$(<"$case_dir/binding")" \
    --recovery-action retry-exact-candidate)
  if output=$(timeout --kill-after=5s 130s "${recovery_command[@]}" 2>&1)
  then
    status=0
  else
    status=$?
  fi
  # Always check the incompatible/different-image start invariant, including
  # when another assertion fails. No case can authorize a predecessor start.
  allowed_start=$(printf 'f%.0s' {1..64})
  [ "$fault" != replace ] || allowed_start=$(printf 'b%.0s' {1..64})
  if [ -f "$case_dir/docker.log" ]; then
    ! grep '^start-id:' "$case_dir/docker.log" |
      grep -v "^start-id:$allowed_start$" ||
      fail "recovery attempted a foreign/predecessor start"
  fi
  [ "$status" -eq 1 ] && [[ "$output" == *"test VPS deployment failed: $expected"* ]] ||
    fail "recovery phase=$phase fault=$fault status=$status expected=$expected"
  [ "$(grep -c '^start-id:' "$case_dir/docker.log" || true)" -eq "$starts" ] ||
    fail "recovery start count phase=$phase fault=$fault"
  if [ "$fault" = create-fails ]; then
    jq -e '.phase == "FORWARD_RECOVERING" and
      .commitSubstep == "replacement-create-intent" and .ownedChild == null' \
      "$case_dir/state/timepad-guard/current.json" >/dev/null ||
      fail "failed create lost durable one-use intent"
    before=$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')
    if output=$(timeout 30s "${recovery_command[@]}" 2>&1); then
      fail "unbound create-intent allowed another create"
    fi
    [[ "$output" == *RECOVERY_REPLACEMENT_CREATE_UNRESOLVED* ]] ||
      fail "unbound create-intent did not refuse explicitly"
    [ "$before" = "$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')" ] ||
      fail "unbound create-intent replay changed state"
    [ "$(grep -c '^compose:up$' "$case_dir/docker.log")" -eq 1 ] ||
      fail "unbound create-intent replay attempted another create"
  elif [ "$starts" -eq 0 ]; then
    after=$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')
    if [ "$fault" = active-child-missing-input ]; then
      cmp -s "$case_dir/active-before" "$case_dir/state/timepad-guard/current.json" ||
        fail "refusal changed durable owned-child state"
    else
      [ "$before" = "$after" ] || fail "refusal changed durable incident state"
    fi
    ! grep -Eq '^((update|stop|start):|compose:(up|create)$)' "$case_dir/docker.log" ||
      fail "refusal mutated runtime"
  else
    jq -e --arg phase "$phase" '.current // . |
      .phase == (if $phase == "COMMITTING" then "COMMITTING" else "VERIFYING" end) and .ownedChild == null
      and .operationEpoch == 1' "$case_dir/state/timepad-guard/current.json" >/dev/null ||
      fail "retry lost incident/phase/child proof"
    jq -e '.State.Running == false and .HostConfig.RestartPolicy.Name == "no"' \
      "$case_dir/runtime.json" >/dev/null || fail "failed retry was not quiesced"
    if [ "$fault" = replace ]; then
      timeout 30s python3 -B "$fixture_bin/recovery.py" lose-replacement "$case_dir"
      before=$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')
      if output=$(timeout 30s "${recovery_command[@]}" 2>&1); then
        fail "missing bound replacement allowed a second replacement"
      fi
      [[ "$output" == *RECOVERY_PROVIDER_ABSENCE_PROOF_REQUIRED* ]] ||
        fail "second replacement did not refuse at absence admission"
      [ "$before" = "$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')" ] ||
        fail "second replacement refusal changed state"
      [ "$(grep -c '^compose:up$' "$case_dir/docker.log")" -eq 1 ] &&
        [ "$(grep -c '^start-id:' "$case_dir/docker.log")" -eq 1 ] ||
        fail "second replacement refusal mutated runtime"
    fi
  fi
  echo "CONTROLLER_RECOVERY_PASS: phase=$phase fault=$fault target_starts=$starts predecessor_starts=0"
}

for phase in CUTOVER_POSSIBLE ROLLING_BACK; do
  assert_bound_recovery "$phase" intact RECOVERY_RETRY_RUNTIME_FAILED 1
  if [ "$phase" = ROLLING_BACK ]; then
    assert_bound_recovery "$phase" foreign PROVIDER_REPAIR_REQUIRED 0
  else
    assert_bound_recovery "$phase" foreign RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED 0
  fi
  assert_bound_recovery "$phase" missing RECOVERY_OWNERSHIP_PROOF_REQUIRED 0
  assert_bound_recovery "$phase" orphan-child RECOVERY_RETRY_RUNTIME_FAILED 1
  assert_bound_recovery "$phase" active-child RECOVERY_RETRY_RUNTIME_FAILED 1
done
assert_bound_recovery ROLLING_BACK missing-input PROVIDER_REPAIR_REQUIRED 0
assert_bound_recovery ROLLING_BACK active-child-missing-input PROVIDER_REPAIR_REQUIRED 0
assert_bound_recovery COMMITTING unknown-inventory RECOVERY_OWNERSHIP_PROOF_REQUIRED 0
assert_bound_recovery COMMITTING create-intent RECOVERY_REPLACEMENT_CREATE_UNRESOLVED 0
assert_bound_recovery COMMITTING create-fails RECOVERY_REPLACEMENT_CREATE_FAILED 0
assert_bound_recovery COMMITTING replace RECOVERY_RETRY_RUNTIME_FAILED 1
unset TIMEPAD_FIXTURE_CASE

# These cases cover dispatch refusals and positively bound live recovery
# failure paths, not successful commit/replacement or the full fault matrix.
# Keep the suite non-green until every required matrix row is executable.
echo "CONTROLLER_MATRIX_BLOCKED: A1-A5 runtime acceptance is not established" >&2
echo "CONTROLLER_MATRIX_BLOCKED: PREPARED/unbound recovery, replacement, deadline and full fault matrix remain" >&2
exit 77
