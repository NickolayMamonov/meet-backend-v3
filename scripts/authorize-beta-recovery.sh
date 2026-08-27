#!/usr/bin/env bash
set -euo pipefail
usage(){ echo "usage: $0 authorize|revalidate --repository OWNER/REPO --source-checkout PATH --source-sha SHA --workflow PATH --output-dir PATH" >&2; exit 2; }
fail(){ echo "beta recovery authorization failed: $*" >&2; exit 1; }
mode=${1:-}; case "$mode" in authorize|revalidate) shift;; *) usage;; esac
repository='' checkout='' source_sha='' workflow='' output_dir='' github_output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) [ "$#" -ge 2 ] && [ -z "$repository" ] || usage; repository=$2; shift 2;;
    --source-checkout) [ "$#" -ge 2 ] && [ -z "$checkout" ] || usage; checkout=$2; shift 2;;
    --source-sha) [ "$#" -ge 2 ] && [ -z "$source_sha" ] || usage; source_sha=$2; shift 2;;
    --workflow) [ "$#" -ge 2 ] && [ -z "$workflow" ] || usage; workflow=$2; shift 2;;
    --output-dir) [ "$#" -ge 2 ] && [ -z "$output_dir" ] || usage; output_dir=$2; shift 2;;
    --github-output) [ "$#" -ge 2 ] && [ -z "$github_output" ] || usage; github_output=$2; shift 2;;
    *) usage;;
  esac
done
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || usage
[ -d "$checkout" ] && [ -d "$output_dir" ] && [ -n "$workflow" ] || usage
[ -z "$github_output" ] || { [ ! -L "$github_output" ] && [ -d "$(dirname -- "$github_output")" ]; } || usage
for tool in git jq sha256sum; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
[ "${GITHUB_REPOSITORY:-}" = "$repository" ] || fail "repository differs"
[ "${GITHUB_SHA:-}" = "$source_sha" ] || fail "SHA differs"
[ "${GITHUB_REF:-}" = refs/heads/dev ] || fail "ref differs"
[ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] || fail "event differs"
git -C "$checkout" fetch --no-tags origin dev master >/dev/null 2>&1 || fail "authority fetch failed"
[ "$(git -C "$checkout" rev-parse HEAD)" = "$source_sha" ] || fail "checkout differs"
[ -z "$(git -C "$checkout" status --porcelain=v1 --untracked-files=all)" ] || fail "checkout is dirty"
[ -z "$(git -C "$checkout" symbolic-ref -q HEAD || true)" ] || fail "checkout is attached"
[ "$(git -C "$checkout" rev-parse refs/remotes/origin/dev)" = "$source_sha" ] || fail "source is not current dev"
master_sha=$(git -C "$checkout" rev-parse refs/remotes/origin/master)
dev_registration=$(git -C "$checkout" show "refs/remotes/origin/dev:$workflow" | sha256sum | awk '{print $1}') || fail "dev registration missing"
master_registration=$(git -C "$checkout" show "refs/remotes/origin/master:$workflow" | sha256sum | awk '{print $1}') || fail "master registration missing"
[ "$dev_registration" = "$master_registration" ] || fail "registration drifted"
if [ "$mode" = authorize ]; then
  command -v gh >/dev/null 2>&1 || fail "gh is required"
  dispatch=$(gh api "repos/$repository/actions/runs/$GITHUB_RUN_ID") || fail "dispatch lookup failed"
  jq -e --arg sha "$source_sha" '.event == "workflow_dispatch" and .head_branch == "dev" and .head_sha == $sha' <<<"$dispatch" >/dev/null || fail "dispatch differs"
  ci=$(gh api "repos/$repository/actions/runs?workflow_id=ci.yml&head_sha=$source_sha") || fail "CI lookup failed"
  jq -e --arg sha "$source_sha" '[.workflow_runs[]?] | any(.[]; .head_sha == $sha and .conclusion == "success")' <<<"$ci" >/dev/null || fail "exact CI is not successful"
fi
files=(
  scripts/authorize-beta-recovery.sh scripts/run-beta-recovery-capture.sh
  scripts/run-beta-recovery-restore.sh scripts/build-beta-recovery-evidence.sh
  scripts/probe-test-vps-recovery-runtime.sh scripts/backup-production.sh
  scripts/beta-recovery-database-proof.sql scripts/beta-recovery-media-proof.sh
)
tooling_digest=$(for file in "${files[@]}"; do [ -f "$checkout/$file" ] || fail "missing tooling: $file"; (cd "$checkout" && sha256sum -- "$file"); done | sort | sha256sum | awk '{print $1}')
workflow_digest=$(git -C "$checkout" show "HEAD:$workflow" | sha256sum | awk '{print $1}')
proof=$output_dir/beta-recovery-authorization.json; tmp=$proof.tmp.$$
trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
jq -cnS --arg mode "$mode" --arg sha "$source_sha" --arg master "$master_sha" \
  --arg dev "$dev_registration" --arg masterReg "$master_registration" \
  --arg tools "$tooling_digest" --arg wf "$workflow_digest" \
  '{schema:"meet-backend/beta-recovery-authorization/v1",mode:$mode,authorized:true,
    sourceSha:$sha,masterSha:$master,workflowDigest:$wf,
    registration:{dev:$dev,master:$masterReg,equal:true},toolingDigest:$tools}' >"$tmp"
chmod 600 "$tmp"; mv -f -- "$tmp" "$proof"; trap - EXIT HUP INT TERM
if [ -n "$github_output" ]; then
  {
    echo "authorized=true"
    echo "source_sha=$source_sha"
    echo "tooling_digest=$tooling_digest"
    echo "workflow_digest=$workflow_digest"
  } >>"$github_output"
fi
