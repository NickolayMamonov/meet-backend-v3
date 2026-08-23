#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --repository OWNER/REPO --source-checkout PATH --source-sha SHA --workflow PATH --output-dir PATH --github-output PATH" >&2
  exit 2
}

fail() {
  echo "dev promotion authorization failed: $*" >&2
  exit 1
}

repository=
source_checkout=
source_sha=
workflow=
output_dir=
github_output=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository)
      [ "$#" -ge 2 ] && [ -z "$repository" ] || usage
      repository=$2
      shift 2
      ;;
    --source-checkout)
      [ "$#" -ge 2 ] && [ -z "$source_checkout" ] || usage
      source_checkout=$2
      shift 2
      ;;
    --source-sha)
      [ "$#" -ge 2 ] && [ -z "$source_sha" ] || usage
      source_sha=$2
      shift 2
      ;;
    --workflow)
      [ "$#" -ge 2 ] && [ -z "$workflow" ] || usage
      workflow=$2
      shift 2
      ;;
    --output-dir)
      [ "$#" -ge 2 ] && [ -z "$output_dir" ] || usage
      output_dir=$2
      shift 2
      ;;
    --github-output)
      [ "$#" -ge 2 ] && [ -z "$github_output" ] || usage
      github_output=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || usage
[ -d "$source_checkout" ] || usage
[ -d "$output_dir" ] || usage
[ -n "$workflow" ] || usage
[ -n "$github_output" ] || usage
[ ! -L "$github_output" ] || fail "GITHUB_OUTPUT path is unsafe"
[ -d "$(dirname -- "$github_output")" ] || usage
command -v git >/dev/null 2>&1 || fail "git is required"
command -v gh >/dev/null 2>&1 || fail "gh is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_REF:?GITHUB_REF is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"

[ "$GITHUB_EVENT_NAME" = workflow_dispatch ] || fail "event is not workflow_dispatch"
[ "$GITHUB_REF" = refs/heads/dev ] || fail "ref is not refs/heads/dev"
[ "$GITHUB_SHA" = "$source_sha" ] || fail "run SHA differs from selected source"

git -C "$source_checkout" fetch --no-tags origin dev master >/dev/null 2>&1 ||
  fail "current dev and master authority fetch failed"

tmp=$(mktemp -d "$output_dir/authorize.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -r -- "$tmp"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

source_proof="$tmp/dev-promotion-source.json"
scripts/verify-dev-promotion-source.sh \
  --repository "$source_checkout" \
  --source-checkout "$source_checkout" \
  --source-sha "$source_sha" \
  --output "$source_proof"

jq -e '
  (type == "object") and
  ((keys | sort) == [
    "authoritySha","clean","detached","remoteSha","schema",
    "sourceSha","treeId","version"
  ]) and
  ((.schema | type) == "string") and
  (.schema == "meet-backend/dev-promotion-source/v1") and
  ((.sourceSha | type) == "string") and
  ((.authoritySha | type) == "string") and
  ((.remoteSha | type) == "string") and
  ((.treeId | type) == "string") and
  ((.version | type) == "string") and
  ((.detached | type) == "boolean") and
  ((.clean | type) == "boolean") and
  (.detached == true) and
  (.clean == true) and
  (.sourceSha == $sourceSha) and
  (.authoritySha == $sourceSha) and
  (.remoteSha == $sourceSha) and
  (.treeId | test("^[0-9a-f]{40}$"))
' --arg sourceSha "$source_sha" "$source_proof" >/dev/null ||
  fail "source authority proof is malformed or not source-bound"
version=$(jq -er '.version' "$source_proof") ||
  fail "source authority version is unavailable"

dispatch=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID") ||
  fail "live run lookup failed"
jq -e '
  (type == "object") and
  ((.event | type) == "string") and
  ((.head_branch | type) == "string") and
  ((.head_sha | type) == "string") and
  (.event == "workflow_dispatch") and
  (.head_branch == "dev") and
  (.head_sha == $sourceSha)
' --arg sourceSha "$source_sha" <<<"$dispatch" >/dev/null ||
  fail "live run identity is malformed or mismatched"

check_environment() {
  local environment_name=$1
  local environment
  environment=$(gh api "repos/$GITHUB_REPOSITORY/environments/$environment_name") ||
    fail "$environment_name environment lookup failed"
  jq -e '
    (type == "object") and
    ((.name | type) == "string") and
    ((.deployment_branch_policy | type) == "object") and
    ((.deployment_branch_policy.custom_branch_policies | type) == "boolean") and
    ((.deployment_branch_policy.protected_branches | type) == "boolean") and
    (.name == $name) and
    (.deployment_branch_policy.custom_branch_policies == true) and
    (.deployment_branch_policy.protected_branches == false)
  ' --arg name "$environment_name" <<<"$environment" >/dev/null ||
    fail "$environment_name environment policy is malformed or mismatched"
}

check_environment closed-beta-promotion
branches="$tmp/closed-beta-promotion-branch-policy.json"
gh api \
  "repos/$GITHUB_REPOSITORY/environments/closed-beta-promotion/deployment-branch-policies?per_page=100" \
  >"$branches" || fail "closed-beta-promotion branch policy lookup failed"
scripts/verify-test-promotion-environment-policy.sh --input "$branches" >/dev/null

check_environment test-vps
test_vps_branches="$tmp/test-vps-branch-policy.json"
gh api \
  "repos/$GITHUB_REPOSITORY/environments/test-vps/deployment-branch-policies?per_page=100" \
  >"$test_vps_branches" || fail "test-vps branch policy lookup failed"
scripts/verify-test-promotion-environment-policy.sh --input "$test_vps_branches" >/dev/null

authority_sha=$(git -C "$source_checkout" rev-parse --verify refs/remotes/origin/dev^{commit}) ||
  fail "fetched dev authority is unavailable"
[ "$authority_sha" = "$source_sha" ] ||
  fail "selected source is not the fetched current dev authority"
head_sha=$(git -C "$source_checkout" rev-parse --verify HEAD^{commit}) ||
  fail "source checkout HEAD is unavailable"
[ "$head_sha" = "$source_sha" ] ||
  fail "source checkout is at another commit"
git -C "$source_checkout" symbolic-ref -q HEAD >/dev/null 2>&1 &&
  fail "source checkout is not detached"
[ -z "$(git -C "$source_checkout" status --porcelain=v1 --untracked-files=all)" ] ||
  fail "source checkout is not clean"
tree_id=$(git -C "$source_checkout" rev-parse --verify HEAD^{tree}) ||
  fail "source checkout tree is unavailable"
jq -e --arg tree "$tree_id" '.treeId == $tree' "$source_proof" >/dev/null ||
  fail "source authority tree proof does not match checkout"

master_registration_sha=$(cd "$source_checkout" &&
  MSYS_NO_PATHCONV=1 git show "refs/remotes/origin/master:$workflow" |
  sha256sum | awk '{print $1}') || fail "master workflow registration lookup failed"
registration_sha=$(cd "$source_checkout" &&
  MSYS_NO_PATHCONV=1 git show "refs/remotes/origin/dev:$workflow" |
  sha256sum | awk '{print $1}') || fail "dev workflow registration lookup failed"
[[ "$master_registration_sha" =~ ^[0-9a-f]{64}$ ]] ||
  fail "master registration digest is malformed"
[[ "$registration_sha" =~ ^[0-9a-f]{64}$ ]] ||
  fail "dev registration digest is malformed"
[ "$master_registration_sha" = "$registration_sha" ] ||
  fail "dev and master workflow registrations differ"
master_sha=$(git -C "$source_checkout" rev-parse --verify refs/remotes/origin/master^{commit}) ||
  fail "master authority is unavailable"
dev_sha=$(git -C "$source_checkout" rev-parse --verify refs/remotes/origin/dev^{commit}) ||
  fail "dev authority is unavailable"
[[ "$master_sha" =~ ^[0-9a-f]{40}$ ]] || fail "master authority is malformed"
[[ "$dev_sha" =~ ^[0-9a-f]{40}$ ]] || fail "dev authority is malformed"

required_checks="$tmp/required-checks.json"
scripts/verify-test-promotion-required-checks.sh \
  --repository "$repository" \
  --source-sha "$source_sha" \
  --output "$required_checks"

jq -e '
  (type == "object") and
  ((keys | sort) == [
    "allRequiredChecksSuccessful","exactSha","requiredJobs",
    "runId","schema","sourceSha","verifiedJobs","workflow"
  ]) and
  ((.schema | type) == "string") and
  (.schema == "meet-backend/test-promotion-required-checks/v1") and
  ((.workflow | type) == "string") and (.workflow == "ci.yml") and
  ((.sourceSha | type) == "string") and (.sourceSha == $sourceSha) and
  ((.runId | type) == "number") and
  ((.requiredJobs | type) == "array") and
  ((.verifiedJobs | type) == "array") and
  ((.exactSha | type) == "boolean") and (.exactSha == true) and
  ((.allRequiredChecksSuccessful | type) == "boolean") and
  (.allRequiredChecksSuccessful == true)
' --arg sourceSha "$source_sha" "$required_checks" >/dev/null ||
  fail "required-check proof is malformed or not source-bound"

authorization_proof="$tmp/promotion-authorization.json"
jq -cnS \
  --arg event "$GITHUB_EVENT_NAME" \
  --arg ref "$GITHUB_REF" \
  --arg sourceSha "$source_sha" \
  --arg masterSha "$master_sha" \
  --arg devSha "$dev_sha" \
  --arg workflow "$workflow" \
  --arg masterRegistrationSha "$master_registration_sha" \
  --arg registrationSha "$registration_sha" '
  {
    schema:"meet-backend/test-promotion-authorization/v1",
    event:$event,
    ref:$ref,
    sourceSha:$sourceSha,
    masterSha:$masterSha,
    devSha:$devSha,
    workflow:$workflow,
    masterRegistrationSha:$masterRegistrationSha,
    devRegistrationSha:$registrationSha,
    authorized:true
  }
' >"$authorization_proof" || fail "authorization proof construction failed"

outputs="$tmp/github-output"
{
  echo "authorized=true"
  echo "source_sha=$source_sha"
  echo "tree_id=$tree_id"
  echo "version=$version"
  echo "master_registration_sha=$master_registration_sha"
  echo "registration_sha=$registration_sha"
} >"$outputs" || fail "authorization output construction failed"

mv -f -- "$source_proof" "$output_dir/dev-promotion-source.json" ||
  fail "source authority artifact publication failed"
mv -f -- "$required_checks" "$output_dir/required-checks.json" ||
  fail "required-check artifact publication failed"
mv -f -- "$authorization_proof" "$output_dir/promotion-authorization.json" ||
  fail "authorization artifact publication failed"
cat "$outputs" >>"$github_output" ||
  fail "GitHub output publication failed"
