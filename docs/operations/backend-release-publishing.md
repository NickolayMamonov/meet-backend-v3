# Backend immutable release publishing

This runbook describes the future-only release controller for
`nickolaymamonov/meet-backend-v3`. It publishes a reviewed release exactly
once; it does not repair, adopt, overwrite, delete, or retag an externally
created release. Android/API fields, TIMEPAD ingestion, idempotent
`(source, sourceExternalId)` upserts, DTO boundaries, Flyway history, and
admin endpoint gates are unrelated product contracts and remain unchanged.

## Authority and protected history

`.release-please-manifest.json` and `version.json` at the exact fetched
`origin/dev` commit are the SemVer authority. The controller is serialized
with the repository release concurrency group, `queue: max`, and
`cancel-in-progress: false`. Every run recomputes its current-action relevant
release-ID set before and after Release Please. Only one positive numeric ID
newly admitted by that invocation can be materialized.

The permanent no-touch tuple is release ID `368531227`, version `1.1.0`,
tag `v1.1.0`, its four assets, absent ref, package aliases, and attestation
state. The durable
`docs/evidence/MEE2-48-protected-history-v1.json` snapshot and its checksum
cover that tuple and immutable predecessor release ID `367640510`, version
`1.0.1`. Compare canonical bytes before and after every hosted checkpoint.
Any mismatch is a hard stop.

The one-time continuation authority is release ID `377201468`, tag `v1.3.0`, version `1.3.0`, and source `a7abfe04f6852f479291a4710ebdee23e9ae8a34`. Its exact pending draft is the only continuation admitted for materialization: `draft:true`, `immutable:false`, `prerelease:false`, `published_at:null`, zero assets, an absent tag ref, and exactly empty `$TAG`, `$VERSION`, `sha-$SOURCE_SHA`, and `latest` registry state. An exact immutable published object is treated as completed and sent to the normal resolver; absence is also normal resolution, while every other object or state for this ID fails closed. It is never deleted, recreated, retagged, or adopted through a different tuple.

## Historical recovery records

Release ID `371012814` was the prior quarantined `v1.2.0` continuation, with source `9b6d2b06c0336ab8d153564dcf6328e81c4d7b36`. That tuple is historical evidence only; it is not an authorization for the current `v1.3.0` continuation.

Release ID `368531227`, tag `v1.1.0`, version `1.1.0`, and source `36ffd11ea4d35147f1df9c1cafa6a330300c1339` remain permanently no-touch. Their four assets, absent ref, package aliases, draft state, and attestation state are protected by the canonical snapshot and must remain byte-for-byte unchanged.

## Normal controller routes

1. `action`: invoke the pinned Release Please action, even when the current
   authority is already published. This permits later commits to create the
   next future release PR.
2. `materialize`: only a newly admitted current-action draft with exact tag,
   version, source SHA, numeric release ID, absent release tag ref, and empty
   asset inventory.
3. `completed`: only after Release Please ran and read-only checks prove that
   no release was created and protected history is equal.

A stale draft, partial asset inventory, populated ref, unexpected release,
wrong source, ambiguous release, or malformed response blocks the run before
Release Please or any writer. A terminal partial is left unchanged and
requires separately authorized incident work; a subsequent normal commit does
not authorize adoption.

## Immutable-policy prerequisite and credential order

The repository immutable-releases setting is enabled by a separately approved
repository owner/admin credential. That credential never enters Actions and no
workflow/helper performs a settings mutation.

After infrastructure is merged, provision and install the dedicated GitHub App
`meet-backend-immutable-policy-reader` **only** on
`nickolaymamonov/meet-backend-v3`, with Administration read-only. The hosted
installation uses the registered slug `meet-backend-policy-reader` (App ID
`4596738`) for that same policy-reader application. Metadata read is implicit;
there are no other configurable permissions. Store only the App ID as the
Actions variable `IMMUTABLE_POLICY_READER_APP_ID`. Store the private key only
as the protected release-environment secret
`IMMUTABLE_POLICY_READER_PRIVATE_KEY`.

The resolved order is: (1) owner/admin enables immutable releases under the
separate approval, (2) Actions mints a short-lived single-repository
installation token requesting Administration read, (3) the credential
verifier reads authenticated installation and repository metadata and
normalizes exact effective Administration `read`, implicit Metadata `read`,
and no configurable write permissions, (4) the policy guard performs a
GET-only read and requires `enabled=true`, and only then (5) Release Please
or publication may proceed. Missing, wrong-repository, unavailable,
write-capable, or uncertain credentials fail closed.

The reader token is passed only to GET-only policy guards. Helpers reject
PUT, PATCH, and DELETE before network I/O. Policy guards run at admission,
before every external writer, and immediately adjacent to the final release
PATCH. A prior successful read is never cached as publication authority.

## One-shot publication

The materialization job reruns Backend CI against the exact source SHA,
builds one `linux/amd64` image with only `$TAG`, `$VERSION`, and
`sha-$SOURCE_SHA` aliases, and verifies runtime, OCI provenance, SBOM, and
registry identity. It creates exactly these four release assets in fixed
order:

* `release-manifest.json`
* `image-index.json`
* `image-inspect.txt`
* `SHA256SUMS`

The final release PATCH is publish-last. Before release assets are uploaded,
the workflow creates and verifies a GitHub workflow artifact attestation for
the generated image-index evidence, and records `artifactAttestation:true` in
the manifest only after that gate succeeds. Immediately before the first
image push and each later writer, the job re-fetches policy and the live
numeric release. Immediately before the final PATCH, it also proves
`refs/tags/v1.1.0` and `refs/tags/$TAG` are absent and applies the shared
permanent deny policy. No shell command or writer intervenes between the final
guard and PATCH.

After PATCH, repository-owned release/ref/package/asset/attestation writers
are forbidden. GitHub's server-side automatic immutable-release attestation
created as the expected consequence of PATCH is allowed and is consumed
read-only. The workflow-created artifact attestation is strictly pre-PATCH;
the workflow does not create a post-PATCH attestation.

## Immutable proof

`scripts/verify-immutable-release-proof.sh` requires the expected repository,
explicit tag `<tag>`, positive numeric release ID, and source SHA. It fetches
the numeric release, resolves the explicit tag back to the same ID, requires
`immutable=true`, and verifies the automatic release attestation. It invokes
each asset check exactly as:

```text
gh release verify-asset <tag> <asset-path> --repo nickolaymamonov/meet-backend-v3
```

An omitted or wrong tag, or a latest release that resolves to an unrelated
release, cannot pass. The normalized proof binds repository, tag, release ID, source,
attestation/bundle identity where exposed, each asset name, API digest, and
downloaded SHA-256. It contains no raw API response or secret. Uploading the
checksummed `MEE2-48-<tag>-immutability-proof` artifact is the only
repository-owned control-plane write after PATCH.

## Terminal partial and rollback

If any external object for the current tuple exists and the run stops, do not rerun it. Leave
the draft and all external objects unchanged. Collect only allowlisted
read-only release/ref/package/attestation evidence and the Actions run URL,
then open separately authorized incident work. Before any current-tuple external
write, the infrastructure PR may be reverted normally after protected-history
equality is proven. After PATCH, no release rollback or compensating mutation
is part of this ticket.

## Verification

Run `git diff --check`, `bash -n scripts/*.sh`, ShellCheck, the immutable
credential/proof fixtures, release route/schema/mutation/ref/registry tests,
`scripts/verify-release-please-bootstrap.sh --auto-state`, `./gradlew test`,
and `./gradlew clean build` when Docker/PostgreSQL prerequisites permit.
Hosted rollout requires Backend CI plus independent QA, code, and compliance
review. Never record App private keys, tokens, OTPs, JWTs, refresh tokens,
database credentials, or provider tokens in evidence.
