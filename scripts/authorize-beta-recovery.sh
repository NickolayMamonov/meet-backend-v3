#!/usr/bin/env bash
set -euo pipefail
usage(){
  echo "usage: $0 validate-recovery-id ID | validate-age-recipient RECIPIENT | authorize|revalidate --repository OWNER/REPO --source-checkout PATH --source-sha SHA --workflow PATH --output-dir PATH" >&2
  exit 2
}
fail(){ echo "beta recovery authorization failed: $*" >&2; exit 1; }
validate_recovery_id(){ [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || fail "recovery ID malformed"; }
bech32_char_value(){
  case "$1" in
    q) bech32_value_result=0;; p) bech32_value_result=1;;
    z) bech32_value_result=2;; r) bech32_value_result=3;;
    y) bech32_value_result=4;; 9) bech32_value_result=5;;
    x) bech32_value_result=6;; 8) bech32_value_result=7;;
    g) bech32_value_result=8;; f) bech32_value_result=9;;
    2) bech32_value_result=10;; t) bech32_value_result=11;;
    v) bech32_value_result=12;; d) bech32_value_result=13;;
    w) bech32_value_result=14;; 0) bech32_value_result=15;;
    s) bech32_value_result=16;; 3) bech32_value_result=17;;
    j) bech32_value_result=18;; n) bech32_value_result=19;;
    5) bech32_value_result=20;; 4) bech32_value_result=21;;
    k) bech32_value_result=22;; h) bech32_value_result=23;;
    c) bech32_value_result=24;; e) bech32_value_result=25;;
    6) bech32_value_result=26;; m) bech32_value_result=27;;
    u) bech32_value_result=28;; a) bech32_value_result=29;;
    7) bech32_value_result=30;; l) bech32_value_result=31;;
    *) return 1;;
  esac
}
bech32_feed(){
  local top=$((bech32_checksum >> 25))
  bech32_checksum=$(((bech32_checksum & 0x1ffffff) << 5 | $1))
  local i
  for i in 0 1 2 3 4; do
    if (( (top >> i) & 1 )); then
      bech32_checksum=$((bech32_checksum ^ bech32_generator[i]))
    fi
  done
}
validate_age_recipient(){
  local recipient=${1:-} i
  [[ "$recipient" =~ ^age1[0-9a-z]{58}$ ]] || fail "age recipient malformed"
  bech32_checksum=1
  bech32_generator=(0x3b6a57b2 0x26508e6d 0x1ea119fa 0x3d4233dd 0x2a1462b3)
  for i in 3 3 3 0 1 7 5; do bech32_feed "$i"; done
  for ((i=4; i<${#recipient}; i++)); do
    bech32_char_value "${recipient:i:1}" || fail "age recipient malformed"
    bech32_feed "$bech32_value_result"
  done
  (( bech32_checksum == 1 )) || fail "age recipient malformed"
  bech32_char_value "${recipient:55:1}" || fail "age recipient malformed"
  (( (bech32_value_result & 15) == 0 )) || fail "age recipient malformed"
}
mode=${1:-}
case "$mode" in
  validate-recovery-id)
    [ "$#" -eq 2 ] || usage
    validate_recovery_id "$2"
    exit 0
    ;;
  validate-age-recipient)
    [ "$#" -eq 2 ] || usage
    validate_age_recipient "$2"
    exit 0
    ;;
  authorize|revalidate) shift;;
  *) usage;;
esac
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
git -C "$checkout" fetch --no-tags origin \
  '+refs/heads/dev:refs/remotes/origin/dev' \
  '+refs/heads/master:refs/remotes/origin/master' >/dev/null 2>&1 ||
  fail "authority fetch failed"
[ "$(git -C "$checkout" rev-parse HEAD)" = "$source_sha" ] || fail "checkout differs"
[ -z "$(git -C "$checkout" status --porcelain=v1 --untracked-files=all)" ] || fail "checkout is dirty"
[ -z "$(git -C "$checkout" symbolic-ref -q HEAD || true)" ] || fail "checkout is attached"
[ "$(git -C "$checkout" rev-parse refs/remotes/origin/dev)" = "$source_sha" ] || fail "source is not current dev"
master_sha=$(git -C "$checkout" rev-parse refs/remotes/origin/master) ||
  fail "master authority is unavailable"
dev_registration=$(git -C "$checkout" show "refs/remotes/origin/dev:$workflow" |
  sha256sum | awk '{print $1}') || fail "dev registration missing"
master_registration=''
git -C "$checkout" cat-file -e "refs/remotes/origin/master:$workflow" ||
  fail "master registration missing"
master_registration=$(git -C "$checkout" show "refs/remotes/origin/master:$workflow" |
  sha256sum | awk '{print $1}') || fail "master registration unreadable"
[[ "$dev_registration" =~ ^[0-9a-f]{64}$ ]] || fail "dev registration malformed"
[[ "$master_registration" =~ ^[0-9a-f]{64}$ ]] || fail "master registration malformed"
[ "$dev_registration" = "$master_registration" ] || fail "registration drifted"

command -v gh >/dev/null 2>&1 || fail "gh is required"
dispatch=$(gh api "repos/$repository/actions/runs/$GITHUB_RUN_ID") ||
  fail "live dispatch lookup failed"
jq -e --arg sha "$source_sha" --arg workflow "$workflow" '
  type == "object" and .event == "workflow_dispatch" and .head_branch == "dev" and
  .head_sha == $sha and ((.path // "") == $workflow or (.workflow_path // "") == $workflow)
' <<<"$dispatch" >/dev/null || fail "live dispatch differs"
ci=$(gh api "repos/$repository/actions/workflows/ci.yml/runs?branch=dev&head_sha=$source_sha&per_page=100") ||
  fail "exact CI lookup failed"
jq -e --arg sha "$source_sha" '
  [ .workflow_runs[]? |
    select(.path == ".github/workflows/ci.yml" and .head_branch == "dev" and
      .head_sha == $sha and .status == "completed" and .conclusion == "success") ] |
  length > 0
' <<<"$ci" >/dev/null || fail "exact CI is not successful"
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
    registration:{dev:$dev,master:$masterReg,masterWorkflowPresent:true,equal:true},
    toolingDigest:$tools}' >"$tmp"
chmod 600 "$tmp"; mv -f -- "$tmp" "$proof"; trap - EXIT HUP INT TERM
if [ -n "$github_output" ]; then
  {
    echo "authorized=true"
    echo "source_sha=$source_sha"
    echo "tooling_digest=$tooling_digest"
    echo "workflow_digest=$workflow_digest"
  } >>"$github_output"
fi
