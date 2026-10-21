#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
workflow=.github/workflows/deploy-test-vps.yml
tmp=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$tmp"
  exit "$status"
}
trap cleanup EXIT

fail() {
  echo "$1" >&2
  exit 1
}

workflow_text=$(<"$workflow")
grep -Fq 'failure_policy:' <<<"$workflow_text" ||
  fail "workflow has no failure_policy input"
grep -Fq 'default: automatic-rollback' <<<"$workflow_text" ||
  fail "legacy automatic-rollback is not the workflow default"
grep -Fq 'type: choice' <<<"$workflow_text" ||
  fail "failure policy is not a workflow choice"
grep -Fq -- '- automatic-rollback' <<<"$workflow_text" ||
  fail "automatic-rollback choice is missing"
grep -Fq -- '- manual-stop' <<<"$workflow_text" ||
  fail "manual-stop choice is missing"
grep -Fq 'FAILURE_POLICY: ${{ inputs.failure_policy }}' <<<"$workflow_text" ||
  fail "failure policy is not passed through the job environment"

manual_preflight_line=$(grep -nF \
  'if [ "$FAILURE_POLICY" = manual-stop ] &&' "$workflow" | cut -d: -f1)
ssh_line=$(grep -nF 'timeout 60s ssh -F "$SSH_CONFIG" test-vps bash -s --' \
  "$workflow" | head -n 1 | cut -d: -f1)
[ -n "$manual_preflight_line" ] && [ -n "$ssh_line" ] &&
  [ "$manual_preflight_line" -lt "$ssh_line" ] ||
  fail "manual-stop/drill preflight is not before remote SSH actions"

remote_argument_count=$(grep -Fc -- '--failure-policy "$FAILURE_POLICY"' "$workflow")
[ "$remote_argument_count" -eq 2 ] ||
  fail "both rollback-drill and final-deploy must pass the policy"
grep -Fq -- '--mode rollback-drill' "$workflow" ||
  fail "rollback-drill remote invocation is missing"
grep -Fq -- '--mode deploy' "$workflow" ||
  fail "final-deploy remote invocation is missing"
grep -Fq 'rollback=completed previous_image_id=$previous_id' "$workflow" ||
  fail "automatic rollback drill proof was removed"
grep -Fq '[ "$status" -eq 86 ]' "$workflow" ||
  fail "rollback drill exit contract was removed"

extract_preflight() {
  awk '
    /- name: Protected test-VPS preflight/ { in_step = 1 }
    in_step && /        run: \|/ { in_run = 1; next }
    in_step && in_run && /^          / {
      sub(/^          /, "")
      print
      next
    }
    in_step && in_run { exit }
  ' "$workflow"
}
extract_preflight >"$tmp/preflight.sh"
[ -s "$tmp/preflight.sh" ] || fail "could not extract actual workflow preflight"

awk '
  /output=\$\(timeout 900s ssh -F "\$SSH_CONFIG" test-vps/ { capture = 1 }
  capture {
    sub(/^          /, "")
    print
    if (/--mode rollback-drill 2>&1\)/) exit
  }
' "$workflow" >"$tmp/rollback-drill-remote.sh"
printf '%s\n' 'status=$?' >>"$tmp/rollback-drill-remote.sh"
[ -s "$tmp/rollback-drill-remote.sh" ] ||
  fail "could not extract actual rollback-drill remote command"
awk '
  /if ! timeout 900s ssh -F "\$SSH_CONFIG" test-vps/ { capture = 1 }
  capture {
    sub(/^          /, "")
    sub(/^if ! /, "")
    sub(/[[:space:]]*\|[[:space:]]*$/, "")
    print
    if (/--mode deploy/) exit
  }
' "$workflow" >"$tmp/final-deploy-remote.sh"
[ -s "$tmp/final-deploy-remote.sh" ] ||
  fail "could not extract actual final-deploy remote command"
awk '
  /- name: Deploy selected release successfully/ { capture = 1 }
  capture && /^      - name:/ { exit }
  capture { print }
' "$workflow" >"$tmp/final-deploy-step.txt"
! grep -Eq 'rollback=completed|ROLLBACK_RESTORED|rolled-back' \
  "$tmp/final-deploy-step.txt" ||
  fail "final-deploy reporting claims predecessor restoration"
awk '
  /- name: Deploy selected release successfully/ { capture = 1 }
  capture && /^      - name:/ { exit }
  capture { print }
' "$workflow" >"$tmp/final-deploy-step.txt"
! grep -Eq 'rollback=completed|ROLLBACK_RESTORED|rolled-back' \
  "$tmp/final-deploy-step.txt" ||
  fail "final deployment reporting claims predecessor restoration"

run_preflight() {
  local policy=$1 drill=$2 status
  set +e
  TAG=v1.2.0 \
    RUN_ROLLBACK_DRILL="$drill" \
    FAILURE_POLICY="$policy" \
    HOST=example.invalid PORT=22 SSH_USER=deploy PATH_ON_HOST=/srv/meet \
    HOST_FINGERPRINT=SHA256:abcdef SSH_PRIVATE_KEY='-----BEGIN OPENSSH PRIVATE KEY-----' \
    bash "$tmp/preflight.sh" >"$tmp/preflight.out" 2>"$tmp/preflight.err"
  status=$?
  set -e
  return "$status"
}

ssh() {
  printf '%s\n' "$*" >>"$tmp/ssh.log"
  return "${SSH_STATUS:-0}"
}
timeout() {
  shift
  "$@"
}

run_workflow_routing() {
  local policy=$1 drill=$2 status
  : >"$tmp/ssh.log"
  if ! run_preflight "$policy" "$drill"; then
    return 1
  fi
  export FAILURE_POLICY=$policy
  export SSH_CONFIG=stub
  export REMOTE_TOOLING=/remote/tooling
  export PATH_ON_HOST=/srv/meet
  export IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3
  export DIGEST=sha256:aaaaaaaa
  export SOURCE_SHA=bbbbbbbb
  export VERSION=1.2.0
  export GITHUB_RUN_ID=1
  export GITHUB_RUN_ATTEMPT=1
  export PUBLIC_URL=https://example.invalid
  if [ "$drill" = true ]; then
    SSH_STATUS=86
    set +e
    eval "$(<"$tmp/rollback-drill-remote.sh")"
    set -e
    [ "$status" -eq 86 ] ||
      fail "actual rollback-drill block did not preserve its remote exit status"
  fi
  SSH_STATUS=0
  eval "$(<"$tmp/final-deploy-remote.sh")"
}

if run_workflow_routing manual-stop true; then
  fail "manual-stop with rollback drill reached a remote action"
fi
[ ! -s "$tmp/ssh.log" ] ||
  fail "manual-stop with rollback drill attempted SSH before rejection"
run_workflow_routing manual-stop false ||
  fail "manual-stop final-deploy routing failed"
[ "$(wc -l <"$tmp/ssh.log")" -eq 1 ] ||
  fail "manual-stop did not reach exactly one final-deploy invocation"
grep -Fq -- '--failure-policy manual-stop' "$tmp/ssh.log" ||
  fail "manual-stop was altered before the final remote invocation"
grep -Fq -- '--mode deploy' "$tmp/ssh.log" ||
  fail "manual-stop did not reach final-deploy"
run_workflow_routing automatic-rollback true ||
  fail "automatic-rollback routing failed"
[ "$(wc -l <"$tmp/ssh.log")" -eq 2 ] ||
  fail "automatic-rollback did not reach both remote invocations"
grep -Fq -- '--failure-policy automatic-rollback' "$tmp/ssh.log" ||
  fail "automatic-rollback was altered before a remote invocation"
grep -Fq -- '--mode rollback-drill' "$tmp/ssh.log" ||
  fail "automatic-rollback did not route to rollback-drill"
grep -Fq -- '--mode deploy' "$tmp/ssh.log" ||
  fail "automatic-rollback did not route to final-deploy"

if run_preflight unknown false; then
  fail "actual workflow preflight accepted an unknown failure policy"
fi

! grep -Fq 'rollback=completed' "$tmp/ssh.log" ||
  fail "manual-stop route claimed predecessor restoration"

echo "timepad_workflow_routing=passed"
