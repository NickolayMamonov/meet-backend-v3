#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

fixture=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$fixture"
  exit "$status"
}
trap cleanup EXIT

fake_bin="$fixture/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
url=
for argument in "$@"; do
  case "$argument" in
    http://*|https://*) url=$argument ;;
  esac
done
case "$url" in
  https://public.test/meetings)
    printf '[]\n200'
    ;;
  https://public.test/actuator)
    printf '404'
    ;;
  http://public.test/meetings)
    printf 'HTTP/1.1 308 Permanent Redirect\nLocation: https://public.test/meetings\n\n308'
    ;;
  https://public.test/admin/demo-catalog/bootstrap)
    printf '403'
    ;;
  *)
    exit 28
    ;;
esac
FAKE_CURL
chmod 700 "$fake_bin/curl"

source scripts/deploy-test-vps-provider-release.sh
PATH="$fake_bin:$PATH" verify_public_contract https://public.test

cat >"$fake_bin/curl" <<'FAILING_CURL'
#!/usr/bin/env bash
set -euo pipefail
exit 28
FAILING_CURL
chmod 700 "$fake_bin/curl"
set +e
failure=$(PATH="$fake_bin:$PATH" bash -c \
  'source scripts/deploy-test-vps-provider-release.sh; verify_public_contract https://public.test' \
  2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
grep -Fq 'public meetings probe failed' <<<"$failure"
echo "public probe fixture passed: success contract, admin guards, redirect, and failure handling"
