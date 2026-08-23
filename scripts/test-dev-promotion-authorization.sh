#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES=$ROOT_DIR/scripts/fixtures/promote-dev-digest-workflow
AUTHORIZER=$ROOT_DIR/scripts/authorize-dev-promotion.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mee2-60-auth.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -r -- "$TMP"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

git_config() {
  git -C "$1" config user.name fixture
  git -C "$1" config user.email fixture@example.invalid
}

mkdir -p "$TMP/seed/.github/workflows" "$TMP/bin"
git init -q "$TMP/seed"
git_config "$TMP/seed"
cp "$ROOT_DIR/.github/workflows/promote-dev-digest-to-test-vps.yml" \
  "$TMP/seed/.github/workflows/promote-dev-digest-to-test-vps.yml"
printf '{\n  "version": "1.2.0"\n}\n' >"$TMP/seed/version.json"
printf 'authorization fixture\n' >"$TMP/seed/tracked.txt"
git -C "$TMP/seed" add .
git -C "$TMP/seed" commit -qm fixture
source_sha=$(git -C "$TMP/seed" rev-parse HEAD)
tree_id=$(git -C "$TMP/seed" rev-parse HEAD^{tree})

git init -q --bare "$TMP/remote.git"
git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/dev
git -C "$TMP/seed" remote add origin "$TMP/remote.git"
git -C "$TMP/seed" push -q origin HEAD:dev
git -C "$TMP/seed" push -q origin HEAD:master
git clone -q "$TMP/remote.git" "$TMP/source"
git -C "$TMP/source" checkout -q --detach "$source_sha"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = api ] || {
  printf 'fixture rejected non-api gh invocation\n' >&2
  exit 1
}
shift
endpoint=
for argument in "$@"; do
  case "$argument" in
    --method|--method=*)
      printf 'fixture rejected explicit HTTP method\n' >&2
      exit 1
      ;;
    *push*|*delete*|*packages*|*deployments*)
      printf 'fixture rejected writer-like endpoint\n' >&2
      exit 1
      ;;
    repos/*)
      endpoint=$argument
      ;;
  esac
done
[ -n "$endpoint" ] || {
  printf 'fixture rejected missing endpoint\n' >&2
  exit 1
}
printf '%s\n' "$endpoint" >>"$GH_CALL_LOG"
case "$endpoint" in
  repos/*/actions/runs/*/jobs\?per_page=100)
    if [ "${AUTH_FIXTURE_CASE:-valid}" = ci-jobs-wrong-type ]; then
      printf '[["wrong job shape"]]\n'
    else
      cat "$AUTH_FIXTURE_ROOT/authorization-ci-jobs.json"
    fi
    ;;
  repos/*/actions/workflows/ci.yml/runs\?head_sha=*)
    if [ "${AUTH_FIXTURE_CASE:-valid}" = ci-runs-wrong-type ]; then
      printf '{"workflow_runs":[]}\n'
    else
      sed "s/0000000000000000000000000000000000000000/$SOURCE_SHA/g" \
        "$AUTH_FIXTURE_ROOT/authorization-ci-runs.json"
    fi
    ;;
  repos/*/actions/runs/*)
    if [ "${AUTH_FIXTURE_CASE:-valid}" = run-wrong-type ]; then
      printf '{"event":false,"head_branch":"dev","head_sha":false}\n'
    else
      sed "s/0000000000000000000000000000000000000000/$SOURCE_SHA/g" \
        "$AUTH_FIXTURE_ROOT/authorization-dispatch.json"
    fi
    ;;
  repos/*/environments/closed-beta-promotion/deployment-branch-policies\?per_page=100|\
  repos/*/environments/test-vps/deployment-branch-policies\?per_page=100)
    if [ "${AUTH_FIXTURE_CASE:-valid}" = branch-policy-wrong-type ]; then
      printf '{"total_count":1,"branch_policies":[{"name":"dev","type":false}]}\n'
    else
      cat "$AUTH_FIXTURE_ROOT/authorization-branch-policy.json"
    fi
    ;;
  repos/*/environments/closed-beta-promotion)
    if [ "${AUTH_FIXTURE_CASE:-valid}" = environment-wrong-type ]; then
      printf '{"name":"closed-beta-promotion","deployment_branch_policy":true}\n'
    else
      cat "$AUTH_FIXTURE_ROOT/authorization-closed-beta-environment.json"
    fi
    ;;
  repos/*/environments/test-vps)
    if [ "${AUTH_FIXTURE_CASE:-valid}" = environment-wrong-type ]; then
      printf '{"name":"test-vps","deployment_branch_policy":true}\n'
    else
      cat "$AUTH_FIXTURE_ROOT/authorization-test-vps-environment.json"
    fi
    ;;
  *)
    printf 'fixture rejected unknown endpoint: %s\n' "$endpoint" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "$TMP/bin/gh"

run_authorization() {
  local case_name=$1
  local output_dir=$2
  local github_output=$3
  PATH="$TMP/bin:$PATH" \
  AUTH_FIXTURE_ROOT="$FIXTURES" \
  AUTH_FIXTURE_CASE="$case_name" \
  SOURCE_SHA="$source_sha" \
  GITHUB_EVENT_NAME=workflow_dispatch \
  GITHUB_REF=refs/heads/dev \
  GITHUB_SHA="$source_sha" \
  GITHUB_REPOSITORY=fixture/meet-backend \
  GITHUB_RUN_ID=32650054493 \
  GH_TOKEN=fixture-token \
  GH_CALL_LOG="$TMP/gh.log" \
  "$AUTHORIZER" \
    --repository fixture/meet-backend \
    --source-checkout "$TMP/source" \
    --source-sha "$source_sha" \
    --workflow .github/workflows/promote-dev-digest-to-test-vps.yml \
    --output-dir "$output_dir" \
    --github-output "$github_output"
}

mkdir "$TMP/valid"
: >"$TMP/valid-output"
run_authorization valid "$TMP/valid" "$TMP/valid-output"
grep -Fxq 'authorized=true' "$TMP/valid-output"
grep -Fxq "source_sha=$source_sha" "$TMP/valid-output"
grep -Fxq "tree_id=$tree_id" "$TMP/valid-output"
grep -Fxq 'version=1.2.0' "$TMP/valid-output"
master_registration_sha=$(sed -n 's/^master_registration_sha=//p' "$TMP/valid-output")
registration_sha=$(sed -n 's/^registration_sha=//p' "$TMP/valid-output")
[[ "$master_registration_sha" =~ ^[0-9a-f]{64}$ ]]
[ "$master_registration_sha" = "$registration_sha" ]
jq -e '
  .schema == "meet-backend/dev-promotion-source/v1" and
  .sourceSha == $source and .version == "1.2.0" and
  .detached == true and .clean == true
' --arg source "$source_sha" "$TMP/valid/dev-promotion-source.json" >/dev/null
jq -e '
  .schema == "meet-backend/test-promotion-authorization/v1" and
  .authorized == true and .sourceSha == $source and
  .masterRegistrationSha == .devRegistrationSha
' --arg source "$source_sha" "$TMP/valid/promotion-authorization.json" >/dev/null
jq -e '
  .schema == "meet-backend/test-promotion-required-checks/v1" and
  .sourceSha == $source and .allRequiredChecksSuccessful == true and
  (.requiredJobs | length) == 5
' --arg source "$source_sha" "$TMP/valid/required-checks.json" >/dev/null
cp "$TMP/valid-output" "$TMP/valid-output-repeat"
rm "$TMP/valid-output"
run_authorization valid "$TMP/valid" "$TMP/valid-output"
cmp "$TMP/valid-output-repeat" "$TMP/valid-output"
[ ! -e "$TMP/mutation.marker" ]
! grep -Eiq 'push|delete|packages|--method' "$TMP/gh.log"

expect_failure() {
  local case_name=$1
  local output_dir="$TMP/$case_name"
  local github_output="$output_dir/output"
  mkdir "$output_dir"
  : >"$github_output"
  if run_authorization "$case_name" "$output_dir" "$github_output" \
    >"$output_dir/stdout" 2>"$output_dir/stderr"; then
    echo "expected authorization rejection: $case_name" >&2
    exit 1
  fi
  [ ! -s "$github_output" ] ||
    { echo "authorization published outputs before rejection: $case_name" >&2; exit 1; }
  [ ! -e "$output_dir/promotion-authorization.json" ] ||
    { echo "authorization proof published before rejection: $case_name" >&2; exit 1; }
  [ -s "$output_dir/stderr" ] ||
    { echo "authorization rejection omitted safe stderr: $case_name" >&2; exit 1; }
}

for case_name in run-wrong-type environment-wrong-type \
  branch-policy-wrong-type ci-runs-wrong-type ci-jobs-wrong-type; do
  expect_failure "$case_name"
done

echo "dev promotion authorization fixture passed"
