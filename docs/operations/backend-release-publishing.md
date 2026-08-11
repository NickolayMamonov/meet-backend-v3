# Backend release publishing and production gate

The backend has one independent SemVer authority in the agreeing
`.release-please-manifest.json` and `version.json` files at the exact fetched
`origin/dev` commit. Gradle, Spring Boot build metadata, OpenAPI metadata, the
OCI version label, Release Please, and the release manifest must agree on the
same `MAJOR.MINOR.PATCH` tuple. The source identity is the exact lowercase
40-character commit SHA established by the unique first-parent commit that
changed both authority files to that version.

## Release flow

Release Please runs only for pushes to `dev`, targets release PRs to `dev`, and
uses the dedicated `RELEASE_PLEASE_TOKEN`. This is a fine-grained,
repository-restricted token owned by the release operator. It must have only
the contents and pull-request permissions required to open/update the Release
Please PR and create its draft release. Record its owner, repository
restriction, expiration, and rotation date in the operator's credential audit;
never put the value in this repository or in logs.

Release Please remains the sole creator and tag authority. Each run first
executes `scripts/resolve-release-descriptor.sh`, which recomputes
`authority_version`, `authority_tag`, and `authority_source_sha` from exact
`origin/dev` state. It finds the unique first-parent boundary that changed
both authority files and proves every later first-parent commit retains the
pair. Disagreement, missing or ambiguous boundaries, post-boundary drift, and
current/future relevant conflicts fail closed.

Before Release Please can run, the workflow checks out the reviewed tooling,
fetches the exact `origin/dev` head, and executes the resolver's read-only
`pre-action` mode with the same
`${{ secrets.RELEASE_PLEASE_TOKEN }}` expression later supplied to Release
Please. The explicit `--require-action-authority` profile first proves a
non-empty credential, the exact authenticated repository identity, and an
explicit `permissions.push == true` value. It then completes paginated release
enumeration. With `ACTIVE=0, COMPLETED=0` (fresh authority), it requires the
canonical ref to be absent before emitting `route=action`; with
`ACTIVE=0, COMPLETED=1`, it requires one strictly validated completed
predecessor and requires the canonical ref to exist and peel exactly to that
predecessor source before emitting `route=action`. Missing, rejected,
under-scoped, malformed, identity-mismatched, filtered-empty, incomplete, or
API-failing authority state fails before a route, Release Please, or any
hosted write.

The default `pre-action` profile is recovery-only. A single
current-authority canonical draft or strict GitHub generated
`untagged-<20 lowercase hex>` placeholder draft selects recovery; the action is
skipped and the normalized recovery descriptor is used directly. Zero visible
candidates fails closed and can never select action. This profile is used by
`release-recovery.yml` and `mutate-release-metadata.sh` with the read-only
`GITHUB_TOKEN`; neither caller receives the release PAT or can authorize
Release Please. A visible generated placeholder therefore remains a recovery
state even when the action-admission profile is used.

When Release Please creates no new release, the resolver can recover exactly
one draft only when its numeric release ID, canonical tag/version,
target/source SHA, draft/unpublished state, source files,
absent-or-source-identical tag, and asset metadata all match that current
authority tuple. A lower-version draft is ignored when its target predates the
current boundary, even if it remains reachable from `dev`. Zero unrelated
candidates is a successful no-publication run; duplicate current drafts and
relevant-but-unverifiable drafts are errors.

A validated published predecessor is an action-authority state, not a
recovery state. The pre-action resolver emits `route=action` only when the
dedicated action credential is positively proven; Release Please then owns
regeneration of the exact `v1.0.2` draft release PR and its review. The
read-only recovery profile never receives that route.

After Release Please reports `release_created=true`, the workflow does not
consume a release ID or derive one from a URL. It passes only the official
`tag_name`, `version`, and `sha` outputs to the resolver's dedicated
`post-action` mode. That mode recomputes the exact `origin/dev` authority,
enumerates every release page, strictly validates every current or future
relevant object, and requires one positive numeric-ID draft whose canonical
tag, version, lowercase full source SHA, target, state, source files, tag ref,
and asset inventory all bind to that authority. It emits the existing
descriptor schema with `origin=post_action`; no output is appended before all
checks pass.

The action output `release_created` value is an exact Boolean contract. The
workflow invokes `post-action` only for `true` and the existing `recover` mode
only for `false`; empty, malformed, or any other value fails closed. A false
result may return one active `origin=recovered` descriptor with a positive
numeric ID and exact authority tuple, or an inactive `origin=completed` or
`origin=none` no-op without a release ID. The route and descriptor are
appended once, after these returned-shape checks. A missing or duplicate draft,
wrong tuple, malformed object/page, invalid state, divergent ref, or invalid
asset inventory produces no partial output and no retry or manual repair.

The publisher receives the immutable descriptor and reruns CI against the
exact `source_sha`; the expected release tag is validated independently and is
not checked out before publication. Current workflow tooling is checked out
separately from the exact historical product source. The image build, if
needed, runs only from the source checkout and publishes exactly:

* `vMAJOR.MINOR.PATCH`
* `MAJOR.MINOR.PATCH`
* `sha-<full-source-sha>`

There is no `latest` alias. The image digest is deployment authority. Every
release mutation is addressed by the numeric GitHub release ID. The release
manifest, image evidence, and `SHA256SUMS` are attached and re-read before the
draft is made public; the numeric `draft=false` update is the final mutation.

### Resume and quarantine state machine

The resolver is metadata-only. Its asset state is either `empty` or
`complete_unverified`, with a deterministic inventory fingerprint. A
non-empty metadata inventory never authorizes a build, registry write, asset
upload, or publication.

The sole asset inventory byte contract is
`scripts/release-asset-inventory.sh`. It admits either an explicitly allowed
empty inventory or the exact four uploaded assets, then projects each asset to
`name,id,size,state,created_at,updated_at,url`, sorts the array by `name`, and
serializes compact JSON with no terminal newline. The fingerprint is the
SHA-256 of exactly those bytes. Raw GitHub asset order is non-semantic and
normalizes to the same bytes; callers do not implement a second validator,
serializer, or digest. Empty admission is resolver-only through
`--allow-empty`; resume verification and mutation paths require the complete
inventory. Any helper or comparison mismatch stops before metadata mutation;
there is no fallback digest, dual-digest compatibility mode, or compensating
write.

The publisher owns the only deep resume admission. For
`complete_unverified`, it downloads every asset by numeric asset ID into a
temporary directory, requires exactly `release-manifest.json`,
`image-index.json`, `image-inspect.txt`, and `SHA256SUMS`, rejects extra,
duplicate, malformed, or path-traversal checksum entries, and verifies every
byte. It then proves release ID/tag/version/source/target identity, one digest
for exactly `vVERSION`, `VERSION`, and `sha-SOURCE_SHA`, no `latest`, OCI
`linux/amd64` identity and readiness, subject-bound provenance/SBOM, and
GitHub attestation. Only this read-only sequence emits the ephemeral
`resume_admission=verified` value.

For `empty`, the publisher requires an empty registry, acquires the existing
create-only lease, repeats the empty admission, and builds. If an earlier
attempt completed the immutable registry write but stopped before evidence
assets were uploaded, the publisher admits the distinct `resume-registry`
route only when the registry is complete, its digest is identity-verified, and
`latest` is confirmed absent; that route reuses the digest, creates no image
write, and continues with attestation, evidence, deep verification, and
publish-last. Partial, divergent, identity-mismatched, raced, or `latest`
registry state and any asset/content/evidence failure leave the release draft
in place. Sanitized failure evidence is written only to the Actions job
summary or a reviewed workflow artifact; release notes are never replaced by
quarantine JSON. The workflow never repairs, replaces, retags, deletes, or
pre-populates registry state.

The registry preflight explicitly inspects `IMAGE:latest` before the lease or
any GHCR write. Only a confirmed not-found response emits `latest=absent`;
successful inspection emits a quarantine state, and authentication, network,
or any other inspection error fails closed as `latest=inspection-failed`.

All pre-write and pre-publication boundaries re-fetch and compare the complete
descriptor and authority tuple from `origin/dev`. Evidence upload is numeric
ID-bound, and publication occurs only after the final deep read-only
verification. The manual `release-recovery.yml` workflow remains an audit and
quarantine path; it does not own automatic recovery or publication.

GHCR does not provide a compare-and-swap primitive in this publication flow.
The accepted admission mechanism is therefore explicit and two-layered:

1. The job uses one package-scoped GitHub Actions concurrency group and, before
   its first GHCR write, creates the non-forced Git ref
   `refs/tags/release-lease-v<version>-<source-sha>` with
   `scripts/acquire-release-lease.sh`. Git ref creation is create-only, so
   cooperating writers cannot both acquire the same lease. The lease is never
   deleted and is an audit/quarantine marker. A complete pre-existing release
   is reused without acquiring a new lease.
2. The build publishes the exact three aliases in one BuildKit promotion
   operation, after a fresh read-only empty-state check taken immediately
   after lease acquisition. An identity-aware post-publish inventory is
   mandatory. If an external writer that is outside the lease policy races
   either check or the operation, the resulting partial, divergent, or
   identity-mismatched state fails closed: the draft stays unpublished,
   sanitized evidence is written only to the Actions summary/artifact, and no
   GHCR repair, retag, copy, overwrite, or delete is attempted.

The zero-write guarantee applies to `release-registry-state.sh` and recovery:
they never mutate GHCR, including when status 42 is returned. It does not
pretend that an unauthorized package writer can be prevented by a registry CAS
that does not exist. GHCR package write access must remain restricted to the
approved publication path. The authorized recovery is a new Conventional
Commit on `dev`, which creates a distinct patch tuple and source SHA through
Release Please; an old lease is not reused.

The publication workflow captures the registry inspection exit status under
`set +e`. A status 42 is handled as sanitized evidence in the Actions summary
or a reviewed artifact, and the job then fails without mutating the release.
No quarantine JSON is attached to a release and no quarantine note is written.

BuildKit provenance and SBOM publication is accepted only when the OCI index
contains at least one subject-bound attestation descriptor and its child
manifest carries both expected in-toto predicate types
(`slsa.dev/provenance` and SPDX or CycloneDX). BuildKit may place both
predicates in one attestation manifest rather than two separate descriptors.
`scripts/verify-oci-evidence.sh` derives the `provenance` and `sbom` fields in
the release manifest from those layers; the workflow does not treat a
handwritten boolean as evidence.

### Recovery, rollback, and hosted evidence

Complete-assets recovery is read-only through its first deep verification. The
ordered boundaries are:

1. deep-verify the observed canonical or generated-placeholder release;
2. canonicalize the same numeric release ID with the complete canonical
   metadata payload when the observed tag is a generated placeholder;
3. deep-verify the canonical draft again;
4. publish the same ID with the complete canonical metadata payload; and
5. perform only read-only release/tag checks afterward.

`scripts/mutate-release-metadata.sh` is the sole release PATCH caller. It
derives the exact `CHANGELOG.md` section from the fetched source, sends
`tag_name`, `target_commitish`, `name`, `body`, `draft`, `prerelease`, and
explicit non-latest metadata, then re-fetches and proves the same ID,
metadata, publication state, and unchanged four-asset fingerprint. It never
compensates after an uncertain mutation.

The read-only GHCR inventory uses scoped package-read access. It accepts one
image digest with exactly `vVERSION`, `VERSION`, and `sha-SOURCE_SHA`, no
`latest`, and only additional untagged or BuildKit subject-marker versions
whose fetched OCI/referrer graph proves attribution to the image or its
linux/amd64 subject. Foreign tags, partial aliases, divergent digests,
unverifiable referrers, API errors, and ambiguity fail closed.

For the hosted predecessor canary, retain evidence that the validated
predecessor selected `pre_action.route=action`, that the dedicated action
credential admitted Release Please, and that Release Please regenerated the
exact `v1.0.2` draft release PR for review. Review the regenerated PR and its
ordinary CI gates before any publication decision; the resolver and Release
Please remain the only authorities for release metadata and tags.

For MEE2-39, hosted state remains read-only before the reviewed fix is merged.
The first merge-triggered run is expected to find the exact v1.1.0 draft
`368531227` in pre-action and use the ordinary recovery route; operators must
not edit, delete, recreate, or manually publish that draft. After the reviewed
merge, inspect read-only evidence for source
`36ffd11ea4d35147f1df9c1cafa6a330300c1339`, exact tag peeling, one digest,
aliases `v1.1.0`, `1.1.0`, and
`sha-36ffd11ea4d35147f1df9c1cafa6a330300c1339`, no `latest`, all four
evidence assets and checksums, runtime/OCI identity, provenance, SBOM,
attestation, publish-last ordering, and unchanged immutable v1.0.1. If code
verification fails, use a reviewed code-only rollback; never repair hosted
release, tag, asset, or GHCR state manually.

Before publication, revert the workflow code normally if verification fails.
After canonicalization, retry from the same canonical draft. After a PATCH or
publication uncertainty, stop and collect read-only evidence; do not issue a
compensating release, tag, asset, or GHCR mutation.

## Production access prerequisites

`NickolayMamonov` is the current master-promotion authority. Before promoting
`dev` to `master`, an operator must record a distinct real GitHub login or team
as `PRODUCTION_APPROVER`. The identity must be an actual collaborator/team,
must review the promotion, and must be the required reviewer for the
`production` Environment. The dispatch initiator and reviewer must be
different people. No placeholder identity is committed or used.

Configure and audit enforceable protections on both `dev` and `master`:

* pull requests are required, with at least one approval;
* stale approvals are dismissed and approval is required after the latest
  push;
* required CI checks are strict and conversations must be resolved;
* force-push and branch deletion are blocked;
* administrators and other bypass actors are not exempt.

The `production` Environment must have required reviewers, prevent self-review,
administrator bypass disabled where available, and a selected deployment
branch policy allowing only exact `master` (no tags). Run
`scripts/audit-default-branch-bootstrap.sh`,
`scripts/audit-github-policies.sh` with a real `PRODUCTION_APPROVER`, and
`scripts/audit-production-environment.sh` after the operator configures the
Environment. These scripts print names and policy evidence only, never values.
The bootstrap audit requires the dispatch/recovery workflow and helper blobs on
the actual default `master` ref and proves no master/dev drift. Until a
reviewed dev-to-master promotion supplies those blobs and the required
protections, dispatch and production readiness remain externally blocked.
Until that identity and those protections exist, production and master
promotion remain externally blocked.

## Protected-empty Environment proof

The first external rollout phase creates `production` with its protection rules
but **without** variables or secrets. Run:

```sh
GITHUB_REPOSITORY=NickolayMamonov/meet-backend-v3 \
GH_TOKEN="$GH_TOKEN" \
scripts/audit-production-environment.sh --expect-unconfigured
```

After a real designated reviewer approves a dispatch from `master`, the first
inline shell step in `deploy-production.yml` receives empty values and exits.
That step runs before checkout, DNS, GitHub API, registry, `ssh-keyscan`, or
SSH. This is the approved missing-configuration proof; no sentinel host,
password, private key, or fake fingerprint is allowed.

Only after operators possess the real VPS host, port, user, absolute path,
SSH host fingerprint, and private key may they store the five Environment
variables and one secret. Then run the configured-name audit:

```sh
GITHUB_REPOSITORY=NickolayMamonov/meet-backend-v3 \
GH_TOKEN="$GH_TOKEN" \
scripts/audit-production-environment.sh --expect-configured
```

Name evidence does not reveal values and does not certify a live deployment.
The deployment requires a healthy predecessor, host-local `.backup.env` with
`AGE_RECIPIENT`, strict native OpenSSH host-key verification, an encrypted
backup, digest pull, host `docker`, Compose, `flock`, `age`, and `curl`
commands, and the existing prepare/update/deploy/rollback scripts.
Before any of those scripts run, the workflow archives the reviewed Compose and
helper files, transfers them over the already fingerprint-validated connection,
verifies their SHA-256 manifest on the VPS, and invokes only that staged copy.
The staged scripts use the live production root for `.env.production`, state,
volumes, and locks while keeping their reviewed code root separate.
First install, database downgrade, infrastructure provisioning, and production
certification are out of scope.
