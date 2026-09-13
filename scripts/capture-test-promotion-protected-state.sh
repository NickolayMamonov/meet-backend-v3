#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 --input PATH --output PATH [--candidate-alias ALIAS]" >&2; exit 2; }
fail() { echo "test-promotion protected-state capture failed: $*" >&2; exit 1; }

input=
output=
candidate_alias=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) [ "$#" -ge 2 ] && [ -z "$input" ] || usage; input=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2 ;;
    --candidate-alias)
      [ "$#" -ge 2 ] && [ -z "$candidate_alias" ] || usage
      candidate_alias=$2
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$input" ] && [ -n "$output" ] || usage
[ -f "$input" ] && [ ! -L "$input" ] || fail "input is missing or unsafe"
[ ! -L "$output" ] || fail "output is unsafe"
[ -d "$(dirname -- "$output")" ] || fail "output directory is unavailable"
[ -z "$candidate_alias" ] ||
  [[ "$candidate_alias" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail "candidate alias is malformed"
command -v jq >/dev/null 2>&1 || fail "jq is required"

temporary=$output.tmp.$$
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM

# The complete API/registry capture is an explicit input shim.  This command
# intentionally has no network client, registry client, or mutation command.
if ! jq -cS \
  --arg proofSha db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529 \
  --arg checksum 'db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529 *docs/evidence/MEE2-48-protected-history-v1.json' \
  --arg candidateAlias "$candidate_alias" '
  def sha40: type == "string" and test("^[0-9a-f]{40}$");
  def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
  def semver: type == "string" and test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$");
  def keys_are($expected):
    . as $value |
    ($expected | sort) as $expected_keys |
    (($value | type) == "object") and
    (($value | keys | sort) == $expected_keys);
  def member($array;$value): ($array | index($value)) != null;
  def valid_authority:
    . as $a |
    ($a.schema == "meet-backend/image-attestation-authority/v1") and
    ($a.scope == "protected-release") and
    ($a.repository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    ($a.image | type == "string" and test("^ghcr[.]io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    ($a.releaseId | type == "number" and floor == . and . > 0) and
    ($a.tag | type == "string" and test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
    ($a.version | type == "string" and semver and . == ($a.tag | sub("^v"; ""))) and
    ($a.sourceRepository | type == "string" and test("^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    ($a.releaseSourceDigest | sha40) and ($a.certificateSourceDigest | sha40) and ($a.signerDigest | sha40) and
    ($a.sourceRef == "refs/heads/dev") and
    ($a.signerWorkflow | type == "string" and startswith(".github/workflows/")) and
    ($a.certificateIdentity == ($a.sourceRepository + "/" + $a.signerWorkflow + "@" + $a.sourceRef)) and
    ($a.oidcIssuer == "https://token.actions.githubusercontent.com") and
    ($a.predicateType == "https://slsa.dev/provenance/v1") and
    ($a.rootDigest | digest) and ($a.platformDigest | digest) and
    ($a.subject | type == "object" and (.name | type == "string" and length > 0) and (.digest | digest) and .digest == $a.rootDigest) and
    ($a.evidenceStorage | type == "object" and (.kind == "oci-registry-bundle" or .kind == "github-api-workflow-artifact"));

  def valid_evidence:
    . as $e |
    ($e.schema == "meet-backend/image-attestation-evidence/v2") and
    ($e.sourceRepository | type == "string" and test("^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    ($e.releaseSourceDigest | sha40) and ($e.certificateSourceDigest | sha40) and ($e.signerDigest | sha40) and
    ($e.sourceRef == "refs/heads/dev") and
    ($e.signerWorkflow | type == "string" and startswith(".github/workflows/")) and
    ($e.certificateIdentity == ($e.sourceRepository + "/" + $e.signerWorkflow + "@" + $e.sourceRef)) and
    ($e.oidcIssuer == "https://token.actions.githubusercontent.com") and
    ($e.predicateType == "https://slsa.dev/provenance/v1") and
    ($e.rootDigest | digest) and ($e.platformDigest | digest) and
    ($e.subject | type == "object" and (.name | type == "string" and length > 0) and (.digest | digest) and .digest == $e.rootDigest) and
    ($e.evidenceStorage | type == "object" and (.kind == "oci-registry-bundle" or .kind == "github-api-workflow-artifact"));

  def expected_assets:
    [
      {id:515612606, name:"release-manifest.json", size:695,
       apiDigest:"sha256:428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb",
       downloadSha256:"428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb"},
      {id:515612616, name:"image-index.json", size:857,
       apiDigest:"sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda",
       downloadSha256:"e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda"},
      {id:515612629, name:"image-inspect.txt", size:849,
       apiDigest:"sha256:614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3",
       downloadSha256:"614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3"},
      {id:515612640, name:"SHA256SUMS", size:249,
       apiDigest:"sha256:6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271",
       downloadSha256:"6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271"}
    ];
  def valid_subject_exact:
    type == "object" and
    keys_are(["digest","name"]) and
    (.name | type == "string" and length > 0) and
    (.digest | digest);
  def valid_asset_exact:
    type == "object" and
    keys_are(["apiDigest","downloadSha256","id","name","size"]) and
    (.id | type == "number" and floor == . and . > 0) and
    (.name | type == "string" and length > 0) and
    (.size | type == "number" and floor == . and . >= 0) and
    (.apiDigest | digest) and
    (.downloadSha256 | type == "string" and test("^[0-9a-f]{64}$"));
  def valid_api_storage_exact:
    . as $s |
    type == "object" and
    keys_are(["asset","assets","bundleDigest","kind"]) and
    .kind == "github-api-workflow-artifact" and
    (.bundleDigest | digest) and
    (.asset | valid_asset_exact) and
    (.assets | type == "array" and length == 4 and (map(valid_asset_exact) | all)) and
    ([.assets[].id] | unique | length == 4) and
    ([.assets[].name] | unique | length == 4) and
    any($s.assets[]; . == $s.asset);
  def valid_oci_authority_storage_exact:
    type == "object" and
    keys_are(["kind"]) and
    .kind == "oci-registry-bundle";
  def valid_oci_evidence_storage_exact:
    . as $s |
    type == "object" and
    keys_are(["bundleDigest","bundleLayerDigest","bundleLayerMediaType",
      "bundleLayerSize","closure","kind","signatureManifestDigest"]) and
    .kind == "oci-registry-bundle" and
    (.bundleDigest | digest) and
    (.signatureManifestDigest | digest) and
    (.bundleLayerDigest | digest) and
    .bundleLayerMediaType == "application/vnd.dev.sigstore.bundle.v0.3+json" and
    (.bundleLayerSize | type == "number" and floor == . and . > 0) and
    (.closure |
      type == "object" and
      keys_are(["bundleDigest","bundleLayerDigest","bundleLayerMediaType",
        "bundleLayerSize","signatureManifestDigest"]) and
      (.bundleDigest | digest) and
      (.signatureManifestDigest | digest) and
      (.bundleLayerDigest | digest) and
      .bundleLayerMediaType == "application/vnd.dev.sigstore.bundle.v0.3+json" and
      (.bundleLayerSize | type == "number" and floor == . and . > 0)) and
    .bundleDigest == .closure.bundleDigest and
    .signatureManifestDigest == .closure.signatureManifestDigest and
    .bundleLayerDigest == .closure.bundleLayerDigest and
    .bundleLayerMediaType == .closure.bundleLayerMediaType and
    .bundleLayerSize == .closure.bundleLayerSize;
  def valid_authority_exact:
    type == "object" and
    keys_are(["certificateIdentity","certificateSourceDigest","evidenceStorage","image",
      "oidcIssuer","platformDigest","predicateType","releaseId","releaseSourceDigest",
      "repository","rootDigest","schema","scope","signerDigest","signerWorkflow",
      "sourceRef","sourceRepository","subject","tag","version"]) and
    .schema == "meet-backend/image-attestation-authority/v1" and
    .scope == "protected-release" and
    .repository == "NickolayMamonov/meet-backend-v3" and
    .image == "ghcr.io/nickolaymamonov/meet-backend-v3" and
    .sourceRepository == "https://github.com/NickolayMamonov/meet-backend-v3" and
    (.releaseSourceDigest | sha40) and
    (.certificateSourceDigest | sha40) and
    (.signerDigest | sha40) and
    .sourceRef == "refs/heads/dev" and
    .signerWorkflow == ".github/workflows/release-please.yml" and
    .certificateIdentity == (.sourceRepository + "/" + .signerWorkflow + "@" + .sourceRef) and
    .oidcIssuer == "https://token.actions.githubusercontent.com" and
    .predicateType == "https://slsa.dev/provenance/v1" and
    (.rootDigest | digest) and
    (.platformDigest | digest) and
    (.subject | valid_subject_exact) and
    (.evidenceStorage | valid_oci_authority_storage_exact or valid_api_storage_exact);
  def valid_evidence_exact:
    type == "object" and
    keys_are(["certificateIdentity","certificateSourceDigest","evidenceStorage","oidcIssuer",
      "platformDigest","predicateType","releaseSourceDigest","rootDigest","schema",
      "signerDigest","signerWorkflow","sourceRef","sourceRepository","subject"]) and
    .schema == "meet-backend/image-attestation-evidence/v2" and
    .sourceRepository == "https://github.com/NickolayMamonov/meet-backend-v3" and
    (.releaseSourceDigest | sha40) and
    (.certificateSourceDigest | sha40) and
    (.signerDigest | sha40) and
    .sourceRef == "refs/heads/dev" and
    .signerWorkflow == ".github/workflows/release-please.yml" and
    .certificateIdentity == (.sourceRepository + "/" + .signerWorkflow + "@" + .sourceRef) and
    .oidcIssuer == "https://token.actions.githubusercontent.com" and
    .predicateType == "https://slsa.dev/provenance/v1" and
    (.rootDigest | digest) and
    (.platformDigest | digest) and
    (.subject | valid_subject_exact) and
    (.evidenceStorage | valid_oci_evidence_storage_exact or valid_api_storage_exact);
  def authority_matches($a;$r;$rel):
    $a.releaseId == $rel.id and
    $a.tag == $rel.tag_name and
    $a.version == ($rel.tag_name | sub("^v"; "")) and
    $a.releaseSourceDigest == $rel.target_commitish and
    $a.rootDigest == $r.digest and
    $a.platformDigest == $r.platformDigest and
    $a.subject == {name:(if $a.releaseId == 367640510 then
      "ghcr.io/nickolaymamonov/meet-backend-v3" else "image-index.json" end),digest:$r.digest} and
    (if $a.releaseId == 367640510 then
      $a.tag == "v1.0.1" and
      $a.version == "1.0.1" and
      $a.releaseSourceDigest == "d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc" and
      $a.rootDigest == "sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6" and
      $a.certificateSourceDigest == "4bff2902511e8e739d7604bf120b121429e60aeb" and
      $a.signerDigest == "4bff2902511e8e739d7604bf120b121429e60aeb" and
      $a.evidenceStorage == {kind:"oci-registry-bundle"}
    elif $a.releaseId == 371012814 then
      $a.tag == "v1.2.0" and
      $a.version == "1.2.0" and
      $a.releaseSourceDigest == "9b6d2b06c0336ab8d153564dcf6328e81c4d7b36" and
      $a.rootDigest == "sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda" and
      $a.certificateSourceDigest == "9af0723444f918594101999a4338b418607cbd01" and
      $a.signerDigest == "9af0723444f918594101999a4338b418607cbd01" and
      $a.evidenceStorage == {
        kind:"github-api-workflow-artifact",
        bundleDigest:"sha256:cf1f5d905c0bb97ca2013b3dd8aa415fb331a63dfec860e0382e5690339e5958",
        asset:expected_assets[1],
        assets:expected_assets
      }
    else false end);
  def evidence_matches($e;$a):
    $e.sourceRepository == $a.sourceRepository and
    $e.releaseSourceDigest == $a.releaseSourceDigest and
    $e.certificateSourceDigest == $a.certificateSourceDigest and
    $e.signerDigest == $a.signerDigest and
    $e.sourceRef == $a.sourceRef and
    $e.signerWorkflow == $a.signerWorkflow and
    $e.certificateIdentity == $a.certificateIdentity and
    $e.oidcIssuer == $a.oidcIssuer and
    $e.predicateType == $a.predicateType and
    $e.rootDigest == $a.rootDigest and
    $e.platformDigest == $a.platformDigest and
    $e.subject == $a.subject and
    $e.evidenceStorage.kind == $a.evidenceStorage.kind and
    (if $a.evidenceStorage.kind == "github-api-workflow-artifact" then
      $e.evidenceStorage == $a.evidenceStorage else true end);
  def project_asset:
    {id:.id,name:.name,size:.size,apiDigest:.apiDigest,downloadSha256:.downloadSha256};
  def project_authority:
    . as $a |
    {schema:$a.schema,scope:$a.scope,repository:$a.repository,image:$a.image,
     releaseId:$a.releaseId,tag:$a.tag,version:$a.version,
     sourceRepository:$a.sourceRepository,releaseSourceDigest:$a.releaseSourceDigest,
     certificateSourceDigest:$a.certificateSourceDigest,signerDigest:$a.signerDigest,
     sourceRef:$a.sourceRef,signerWorkflow:$a.signerWorkflow,
     certificateIdentity:$a.certificateIdentity,oidcIssuer:$a.oidcIssuer,
     predicateType:$a.predicateType,rootDigest:$a.rootDigest,
     platformDigest:$a.platformDigest,
     subject:{name:$a.subject.name,digest:$a.subject.digest},
     evidenceStorage:(if $a.evidenceStorage.kind == "oci-registry-bundle" then
       {kind:$a.evidenceStorage.kind}
     else
       {kind:$a.evidenceStorage.kind,bundleDigest:$a.evidenceStorage.bundleDigest,
        asset:($a.evidenceStorage.asset | project_asset),
        assets:[$a.evidenceStorage.assets[] | project_asset]}
     end)};
  def project_evidence:
    . as $e |
    {schema:$e.schema,sourceRepository:$e.sourceRepository,
     releaseSourceDigest:$e.releaseSourceDigest,
     certificateSourceDigest:$e.certificateSourceDigest,signerDigest:$e.signerDigest,
     sourceRef:$e.sourceRef,signerWorkflow:$e.signerWorkflow,
     certificateIdentity:$e.certificateIdentity,oidcIssuer:$e.oidcIssuer,
     predicateType:$e.predicateType,rootDigest:$e.rootDigest,
     platformDigest:$e.platformDigest,
     subject:{name:$e.subject.name,digest:$e.subject.digest},
     evidenceStorage:(if $e.evidenceStorage.kind == "oci-registry-bundle" then
       {kind:$e.evidenceStorage.kind,bundleDigest:$e.evidenceStorage.bundleDigest,
        signatureManifestDigest:$e.evidenceStorage.signatureManifestDigest,
        bundleLayerDigest:$e.evidenceStorage.bundleLayerDigest,
        bundleLayerSize:$e.evidenceStorage.bundleLayerSize,
        bundleLayerMediaType:$e.evidenceStorage.bundleLayerMediaType,
        closure:{
          signatureManifestDigest:$e.evidenceStorage.closure.signatureManifestDigest,
          bundleLayerDigest:$e.evidenceStorage.closure.bundleLayerDigest,
          bundleLayerMediaType:$e.evidenceStorage.closure.bundleLayerMediaType,
          bundleLayerSize:$e.evidenceStorage.closure.bundleLayerSize,
          bundleDigest:$e.evidenceStorage.closure.bundleDigest}}
     else
       {kind:$e.evidenceStorage.kind,bundleDigest:$e.evidenceStorage.bundleDigest,
        asset:($e.evidenceStorage.asset | project_asset),
        assets:[$e.evidenceStorage.assets[] | project_asset]}
     end)};
  . as $raw |
  (
    type == "object" and
    keys_are(["image","proof","releases","registry","repository","schema","tagRefs"]) and
    .schema == "meet-backend/test-promotion-protected-state-input/v2" and
    (.repository == "nickolaymamonov/meet-backend-v3") and
    (.image == "ghcr.io/nickolaymamonov/meet-backend-v3") and
    (.releases | type == "array" and length > 0) and
    (.releases | (map((keys | sort) == ["assets","draft","id","immutable","prerelease","protected","published_at","tag_name","target_commitish"]) | all)) and
    (.releases | (map(.assets | map((keys | sort) == ["id","name","sha256","size"]) | all) | all)) and
    (.releases | (map(.id | type == "number" and floor == . and . > 0) | all)) and
    (.releases | (map(.tag_name | type == "string" and test("^v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")) | all)) and
    (.releases | (map(.target_commitish | sha40) | all)) and
    (.releases | (map(.draft | type == "boolean") | all)) and
    (.releases | (map(.immutable | type == "boolean") | all)) and
    (.releases | (map(.protected | type == "boolean") | all)) and
    (.releases | (map(.prerelease | type == "boolean") | all)) and
    (.releases | (map(.assets |
      map((.id | type == "number" and floor == . and . > 0) and
          (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$")) and
          (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.size | type == "number" and floor == . and . >= 0)) | all) | all)) and
    (.releases | (map(.id) | unique | length) == length) and
    (.tagRefs | type == "array" and length > 0) and
    (.tagRefs | (map((keys | sort) == ["objectSha","objectType","peeledCommitSha","state","tag"]) | all)) and
    (.tagRefs | (map(.tag) | unique | length) == length) and
    (.tagRefs | (map(.tag | type == "string" and startswith("v")) | all)) and
    (.tagRefs | (map(
      if .state == "absent" then
        .objectType == null and .objectSha == null and .peeledCommitSha == null
      elif .state == "present" then
        (.objectType == "commit" or .objectType == "tag") and
        (.objectSha | sha40) and (.peeledCommitSha | sha40)
      else false end) | all)) and
    (.registry | keys_are(["authorities","evidence","manifests","subjects","versions"])) and
    (.registry.versions | type == "array" and
      (map((keys | sort) == ["digest","id","tags"]) | all) and
      (map(.digest | digest) | all) and
      ((map(.id) | unique | length) == length) and
      ((map(.digest) | unique | length) == length)) and
    (.registry.versions | (map(.tags | type == "array") | all)) and
    (.registry.versions | (map(.tags | all(.[]?; type == "string" and length > 0)) | all)) and
    (.registry.subjects | type == "array" and
      (map((keys | sort) == ["aliases","digest","kind","platformDigest","releaseId","rootDigest"]) | all) and
      (map(.digest | digest) | all) and
      ((map(.digest) | unique | length) == length) and
      (map(.kind == "root" or .kind == "platform") | all) and
      (map(.releaseId | type == "number" and floor == . and . > 0) | all) and
      (map(.aliases | type == "array" and all(.[]?; type == "string" and length > 0)) | all)) and
    (.registry.manifests | type == "array" and
      (map((keys | sort) == ["artifactType","children","digest","mediaType","predicateTypes","size","subjectDigest"]) | all) and
      (map(.digest | digest) | all) and
      ((map(.digest) | unique | length) == length) and
      (map(.children | type == "array") | all) and
      (map(.mediaType | type == "string" and length > 0) | all) and
      (map(.size | type == "number" and floor == . and . >= 0) | all) and
      (map(.predicateTypes | type == "array" and all(.[]?; type == "string" and length > 0)) | all)) and
    (.registry.authorities | type == "array" and
      (map(valid_authority) | all) and
      ((map(.releaseId) | unique | length) == length) and
      ((map(.rootDigest) | unique | length) == length)) and
    (.registry.evidence | type == "array" and
      (map(valid_evidence) | all) and
      ((map(.rootDigest) | unique | length) == length)) and
    (.proof | keys_are(["checksum","path","sha256"]) and
      .path == "docs/evidence/MEE2-48-protected-history-v1.json" and
      .sha256 == $proofSha and .checksum == $checksum)
  ) as $valid |
  if $valid then $raw else error("input shape or proof identity is invalid") end |
  ([.releases[] | select(.id == 371012814)] |
    if length == 1 then .[0] else error("public release identity is ambiguous") end) as $public |
  if ($public.tag_name == "v1.2.0" and
      ($public.draft | not) and ($public.prerelease | not) and
      $public.immutable and $public.published_at != null)
  then .
  else error("public v1.2.0 release identity is invalid")
  end |
  ([.releases[] | select(.protected or .id == 371012814)] | map(.id) | unique) as $protectedIds |
  ([.releases[] | select(member($protectedIds;.id))]) as $protectedReleases |
  (if ([
    $protectedReleases[] |
    . as $release |
    ([$raw.tagRefs[] | select(.tag == $release.tag_name)] |
      if length == 1 then
        .[0].state == "present" and .[0].peeledCommitSha == $release.target_commitish
      else false end)
  ] | all) then . else error("protected tag ref identity is invalid") end) |
  ([ $protectedIds[]? as $id |
     ([.registry.subjects[] | select(.kind == "root" and .releaseId == $id)] |
       if length == 1 then .[0] else error("protected root subject is ambiguous") end)
   ]) as $roots |
  ([ $roots[] as $root |
     ([ $raw.registry.subjects[] |
       select(.kind == "platform" and
         .digest == $root.platformDigest and
         .rootDigest == $root.digest and
         .releaseId == $root.releaseId)] |
       if length == 1 then .[0]
       else error("protected platform subject is ambiguous or unbound") end)
   ]) as $platforms |
  ([ $platforms[]?.digest ] | unique | sort) as $platformDigests |
  (if
    ([.releases[] | select(.id == 367640510)] | length) == 1 and
    ([.releases[] | select(.id == 367640510)][0] |
      .tag_name == "v1.0.1" and
      .target_commitish == "d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc" and
      .draft == false and .immutable == true and
      .protected == true and .prerelease == false) and
    ([.releases[] | select(.id == 371012814)] | length) == 1 and
    ([.releases[] | select(.id == 371012814)][0] |
      .tag_name == "v1.2.0" and
      .target_commitish == "9b6d2b06c0336ab8d153564dcf6328e81c4d7b36" and
      .draft == false and .immutable == true and
      .protected == false and .prerelease == false) and
    ($raw.registry.authorities | length) == ($roots | length) and
    ($raw.registry.evidence | length) == ($roots | length) and
    ($raw.registry.authorities | map(valid_authority_exact) | all) and
    ($raw.registry.evidence | map(valid_evidence_exact) | all) and
    (all($raw.registry.authorities[];
      . as $a | any($roots[]; .digest == $a.rootDigest))) and
    (all($raw.registry.evidence[];
      . as $e | any($roots[]; .digest == $e.rootDigest))) and
    ([
      $roots[] as $r |
      ([ $raw.registry.authorities[] | select(.rootDigest == $r.digest)] | .[0]) as $a |
      ([ $protectedReleases[] | select(.id == $r.releaseId)] | .[0]) as $rel |
      authority_matches($a;$r;$rel)
    ] | all) and
    ([
      $roots[] as $r |
      ([ $raw.registry.authorities[] | select(.rootDigest == $r.digest)] | .[0]) as $a |
      ([ $raw.registry.evidence[] | select(.rootDigest == $r.digest)] | .[0]) as $e |
      evidence_matches($e;$a)
    ] | all)
  then .
  else error("protected authority or evidence contract is invalid")
  end) |
  ([ $protectedReleases[]? | .tag_name, (.tag_name | sub("^v"; "")), ("sha-" + .target_commitish) ] | unique) as $identityAliases |
  (if ([
    $roots[] |
    . as $root |
    .aliases[]? |
    . as $alias |
    any($raw.registry.versions[]?; .digest == $root.digest and
      any(.tags[]?; . == $alias))
  ] | all) then . else error("protected subject aliases disagree with registry tags") end) |
  ([ $roots[]?.digest, $platforms[]?.digest ] | unique) as $baseDigests |
  ([.registry.versions[] | select(
    member($baseDigests;.digest) or
    any(.tags[]?; member($identityAliases;.)) or
    ($candidateAlias != "" and member($baseDigests;.digest) and
      any(.tags[]?; . == $candidateAlias))
  )]) as $touchedVersions |
  ([ $touchedVersions[]?.digest ] | unique) as $touchedDigests |
  ([ $baseDigests[]?, $touchedDigests[]? ] | unique) as $seeds |
  (.registry.manifests) as $manifestTable |
  (reduce range(0; 32) as $round ($seeds;
    . as $known |
    ([ $manifestTable[] | select(member($known;.digest) or (.subjectDigest != null and member($known;.subjectDigest))) |
       (.digest, .children[]?) ] | unique) as $next |
    ($known + $next | unique)
  )) as $closure |
  (if ([
    $closure[] |
    . as $closedDigest |
    any($manifestTable[]?; .digest == $closedDigest)
  ] | all) then . else error("referrer closure contains an unbound digest") end) |
  ([.registry.versions[] | select(
    member($closure;.digest) or
    any(.tags[]?; member($identityAliases;.)) or
    ($candidateAlias != "" and member($closure;.digest) and
      any(.tags[]?; . == $candidateAlias))
  )]) as $protectedVersions |
  ([ $protectedVersions[]?.tags[]? ] | unique) as $allAliases |
  ([ $identityAliases[]?, $allAliases[]? ] | unique | sort) as $aliases |
  ([ $aliases[]? as $alias |
     {alias:$alias,digests:([.registry.versions[] | select(any(.tags[]?; . == $alias)) | .digest] | unique | sort)}
   ] | sort_by(.alias)) as $aliasBindings |
  {
    schema:"meet-backend/test-promotion-protected-state/v2",
    repository:$raw.repository,
    image:$raw.image,
    publicRelease:{id:$public.id,tag:$public.tag_name,version:($public.tag_name | sub("^v"; "")),sourceSha:$public.target_commitish},
    releases:([$raw.releases[] | {id,tag:.tag_name,version:(.tag_name | sub("^v"; "")),sourceSha:.target_commitish,draft,immutable,protected,prerelease,publishedAt:.published_at}] | sort_by(.id)),
    tagRefs:([$raw.tagRefs[] | {tag,state,objectType,objectSha,peeledCommitSha}] | sort_by(.tag)),
    assets:([$raw.releases[] as $release | $release.assets[] | {releaseId:$release.id,id,name,size,sha256}] | sort_by(.releaseId,.name,.id)),
    protected:{
      releaseIds:$protectedIds,
      aliases:$aliasBindings,
      rootDigests:([ $roots[].digest ] | unique | sort),
      platformDigests:($platformDigests | unique | sort),
      subjectDigests:($closure | unique | sort),
      versions:([$protectedVersions[] | {id,digest,tags:(.tags | unique | sort)}] | sort_by(.digest,.id)),
      subjects:([
        $raw.registry.subjects[] | select(member($closure;.digest)) |
        {digest,kind,releaseId,rootDigest,platformDigest,aliases:(.aliases | unique | sort)}
      ] | sort_by(.digest)),
      manifests:([
        $raw.registry.manifests[] | select(member($closure;.digest)) |
        {digest,mediaType,size,subjectDigest,artifactType,predicateTypes:(.predicateTypes | unique | sort),children:(.children | unique | sort)}
      ] | sort_by(.digest)),
      referrerClosure:([
        $raw.registry.manifests[] |
        select(member($closure;.digest) and (.subjectDigest != null or (.children | length) > 0)) |
        {digest,mediaType,size,subjectDigest,artifactType,predicateTypes:(.predicateTypes | unique | sort),children:(.children | unique | sort)}
      ] | sort_by(.digest)),
      authorities:([
        $raw.registry.authorities[] | select(. as $a | any($roots[]?; .digest == $a.rootDigest)) | project_authority
      ] | sort_by(.releaseId,.rootDigest)),
      attestationEvidence:([
        $raw.registry.evidence[] | select(. as $a | any($roots[]?; .digest == $a.rootDigest)) | project_evidence
      ] | sort_by(.rootDigest,.evidenceStorage.kind)),
      storageKinds:([
        $raw.registry.authorities[] | select(. as $a | any($roots[]?; .digest == $a.rootDigest)) |  .evidenceStorage.kind
      ] | unique | sort)
    },
    proof:{path:$raw.proof.path,sha256:$raw.proof.sha256,checksum:$raw.proof.checksum}
  }
' "$input" >"$temporary"; then
  fail "input is malformed, ambiguous, or outside the protected contract"
fi
[ -s "$temporary" ] || fail "canonical projection is empty"
[ "$(wc -l <"$temporary" | tr -d " ")" -eq 1 ] || fail "canonical projection is not compact JSON"
chmod 600 "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || fail "output publication failed"
trap - EXIT HUP INT TERM
