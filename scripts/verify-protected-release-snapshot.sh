#!/usr/bin/env bash
set -euo pipefail

snapshot=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot) snapshot=${2:?}; shift 2 ;;
    *) echo "usage: $0 --snapshot PATH" >&2; exit 2 ;;
  esac
done

[ -f "$snapshot" ] || { echo "snapshot is missing" >&2; exit 1; }
jq -e '
  def required_asset:
    type == "object" and
    (.id | type == "number" and floor == . and . > 0) and
    (.name | type == "string" and length > 0) and
    (.label == null or (.label | type == "string")) and
    (.size | type == "number" and floor == . and . >= 0) and
    (.apiDigest == null or
      (.apiDigest | type == "string" and test("^[A-Za-z0-9+.-]+:[0-9a-f]+$"))) and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$"));
  def required_ref:
    type == "object" and
    (.tag | type == "string" and startswith("v")) and
    (.state == "absent" or
      (.state == "present" and
       (.objectType == "commit" or .objectType == "tag") and
       (.objectSha | type == "string" and test("^[0-9a-f]{40}$")) and
       (.peeledCommitSha | type == "string" and test("^[0-9a-f]{40}$")) and
       (.annotatedChain | type == "array")));
  def required_registry:
    type == "object" and
    (.protectedAliasBindings | type == "object") and
    (.subjectDigest == null or
      (.subjectDigest | type == "string" and test("^sha256:[0-9a-f]{64}$"))) and
    (.subjectAliases | type == "array" and all(.[]; type == "string")) and
    (.versions | type == "array" and all(.[]; (
      type == "object" and
      (.id | type == "number" and floor == . and . > 0) and
      (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.tags | type == "array" and all(.[]; type == "string"))
    ))) and
    (.referrers | type == "array" and all(.[]; (
      type == "object" and
      (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.mediaType | type == "string") and
      (.size | type == "number" and floor == . and . >= 0) and
      (.subjectDigest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.artifactType == null or (.artifactType | type == "string")) and
      (.predicateTypes | type == "array" and all(.[]; type == "string")) and
      (.rawManifestSha256 | type == "string" and test("^[0-9a-f]{64}$"))
    )));
  def required_object:
    type == "object" and
    (.identity | type == "object" and
      (.releaseId | type == "number" and floor == . and . > 0) and
      (.version | type == "string" and test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")) and
      (.tag | type == "string" and startswith("v")) and
      (.sourceSha | type == "string" and test("^[0-9a-f]{40}$"))) and
    (.release | type == "object" and
      (.id | type == "number" and floor == . and . > 0) and
      (.tagName | type == "string") and
      (.targetCommitish | type == "string" and test("^[0-9a-f]{40}$")) and
      (.draft | type == "boolean") and (.immutable | type == "boolean") and
      (.prerelease | type == "boolean") and
      (.bodySha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    (.assets | type == "array" and all(.[]; required_asset)) and
    (.gitRef | required_ref) and
    (.registry | required_registry) and
    (.githubAttestations | type == "array" and all(.[]; (
      type == "object" and
      (.predicateType | type == "string") and
      (.bundleDigest | type == "string")
    )));
  type == "object" and
  .schema == "meet-backend/protected-release-history/v1" and
  (.repository | type == "string" and test("^[^/]+/[^/]+$") and . == ascii_downcase) and
  (.image | type == "string" and test("^ghcr[.]io/") and . == ascii_downcase) and
  (.objects | type == "object") and
  (.objects.blockedV1_1_0 | required_object) and
  (.objects.immutableV1_0_1 | required_object) and
  .objects.blockedV1_1_0.identity.releaseId == 368531227 and
  .objects.blockedV1_1_0.identity.version == "1.1.0" and
  .objects.blockedV1_1_0.identity.tag == "v1.1.0" and
  .objects.blockedV1_1_0.release.id ==
    .objects.blockedV1_1_0.identity.releaseId and
  .objects.blockedV1_1_0.release.tagName == "v1.1.0" and
  .objects.blockedV1_1_0.release.targetCommitish ==
    .objects.blockedV1_1_0.identity.sourceSha and
  .objects.blockedV1_1_0.release.draft == true and
  .objects.blockedV1_1_0.release.immutable == false and
  .objects.blockedV1_1_0.release.publishedAt == null and
  (.objects.blockedV1_1_0.assets | length == 4) and
  .objects.blockedV1_1_0.gitRef.state == "absent" and
  .objects.immutableV1_0_1.identity.releaseId == 367640510 and
  .objects.immutableV1_0_1.identity.version == "1.0.1" and
  .objects.immutableV1_0_1.identity.tag == "v1.0.1" and
  .objects.immutableV1_0_1.release.id ==
    .objects.immutableV1_0_1.identity.releaseId and
  .objects.immutableV1_0_1.release.tagName == "v1.0.1" and
  .objects.immutableV1_0_1.release.targetCommitish ==
    .objects.immutableV1_0_1.identity.sourceSha and
  .objects.immutableV1_0_1.release.draft == false and
  .objects.immutableV1_0_1.release.publishedAt != null and
  (.objects.immutableV1_0_1.assets | length == 4) and
  .objects.immutableV1_0_1.gitRef.state == "present" and
  .objects.immutableV1_0_1.gitRef.peeledCommitSha ==
    .objects.immutableV1_0_1.identity.sourceSha
' "$snapshot" >/dev/null ||
  { echo "protected snapshot schema or identity is invalid" >&2; exit 1; }
