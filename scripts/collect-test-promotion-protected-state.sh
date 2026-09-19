#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

supported_authority_rows() {
  jq -cnS '[
    {id:371012814,tag:"v1.2.0",version:"1.2.0",source:"9b6d2b06c0336ab8d153564dcf6328e81c4d7b36",signer:"9af0723444f918594101999a4338b418607cbd01",packageId:1135861098,root:"sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda",platform:"sha256:3d2741adeb501f103b1fdc2b79c9e2cdb30f30ab257805d2fe67e57bc6d222b6",draft:false,prerelease:false,immutable:true,invocation:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/31880582935/attempts/1",subject:"image-index.json",storage:"github-api-workflow-artifact",bundle:"sha256:6fc87b8c7167fdc24de74853264ed3dde855896913fd609f41680267c265f414"},
    {id:377201468,tag:"v1.3.0",version:"1.3.0",source:"a7abfe04f6852f479291a4710ebdee23e9ae8a34",signer:"79263bfed6427dc1a45900e338805c52dbd5f59d",packageId:1178492365,root:"sha256:88b697872331ed2786f2d9009c769a87c32470086702faacf9874576fe094e9e",platform:"sha256:b98ef109b9f0aeed909a15d44908087093b9177313813040ddbeb2d415c51961",draft:false,prerelease:false,immutable:true,invocation:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/33075760603/attempts/1",subject:"image-index.json",storage:"github-api-workflow-artifact",bundle:"sha256:7675da813f32cba607a12305dbeeaef475a85b204d83709642316ddb14887084"}
  ]'
}
retired_product_rows() {
  jq -cnS '[
    {
      id:367640510,tag:"v1.0.1",version:"1.0.1",
      source:"d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc",
      closure:[
        {kind:"root",id:1115681835,digest:"sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6",tags:["sha-d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc","1.0.1","v1.0.1"]},
        {kind:"platform",id:1115681794,digest:"sha256:2e2f41478f341da8df7e573c48c59ee1734ee7d29e9a7be614f3660adac64554",tags:[]},
        {kind:"legacy",id:1115681816,digest:"sha256:9f7ba89024aa1242b835230a2d158d0c87cc93ecf5a1a7138d493f3ac741a875",tags:[]},
        {kind:"sigstore",id:1115891804,digest:"sha256:deae4981eb0593d6d4dbaaca4ac36486e9174727c1c0dc1d407ad37608133f6d",tags:[]},
        {kind:"marker",id:1115891833,digest:"sha256:4a25f1ec46c8a897a7b7b4696abffdd3e913570f59ed7041cee4d1a5f76ca038",tags:["sha256-41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6"]}
      ]
    },
    {
      id:368531227,tag:"v1.1.0",version:"1.1.0",
      source:"36ffd11ea4d35147f1df9c1cafa6a330300c1339",
      closure:[
        {kind:"root",id:1123238824,digest:"sha256:c156a8a1436b008eea2980711b233b6f800cf60a36cdbe08faf480a2c97e6570",tags:["sha-36ffd11ea4d35147f1df9c1cafa6a330300c1339","1.1.0","v1.1.0"]},
        {kind:"platform",id:null,digest:"sha256:a04f84d5325cbe67b536b3000353da765ae4412ab0b0b9acabce1ecbba61c3ee",tags:[]},
        {kind:"legacy",id:null,digest:"sha256:6b9341ece696b0de761b703ef29047cf0182b3a55fb513f662eae494e2cf667f",tags:[]},
        {kind:"sigstore",id:1123240857,digest:"sha256:6f8c8a92a39bdfbf47c1f95ff7ba01b55f5f767126dd77751ea67bae17b0f29a",tags:[]},
        {kind:"marker",id:null,digest:"sha256:7f4c29b519fb2ce28696557e1592f544adebb5b5ffa4d13e4262a64295d593a4",tags:["sha256-c156a8a1436b008eea2980711b233b6f800cf60a36cdbe08faf480a2c97e6570"]}
      ]
    }
  ]'
}

backend_version_at_least_floor() {
  local version=$1 major minor _patch
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    return 1
  IFS=. read -r major minor _patch <<<"$version"
  (( major > 1 || (major == 1 && minor >= 2) ))
}

select_supported_authority() {
  local product=$1
  supported_authority_rows | jq -cS --argjson product "$product" '
    def aliases_match($p;$r):
      ($p.package.tags | type == "array") and
      ($p.package.tags | length) == 3 and
      ($p.package.tags | unique | length) == 3 and
      ($p.package.tags | sort) ==
        (["sha-" + $r.source,$r.version,$r.tag] | sort);
    def discriminates($p;$r):
      $p.release.id == $r.id or $p.release.tag == $r.tag or
      $p.release.version == $r.version or $p.release.source == $r.source or
      $p.package.id == $r.packageId or $p.rootDigest == $r.root or
      $p.platform.digest == $r.platform or
      any($p.package.tags[]?;
        . == ("sha-" + $r.source) or . == $r.version or . == $r.tag);
    [.[] | select(discriminates($product;.))] as $matches |
    if ($matches | length) == 0 then
      {status:"unrelated"}
    elif ($matches | length) != 1 then
      error("ambiguous supported authority")
    else
      $matches[0] as $row |
      if $product.repository == "NickolayMamonov/meet-backend-v3" and
         $product.image == "ghcr.io/nickolaymamonov/meet-backend-v3" and
         $product.release == {
           id:$row.id,tag:$row.tag,version:$row.version,source:$row.source,
           draft:$row.draft,prerelease:$row.prerelease,immutable:$row.immutable
         } and
         $product.package.id == $row.packageId and
         $product.package.digest == $row.root and
         aliases_match($product;$row) and
         $product.rootDigest == $row.root and
         $product.platform.digest == $row.platform and
         $product.platform.mediaType == "application/vnd.oci.image.manifest.v1+json" and
         $product.platform.size == 1815 and
         $product.platform.platform == {architecture:"amd64",os:"linux"}
      then {status:"supported-authority",row:$row}
      else error("supported product tuple mismatch")
      end
    end
  '
}

filter_active_package_versions() {
  local versions=$1 retired
  retired=$(retired_product_rows) || return 1
  jq -cS --argjson retired "$retired" '
    def tags_equal($left;$right):
      ($left | type == "array") and
      ($left | length) == ($left | unique | length) and
      ($left | sort) == ($right | sort);
    if type != "array" or
       any(.[];
         (.id | type != "number") or (.id | floor != .) or .id <= 0 or
         (.digest | type != "string") or
         (.digest | test("^sha256:[0-9a-f]{64}$") | not) or
         (.tags | type != "array") or
         any(.tags[]?; type != "string" or length == 0)) or
       ((map(.id) | unique | length) != length) or
       ((map(.digest) | unique | length) != length)
    then error("package inventory is malformed or ambiguous")
    else
      reduce .[] as $version
        ({active:[]};
          ([$retired[] |
            select(
              any(.closure[]; .digest == $version.digest or
                (.id != null and .id == $version.id)) or
              any(.closure[].tags[]?;
                . as $tag | ($version.tags | index($tag)) != null)
            )]) as $rows |
          if ($rows | length) == 0 then
            .active += [$version]
          elif ($rows | length) != 1 then
            error("package version crosses retired rows")
          else
            $rows[0] as $row |
            ([$row.closure[] | select(.digest == $version.digest)]) as $items |
            if ($items | length) != 1 then
              error("retired discriminator points to a foreign digest")
            else
              $items[0] as $item |
              if ($item.id != null and $item.id != $version.id) or
                 (tags_equal($version.tags;$item.tags) | not)
              then error("retired package tuple is malformed")
              else .
              end
            end
          end) |
      .active
    end
  ' <<<"$versions"
}

is_retired_digest() {
  local digest=$1
  retired_product_rows | jq -e --arg digest "$digest" \
    'any(.[].closure[]; .digest == $digest)' >/dev/null
}

validate_supported_attestation() {
  local response=$1 selection=$2 subject=$3 normalized compact_bundle hash expected_bundle
  record=$(jq -c '.[0]' <<<"$response") || return 1
  normalized=$(jq -cS --arg subject "${subject#sha256:}" --argjson selection "$selection" '
    if type != "array" or length != 1 then
      error("result cardinality")
    else
      .[0] as $record |
      $record.attestation.bundle as $bundle |
      $record.verificationResult as $result |
      $result.signature.certificate as $certificate |
      $result.statement.subject as $subjects |
      if ($bundle | type) != "object" or
         ($subjects | type) != "array" or
         ($subjects | length) != 1 or
         $subjects[0].digest.sha256 != $subject or
         $certificate.sourceRepositoryURI != "https://github.com/NickolayMamonov/meet-backend-v3" or
         $certificate.sourceRepositoryDigest != $selection.row.signer or
         $certificate.sourceRepositoryRef != "refs/heads/dev" or
         $certificate.buildSignerURI != "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev" or
         $certificate.buildSignerDigest != $selection.row.signer or
         $certificate.subjectAlternativeName != "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev" or
         $certificate.issuer != "https://token.actions.githubusercontent.com" or
         $certificate.runInvocationURI != $selection.row.invocation or
         $result.statement.predicateType != "https://slsa.dev/provenance/v1" or
         $subjects[0].name != $selection.row.subject
      then
        error("observed evidence mismatch")
      else
        {
          bundle:$bundle,
          output:{
            subjectDigest:("sha256:" + $subject),
            predicateType:$result.statement.predicateType,
            sourceRepository:$certificate.sourceRepositoryURI,
            sourceDigest:$certificate.sourceRepositoryDigest,
            workflowRef:$certificate.sourceRepositoryRef,
            signerWorkflow:$certificate.buildSignerURI,
            bundleDigest:null
          }
        }
      end
    end
  ' <<<"$response") || return 1
  compact_bundle=$(jq -cS '.attestation.bundle' <<<"$record") || return 1
  compact_bundle=${compact_bundle%$'\r'}
  hash=$(printf '%s\n' "$compact_bundle" | sha256sum | awk '{print $1}') ||
    return 1
  expected_bundle=$(jq -r '.row.bundle' <<<"$selection") || return 1
  [ "sha256:$hash" = "$expected_bundle" ] || return 1
  jq -cnS --argjson normalized "$normalized" --arg bundle "sha256:$hash" \
    '$normalized.output | .bundleDigest = $bundle'
}

download_workflow_artifact() {
  local release_id=$1 expected_digest=$2 destination=$3
  local asset asset_id asset_digest asset_size actual_digest actual_size
  asset=$(jq -c --argjson releaseId "$release_id" '
    [.[] | select(.id == $releaseId) | .assets[] |
      select(.name == "image-index.json")] |
    if length == 1 then .[0] else empty end
  ' "$tmp/releases-normalized.json") ||
    fail "workflow artifact inventory lookup failed for release $release_id"
  [ -n "$asset" ] || fail "release $release_id does not have exactly one image-index.json asset"
  asset_id=$(jq -r '.id // empty' <<<"$asset")
  asset_digest=$(jq -r '.sha256 // empty' <<<"$asset")
  asset_size=$(jq -r '.size // empty' <<<"$asset")
  jq -e '.id | type == "number" and floor == . and . > 0' <<<"$asset" >/dev/null ||
    fail "workflow artifact ID is malformed for release $release_id"
  [[ "$asset_id" =~ ^[1-9][0-9]*$ ]] ||
    fail "workflow artifact ID is malformed for release $release_id"
  [ "$asset_digest" = "${expected_digest#sha256:}" ] ||
    fail "workflow artifact digest disagrees with image root for release $release_id"
  [[ "$asset_size" =~ ^[0-9]+$ ]] || fail "workflow artifact size is malformed for release $release_id"
  gh api --header 'Accept: application/octet-stream' \
    "repos/$repository/releases/assets/$asset_id" >"$destination" ||
    fail "workflow artifact read failed for release $release_id"
  actual_digest=$(sha256sum "$destination" | awk '{print $1}')
  [ "$actual_digest" = "$asset_digest" ] ||
    fail "workflow artifact bytes do not match release asset digest for $release_id"
  actual_size=$(wc -c <"$destination" | tr -d ' ')
  [ "$actual_size" -eq "$asset_size" ] ||
    fail "workflow artifact bytes do not match release asset size for $release_id"
}

collect_verified_attestations() {
  local digest=$1 source_digest=$2 record compact_bundle bundle_sha
  local selection=${3:-}
  local selection_status=
  if [ -n "$selection" ]; then
    selection_status=$(jq -r '.status // empty' <<<"$selection")
  fi
  if [ "$selection_status" = supported-authority ]; then
    local signer storage release_id artifact
    local -a common_args=() args=()
    signer=$(jq -r '.row.signer' <<<"$selection")
    storage=$(jq -r '.row.storage' <<<"$selection")
    release_id=$(jq -r '.row.id' <<<"$selection")
    common_args=(--repo "$repository" --source-digest "$signer"
      --source-ref refs/heads/dev
      --signer-workflow github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml
      --signer-digest "$signer"
      --cert-oidc-issuer https://token.actions.githubusercontent.com
      --predicate-type https://slsa.dev/provenance/v1 --format json)
    case "$storage" in
      github-api-workflow-artifact)
        artifact="$tmp/workflow-artifact-${digest#sha256:}.json"
        download_workflow_artifact "$release_id" "$digest" "$artifact"
        args=("$artifact" "${common_args[@]}")
        ;;
      *)
        fail "supported authority has unsupported verification transport: $storage"
        ;;
    esac
    local supported_file="$tmp/github-${digest#sha256:}.json"
    gh attestation verify "${args[@]}" >"$supported_file" ||
      fail "GitHub attestation verification failed for $digest"
    validate_supported_attestation "$(<"$supported_file")" "$selection" "$digest" \
      >"$tmp/supported-${digest#sha256:}.json" ||
      fail "supported GitHub attestation evidence is malformed for $digest"
    cat "$tmp/supported-${digest#sha256:}.json" >>"$tmp/attestations.jsonl"
    return
  fi
  local verified_file="$tmp/github-${digest#sha256:}.json"
  if [ ! -f "$verified_file" ]; then
    gh attestation verify "oci://$image@$digest" \
      --repo "$repository" --source-digest "$source_digest" --format json \
      >"$verified_file" ||
      fail "GitHub attestation verification failed for $digest"
  fi
  jq -e --arg subject "${digest#sha256:}" \
    --arg repository "https://github.com/$repository" \
    --arg source "$source_digest" '
    type == "array" and length > 0 and
    all(.[];
      (.attestation.bundle | type == "object") and
      (.verificationResult | type == "object") and
      (.verificationResult.statement.predicateType |
        type == "string" and length > 0) and
      ([.verificationResult.statement.subject[]? |
        select(.digest.sha256? == $subject)] | length) == 1 and
      (.verificationResult.signature.certificate as $certificate |
        $certificate.sourceRepositoryURI == $repository and
        $certificate.sourceRepositoryDigest == $source and
        ($certificate.sourceRepositoryRef |
          type == "string" and startswith("refs/")) and
        ($certificate.buildSignerURI |
          type == "string" and
          startswith($repository + "/.github/workflows/") and
          endswith("@" + $certificate.sourceRepositoryRef)) and
        $certificate.subjectAlternativeName == $certificate.buildSignerURI)
    )
  ' "$verified_file" >/dev/null ||
    fail "verified GitHub attestation evidence is malformed for $digest"
  while IFS= read -r record; do
    compact_bundle=$(jq -cS '.attestation.bundle' <<<"$record") ||
      fail "verified GitHub attestation bundle hashing failed for $digest"
    compact_bundle=${compact_bundle%$'\r'}
    bundle_sha=$(printf '%s\n' "$compact_bundle" | sha256sum | awk '{print $1}') ||
      fail "verified GitHub attestation bundle hashing failed for $digest"
    jq -cS --arg subjectDigest "$digest" \
      --arg bundleDigest "sha256:$bundle_sha" '
      .verificationResult as $result |
      $result.signature.certificate as $certificate |
      {
        subjectDigest:$subjectDigest,
        predicateType:$result.statement.predicateType,
        sourceRepository:$certificate.sourceRepositoryURI,
        sourceDigest:$certificate.sourceRepositoryDigest,
        workflowRef:$certificate.sourceRepositoryRef,
        signerWorkflow:$certificate.buildSignerURI,
        bundleDigest:$bundleDigest
      }
    ' <<<"$record" >>"$tmp/attestations.jsonl" ||
      fail "verified GitHub attestation normalization failed for $digest"
  done < <(jq -c '.[]' "$verified_file")
}

usage() {
  echo "usage: $0 --repository OWNER/REPO --image ghcr.io/OWNER/IMAGE --output PATH [--candidate-alias ALIAS]" >&2
  exit 2
}

fail() { echo "test-promotion protected-state collection failed: $*" >&2; exit 1; }

normalize_artifact_predicate_types() {
  local manifest=$1
  jq -c '
    [.layers[]?.annotations["in-toto.io/predicate-type"]?]
    | map(select(type == "string" and length > 0))
    | unique
    | sort
  ' "$manifest"
}

normalize_modern_attestation_predicates() {
  local manifest=$1 subject_digest=$2 selection=${3:-} selection_json
  selection_json=${selection:-'{}'}
  jq -cS --arg subject "$subject_digest" \
    --argjson selection "$selection_json" '
    if .artifactType !=
         "application/vnd.docker.attestation.manifest.v1+json" or
       (.subject | type) != "object" or
       .subject.digest != $subject or
       (.subject.mediaType | type) != "string" or
       (.subject.mediaType | length) == 0 or
       (.subject.size | type) != "number" or .subject.size <= 0 or
       (.layers | type) != "array" or (.layers | length) == 0 or
       any(.layers[];
         .mediaType != "application/vnd.in-toto+json" or
         (.digest | type) != "string" or
         (.digest | test("^sha256:[0-9a-f]{64}$") | not) or
         (.size | type) != "number" or .size < 0 or
         (.annotations["in-toto.io/predicate-type"] | type) != "string" or
         (.annotations["in-toto.io/predicate-type"] | length) == 0)
    then error("modern attestation shape is malformed")
    else
      [.layers[].annotations["in-toto.io/predicate-type"]] as $predicates |
      ($predicates | unique | sort) as $normalized |
      if ($predicates | length) != ($normalized | length) or
         ($normalized | index("https://slsa.dev/provenance/v1")) == null or
         ($selection.status == "supported-authority" and
          $normalized != [
            "https://slsa.dev/provenance/v1",
            "https://spdx.dev/Document"
          ])
      then error("modern attestation predicates are malformed")
      else $normalized
      end
    end
  ' "$manifest"
}

manifest_observation_from_raw() {
  local manifest=$1 digest=$2 media_type=$3 size=$4
  jq -cS --arg digest "$digest" --arg mediaType "$media_type" \
    --argjson size "$size" '
    def valid_digest:
      type == "string" and test("^sha256:[0-9a-f]{64}$");
    def scalar_fact($value):
      {state:"complete",value:$value};
    def set_fact($values):
      {state:"complete",values:($values | unique | sort)};
    if type != "object" or .schemaVersion != 2 then
      error("raw manifest shape is malformed")
    elif (($digest | valid_digest) | not) or
         ($mediaType | type != "string" or length == 0) or
         ($size | type != "number" or floor != . or . <= 0) then
      error("raw manifest identity is malformed")
    elif (has("subject") and .subject != null and
          (.subject | type) != "object") then
      error("raw manifest subject is malformed")
    elif (.subject? != null and
          ((.subject.digest? | valid_digest) | not)) then
      error("raw manifest subject digest is malformed")
    elif (has("artifactType") and .artifactType != null and
          (.artifactType | type != "string" or length == 0)) then
      error("raw manifest artifact type is malformed")
    elif (.manifests? != null and
          ((.manifests | type) != "array" or
           any(.manifests[]; type != "object" or
             ((.digest | valid_digest) | not)))) then
      error("raw manifest children are malformed")
    elif (.layers? != null and (.layers | type) != "array") then
      error("raw manifest layers are malformed")
    elif (.layers? != null and any(.layers[];
          type != "object" or
          (.annotations? != null and
           (.annotations | type) != "object") or
          ((.annotations? // {})["in-toto.io/predicate-type"]? != null and
           ((((.annotations? // {})["in-toto.io/predicate-type"] | type) !=
              "string") or
            (((.annotations? // {})["in-toto.io/predicate-type"] | length) ==
              0))))) then
      error("raw manifest predicates are malformed")
    else
      {
        digest:$digest,
        mediaType:$mediaType,
        size:$size,
        facts:{
          subjectDigest:scalar_fact(
            if .subject? == null then null else .subject.digest end),
          artifactType:scalar_fact(.artifactType? // null),
          predicateTypes:set_fact([
            .layers[]?.annotations["in-toto.io/predicate-type"]?
            | select(type == "string" and length > 0)
          ]),
          children:set_fact([.manifests[]?.digest])
        }
      }
    end
  ' "$manifest"
}

manifest_observation_from_descriptor() {
  local descriptor=$1
  jq -cS '
    def valid_digest:
      type == "string" and test("^sha256:[0-9a-f]{64}$");
    def unknown:
      {state:"unknown"};
    def positive_scalar($value):
      if ($value | type) == "string" and ($value | length) > 0 then
        {state:"positive",value:$value}
      else
        error("contextual scalar fact is malformed")
      end;
    def partial_set($values):
      if ($values | type) != "array" or
         any($values[]; type != "string" or length == 0) then
        error("contextual set fact is malformed")
      else
        {state:"partial",values:($values | unique | sort)}
      end;
    if type != "object" or
       (.digest | valid_digest | not) or
       (.mediaType | type != "string" or length == 0) or
       (.size | type != "number" or floor != . or . <= 0) then
      error("contextual descriptor is malformed")
    elif (has("subjectDigest") and .subjectDigest != null and
          (.subjectDigest | valid_digest | not)) then
      error("contextual subject digest is malformed")
    elif (has("artifactType") and .artifactType != null and
          (.artifactType | type != "string" or length == 0)) then
      error("contextual artifact type is malformed")
    elif (has("predicateTypes") and .predicateTypes != null and
          (.predicateTypes | type != "array" or
           any(.[]; type != "string" or length == 0))) then
      error("contextual predicate types are malformed")
    elif (has("children") and .children != null and
          (.children | type != "array" or
           any(.[]; valid_digest | not))) then
      error("contextual children are malformed")
    else
      {
        digest,
        mediaType,
        size,
        facts:{
          subjectDigest:
            if (.subjectDigest? // null) == null then unknown
            else positive_scalar(.subjectDigest) end,
          artifactType:
            if (.artifactType? // null) == null then unknown
            else positive_scalar(.artifactType) end,
          predicateTypes:
            if (.predicateTypes? // null) == null or
               (.predicateTypes | length) == 0 then unknown
            else partial_set(.predicateTypes) end,
          children:
            if (.children? // null) == null or
               (.children | length) == 0 then unknown
            else partial_set(.children) end
        }
      }
    end
  ' <<<"$descriptor"
}

canonicalize_manifest_observations() {
  local observations=$1
  jq -csS '
    def valid_digest:
      type == "string" and test("^sha256:[0-9a-f]{64}$");
    def normalize_set($values):
      if ($values | type) != "array" or
         any($values[]; type != "string" or length == 0) then
        error("manifest observation set is malformed")
      else
        $values | unique | sort
      end;
    def nonempty_string($value):
      ($value | type) == "string" and ($value | length) > 0;
    def validate_scalar_fact:
      . as $fact |
      if ($fact | type) != "object" or
         ($fact.state | type) != "string" then
        error("manifest observation scalar fact is malformed")
      elif $fact.state == "unknown" and
           (($fact | has("value")) or ($fact | has("values"))) then
        error("manifest observation unknown scalar fact has a value")
      elif $fact.state == "positive" and
           ((nonempty_string($fact.value) | not) or
            ($fact | has("values"))) then
        error("manifest observation positive scalar fact is malformed")
      elif $fact.state == "complete" and
           (($fact | has("value") | not) or
            ($fact.value != null and
             (nonempty_string($fact.value) | not))) then
        error("manifest observation complete scalar fact is malformed")
      elif $fact.state == "positive" or $fact.state == "complete" then
        .
      elif $fact.state == "unknown" then
        .
      else
        error("manifest observation scalar state is unsupported")
      end;
    def validate_set_fact:
      . as $fact |
      if ($fact | type) != "object" or
         ($fact.state | type) != "string" then
        error("manifest observation set fact is malformed")
      elif $fact.state == "unknown" and ($fact | has("values")) then
        error("manifest observation unknown set fact has values")
      elif ($fact.state == "partial" or $fact.state == "complete") and
           ($fact | has("values") | not) then
        error("manifest observation set fact has no values")
      elif $fact.state == "partial" or $fact.state == "complete" then
        $fact.values = normalize_set($fact.values)
      elif $fact.state == "unknown" then
        .
      else
        error("manifest observation set state is unsupported")
      end;
    def validate_observation:
      if type != "object" or
         (.digest | valid_digest | not) or
         (.mediaType | type != "string" or length == 0) or
         (.size | type != "number" or floor != . or . <= 0) or
         (.facts | type != "object") then
        error("manifest observation identity is malformed")
      elif (
        (.facts.subjectDigest | validate_scalar_fact) and
        (.facts.artifactType | validate_scalar_fact) and
        (.facts.predicateTypes | validate_set_fact) and
        (.facts.children | validate_set_fact)
      ) then
        .
      else
        error("manifest observation facts are malformed")
      end;
    def conflict($digest;$field):
      error("manifest observation conflict: \($digest) \($field)");
    def scalar_facts($rows;$name):
      [$rows[].facts[$name]];
    def positive_values($rows;$name):
      [scalar_facts($rows;$name)[] |
        select(.state == "positive") | .value];
    def complete_values($rows;$name):
      [scalar_facts($rows;$name)[] |
        select(.state == "complete") | .value];
    def scalar_result($rows;$digest;$name):
      (positive_values($rows;$name) | unique) as $positive |
      (complete_values($rows;$name) | unique) as $complete |
      if ($positive | length) > 1 or ($complete | length) > 1 or
         (($complete | index(null)) != null and ($positive | length) > 0) or
         (($complete | length) == 1 and $complete[0] != null and
          ($positive | length) > 0 and $positive[0] != $complete[0]) then
        conflict($digest;$name)
      elif ($complete | length) == 1 then
        $complete[0]
      else
        error("manifest observation unresolved: \($digest) \($name)")
      end;
    def set_facts($rows;$name):
      [$rows[].facts[$name]];
    def partial_values($rows;$name):
      [set_facts($rows;$name)[] |
        select(.state == "partial") | .values];
    def complete_sets($rows;$name):
      [set_facts($rows;$name)[] |
        select(.state == "complete") | .values];
    def union_sets($sets):
      reduce $sets[] as $set ([]; . + $set) | unique | sort;
    def set_result($rows;$digest;$name):
      (partial_values($rows;$name)) as $partial |
      (complete_sets($rows;$name) | map(unique | sort) | unique) as $complete |
      if ($complete | length) > 1 then
        conflict($digest;$name)
      elif ($complete | length) == 1 and
           any($partial[]; . as $part |
             any($part[]; . as $value |
               (($complete[0] | index($value)) == null))) then
        conflict($digest;$name)
      elif ($complete | length) == 1 then
        $complete[0]
      else
        error("manifest observation unresolved: \($digest) \($name)")
      end;
    (map(validate_observation) | group_by(.digest) |
      map(
        . as $rows |
        $rows[0].digest as $digest |
        if any($rows[]; .mediaType != $rows[0].mediaType) then
          conflict($digest;"mediaType")
        elif any($rows[]; .size != $rows[0].size) then
          conflict($digest;"size")
        else
          {
            digest:$digest,
            mediaType:$rows[0].mediaType,
            size:$rows[0].size,
            subjectDigest:scalar_result($rows;$digest;"subjectDigest"),
            artifactType:scalar_result($rows;$digest;"artifactType"),
            predicateTypes:set_result($rows;$digest;"predicateTypes"),
            children:set_result($rows;$digest;"children")
          }
        end
      ) |
      sort_by(.digest))
  ' "$observations"
}

main() {
repository=
image=
output=
candidate_alias=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) [ "$#" -ge 2 ] && [ -z "$repository" ] || usage; repository=$2; shift 2 ;;
    --image) [ "$#" -ge 2 ] && [ -z "$image" ] || usage; image=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2 ;;
    --candidate-alias) [ "$#" -ge 2 ] && [ -z "$candidate_alias" ] || usage; candidate_alias=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$image" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[ -n "$output" ] || usage
[ -z "$candidate_alias" ] || [[ "$candidate_alias" =~ ^[A-Za-z0-9._-]+$ ]] || usage
for command_name in gh jq docker sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
: "${GH_TOKEN:?GH_TOKEN is required}"

output_dir=$(dirname -- "$output")
[ -d "$output_dir" ] && [ ! -L "$output_dir" ] || fail "output directory is unavailable"
[ ! -L "$output" ] || fail "output path is unsafe"

tmp=$(mktemp -d)
main_bash_pid=$BASHPID
cleanup_tmp() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$BASHPID" = "$main_bash_pid" ]; then
    rm -r -- "$tmp"
  fi
  exit "$status"
}
trap cleanup_tmp EXIT HUP INT TERM

gh api --paginate --slurp "repos/$repository/releases?per_page=100" \
  >"$tmp/releases.json" || fail "release inventory read failed"
gh api --paginate --slurp \
  "users/${repository%%/*}/packages/container/${repository##*/}/versions?per_page=100" \
  >"$tmp/packages.json" || fail "package inventory read failed"

jq -e 'type == "array" and all(.[]; type == "array")' "$tmp/releases.json" >/dev/null ||
  fail "release inventory response is malformed"
jq -e 'type == "array" and all(.[]; type == "array")' "$tmp/packages.json" >/dev/null ||
  fail "package inventory response is malformed"

jq -cS --arg repository "$repository" '
  [add // [] | .[] |
    {
      id,
      tag_name,
      target_commitish:(.target_commitish // ""),
      draft:(.draft // false),
      immutable:(if (.immutable | type) == "boolean" then .immutable else error("release immutable field is missing or not boolean") end),
      protected:(
        (.tag_name | capture(
          "^v(?<major>0|[1-9][0-9]*)[.](?<minor>0|[1-9][0-9]*)[.](?<patch>0|[1-9][0-9]*)$"
        )) as $version |
        ((.protected //
          (((.draft // false) | not) and
           ((.prerelease // false) | not))) and
         (($version.major | tonumber) > 1 or
          (($version.major | tonumber) == 1 and
           ($version.minor | tonumber) >= 2)))
      ),
      prerelease:(.prerelease // false),
      published_at,
      assets:(
        [.assets[] |
          {
            id,
            name,
            size,
            sha256:(.digest // "" | sub("^sha256:";""))
          }]
      )
    }
  ]
' "$tmp/releases.json" >"$tmp/releases-normalized.json" ||
  fail "release inventory normalization failed"

jq -e '
  all(.[];
    (.id | type == "number") and
    (.tag_name | type == "string" and test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
    (.target_commitish | type == "string" and test("^[0-9a-f]{40}$")) and
    all(.assets[];
      (.id | type == "number" and floor == . and . > 0) and
      (.sha256 | test("^[0-9a-f]{64}$"))
    )
  )
' "$tmp/releases-normalized.json" >/dev/null ||
  fail "release inventory contains an unsupported or undigested asset"

release_tags=$(jq -r '.[] | select(.protected) | .tag_name' \
  "$tmp/releases-normalized.json")
tag_refs=$(
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    target=$(jq -r --arg tag "$tag" '.[] | select(.tag_name == $tag) | .target_commitish' \
      "$tmp/releases-normalized.json")
    ref_json=$(gh api "repos/$repository/git/ref/tags/$tag" 2>/dev/null) ||
      fail "tag ref read failed for $tag"
    object_type=$(jq -r '.object.type // empty' <<<"$ref_json")
    object_sha=$(jq -r '.object.sha // empty' <<<"$ref_json")
    peeled_sha=$object_sha
    if [ "$object_type" = tag ]; then
      peeled_sha=$(gh api "repos/$repository/git/tags/$object_sha" |
        jq -r '.object.sha // empty')
    fi
    [ "$object_type" = commit ] || [ "$object_type" = tag ] ||
      fail "tag ref type is unsupported for $tag"
    [ "$object_sha" = "$target" ] || [ "$peeled_sha" = "$target" ] ||
      fail "tag ref does not match release target for $tag"
    jq -cnS --arg tag "$tag" --arg objectType "$object_type" \
      --arg objectSha "$object_sha" --arg peeledCommitSha "$peeled_sha" \
      '{tag:$tag,state:"present",objectType:$objectType,objectSha:$objectSha,peeledCommitSha:$peeledCommitSha}'
  done <<<"$release_tags"
)
printf '%s\n' "$tag_refs" | jq -sS . >"$tmp/tag-refs.json"

jq -cS '
  [add // [] | .[] |
    {
      id,
      digest:.name,
      tags:(.metadata.container.tags // [])
    }]
' "$tmp/packages.json" >"$tmp/versions.json" ||
  fail "package inventory normalization failed"
filter_active_package_versions "$(<"$tmp/versions.json")" \
  >"$tmp/versions-active.json" ||
  fail "package inventory conflicts with retired history"
mv "$tmp/versions-active.json" "$tmp/versions.json"
jq -e --slurpfile releases "$tmp/releases-normalized.json" '
  def below_floor:
    (.tag_name | capture(
      "^v(?<major>0|[1-9][0-9]*)[.](?<minor>0|[1-9][0-9]*)[.](?<patch>0|[1-9][0-9]*)$"
    )) as $version |
    (($version.major | tonumber) < 1 or
     (($version.major | tonumber) == 1 and
      ($version.minor | tonumber) < 2));
  all(.[];
    . as $package |
    all($releases[0][] | select(below_floor);
      (.tag_name as $tag |
       ($tag | sub("^v";"")) as $version |
       ("sha-" + .target_commitish) as $source |
       all($package.tags[]?;
         . != $tag and . != $version and . != $source))))
' "$tmp/versions.json" >/dev/null ||
  fail "pre-floor aliases remain in active package inventory"

: >"$tmp/subjects.jsonl"
: >"$tmp/manifests.jsonl"
: >"$tmp/attestations.jsonl"
: >"$tmp/versions.jsonl"

validate_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "registry descriptor digest is malformed"
}

validate_descriptor() {
  local descriptor=$1
  jq -e '
    type == "object" and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.mediaType | type == "string" and length > 0) and
    (.size | type == "number" and floor == . and . > 0)
  ' <<<"$descriptor" >/dev/null ||
    fail "registry descriptor is malformed"
}

read_raw_manifest() {
  local digest=$1 destination=$2 expected_media=${3:-} expected_size=${4:-}
  local actual_digest actual_media actual_size
  validate_digest "$digest"
  docker buildx imagetools inspect --raw "$image@$digest" >"$destination" 2>/dev/null ||
    fail "registry manifest read failed for $digest"
  jq -e 'type == "object" and .schemaVersion == 2' "$destination" >/dev/null ||
    fail "registry manifest is malformed for $digest"
  actual_digest="sha256:$(sha256sum "$destination" | awk '{print $1}')"
  [ "$actual_digest" = "$digest" ] ||
    fail "registry manifest bytes do not match $digest"
  actual_media=$(jq -r '.mediaType // empty' "$destination")
  [ -n "$actual_media" ] || fail "registry manifest has no media type for $digest"
  actual_size=$(wc -c <"$destination" | tr -d ' ')
  [ "$actual_size" -gt 0 ] || fail "registry manifest is empty for $digest"
  [ -z "$expected_media" ] || [ "$actual_media" = "$expected_media" ] ||
    fail "registry descriptor media type disagrees with manifest for $digest"
  [ -z "$expected_size" ] || [ "$actual_size" -eq "$expected_size" ] ||
    fail "registry descriptor size disagrees with manifest for $digest"
}

while IFS=$'\t' read -r version_id digest tags_json; do
  selection=
  raw="$tmp/raw-${digest#sha256:}.json"
  read_raw_manifest "$digest" "$raw"
  media_type=$(jq -r '.mediaType // empty' "$raw")
  manifest_size=$(wc -c <"$raw" | tr -d ' ')
  release_id=$(jq -r --argjson tags "$tags_json" '
    [.[] as $release |
      select($release.protected and any($tags[]?; . == $release.tag_name or
        . == ($release.tag_name | sub("^v";"")) or
        . == ("sha-" + $release.target_commitish))) |
      $release.id] | first // 0
  ' "$tmp/releases-normalized.json")
  jq -cnS --argjson id "$version_id" --arg digest "$digest" \
    --argjson tags "$tags_json" '{id:$id,digest:$digest,tags:$tags}' >>"$tmp/versions.jsonl"
  if [ "$media_type" = application/vnd.oci.image.index.v1+json ]; then
    jq -e '
      (.manifests | type == "array" and length > 0) and
      all(.manifests[]; type == "object")
    ' "$raw" >/dev/null || fail "registry image index is malformed for $digest"
    while IFS= read -r descriptor; do validate_descriptor "$descriptor"; done < <(
      jq -c '.manifests[]' "$raw"
    )
    platform_descriptor=$(jq -c '
      [.manifests[] |
        select(
          .platform.os == "linux" and
          .platform.architecture == "amd64" and
          ((.platform.variant? // "") == "")
        )] |
      if length == 1 then .[0] else empty end
    ' "$raw")
    platform_digest=$(jq -r '.digest // empty' <<<"$platform_descriptor")
    if [ "$release_id" -gt 0 ]; then
      [ -n "$platform_digest" ] ||
        fail "release image index has no unique linux/amd64 subject"
    fi
    if [ "$release_id" -gt 0 ]; then
release_record=$(jq -c --argjson id "$release_id" '.[]|select(.id==$id)|{id,tag:.tag_name,version:(.tag_name|sub("^v";"")),source:.target_commitish,draft,prerelease,immutable}' "$tmp/releases-normalized.json")
      product_context=$(jq -cnS --arg repository "$repository" --arg image "$image" --argjson release "$release_record" --argjson packageId "$version_id" --arg digest "$digest" --argjson tags "$tags_json" --argjson platform "$platform_descriptor" '{repository:$repository,image:$image,release:$release,package:{id:$packageId,digest:$digest,tags:$tags},rootDigest:$digest,platform:$platform}')
      selection=$(select_supported_authority "$product_context") ||
        fail "supported product authority selection failed for $digest"
      jq -cnS --arg digest "$digest" --argjson releaseId "$release_id" \
        --arg platformDigest "$platform_digest" --argjson aliases "$tags_json" \
        '{digest:$digest,kind:"root",releaseId:$releaseId,rootDigest:null,
          platformDigest:$platformDigest,aliases:$aliases}' >>"$tmp/subjects.jsonl"
      release_source=$(jq -r --argjson id "$release_id" \
        '.[] | select(.id == $id) | .target_commitish' \
        "$tmp/releases-normalized.json")
      collect_verified_attestations "$digest" "$release_source" "$selection"
    fi
    manifest_observation_from_raw "$raw" "$digest" "$media_type" "$manifest_size" \
      >>"$tmp/manifests.jsonl" ||
      fail "registry image index observation construction failed for $digest"
    while IFS= read -r descriptor; do
      child_digest=$(jq -r '.digest' <<<"$descriptor")
      ! is_retired_digest "$child_digest" ||
        fail "active manifest references a retired digest: $child_digest"
      child_media=$(jq -r '.mediaType' <<<"$descriptor")
      child_size=$(jq -r '.size' <<<"$descriptor")
      child_raw="$tmp/raw-${child_digest#sha256:}.json"
      read_raw_manifest "$child_digest" "$child_raw" "$child_media" "$child_size"
      manifest_observation_from_raw \
        "$child_raw" "$child_digest" "$child_media" "$child_size" \
        >>"$tmp/manifests.jsonl" ||
        fail "registry child observation construction failed for $child_digest"
      if [ "$release_id" -gt 0 ] &&
         jq -e '
           .platform.os == "linux" and
           .platform.architecture == "amd64" and
           ((.platform.variant? // "") == "")
         ' \
           <<<"$descriptor" >/dev/null; then
        jq -cnS --arg digest "$child_digest" --arg mediaType "$child_media" \
          --arg rootDigest "$digest" --argjson releaseId "$release_id" \
          '{digest:$digest,kind:"platform",releaseId:$releaseId,rootDigest:$rootDigest,
            platformDigest:null,aliases:[]}' >>"$tmp/subjects.jsonl"
      fi
      if jq -e \
        '.annotations["vnd.docker.reference.type"] == "attestation-manifest"' \
        <<<"$descriptor" >/dev/null; then
        descriptor_subject=$(jq -r \
          '.annotations["vnd.docker.reference.digest"] // empty' <<<"$descriptor")
        actual_subject=$(jq -r '.subject.digest // empty' "$child_raw")
        artifact_type=$(jq -r '.artifactType // empty' "$child_raw")
        validate_digest "$descriptor_subject"
        [ "$descriptor_subject" = "$actual_subject" ] ||
          fail "attestation subject binding disagrees for $child_digest"
        [ "$descriptor_subject" = "$digest" ] ||
          [ "$descriptor_subject" = "$platform_digest" ] ||
          fail "attestation is bound to a foreign subject for $child_digest"
        if [ "$release_id" -gt 0 ]; then
          predicate_types=$(normalize_modern_attestation_predicates \
            "$child_raw" "$descriptor_subject" "$selection") ||
            fail "supported attestation shape is malformed for $child_digest"
        else
          predicate_types=$(normalize_artifact_predicate_types "$child_raw") ||
            fail "attestation predicate binding is malformed for $child_digest"
        fi
        [ -n "$artifact_type" ] ||
          fail "attestation artifact type is missing for $child_digest"
        [ "$(jq length <<<"$predicate_types")" -gt 0 ] ||
          fail "attestation predicate binding is missing for $child_digest"
        contextual_descriptor=$(jq -cnS \
          --arg digest "$child_digest" --arg mediaType "$child_media" \
          --argjson size "$child_size" \
          --arg subjectDigest "$descriptor_subject" \
          --arg artifactType "$artifact_type" \
          --argjson predicateTypes "$predicate_types" \
          '{digest:$digest,mediaType:$mediaType,size:$size,
            subjectDigest:$subjectDigest,artifactType:$artifactType,
            predicateTypes:$predicateTypes}')
        manifest_observation_from_descriptor "$contextual_descriptor" \
          >>"$tmp/manifests.jsonl" ||
          fail "attestation observation construction failed for $child_digest"
      fi
    done < <(jq -c '.manifests[]' "$raw")
  else
    subject_digest=$(jq -r '.subject.digest // empty' "$raw")
    if [ -n "$subject_digest" ] && is_retired_digest "$subject_digest"; then
      fail "active artifact is bound to a retired subject: $digest"
    fi
    artifact_type=$(jq -r '.artifactType // empty' "$raw")
    predicate_types=$(normalize_artifact_predicate_types "$raw") ||
      fail "artifact predicate binding is malformed for $digest"
    if [ -n "$subject_digest" ] || [ -n "$artifact_type" ] ||
       [ "$(jq length <<<"$predicate_types")" -gt 0 ]; then
      [ -n "$artifact_type" ] ||
        fail "artifact manifest type is missing for $digest"
      [ "$(jq length <<<"$predicate_types")" -gt 0 ] ||
        fail "artifact manifest predicate binding is missing for $digest"
      if [ -z "$subject_digest" ]; then
        continue
      fi
      validate_digest "$subject_digest"
    fi
    manifest_observation_from_raw "$raw" "$digest" "$media_type" "$manifest_size" \
      >>"$tmp/manifests.jsonl" ||
      fail "registry manifest observation construction failed for $digest"
  fi
done < <(jq -r '.[] | [.id,.digest,(.tags | @json)] | @tsv' "$tmp/versions.json")

jq -sS '
  group_by(.digest) |
  map(if (unique | length) == 1 then .[0]
      else error("conflicting registry subject bindings") end) |
  sort_by(.digest)
' "$tmp/subjects.jsonl" >"$tmp/subjects.json" ||
  fail "registry subject bindings conflict"
canonicalize_manifest_observations "$tmp/manifests.jsonl" >"$tmp/manifests.json" ||
  fail "registry manifest descriptors conflict"
jq -e --slurpfile manifests "$tmp/manifests.json" '
  [.[] as $version |
    any($manifests[0][]; .digest == $version.digest)] |
  all
' "$tmp/versions.json" >/dev/null ||
  fail "package inventory contains an unbound manifest"
jq -sS '
  group_by(.bundleDigest) |
  map(if (unique | length) == 1 then .[0]
      else error("conflicting verified GitHub attestation records") end) |
  sort_by(.subjectDigest,.predicateType,.bundleDigest)
' "$tmp/attestations.jsonl" >"$tmp/attestations.json" ||
  fail "verified GitHub attestation records conflict"

temporary=$output.tmp.$$
trap 'rm -f -- "$temporary"; rm -r -- "$tmp"' EXIT HUP INT TERM
jq -cnS \
  --arg repository "$repository" --arg image "$image" \
  --slurpfile releases "$tmp/releases-normalized.json" \
  --slurpfile tagRefs "$tmp/tag-refs.json" \
  --slurpfile versions "$tmp/versions.json" \
  --slurpfile subjects "$tmp/subjects.json" \
  --slurpfile manifests "$tmp/manifests.json" \
  --slurpfile attestations "$tmp/attestations.json" \
  --arg candidateAlias "$candidate_alias" '
  {
    schema:"meet-backend/test-promotion-protected-state-input/v1",
    repository:$repository,image:$image,
    releases:($releases[0] // []),
    tagRefs:($tagRefs[0] // []),
    registry:{
      versions:($versions[0] // []),
      subjects:($subjects[0] // []),
      manifests:($manifests[0] // []),
      attestations:($attestations[0] // [])
    },
    proof:{
      path:"docs/evidence/MEE2-48-protected-history-v1.json",
      sha256:"db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529",
      checksum:"db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529 *docs/evidence/MEE2-48-protected-history-v1.json"
    }
  }
' >"$temporary" || fail "protected-state input construction failed"
chmod 600 "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || fail "protected-state input publication failed"
rm -r -- "$tmp"
trap - EXIT HUP INT TERM
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
