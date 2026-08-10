#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 inspect <registry-image> <version> <revision> [--quarantine-file path]" >&2
  exit 2
}

[ "$#" -ge 4 ] || usage
COMMAND=$1
IMAGE=$2
VERSION=$3
REVISION=$4
QUARANTINE_FILE=release-quarantine.json
if [ "$#" -gt 4 ]; then
  [ "$#" -eq 6 ] && [ "$5" = --quarantine-file ] || usage
  QUARANTINE_FILE=$6
fi
[ "$COMMAND" = inspect ] || usage
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "invalid version" >&2
  exit 2
}
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid source revision" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required for identity inspection" >&2; exit 2; }
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

refs=(
  "$IMAGE:v$VERSION"
  "$IMAGE:$VERSION"
  "$IMAGE:sha-$REVISION"
)
digests=()
present=0
missing=0
identity_mismatch=0
inspection_failure=0
latest_present=0

inspect_ref() {
  local ref=$1 output digest
  if ! output=$(docker buildx imagetools inspect "$ref" 2>&1); then
    if grep -Eqi 'manifest unknown|not found|does not exist|name unknown' <<<"$output"; then
      printf '%s absent\n' "${ref##*:}"
      missing=$((missing + 1))
      return 0
    fi
    echo "registry inspection failed for ${ref##*:}; refusing to publish" >&2
    inspection_failure=1
    return 0
  fi
  digest=$(awk '$1 == "Digest:" { print $2; exit }' <<<"$output")
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "registry inspection returned no valid digest for ${ref##*:}" >&2
    inspection_failure=1
    return 0
  fi
  printf '%s %s\n' "${ref##*:}" "$digest"
  digests+=("$digest")
  present=$((present + 1))
}

for ref in "${refs[@]}"; do
  inspect_ref "$ref"
done

latest_output=
if latest_output=$(docker buildx imagetools inspect "$IMAGE:latest" 2>&1); then
  printf 'latest=present\n'
  latest_present=1
else
  if grep -Eqi 'manifest unknown|name unknown|repository does not exist|not found' \
    <<<"$latest_output"; then
    printf 'latest=absent\n'
  else
    printf 'latest=inspection-failed\n'
    inspection_failure=1
  fi
fi

if [ "$inspection_failure" -ne 0 ]; then
  echo "state=inspection-failed"
  exit 1
fi
if [ "$latest_present" -ne 0 ]; then
  {
    printf '{\n'
    printf '  "status": "quarantined",\n'
    printf '  "latestPresent": true,\n'
    printf '  "registryWrites": 0,\n'
    printf '  "reason": "latest-alias-is-forbidden"\n'
    printf '}\n'
  } > "$QUARANTINE_FILE"
  echo "state=quarantined"
  echo "quarantine=$QUARANTINE_FILE"
  exit 42
fi
if [ "$present" -eq 0 ]; then
  echo "state=empty"
  exit 0
fi

unique_digests=$(printf '%s\n' "${digests[@]}" | sort -u | wc -l | tr -d ' ')
if [ "$unique_digests" -eq 1 ]; then
  digest=${digests[0]}
  raw=$(docker buildx imagetools inspect --raw "${refs[0]}@$digest" 2>/dev/null || true)
  image_json=$(docker pull "${refs[0]}@$digest" >/dev/null 2>&1 &&
    docker image inspect "${refs[0]}@$digest" --format '{{json .}}' || true)
  labels=$(jq -c '.Config.Labels // {}' <<<"$image_json" 2>/dev/null || echo '{}')
  platform=$(jq -r '[.Os // "", .Architecture // ""] | join("/")' <<<"$image_json" 2>/dev/null || echo /)
  user=$(jq -r '.Config.User // ""' <<<"$image_json" 2>/dev/null || true)
  label_version=$(jq -r '."org.opencontainers.image.version" // ""' <<<"$labels")
  label_revision=$(jq -r '."org.opencontainers.image.revision" // ""' <<<"$labels")
  label_source=$(jq -r '."org.opencontainers.image.source" // ""' <<<"$labels")
  raw_file=$(mktemp)
  printf '%s\n' "$raw" > "$raw_file"
  evidence=$("$SCRIPT_DIR/verify-oci-evidence.sh" "$IMAGE" "$digest" "$raw_file" 2>/dev/null || true)
  rm -f "$raw_file"
  provenance=$(awk -F= '/^provenance=/{print $2}' <<<"$evidence")
  sbom=$(awk -F= '/^sbom=/{print $2}' <<<"$evidence")
  if [ "$label_version" != "$VERSION" ] ||
     [ "$label_revision" != "$REVISION" ] ||
     [ "$label_source" != "https://github.com/NickolayMamonov/meet-backend-v3" ] ||
     [ "$platform" != "linux/amd64" ] ||
     [ "$user" != "10001:10001" ] ||
     [ "$provenance" != true ] ||
     [ "$sbom" != true ]; then
    identity_mismatch=1
  fi
  printf 'identity version=%s revision=%s source=%s platform=%s user=%s provenance=%s sbom=%s\n' \
    "$label_version" "$label_revision" "$label_source" "$platform" "$user" "$provenance" "$sbom"
fi

if [ "$present" -eq 3 ] && [ "$unique_digests" -eq 1 ] && [ "$identity_mismatch" -eq 0 ]; then
  echo "state=complete"
  echo "digest=${digests[0]}"
  exit 0
fi

# This branch intentionally contains no docker tag/push/delete/copy command.
# Partial, divergent, identity-mismatched, and externally raced states are
# evidence-only quarantine states. A new patch tuple/source SHA supersedes it.
{
  printf '{\n'
  printf '  "status": "quarantined",\n'
  printf '  "version": "%s",\n' "$VERSION"
  printf '  "sourceSha": "%s",\n' "$REVISION"
  printf '  "presentAliases": %s,\n' "$present"
  printf '  "missingAliases": %s,\n' "$missing"
  printf '  "identityMismatch": %s,\n' "$([ "$identity_mismatch" -ne 0 ] && echo true || echo false)"
  printf '  "registryWrites": 0,\n'
  printf '  "reason": "partial-or-divergent-identity-mismatch-or-raced-alias-state"\n'
  printf '}\n'
} > "$QUARANTINE_FILE"
echo "state=quarantined"
echo "quarantine=$QUARANTINE_FILE"
exit 42
