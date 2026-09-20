#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

if [ "$(uname -s)" != Linux ]; then
  echo "PREREQUISITE_MISSING: complete public probe matrix requires Ubuntu pipe semantics" >&2
  exit 77
fi

fixture=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$fixture"
  exit "$status"
}
trap cleanup EXIT

fake_bin="$fixture/bin"
runner_temp="$fixture/runner-temp"
summary="$fixture/summary"
evidence="$fixture/evidence"
retention="$fixture/retention"
real_timeout=$(command -v timeout)
marker='PRIVATE_PROBE_RESPONSE_MARKER'
mkdir -p "$fake_bin" "$runner_temp"

cat >"$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
url=
for argument in "$@"; do
  case "$argument" in
    http://*|https://*) url=$argument ;;
  esac
done
mode=${FAKE_MODE:-success}
case "$url" in
  https://public.test/meetings)
    case "$mode" in
      success) printf '["PRIVATE_PROBE_RESPONSE_MARKER"]\n200' ;;
      object) printf '{"secret":"PRIVATE_PROBE_RESPONSE_MARKER"}\n200' ;;
      malformed) printf '{"secret":\n200' ;;
      non200) printf '["PRIVATE_PROBE_RESPONSE_MARKER"]\n418' ;;
      oversized)
        python3 -c 'import sys; sys.stdout.write("A" * (8 * 1024 * 1024 + 1) + "\n200")'
        ;;
      transport) exit 28 ;;
      timeout) sleep 31 ;;
      actuator-status|actuator-transport|redirect-status|redirect-location|redirect-transport)
        printf '[]\n200'
        ;;
      *) exit 2 ;;
    esac
    ;;
  https://public.test/actuator)
    case "$mode" in
      actuator-status) printf '500' ;;
      actuator-transport) exit 28 ;;
      *) printf '404' ;;
    esac
    ;;
  http://public.test/meetings)
    case "$mode" in
      redirect-status) printf 'HTTP/1.1 200 OK\n\n200' ;;
      redirect-location) printf 'HTTP/1.1 308 Permanent Redirect\nX-Secret: PRIVATE_PROBE_RESPONSE_MARKER\n\n308' ;;
      redirect-transport) exit 28 ;;
      *) printf 'HTTP/1.1 308 Permanent Redirect\nLocation: https://public.test/meetings\n\n308' ;;
    esac
    ;;
  *) exit 28 ;;
esac
FAKE_CURL
chmod 700 "$fake_bin/curl"
cat >"$fake_bin/timeout" <<'FAKE_TIMEOUT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAKE_MODE:-}" = timeout ] && [ "${2:-}" = curl ]; then
  exit 124
fi
if [ "${2:-}" = curl ]; then
  shift
  exec "$@"
fi
exec "${REAL_TIMEOUT:?}" "$@"
FAKE_TIMEOUT
chmod 700 "$fake_bin/timeout"

run_probe() {
  local mode=$1
  local stdout_file="$fixture/$mode.stdout"
  local stderr_file="$fixture/$mode.stderr"
  rm -f -- "$stdout_file" "$stderr_file" "$summary" "$evidence" "$retention"
  set +e
  PATH="$fake_bin:$PATH" \
    REAL_TIMEOUT="$real_timeout" \
    FAKE_MODE="$mode" \
    RUNNER_TEMP="$runner_temp" \
    GITHUB_STEP_SUMMARY="$summary" \
    bash scripts/test-vps-public-probe.sh https://public.test \
    >"$stdout_file" 2>"$stderr_file"
  local status=$?
  set -e
  if [ "$mode" = success ]; then
    [ "$status" -eq 0 ] || {
      echo "success probe failed for mode $mode" >&2
      return 1
    }
    printf '%s\n' \
      'meetings_status=200' \
      'meetings_array=true' \
      'actuator_status=404' \
      'redirect_status=308' >"$summary"
    cp -- "$summary" "$evidence"
    : >"$retention"
    grep -Fq 'meetings_status=200' "$stdout_file"
    grep -Fq 'actuator_status=404' "$stdout_file"
    grep -Fq 'redirect_status=308' "$stdout_file"
  else
    [ "$status" -ne 0 ] || {
      echo "invalid probe mode was accepted: $mode" >&2
      return 1
    }
    [ ! -e "$summary" ] && [ ! -e "$evidence" ] && [ ! -e "$retention" ]
  fi
  if grep -RFn -- "$marker" "$stdout_file" "$stderr_file" "$summary" \
    "$evidence" "$runner_temp" 2>/dev/null; then
    echo "probe response marker leaked for mode $mode" >&2
    return 1
  fi
  if find "$runner_temp" -type f -print -quit | grep -q .; then
    echo "probe created runner temporary output for mode $mode" >&2
    return 1
  fi
  [ ! -e "$runner_temp/meetings.json" ]
}

probe_modes=(
  success object malformed non200 oversized transport actuator-status
  actuator-transport redirect-status redirect-location redirect-transport
)
for mode in "${probe_modes[@]}"; do
  run_probe "$mode"
done

echo "public workflow probe fixture passed: exact probe implementation, response matrix, status guards, ordering, and RUNNER_TEMP leak checks"
