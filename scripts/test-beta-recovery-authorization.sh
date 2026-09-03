#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
authorizer=$root/scripts/authorize-beta-recovery.sh
fixtures=$root/scripts/fixtures/beta-recovery
tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/seed/.github/workflows"
cp -R -- "$root/scripts" "$tmp/seed/"
cp -- "$root/.github/workflows/prove-beta-backup-restore.yml" \
  "$tmp/seed/.github/workflows/"
git -C "$tmp/seed" init -q
git -C "$tmp/seed" config user.name fixture
git -C "$tmp/seed" config user.email fixture@example.invalid
git -C "$tmp/seed" add .
git -C "$tmp/seed" commit -qm fixture
source_sha=$(git -C "$tmp/seed" rev-parse HEAD)
git init -q --bare "$tmp/remote.git"
git -C "$tmp/seed" remote add origin "$tmp/remote.git"
git -C "$tmp/seed" push -q origin HEAD:dev
git -C "$tmp/seed" push -q origin HEAD:master
git -C "$tmp/seed" checkout -q --detach "$source_sha"
source=$tmp/seed

cat >"$tmp/bin-gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = api ] || exit 1
shift
endpoint=
for argument in "$@"; do
  case "$argument" in
    repos/*) endpoint=$argument ;;
    *push*|*delete*|*packages*|*deployments*) exit 1 ;;
  esac
done
[ -n "$endpoint" ] || exit 1
printf '%s\n' "$endpoint" >>"$GH_CALL_LOG"
case "$endpoint" in
  repos/*/actions/runs/*)
    jq -cn --arg sha "$SOURCE_SHA" \
      '{event:"workflow_dispatch",head_branch:"dev",head_sha:$sha,
        path:".github/workflows/prove-beta-backup-restore.yml"}'
    ;;
  repos/*/actions/workflows/ci.yml/runs*)
    jq -cn --arg sha "$SOURCE_SHA" \
      '{workflow_runs:[{path:".github/workflows/ci.yml",head_branch:"dev",
        head_sha:$sha,status:"completed",conclusion:"success"}]}'
    ;;
  repos/*/environments/closed-beta-restore/deployment-branch-policies*)
    if [ "${AUTH_FIXTURE_CASE:-valid}" = wrong-branch ]; then
      printf '%s\n' '{"total_count":1,"branch_policies":[{"name":"main","type":"branch"}]}'
    else
      cat "$FIXTURE_ROOT/closed-beta-restore-branches.json"
    fi
    ;;
  repos/*/environments/closed-beta-restore/secrets*)
    echo 'Forbidden' >&2
    exit 22
    ;;
  repos/*/environments/closed-beta-restore)
    case "${AUTH_FIXTURE_CASE:-valid}" in
      missing-environment) exit 1 ;;
      wrong-reviewer)
        jq '.protection_rules[0].reviewers=[{"type":"Bot","reviewer":{"id":1}}]' \
          "$FIXTURE_ROOT/closed-beta-restore-environment.json"
        ;;
      admin-bypass)
        jq '.can_admins_bypass=true' \
          "$FIXTURE_ROOT/closed-beta-restore-environment.json"
        ;;
      *)
        cat "$FIXTURE_ROOT/closed-beta-restore-environment.json"
        ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin-gh"

run_authorization() {
  local case_name=$1 output_dir=$2 output_file=$3
  PATH="$tmp:$PATH" \
  GH_CALL_LOG="$tmp/gh.log" \
  FIXTURE_ROOT="$fixtures" \
  AUTH_FIXTURE_CASE="$case_name" \
  GITHUB_REPOSITORY=fixture/meet-backend \
  GITHUB_SHA="$source_sha" \
  GITHUB_REF=refs/heads/dev \
  GITHUB_EVENT_NAME=workflow_dispatch \
  GITHUB_RUN_ID=123 \
  SOURCE_SHA="$source_sha" \
  GH_TOKEN=fixture-token \
  "$authorizer" authorize \
    --repository fixture/meet-backend \
    --source-checkout "$source" \
    --source-sha "$source_sha" \
    --workflow .github/workflows/prove-beta-backup-restore.yml \
    --output-dir "$output_dir" \
    --github-output "$output_file"
}

mkdir -p "$tmp/bin"
mv -- "$tmp/bin-gh" "$tmp/gh"
mkdir "$tmp/valid"
: >"$tmp/valid-output"
run_authorization valid "$tmp/valid" "$tmp/valid-output"
grep -Fxq 'authorized=true' "$tmp/valid-output"
expected_tooling_digest=$(cd "$source" && for file in scripts/authorize-beta-recovery.sh \
  scripts/run-beta-recovery-capture.sh scripts/run-beta-recovery-restore.sh \
  scripts/build-beta-recovery-evidence.sh scripts/run-beta-recovery-remote-probe.sh \
  scripts/production-compose.sh scripts/probe-test-vps-recovery-runtime.sh \
  scripts/backup-production.sh scripts/beta-recovery-database-proof.sql \
  scripts/beta-recovery-media-proof.sh scripts/install-beta-recovery-age.sh \
  scripts/materialize-beta-recovery-known-hosts.sh \
  scripts/validate-beta-recovery-artifact-retention.sh scripts/admit-beta-recovery-artifact.sh; do
  sha256sum -- "$file"
done | sort | sha256sum | awk '{print $1}')
jq -e --arg digest "$expected_tooling_digest" '.toolingDigest == $digest' \
  "$tmp/valid/beta-recovery-authorization.json" >/dev/null
grep -Fxq "tooling_digest=$expected_tooling_digest" "$tmp/valid-output"
jq -e '
  .authorized == true and
  .restoreEnvironment == {
    name:"closed-beta-restore",protected:true,requiredReviewers:true,
    preventSelfReview:true,administratorBypass:false,deploymentBranch:"dev"
  }
' "$tmp/valid/beta-recovery-authorization.json" >/dev/null

expect_failure() {
  local case_name=$1 output_dir="$tmp/$1"
  mkdir "$output_dir"
  : >"$output_dir/github-output"
  if run_authorization "$case_name" "$output_dir" "$output_dir/github-output" \
    >"$output_dir/stdout" 2>"$output_dir/stderr"; then
    echo "expected authorization rejection: $case_name" >&2
    exit 1
  fi
  [ ! -s "$output_dir/github-output" ]
  [ ! -e "$output_dir/beta-recovery-authorization.json" ]
  [ -s "$output_dir/stderr" ]
}

for case_name in missing-environment wrong-reviewer admin-bypass wrong-branch; do
  expect_failure "$case_name"
done

grep -Fxq 'repos/fixture/meet-backend/environments/closed-beta-restore' "$tmp/gh.log"
grep -Fxq \
  'repos/fixture/meet-backend/environments/closed-beta-restore/deployment-branch-policies?per_page=100' \
  "$tmp/gh.log"
if grep -Fq \
  'repos/fixture/meet-backend/environments/closed-beta-restore/secrets?per_page=100' \
  "$tmp/gh.log"; then
  echo "unsupported Environment secret inventory endpoint was called" >&2
  exit 1
fi
echo "beta recovery authorization environment fixtures passed"
