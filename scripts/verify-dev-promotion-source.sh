#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --repository PATH --source-checkout PATH --source-sha SHA --output PATH [--git-command COMMAND]" >&2
  exit 2
}

fail() {
  echo "dev promotion source verification failed: $1" >&2
  exit 1
}

repository=
source_checkout=
source_sha=
output=
git_command=git

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
    --output)
      [ "$#" -ge 2 ] && [ -z "$output" ] || usage
      output=$2
      shift 2
      ;;
    --git-command)
      [ "$#" -ge 2 ] && [ "$git_command" = git ] || usage
      git_command=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || usage
[ -d "$repository" ] || usage
[ -d "$source_checkout" ] || usage
[ -n "$output" ] || usage
case "$git_command" in ""|*[[:space:]]*) usage ;; esac
command -v "$git_command" >/dev/null 2>&1 ||
  fail "git command is unavailable"
[ ! -L "$output" ] || fail "output path is unsafe"
if [ -e "$output" ]; then
  [ -f "$output" ] || fail "output path is unsafe"
fi
[ -d "$(dirname -- "$output")" ] || fail "output directory is unavailable"

repo_git() {
  "$git_command" -C "$repository" "$@"
}

source_git() {
  "$git_command" -C "$source_checkout" "$@"
}

repo_git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "repository checkout is invalid"
source_git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "source checkout is invalid"

repo_git fetch --no-tags origin \
  '+refs/heads/dev:refs/remotes/origin/dev' >/dev/null 2>&1 ||
  fail "current dev authority fetch failed"

authority_sha=$(repo_git rev-parse --verify 'refs/remotes/origin/dev^{commit}' 2>/dev/null) ||
  fail "fetched dev authority is unavailable"
[[ "$authority_sha" =~ ^[0-9a-f]{40}$ ]] ||
  fail "fetched dev authority is malformed"

remote_lines=$(repo_git ls-remote --exit-code origin refs/heads/dev 2>/dev/null) ||
  fail "remote dev authority lookup failed"
remote_count=$(printf '%s\n' "$remote_lines" |
  awk -F '\t' '$2 == "refs/heads/dev" { count++ } END { print count + 0 }')
[ "$remote_count" -eq 1 ] ||
  fail "remote dev authority is ambiguous"
remote_sha=$(printf '%s\n' "$remote_lines" |
  awk -F '\t' '$2 == "refs/heads/dev" { print $1 }')
[[ "$remote_sha" =~ ^[0-9a-f]{40}$ ]] ||
  fail "remote dev authority is malformed"
[ "$authority_sha" = "$remote_sha" ] ||
  fail "fetched and current remote dev authority differ"
[ "$source_sha" = "$authority_sha" ] ||
  fail "selected source is not the current dev authority"

head_sha=$(source_git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
  fail "source checkout HEAD is unavailable"
[ "$head_sha" = "$source_sha" ] ||
  fail "source checkout is at another commit"
if source_git symbolic-ref -q HEAD >/dev/null 2>&1; then
  fail "source checkout is not detached"
fi
[ -z "$(source_git status --porcelain=v1 --untracked-files=all 2>/dev/null)" ] ||
  fail "source checkout is not clean"

authority_tree=$(repo_git rev-parse --verify "$source_sha^{tree}" 2>/dev/null) ||
  fail "authority tree is unavailable"
source_tree=$(source_git rev-parse --verify 'HEAD^{tree}' 2>/dev/null) ||
  fail "source tree is unavailable"
[[ "$authority_tree" =~ ^[0-9a-f]{40}$ ]] ||
  fail "authority tree is malformed"
[ "$source_tree" = "$authority_tree" ] ||
  fail "source checkout tree differs from authority"

version_json=$(repo_git show "$source_sha:version.json" 2>/dev/null) ||
  fail "authority version manifest is unavailable"
version=$(jq -er '
  if (type == "object") and ((keys | sort) == ["version"]) and
     ((.version | type) == "string") and
     ((.version | test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")))
  then .version
  else error("invalid version manifest")
  end
' <<<"$version_json" 2>/dev/null) ||
  fail "authority version manifest is not canonical"

tmp_output=$output.tmp.$$
trap 'rm -f -- "$tmp_output"' EXIT HUP INT TERM
jq -cnS \
  --arg schema "meet-backend/dev-promotion-source/v1" \
  --arg sourceSha "$source_sha" \
  --arg authoritySha "$authority_sha" \
  --arg remoteSha "$remote_sha" \
  --arg treeId "$authority_tree" \
  --arg version "$version" '
  {
    schema:$schema,
    sourceSha:$sourceSha,
    authoritySha:$authoritySha,
    remoteSha:$remoteSha,
    treeId:$treeId,
    version:$version,
    detached:true,
    clean:true
  }
' >"$tmp_output" || fail "source authority output construction failed"
chmod 600 "$tmp_output" 2>/dev/null || true
mv -f -- "$tmp_output" "$output" ||
  fail "source authority output publication failed"
trap - EXIT HUP INT TERM
