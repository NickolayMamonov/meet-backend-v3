#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --event schedule|workflow_dispatch --run-ref refs/heads/master --default-ref refs/heads/master --scheduler-sha SHA --checkout-sha SHA --ci-sha SHA --environment NAME" >&2
  exit 2
}

event='' run_ref='' default_ref='' scheduler_sha='' checkout_sha='' ci_sha='' environment=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event) [ "$#" -ge 2 ] || usage; event=$2; shift 2 ;;
    --run-ref) [ "$#" -ge 2 ] || usage; run_ref=$2; shift 2 ;;
    --default-ref) [ "$#" -ge 2 ] || usage; default_ref=$2; shift 2 ;;
    --scheduler-sha) [ "$#" -ge 2 ] || usage; scheduler_sha=$2; shift 2 ;;
    --checkout-sha) [ "$#" -ge 2 ] || usage; checkout_sha=$2; shift 2 ;;
    --ci-sha) [ "$#" -ge 2 ] || usage; ci_sha=$2; shift 2 ;;
    --environment) [ "$#" -ge 2 ] || usage; environment=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$event" in schedule|workflow_dispatch) ;; *) usage ;; esac
[ "$run_ref" = refs/heads/master ] && [ "$default_ref" = refs/heads/master ] || {
  echo "recurring scheduler must run from the authorized master ref" >&2; exit 1;
}
for sha in "$scheduler_sha" "$checkout_sha" "$ci_sha"; do
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "revision is invalid" >&2; exit 1; }
done
[[ "$environment" =~ ^closed-beta-recurring-(capture|probe|restore|promote|prune|monitor)$ ]] ||
  { echo "recurring environment is invalid" >&2; exit 1; }
[ "$scheduler_sha" != "$checkout_sha" ] || {
  echo "scheduler and detached tooling revisions must remain distinct evidence" >&2; exit 1;
}
printf 'recurring_authorized=true environment=%s run_ref=%s scheduler_sha=%s checkout_sha=%s ci_sha=%s\n' \
  "$environment" "$run_ref" "$scheduler_sha" "$checkout_sha" "$ci_sha"
