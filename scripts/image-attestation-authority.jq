# Shared, pure authority policy.  This module contains no I/O and is safe to
# include from collectors, readers, projectors, and admission checks.

def sha40: type == "string" and test("^[0-9a-f]{40}$");
def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
def semver: type == "string" and test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$");
def exact_keys($keys): type == "object" and (keys | sort) == ($keys | sort);
def source_repository: "https://github.com/NickolayMamonov/meet-backend-v3";
def repository: "NickolayMamonov/meet-backend-v3";
def image: "ghcr.io/nickolaymamonov/meet-backend-v3";
def source_ref: "refs/heads/dev";
def issuer: "https://token.actions.githubusercontent.com";
def predicate: "https://slsa.dev/provenance/v1";

def historical_catalog:
  [
    {
      release:{id:367640510,tag:"v1.0.1",version:"1.0.1",
        source:"d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc",
        draft:false,prerelease:false,immutable:false},
      productImage:{
        sourceSha:"d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc",
        version:"1.0.1",
        rootDigest:"sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6",
        rootMediaType:"application/vnd.oci.image.index.v1+json",
        rootSize:856,
        platform:{digest:"sha256:2e2f41478f341da8df7e573c48c59ee1734ee7d29e9a7be614f3660adac64554",
          mediaType:"application/vnd.oci.image.manifest.v1+json",size:1815,
          platform:{os:"linux",architecture:"amd64"}}},
      attestation:{
        certificateSourceDigest:"4bff2902511e8e739d7604bf120b121429e60aeb",
        signerDigest:"4bff2902511e8e739d7604bf120b121429e60aeb",
        signerWorkflow:".github/workflows/release-please.yml",
        certificateIdentity:(source_repository+"/.github/workflows/release-please.yml@"+source_ref),
        runInvocationURI:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/31368625251/attempts/1",
        subject:{name:image,digest:"sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6"},
        canonicalBundleDigest:"sha256:d238057705a334533fa3962ef0a7d96e8999696392b438199fbdbe37488e5950"},
      evidenceStorage:{kind:"oci-registry-bundle"}
    },
    {
      release:{id:368531227,tag:"v1.1.0",version:"1.1.0",
        source:"36ffd11ea4d35147f1df9c1cafa6a330300c1339",
        draft:true,prerelease:false,immutable:false},
      productImage:{
        sourceSha:"36ffd11ea4d35147f1df9c1cafa6a330300c1339",
        version:"1.1.0",
        rootDigest:"sha256:c156a8a1436b008eea2980711b233b6f800cf60a36cdbe08faf480a2c97e6570",
        rootMediaType:"application/vnd.oci.image.index.v1+json",
        rootSize:856,
        platform:{digest:"sha256:a04f84d5325cbe67b536b3000353da765ae4412ab0b0b9acabce1ecbba61c3ee",
          mediaType:"application/vnd.oci.image.manifest.v1+json",size:1815,
          platform:{os:"linux",architecture:"amd64"}}},
      attestation:{
        certificateSourceDigest:"8598a31e60d0bae784bebf43404f3b1e91d603e1",
        signerDigest:"8598a31e60d0bae784bebf43404f3b1e91d603e1",
        signerWorkflow:".github/workflows/release-please.yml",
        certificateIdentity:(source_repository+"/.github/workflows/release-please.yml@"+source_ref),
        runInvocationURI:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/31551286770/attempts/1",
        subject:{name:image,digest:"sha256:c156a8a1436b008eea2980711b233b6f800cf60a36cdbe08faf480a2c97e6570"},
        canonicalBundleDigest:"sha256:02268aa7d49ca85c979f4437c1046cca7bce19379eca2eaac28b786acc7daa1f"},
      evidenceStorage:{kind:"oci-registry-bundle"}
    },
    {
      release:{id:371012814,tag:"v1.2.0",version:"1.2.0",
        source:"9b6d2b06c0336ab8d153564dcf6328e81c4d7b36",
        draft:false,prerelease:false,immutable:true},
      productImage:{
        sourceSha:"9b6d2b06c0336ab8d153564dcf6328e81c4d7b36",
        version:"1.2.0",
        rootDigest:"sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda",
        rootMediaType:"application/vnd.oci.image.index.v1+json",
        rootSize:857,
        platform:{digest:"sha256:3d2741adeb501f103b1fdc2b79c9e2cdb30f30ab257805d2fe67e57bc6d222b6",
          mediaType:"application/vnd.oci.image.manifest.v1+json",size:1815,
          platform:{os:"linux",architecture:"amd64"}}},
      attestation:{
        certificateSourceDigest:"9af0723444f918594101999a4338b418607cbd01",
        signerDigest:"9af0723444f918594101999a4338b418607cbd01",
        signerWorkflow:".github/workflows/release-please.yml",
        certificateIdentity:(source_repository+"/.github/workflows/release-please.yml@"+source_ref),
        runInvocationURI:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/31880582935/attempts/1",
        subject:{name:"image-index.json",digest:"sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda"},
        canonicalBundleDigest:"sha256:cf1f5d905c0bb97ca2013b3dd8aa415fb331a63dfec860e0382e5690339e5958"},
      evidenceStorage:{kind:"github-api-workflow-artifact",bundleDigest:"sha256:cf1f5d905c0bb97ca2013b3dd8aa415fb331a63dfec860e0382e5690339e5958",
        subjectName:"image-index.json"}
    },
    {
      release:{id:377201468,tag:"v1.3.0",version:"1.3.0",
        source:"a7abfe04f6852f479291a4710ebdee23e9ae8a34",
        draft:false,prerelease:false,immutable:true},
      productImage:{
        sourceSha:"a7abfe04f6852f479291a4710ebdee23e9ae8a34",
        version:"1.3.0",
        rootDigest:"sha256:88b697872331ed2786f2d9009c769a87c32470086702faacf9874576fe094e9e",
        rootMediaType:"application/vnd.oci.image.index.v1+json",
        rootSize:857,
        platform:{digest:"sha256:b98ef109b9f0aeed909a15d44908087093b9177313813040ddbeb2d415c51961",
          mediaType:"application/vnd.oci.image.manifest.v1+json",size:1815,
          platform:{os:"linux",architecture:"amd64"}}},
      attestation:{
        certificateSourceDigest:"79263bfed6427dc1a45900e338805c52dbd5f59d",
        signerDigest:"79263bfed6427dc1a45900e338805c52dbd5f59d",
        signerWorkflow:".github/workflows/release-please.yml",
        certificateIdentity:(source_repository+"/.github/workflows/release-please.yml@"+source_ref),
        runInvocationURI:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/33075760603/attempts/1",
        subject:{name:"image-index.json",digest:"sha256:88b697872331ed2786f2d9009c769a87c32470086702faacf9874576fe094e9e"},
        canonicalBundleDigest:"sha256:cb48b0ad1cf2a02733057e337bbba3ea4dc493c311f95117afb3381f894e19a8"},
      evidenceStorage:{kind:"github-api-workflow-artifact",bundleDigest:"sha256:cb48b0ad1cf2a02733057e337bbba3ea4dc493c311f95117afb3381f894e19a8",
        subjectName:"image-index.json"}
    }
  ];

def candidate_expected($ctx):
  {
    repository: repository,
    image: image,
    sourceRef: source_ref,
    signerWorkflow: ".github/workflows/promote-dev-digest-to-test-vps.yml",
    certificateSourceDigest: $ctx.productImage.sourceSha,
    signerDigest: $ctx.productImage.sourceSha,
    certificateIdentity: (source_repository+"/.github/workflows/promote-dev-digest-to-test-vps.yml@"+source_ref),
    oidcIssuer: issuer,
    predicateType: predicate,
    rootDigest: $ctx.productImage.rootDigest,
    platformDigest: $ctx.productImage.platform.digest,
    subject:{
      name:image,
      digest:$ctx.productImage.rootDigest
    }
  };

def valid_context:
  exact_keys(["image","productImage","profile","release","repository","schema"]) and
  .schema == "meet-backend/image-attestation-context/v1" and
  .repository == repository and .image == image and
  (.profile == "historical" or .profile == "candidate") and
  (.release == null or
    (.release |
      exact_keys(["draft","id","prerelease","source","tag","version"]) and
      (.id|type) == "number" and (.id|floor) == .id and .id > 0 and
      (.tag|type) == "string" and (.tag|test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
      (.version|semver) and .tag == ("v"+.version) and
      (.source|sha40) and (.draft|type) == "boolean" and
      (.prerelease|type) == "boolean"
    )
  ) and
  (.productImage |
    exact_keys(["platform","rootDigest","rootMediaType","rootSize","sourceSha","version"]) and
    (.sourceSha|sha40) and (.version|semver) and (.rootDigest|digest) and
    (.rootMediaType == "application/vnd.oci.image.index.v1+json") and
    (.rootSize|type == "number" and floor == . and . > 0) and
    (.platform |
      exact_keys(["digest","mediaType","platform","size"]) and
      (.digest|digest) and
      (.mediaType == "application/vnd.oci.image.manifest.v1+json") and
      (.size|type == "number" and floor == . and . > 0) and
      (.platform|type == "object") and
      (.platform.os == "linux") and (.platform.architecture == "amd64")
    )
  );

def resolve_authority:
  . as $ctx |
  if ($ctx|valid_context) | not then error("invalid image attestation context")
  elif $ctx.profile == "historical" then
    [historical_catalog[] |
      select(.release.id == $ctx.release.id and
        .release.tag == $ctx.release.tag and
        .release.version == $ctx.release.version and
        .release.source == $ctx.release.source and
        .productImage.sourceSha == $ctx.productImage.sourceSha and
        .productImage.rootDigest == $ctx.productImage.rootDigest and
        .productImage.platform.digest == $ctx.productImage.platform.digest)] as $matches |
    if ($matches|length) != 1 then error("historical authority is not an exact unique match")
    else
      {schema:"meet-backend/image-attestation-policy/v1",context:$ctx,
       expected:($matches[0] + {
         repository:repository,image:image,
         sourceRepository:source_repository,sourceRef:source_ref,
         oidcIssuer:issuer,predicateType:predicate
       })}
    end
  else
    {schema:"meet-backend/image-attestation-policy/v1",context:$ctx,
     expected:({profile:"candidate"} + candidate_expected($ctx))}
  end;

def normalize_verified_result($verified; $bundleDigest; $storage):
  if (($verified|type) != "object" or
      ($verified.repository // "") != repository or
      ($verified.sourceRef // "") != source_ref or
      ($verified.oidcIssuer // "") != issuer or
      ($verified.predicateType // "") != predicate or
      (($verified.certificateSourceDigest // "")|sha40) == false or
      (($verified.signerDigest // "")|sha40) == false or
      (($verified.rootDigest // "")|digest) == false or
      (($verified.platformDigest // "")|digest) == false)
  then error("verified authority result is incomplete")
  else
    {schema:"meet-backend/image-attestation-authority/v1",
     repository:repository,image:image,
     sourceRef:source_ref,oidcIssuer:issuer,predicateType:predicate,
     certificateSourceDigest:$verified.certificateSourceDigest,
     signerDigest:$verified.signerDigest,
     rootDigest:$verified.rootDigest,platformDigest:$verified.platformDigest,
     subject:($verified.subject // error("verified subject is missing")),
     evidenceStorage:({kind:$storage,bundleDigest:$bundleDigest})}
  end;

def assert_authority:
  . as $a |
  ($a|type == "object") and
  ($a.schema == "meet-backend/image-attestation-authority/v1") and
  ($a.repository == repository) and ($a.image == image) and
  ($a.sourceRef == source_ref) and ($a.oidcIssuer == issuer) and
  ($a.predicateType == predicate) and
  ($a.certificateSourceDigest|sha40) and ($a.signerDigest|sha40) and
  ($a.rootDigest|digest) and ($a.platformDigest|digest) and
  ($a.subject|type == "object") and ($a.subject.digest == $a.rootDigest) and
  ($a.evidenceStorage|type == "object") and
  ($a.evidenceStorage.kind == "oci-registry-bundle" or
   $a.evidenceStorage.kind == "github-api-workflow-artifact");
