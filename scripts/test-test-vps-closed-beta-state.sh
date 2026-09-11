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
    '{{.State.Running}}') printf 'true\n';;
    '{{.State.Health.Status}}') printf 'healthy\n';;
    *) exit 1;;
  esac
else exit 1; fi
EOF
chmod +x "$TMP/bin/docker"
unset -f docker 2>/dev/null || true
export PATH="$TMP/bin:$PATH" ROOT="$TMP/root" COMPOSE="$TMP/tooling/production-compose.sh"
hash -r
export IMAGE IMAGE_ID REVISION VERSION RUNTIME_HASH
bash "$VERIFY" --phase predecessor --root "$TMP/root" --compose-script "$TMP/tooling/production-compose.sh" \
  --state-mode empty-closed \
  --state-dir "$TMP/state" --expected-image "$IMAGE" --expected-image-id "$IMAGE_ID" \
  --expected-revision "$REVISION" --expected-version "$VERSION" --expected-runtime-hash "$RUNTIME_HASH" \
  --output "$TMP/predecessor.json"
jq -e '.schema == "meet-backend/test-vps-closed-beta-state/v2" and .phase == "predecessor" and .stateMode == "empty-closed" and .containerHealthy' \
  "$TMP/predecessor.json" >/dev/null

# The probe emits the admin result for every public-url phase.  Exercise the
# phase validator's configured and blank-key contracts across all four phase
# names, rather than treating final as a special case.
VALIDATE=$ROOT_DIR/scripts/validate-test-vps-phase-file.sh
cat >"$TMP/bin/stat" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  %u:%g) printf '0:0\n' ;;
  %a) printf '600\n' ;;
  %s) wc -c <"$3" | tr -d ' ' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/stat"
for phase in predecessor candidate rollback final; do
  for admin_configured in true false; do
    admin_authenticated=false
    admin_blank=true
    if [ "$admin_configured" = true ]; then
      admin_authenticated=true
      admin_blank=false
    fi
    phase_file="$TMP/state/$phase.json"
    jq -n --arg phase "$phase" --arg image "$IMAGE" --arg image_digest "${IMAGE##*@}" \
      --arg image_id "$IMAGE_ID" --arg revision "$REVISION" --arg version "$VERSION" \
      --arg runtime_hash "$RUNTIME_HASH" \
      --argjson admin_configured "$admin_configured" \
      --argjson admin_authenticated "$admin_authenticated" \
      --argjson admin_blank "$admin_blank" '
      {
        schema:"meet-backend/test-vps-closed-beta-state/v2",
        phase:$phase,stateMode:"empty-closed",image:$image,imageId:$image_id,
        revision:$revision,version:$version,runtimeConfigHash:$runtime_hash,
        containerHealthy:true,environmentMatched:true,
        assetsCount:13,assetsVerified:true,
        adminKeyConfigured:$admin_configured,
        adminAuthenticatedDisabled404:$admin_authenticated,
        adminBlankDisabled403:$admin_blank,
        zeroStateProbe:{
          schema:"meet-backend/test-vps-zero-state-probe/v2",
          phase:$phase,image:$image_digest,imageId:$image_id,sourceSha:$revision,
          version:$version,runtimeConfigHash:$runtime_hash,
          admission:{mode:"empty-closed",stateSha256:null},
          database:{
            tables:(reduce [
              "ad_block_communities","ad_block_users","ad_blocks",
              "communities","community_subscribers","community_tags",
              "demo_catalog_state","meeting_participants","meeting_tags",
              "meetings","tags","user_interests","user_social_media","users"
            ][] as $name ({}; .[$name] = 0)),
            totalRows:0
          },
          http:{
            meetingsStatus:200,meetingsJson:true,meetingsCount:0,
            adminKeyConfigured:$admin_configured,
            adminAuthenticatedDisabled404:$admin_authenticated,
            adminBlankDisabled403:$admin_blank
          },
          runtime:{
            containerHealthy:true,topologyVerified:true,hardeningVerified:true,
            volumesVerified:true,postgresWritablePrimary:true,
            nonIdleApplicationTransactions:0,smtpIdleSamples:[0,0]
          },
          zeroState:"closed",zeroStateObserved:true
        }
      }
    ' >"$phase_file"
    PATH="$TMP/bin:$PATH" "$VALIDATE" \
      --root "$TMP/root" --state-dir "$TMP/state" --phase "$phase" \
      --state-mode empty-closed --expected-image "$IMAGE" \
      --expected-image-id "$IMAGE_ID" --expected-revision "$REVISION" \
      --expected-version "$VERSION" --output "$phase_file"
  done
done

if bash "$VERIFY" --phase nope --root "$TMP/root" --compose-script "$TMP/tooling/production-compose.sh" \
  --state-dir "$TMP/state" --expected-image "$IMAGE" --expected-image-id "$IMAGE_ID" \
  --expected-revision "$REVISION" --expected-version "$VERSION" --expected-runtime-hash "$RUNTIME_HASH" \
  --output "$TMP/bad.json" >"$TMP/bad.stdout" 2>"$TMP/bad.stderr"; then
  exit 1
fi
[ ! -s "$TMP/bad.stdout" ] && [ -s "$TMP/bad.stderr" ]
echo "test VPS closed-beta host-state fixtures passed"
