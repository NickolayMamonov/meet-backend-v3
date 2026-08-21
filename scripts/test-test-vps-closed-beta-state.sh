#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-test-vps-closed-beta-state.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REVISION=cccccccccccccccccccccccccccccccccccccccc
VERSION=1.2.0
RUNTIME_HASH=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
mkdir -p "$TMP/bin" "$TMP/root" "$TMP/state" "$TMP/tooling"
cp -- "$VERIFY" "$TMP/tooling/verify-test-vps-closed-beta-state.sh"
chmod +x "$TMP/tooling/verify-test-vps-closed-beta-state.sh"
VERIFY=$TMP/tooling/verify-test-vps-closed-beta-state.sh
printf 'BACKEND_IMAGE=%s\nBACKEND_REVISION=%s\nBACKEND_VERSION=%s\n' "$IMAGE" "$REVISION" "$VERSION" >"$TMP/root/.env.production"
printf 'services:\n  backend:\n' >"$TMP/root/docker-compose.production.yml"
cat >"$TMP/tooling/test-vps-runtime-invariants.sh" <<'EOF'
runtime_compose() { printf 'backend-container\n'; }
runtime_release_field() {
  case "$2" in BACKEND_IMAGE) printf '%s\n' "$IMAGE";; BACKEND_REVISION) printf '%s\n' "$REVISION";; BACKEND_VERSION) printf '%s\n' "$VERSION";; *) return 1;; esac
}
verify_environment_matches_container() { return 0; }
EOF
cat >"$TMP/tooling/production-compose.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/tooling/production-compose.sh"
cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = image ] && [ "$2" = inspect ]; then
  case "$5" in
    '{{.Id}}') printf '%s\n' "$IMAGE_ID";;
    *org.opencontainers.image.source*) printf '%s\n' 'https://github.com/NickolayMamonov/meet-backend-v3';;
    *org.opencontainers.image.revision*) printf '%s\n' "$REVISION";;
    *org.opencontainers.image.version*) printf '%s\n' "$VERSION";;
    '{{.Config.User}}') printf '10001:10001\n';;
    *) exit 1;;
  esac
elif [ "$1" = inspect ]; then
  case "$4" in
    '{{.Image}}') printf '%s\n' "$IMAGE_ID";;
    *Config.Image*) printf '%s\n' "$IMAGE";;
    *com.docker.compose.config-hash*) printf '%s\n' "$RUNTIME_HASH";;
    *) exit 1;;
  esac
else exit 1; fi
EOF
chmod +x "$TMP/bin/docker"
unset -f docker 2>/dev/null || true
export PATH="$TMP/bin:$PATH" ROOT="$TMP/root" COMPOSE="$TMP/tooling/production-compose.sh"
hash -r
export IMAGE IMAGE_ID REVISION VERSION RUNTIME_HASH
"$VERIFY" --phase predecessor --root "$TMP/root" --compose-script "$TMP/tooling/production-compose.sh" \
  --state-dir "$TMP/state" --expected-image "$IMAGE" --expected-image-id "$IMAGE_ID" \
  --expected-revision "$REVISION" --expected-version "$VERSION" --expected-runtime-hash "$RUNTIME_HASH" \
  --output "$TMP/predecessor.json"
jq -e '.schema == "meet-backend/test-vps-closed-beta-state/v1" and .phase == "predecessor" and .containerHealthy' \
  "$TMP/predecessor.json" >/dev/null
if "$VERIFY" --phase nope --root "$TMP/root" --compose-script "$TMP/tooling/production-compose.sh" \
  --state-dir "$TMP/state" --expected-image "$IMAGE" --expected-image-id "$IMAGE_ID" \
  --expected-revision "$REVISION" --expected-version "$VERSION" --expected-runtime-hash "$RUNTIME_HASH" \
  --output "$TMP/bad.json" >"$TMP/bad.stdout" 2>"$TMP/bad.stderr"; then
  exit 1
fi
[ ! -s "$TMP/bad.stdout" ] && [ -s "$TMP/bad.stderr" ]
echo "test VPS closed-beta host-state fixtures passed"
