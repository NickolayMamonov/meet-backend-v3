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

def expected_assets($releaseId):
  if $releaseId == 371012814 then
    [
      {id:515612606,name:"release-manifest.json",size:695,
       apiDigest:"sha256:428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb",
       downloadSha256:"428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb"},
      {id:515612616,name:"image-index.json",size:857,
       apiDigest:"sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda",
       downloadSha256:"e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda"},
      {id:515612629,name:"image-inspect.txt",size:849,
       apiDigest:"sha256:614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3",
       downloadSha256:"614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3"},
      {id:515612640,name:"SHA256SUMS",size:249,
       apiDigest:"sha256:6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271",
       downloadSha256:"6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271"}
    ]
  elif $releaseId == 377201468 then
    [
      {id:532339115,name:"SHA256SUMS",size:255,
       apiDigest:"sha256:ac70335a2301856b09a912400b977cb4d67653c9d7a370ad5834ae5f591dd476",
       downloadSha256:"ac70335a2301856b09a912400b977cb4d67653c9d7a370ad5834ae5f591dd476"},
      {id:532339069,name:"image-index.json",size:857,
       apiDigest:"sha256:88b697872331ed2786f2d9009c769a87c32470086702faacf9874576fe094e9e",
       downloadSha256:"88b697872331ed2786f2d9009c769a87c32470086702faacf9874576fe094e9e"},
      {id:532339092,name:"image-inspect.txt",size:849,
       apiDigest:"sha256:5f0836e04868ca8e036d44a8c5517d84dfc51bbf1282a87a589d3acd2443addf",
       downloadSha256:"5f0836e04868ca8e036d44a8c5517d84dfc51bbf1282a87a589d3acd2443addf"},
      {id:532339036,name:"release-manifest.json",size:695,
       apiDigest:"sha256:cd34df22ab90a6d5f5b3624bed03d7c2527a842e278136b383bcebe985f1ca6e",
       downloadSha256:"cd34df22ab90a6d5f5b3624bed03d7c2527a842e278136b383bcebe985f1ca6e"}
    ]
  else []
  end;

def assert_authority($a; $e; $release; $root; $platform; $rootManifest; $platformManifest):
  [historical_catalog[] |
    select(.release.id == $a.releaseId and
      .release.tag == $a.tag and
      .release.version == $a.version and
      .release.source == $a.releaseSourceDigest and
      .productImage.rootDigest == $a.rootDigest)] as $matches |
  if ($matches | length) != 1 then false
  else
    ($matches[0]) as $catalog |
    ($a | exact_keys([
      "certificateIdentity","certificateSourceDigest","evidenceStorage","image",
      "oidcIssuer","platformDigest","predicateType","releaseId",
      "releaseSourceDigest","repository","rootDigest","schema","scope",
      "signerDigest","signerWorkflow","sourceRef","sourceRepository",
      "subject","tag","version"
    ])) and
    ($a.schema == "meet-backend/image-attestation-authority/v1") and
    ($a.scope == "protected-release") and
    ($a.repository == repository) and ($a.image == image) and
    ($a.sourceRepository == source_repository) and ($a.sourceRef == source_ref) and
    ($a.oidcIssuer == issuer) and ($a.predicateType == predicate) and
    ($a.releaseId == $catalog.release.id) and
    ($a.tag == $catalog.release.tag) and ($a.version == $catalog.release.version) and
    ($a.releaseSourceDigest == $catalog.release.source) and
    ($a.certificateSourceDigest == $catalog.attestation.certificateSourceDigest) and
    ($a.signerDigest == $catalog.attestation.signerDigest) and
    ($a.signerWorkflow == $catalog.attestation.signerWorkflow) and
    ($a.certificateIdentity == $catalog.attestation.certificateIdentity) and
    ($a.rootDigest == $catalog.productImage.rootDigest) and
    ($a.platformDigest | digest) and
    ($a.subject.digest == $a.rootDigest) and
    ($a.subject.name | type == "string") and
    ($a.subject.name == $catalog.attestation.subject.name or
      ($a.subject.name | ascii_downcase) == image) and
    ($release | type == "object" and
      .id == $catalog.release.id and .tag_name == $catalog.release.tag and
      .target_commitish == $catalog.release.source and
      .draft == $catalog.release.draft and
      .prerelease == $catalog.release.prerelease) and
    ($root | type == "object" and
      .kind == "root" and .releaseId == $catalog.release.id and
      .digest == $a.rootDigest and .platformDigest == $a.platformDigest) and
    ($platform | type == "object" and
      .kind == "platform" and .releaseId == $catalog.release.id and
      .rootDigest == $a.rootDigest and .digest == $a.platformDigest) and
    ($rootManifest | type == "object" and
      .digest == $a.rootDigest and
      .mediaType == $catalog.productImage.rootMediaType) and
    ($platformManifest | type == "object" and
      .digest == $a.platformDigest and
      .mediaType == $catalog.productImage.platform.mediaType) and
    ($e | type == "object" and
      exact_keys([
        "certificateIdentity","certificateSourceDigest","evidenceStorage",
        "oidcIssuer","platformDigest","predicateType","releaseSourceDigest",
        "rootDigest","schema","signerDigest","signerWorkflow","sourceRef",
        "sourceRepository","subject"
      ]) and
      .schema == "meet-backend/image-attestation-evidence/v2" and
      .sourceRepository == $a.sourceRepository and
      .releaseSourceDigest == $a.releaseSourceDigest and
      .certificateSourceDigest == $a.certificateSourceDigest and
      .signerDigest == $a.signerDigest and .sourceRef == $a.sourceRef and
      .signerWorkflow == $a.signerWorkflow and
      .certificateIdentity == $a.certificateIdentity and
      .oidcIssuer == $a.oidcIssuer and .predicateType == $a.predicateType and
      .rootDigest == $a.rootDigest and .platformDigest == $a.platformDigest and
      .subject == $a.subject and
      (.evidenceStorage | type == "object" and
        .kind == $a.evidenceStorage.kind and
        if .kind == "oci-registry-bundle" then
          exact_keys([
            "bundleDigest","bundleLayerDigest","bundleLayerMediaType",
            "bundleLayerSize","kind","signatureManifestDigest"
          ]) and
          (.bundleDigest | digest) and (.bundleLayerDigest | digest) and
          (.signatureManifestDigest | digest) and
          .bundleLayerMediaType == "application/vnd.dev.sigstore.bundle.v0.3+json" and
          (.bundleLayerSize | type == "number" and floor == . and . > 0)
        elif .kind == "github-api-workflow-artifact" then
          exact_keys(["asset","assets","bundleDigest","kind"]) and
          (.bundleDigest | digest) and
          (.assets == (expected_assets($a.releaseId) | sort_by(.id))) and
          (.asset == (expected_assets($a.releaseId)[] |
            select(.name == "image-index.json")))
        else false end)) and
    ($a.evidenceStorage | type == "object" and
      if .kind == "oci-registry-bundle" then
        exact_keys(["kind"])
      elif .kind == "github-api-workflow-artifact" then
        exact_keys(["asset","assets","bundleDigest","kind"]) and
        .bundleDigest == $catalog.evidenceStorage.bundleDigest and
        (.assets == (expected_assets($a.releaseId) | sort_by(.id))) and
        (.asset == (expected_assets($a.releaseId)[] |
          select(.name == "image-index.json")))
      else false end)
  end;
