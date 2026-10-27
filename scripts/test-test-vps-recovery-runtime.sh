#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "test VPS recovery runtime test failed: $*" >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
probe=$script_dir/probe-test-vps-recovery-runtime.sh
for tool in bash jq mktemp; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
[[ $(uname -s) == Linux ]] || fail "isolated Linux fixture required"
real_jq=$(command -v jq)
bash -n "$probe"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM

make_case(){
  local case_dir="$fixture/$1"
  mkdir -p "$case_dir/bin" "$case_dir/root" "$case_dir/output"
  printf 'BACKEND_IMAGE=offline-fixture\n' >"$case_dir/root/.env.production"
  for suffix in response.UNRELATED headers.UNRELATED tmp.UNRELATED; do
    printf 'unrelated:%s\n' "$suffix" >"$case_dir/output/runtime.json.$suffix"
  done
  cat >"$case_dir/bin/compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "ps -q backend" ] || exit 71
printf 'fixture-container\n'
EOF
  cat >"$case_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = inspect ] || exit 72
case "${4:-}" in
  *State.Running*) printf 'true\n' ;;
  *State.Health*) printf 'healthy\n' ;;
  *'{{.Image}}'*) printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
  *config-hash*) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
  *'{{range .Mounts}}'*) printf 'volume|meet-production_uploads_data\n' ;;
  *) exit 73 ;;
esac
EOF
  cat >"$case_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"${CALL_LOG:?}"
case "${CURL_ACTION:-}" in
  HUP|INT|TERM|KILL) kill "-${CURL_ACTION}" "$PROBE_PID";;
esac
curl_count=0
[ ! -f "${CURL_COUNT_FILE:?}" ] || read -r curl_count <"$CURL_COUNT_FILE"
curl_count=$((curl_count + 1))
printf '%s\n' "$curl_count" >"$CURL_COUNT_FILE"
if [ "${SIGNAL_CURL_NUMBER:-0}" -eq "$curl_count" ]; then
  kill "-${SIGNAL_AT_CURL:?}" "$PROBE_PID"
fi
output=/dev/null headers= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2;;
    -D) headers=$2; shift 2;;
    -w) shift 2;;
    *) url=$1; shift;;
  esac
done
if [ -n "$headers" ]; then
  printf 'location: https://api.whysoezzy.online/meetings\n' >"$headers"
  exit 0
elif [[ "$url" == */meetings ]]; then
  [ "${CURL_ACTION:-}" = FAIL ] && exit 81
  printf '[]\n' >"$output"
  printf '200'
elif [[ "$url" == */actuator ]]; then
  printf '404'
else
  exit 82
fi
EOF
  cat >"$case_dir/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count_file=${MKTEMP_COUNT_FILE:?}
count=0
[ ! -f "$count_file" ] || read -r count <"$count_file"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
[ "${FAIL_MKTEMP_AT:-0}" -ne "$count" ] || exit 83
path=$(/usr/bin/mktemp "$@")
if [ "${SIGNAL_MKTEMP_AT:-0}" -eq "$count" ]; then
  kill "-${SIGNAL_AT_MKTEMP:?}" "$PROBE_PID"
fi
printf '%s\n' "$path"
EOF
  cat >"$case_dir/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FAIL_JQ_STAGE:-}" in
  validation) [ "${1:-}" != -e ] || exit 86 ;;
  serialization)
    if [[ "$*" == *meet-backend/test-vps-recovery-runtime/v1* ]]; then
      exit 87
    fi
    ;;
esac
exec "$REAL_JQ" "$@"
EOF
  cat >"$case_dir/bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    "${FAIL_CLEANUP_PATH:-}"*)
      [ -n "${FAIL_CLEANUP_PATH:-}" ] || continue
      printf 'cleanup failed %s\n' "$arg" >>"${CALL_LOG:?}"
      exit 84
      ;;
  esac
done
exec /bin/rm "$@"
EOF
  cat >"$case_dir/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${FAIL_MV:-0}" != 1 ] || exit 85
/bin/mv "$@"
if [ -n "${SIGNAL_AFTER_RENAME:-}" ]; then
  kill "-${SIGNAL_AFTER_RENAME}" "$PROBE_PID"
fi
EOF
  cat >"$case_dir/bin/chmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/bin/chmod "$@"
if [ "${FAIL_CHMOD:-0}" = 1 ]; then
  exit 88
fi
if [ -n "${SIGNAL_BEFORE_PUBLISH:-}" ]; then
  kill "-${SIGNAL_BEFORE_PUBLISH}" "$PROBE_PID"
fi
EOF
  chmod 755 "$case_dir/bin/"*
}

invoke(){
  local case_dir=$1
  shift
  env CALL_LOG="$case_dir/calls.log" \
    REAL_JQ="$real_jq" \
    MKTEMP_COUNT_FILE="$case_dir/mktemp-count" \
    CURL_COUNT_FILE="$case_dir/curl-count" \
    PATH="$case_dir/bin:$PATH" \
    bash -c 'PROBE_PID=$$; export PROBE_PID; exec bash "$@"' \
      bash "$probe" --root "$case_dir/root" \
      --compose-script "$case_dir/bin/compose" --output "$case_dir/output/runtime.json" \
      --public-url https://api.whysoezzy.online "$@"
}

assert_unrelated_files(){
  local case_dir=$1 suffix
  for suffix in response.UNRELATED headers.UNRELATED tmp.UNRELATED; do
    [ "$(cat "$case_dir/output/runtime.json.$suffix")" = "unrelated:$suffix" ] ||
      fail "unrelated similarly named file changed: $suffix"
  done
}

assert_no_allocations(){
  local case_dir=$1 file
  for file in "$case_dir"/output/runtime.json.response.* \
    "$case_dir"/output/runtime.json.headers.* "$case_dir"/output/runtime.json.tmp.*; do
    case "$file" in *.UNRELATED) continue;; esac
    [ ! -e "$file" ] || fail "temporary survived cleanup: $file"
  done
  assert_unrelated_files "$case_dir"
}

# Success preserves the output contract, mode, and unrelated lookalikes.
make_case success
success="$fixture/success"
invoke "$success"
jq -e '.schema=="meet-backend/test-vps-recovery-runtime/v1" and .healthy==true and
  .runtime.health=="healthy" and .https.meetingsJson==true' "$success/output/runtime.json" >/dev/null
[ "$(stat -c '%a' "$success/output/runtime.json")" = 600 ] || fail "published mode changed"
assert_no_allocations "$success"

# Fail each allocation in turn; successful prior allocations are cleaned.
for allocation in 1 2 3; do
  make_case "mktemp-$allocation"
  case_dir="$fixture/mktemp-$allocation"
  status=0
  FAIL_MKTEMP_AT=$allocation invoke "$case_dir" || status=$?
  if [ "$status" -eq 0 ]; then
    fail "mktemp failure at allocation $allocation succeeded"
  fi
  [ "$status" -eq 83 ] || fail "mktemp failure status changed to $status"
  assert_no_allocations "$case_dir"
  [ ! -e "$case_dir/output/runtime.json" ] || fail "failed allocation published output"
done

make_case jq-validation-failure
case_dir="$fixture/jq-validation-failure"
status=0
FAIL_JQ_STAGE=validation invoke "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || status=$?
[ "$status" -eq 1 ] || fail "jq validation failure status changed to $status"
grep -Fq 'meetings response is not JSON array' "$case_dir/stderr" ||
  fail "jq validation failure was not propagated"
assert_no_allocations "$case_dir"
[ ! -e "$case_dir/output/runtime.json" ] || fail "jq validation failure published output"

make_case jq-serialization-failure
case_dir="$fixture/jq-serialization-failure"
status=0
FAIL_JQ_STAGE=serialization invoke "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || status=$?
[ "$status" -eq 87 ] || fail "jq serialization failure status changed to $status"
assert_no_allocations "$case_dir"
[ ! -e "$case_dir/output/runtime.json" ] || fail "jq serialization failure published output"

make_case chmod-failure
case_dir="$fixture/chmod-failure"
status=0
FAIL_CHMOD=1 invoke "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || status=$?
[ "$status" -eq 88 ] || fail "chmod failure status changed to $status"
assert_no_allocations "$case_dir"
[ ! -e "$case_dir/output/runtime.json" ] || fail "chmod failure published output"

make_case curl-failure
case_dir="$fixture/curl-failure"
status=0
CURL_ACTION=FAIL invoke "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || status=$?
[ "$status" -eq 1 ] || fail "curl failure status changed to $status"
grep -Fq 'meetings status differs' "$case_dir/stderr" ||
  fail "curl failure was not propagated"
assert_no_allocations "$case_dir"

make_case rename-failure
case_dir="$fixture/rename-failure"
status=0
FAIL_MV=1 invoke "$case_dir" || status=$?
[ "$status" -eq 85 ] || fail "publication rename failure status changed to $status"
assert_no_allocations "$case_dir"
[ ! -e "$case_dir/output/runtime.json" ] || fail "failed rename published output"

make_case cleanup-failure
case_dir="$fixture/cleanup-failure"
if FAIL_CLEANUP_PATH="$case_dir/output/runtime.json.response." \
  invoke "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"; then
  fail "cleanup failure reported success"
fi
grep -Fq 'temporary-file cleanup failed' "$case_dir/stderr" ||
  fail "cleanup failure was not diagnosed"
jq -e '.healthy==true' "$case_dir/output/runtime.json" >/dev/null ||
  fail "cleanup failure unexpectedly removed the published output"
[ "$(find "$case_dir/output" -maxdepth 1 -name 'runtime.json.response.*' ! -name '*.UNRELATED' | wc -l)" -eq 1 ] ||
  fail "cleanup failure did not leave the failed unlink visible"
[ "$(find "$case_dir/output" -maxdepth 1 -name 'runtime.json.headers.*' ! -name '*.UNRELATED' | wc -l)" -eq 0 ] ||
  fail "cleanup failure did not remove the owned header temporary"
[ "$(find "$case_dir/output" -maxdepth 1 -name 'runtime.json.tmp.*' ! -name '*.UNRELATED' | wc -l)" -eq 0 ] ||
  fail "cleanup failure did not remove the owned publication temporary"
for file in response.UNRELATED headers.UNRELATED tmp.UNRELATED; do
  [ "$(cat "$case_dir/output/runtime.json.$file")" = "unrelated:$file" ] ||
    fail "cleanup failure changed an unrelated lookalike: $file"
done

# Signals at each allocation and HTTP boundary must exit immediately and
# clean invocation-owned files.
for signal in HUP INT TERM; do
  for allocation in 1 2 3; do
    make_case "signal-allocation-$signal-$allocation"
    case_dir="$fixture/signal-allocation-$signal-$allocation"
    status=0
    SIGNAL_MKTEMP_AT=$allocation SIGNAL_AT_MKTEMP=$signal invoke "$case_dir" || status=$?
    case "$signal:$status" in HUP:129|INT:130|TERM:143) ;; *)
      fail "$signal at allocation $allocation returned $status";;
    esac
    assert_no_allocations "$case_dir"
  done
done
for signal in HUP INT TERM; do
  for curl_number in 1 2 3; do
    make_case "signal-$signal-$curl_number"
    case_dir="$fixture/signal-$signal-$curl_number"
    status=0
    SIGNAL_CURL_NUMBER=$curl_number SIGNAL_AT_CURL=$signal invoke "$case_dir" || status=$?
    case "$signal:$status" in HUP:129|INT:130|TERM:143) ;; *)
      fail "$signal at HTTP boundary $curl_number returned $status";;
    esac
    assert_no_allocations "$case_dir"
    [ "$(grep -c '^curl ' "$case_dir/calls.log")" -eq "$curl_number" ] ||
      fail "$signal resumed probe commands"
  done
done
for signal in HUP INT TERM; do
  make_case "signal-publish-$signal"
  case_dir="$fixture/signal-publish-$signal"
  status=0
  SIGNAL_BEFORE_PUBLISH=$signal invoke "$case_dir" || status=$?
  case "$signal:$status" in HUP:129|INT:130|TERM:143) ;; *)
    fail "$signal before publication returned $status";;
  esac
  assert_no_allocations "$case_dir"
  [ ! -e "$case_dir/output/runtime.json" ] ||
    fail "$signal before publication published output"

  make_case "signal-after-publish-$signal"
  case_dir="$fixture/signal-after-publish-$signal"
  status=0
  SIGNAL_AFTER_RENAME=$signal invoke "$case_dir" || status=$?
  case "$signal:$status" in HUP:129|INT:130|TERM:143) ;; *)
    fail "$signal after publication returned $status";;
  esac
  assert_no_allocations "$case_dir"
  jq -e '.healthy==true' "$case_dir/output/runtime.json" >/dev/null ||
    fail "$signal after publication lost the published output"
done

# SIGKILL cannot run traps. A later invocation may not sweep those leftovers.
make_case killed
case_dir="$fixture/killed"
status=0
CURL_ACTION=KILL invoke "$case_dir" 2>"$case_dir/sigkill.stderr" || status=$?
[ "$status" -ne 0 ] || fail "SIGKILL fixture unexpectedly succeeded"
shopt -s nullglob
leftovers=("$case_dir"/output/runtime.json.response.* "$case_dir"/output/runtime.json.headers.*)
[ "${#leftovers[@]}" -gt 0 ] || fail "SIGKILL did not leave expected crash evidence"
before=$(printf '%s\n' "${leftovers[@]}" | sort | xargs -r sha256sum)
unset CURL_ACTION
invoke "$case_dir"
after=$(printf '%s\n' "${leftovers[@]}" | sort | xargs -r sha256sum)
[ "$before" = "$after" ] || fail "later invocation swept historical crash evidence"
jq -e '.healthy==true' "$case_dir/output/runtime.json" >/dev/null
echo "test VPS recovery runtime allocation contract passed: success=2 mktemp-failure=3 jq-validation-failure=1 jq-serialization-failure=1 chmod-failure=1 curl-failure=1 rename-failure=1 cleanup-failure=1 allocation-signals=9 http-signals=9 prepublish-signals=3 postpublish-signals=3 sigkill-no-sweep=1"
