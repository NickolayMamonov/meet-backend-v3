#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --root PATH --state-dir PATH --phase predecessor|candidate|rollback|final --output PATH" >&2
  exit 2
}

fail() {
  echo "test VPS phase validation failed: $*" >&2
  exit 1
}

root=
state_dir=
phase=
output=
expected_image=
expected_image_id=
expected_revision=
expected_version=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
    --state-dir) [ "$#" -ge 2 ] || usage; state_dir=$2; shift 2 ;;
    --phase) [ "$#" -ge 2 ] || usage; phase=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    --expected-image) [ "$#" -ge 2 ] || usage; expected_image=$2; shift 2 ;;
    --expected-image-id) [ "$#" -ge 2 ] || usage; expected_image_id=$2; shift 2 ;;
    --expected-revision) [ "$#" -ge 2 ] || usage; expected_revision=$2; shift 2 ;;
    --expected-version) [ "$#" -ge 2 ] || usage; expected_version=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$root" != *..* ]] || usage
[[ "$state_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$state_dir" != *..* ]] || usage
case "$phase" in predecessor|candidate|rollback|final) ;; *) usage ;; esac
if [ -n "$expected_image" ]; then
  [[ "$expected_image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] || usage
fi
if [ -n "$expected_image_id" ]; then
  [[ "$expected_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
fi
if [ -n "$expected_revision" ]; then
  [[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || usage
fi
if [ -n "$expected_version" ]; then
  [[ "$expected_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
fi
[[ "$output" = "$state_dir/$phase.json" ]] || usage
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -d "$root" ] && [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || fail "phase root is unavailable"
[ -f "$output" ] && [ ! -L "$output" ] || fail "phase file is missing or unsafe"
owner=$(stat -c '%u:%g' "$output") || fail "phase owner cannot be read"
[ "$owner" = "0:0" ] || fail "phase owner is not root"
mode=$(stat -c '%a' "$output") || fail "phase mode cannot be read"
[ "$mode" -le 600 ] || fail "phase mode is too broad"
size=$(stat -c '%s' "$output") || fail "phase size cannot be read"
[ "$size" -le 65536 ] || fail "phase file is too large"
canonical=$(realpath -e -- "$output") || fail "phase path cannot be canonicalized"
case "$canonical" in "$state_dir/$phase.json") ;; *) fail "phase path escaped state directory" ;; esac
jq -e --arg phase "$phase" \
  --arg expected_image "$expected_image" \
  --arg expected_image_id "$expected_image_id" \
  --arg expected_revision "$expected_revision" \
  --arg expected_version "$expected_version" '
  type == "object" and
  (keys | sort) == [
    "adminAuthenticatedDisabled404","adminBlankDisabled403","adminKeyConfigured",
    "assetsCount","assetsVerified","containerHealthy","environmentMatched",
    "image","imageId","phase","revision","runtimeConfigHash","schema","version"
  ] and
  .schema == "meet-backend/test-vps-closed-beta-state/v1" and
  .phase == $phase and
  (if $expected_image == "" then true else .image == $expected_image end) and
  (if $expected_image_id == "" then true else .imageId == $expected_image_id end) and
  (if $expected_revision == "" then true else .revision == $expected_revision end) and
  (if $expected_version == "" then true else .version == $expected_version end) and
  (.image | type == "string" and test("^ghcr[.]io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$")) and
  (.imageId | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
  (.revision | type == "string" and test("^[0-9a-f]{40}$")) and
  (.version | type == "string" and test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")) and
  (.runtimeConfigHash | type == "string" and test("^[0-9a-f]{64}$")) and
  .containerHealthy == true and
  .environmentMatched == true and
  (.assetsCount | type == "number" and floor == . and . >= 0) and
  (.assetsVerified | type == "boolean") and
  (.adminKeyConfigured | type == "boolean") and
  (.adminAuthenticatedDisabled404 | type == "boolean") and
  (.adminBlankDisabled403 | type == "boolean") and
  (if .phase != "final"
   then .adminAuthenticatedDisabled404 == false and .adminBlankDisabled403 == false
   elif .adminKeyConfigured
   then .adminAuthenticatedDisabled404 == true and .adminBlankDisabled403 == false
   else .adminAuthenticatedDisabled404 == false and .adminBlankDisabled403 == true
   end)
' "$output" >/dev/null || fail "phase schema is invalid"
