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
QUARANTINE_FILE=${6:-release-quarantine.json}
[ "$COMMAND" = inspect ] || usage
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "invalid version" >&2
  exit 2
}
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid source revision" >&2; exit 2; }

refs=(
  "$IMAGE:v$VERSION"
  "$IMAGE:$VERSION"
  "$IMAGE:sha-$REVISION"
)
digests=()
present=0
missing=0
for ref in "${refs[@]}"; do
  if ! output=$(docker buildx imagetools inspect "$ref" 2>&1); then
    if ! grep -Eqi 'manifest unknown|not found|does not exist|name unknown' <<<"$output"; then
      echo "registry inspection failed for ${ref##*:}; refusing to classify or publish" >&2
      exit 1
    fi
  fi
  digest=$(printf '%s\n' "$output" | awk '$1 == "Digest:" { print $2; exit }')
  if [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf '%s %s\n' "${ref##*:}" "$digest"
    digests+=("$digest")
    present=$((present + 1))
  else
    printf '%s absent\n' "${ref##*:}"
    missing=$((missing + 1))
  fi
done

if [ "$present" -eq 0 ]; then
  echo "state=empty"
  exit 0
fi

if [ "$present" -eq 3 ] && [ "${digests[0]}" = "${digests[1]}" ] &&
   [ "${digests[1]}" = "${digests[2]}" ]; then
  echo "state=complete"
  echo "digest=${digests[0]}"
  exit 0
fi

# This branch intentionally contains no docker tag/push/delete/copy command.
# A partial, divergent, or externally raced package is evidence only. A new
# patch tuple/source SHA must supersede it through Release Please.
{
  printf '{\n'
  printf '  "status": "quarantined",\n'
  printf '  "version": "%s",\n' "$VERSION"
  printf '  "sourceSha": "%s",\n' "$REVISION"
  printf '  "presentAliases": %s,\n' "$present"
  printf '  "missingAliases": %s,\n' "$missing"
  printf '  "registryWrites": 0,\n'
  printf '  "reason": "partial-or-divergent-or-raced-alias-state"\n'
  printf '}\n'
} > "$QUARANTINE_FILE"
echo "state=quarantined"
echo "quarantine=$QUARANTINE_FILE"
exit 42
