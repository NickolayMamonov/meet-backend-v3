# MEE2-48 — Clean backend v1.2.0 implementation plan

## Planning status

This revision replaces the earlier planning comment with an executable,
future-only release plan. It incorporates all review rounds: Release Please
freshness, true multi-run controller queuing, entry-versus-terminal semantics
after a published release, the separately authorized terminal-partial
transition, the final tag/ref boundary, complete durable historical equality
evidence, stale operator guidance, and the currently disabled repository
immutable-releases policy.

- **Starting revision:** exact `origin/dev`
  `8ccaa8a10c705d7d9d1cf4ce6d7094800105eeb4`.
- **Release target:** existing open Release Please PR #41,
  `chore(dev): release 1.2.0`.
- **Permanent no-touch tuple:** release ID `368531227`, version `1.1.0`, tag
  `v1.1.0`, its four assets, its currently absent Git ref, and its GHCR and
  attestation state.
- **Immutable predecessor:** public v1.0.1, release ID `367640510`.
- **Planning-node production changes:** none. This file is the durable planning
  artifact.

### Planning checklist

- [x] Preserve the valid future-only state-machine and no-touch decisions.
- [x] Make current-action draft freshness executable under overlapping runs.
- [x] Define the final absent-ref-to-published-ref mutation boundary.
- [x] Define durable canonical historical snapshots and exact comparisons.
- [x] Add the release runbook and linked operator guidance to the change set.
- [x] Require `queue: max` and cover the release-merge three-push case.
- [x] Separate pre-action entry permission from post-action `completed`.
- [x] Define the separately authorized transition after a terminal partial.
- [x] Cover all stable protected release/asset metadata and drift cases.
- [x] Make repository immutability an explicit separately approved prerequisite.
- [x] Add live disabled/uncertain policy guards and negative fixtures.
- [x] Require API immutability and automatic release-attestation proof.
- [x] Bind every asset-integrity verification to the exact expected tag and
      numeric release.
- [x] Provision a dedicated hosted Administration-read GitHub App credential
      and prove its effective token cannot authorize policy writes.
- [x] Update acceptance, verification, rollout, rollback, and non-goals.
- [x] Implementation adds tests before deleting the legacy paths.
- [x] Implementation records the protected-history baseline before merge.
- [ ] Implementation passes local, hosted, QA, code, and compliance checks.
- [ ] Operators execute the two-merge rollout and preserve final evidence.

## Authority and stop conditions

Implementation starts from a fresh managed worktree at the then-current exact
`origin/dev`. Re-fetching is allowed; silently changing the planned behavior is
not. Stop and return for review if:

- PR #41 is closed, replaced, retargeted, or no longer selects exactly 1.2.0;
- its eventual release-authority diff contains files beyond
  `.release-please-manifest.json`, `CHANGELOG.md`, and `version.json`;
- release ID `368531227`, `refs/tags/v1.1.0`, or immutable v1.0.1 differs from
  the committed protected-history baseline;
- a stale hosted workflow targets v1.1.0 or enters a retired route;
- repository immutable releases are not explicitly approved and observed live
  as `enabled=true` before the v1.2.0 release-PR merge and before every
  v1.2.0 materialization/publication boundary;
- any v1.2.0 draft, ref, alias, attestation, or asset already exists before the
  authorized one-shot path expects it;
- the infrastructure merge or PR #41 merge cannot be observed without
  bypassing branch protection or normal review;
- a partial v1.2.0 external state exists and remediation would require delete,
  overwrite, retag, resume, canonicalization, or publication of that state.

The backend product contract remains unchanged: Android-facing endpoints and
fields stay compatible; admin endpoints stay gated; TIMEPAD remains under
`ingestion/timepad`; `(source, sourceExternalId)` upsert remains idempotent;
JPA entities remain behind DTOs; applied Flyway migrations are not edited; and
no secret, OTP, JWT, refresh token, database credential, or provider token is
logged or persisted as evidence.

## Target release state machine

`.github/workflows/release-please.yml` becomes the single release controller.
Entry classification and terminal routing are deliberately different
contracts.

**Entry classification** returns only `invoke-action` or a hard rejection.
An exact published current-authority release is an `invoke-action` state, not
a reason to skip Release Please. This is required because conventional commits
after published v1.2.0 must still create or refresh the future v1.2.1/v1.3.0
release PR. A non-empty or partial current-authority draft is a hard rejection
unless a later, separately authorized policy change quarantines that exact
tuple as described below.

After the pinned action has actually run, the controller emits one of these
terminal routes:

1. **`action`** — Release Please may create or update the release PR. While
   authority is 1.1.0 it runs with `skip-github-release: true`, so it cannot
   create or mutate a v1.1.0 release or tag.
2. **`materialize`** — accepted only when the current Release Please action
   invocation proves that it created exactly one new, positive numeric release
   ID whose official `tag_name`, `version`, and `sha` outputs match the newly
   fetched canonical empty draft.
3. **`completed`** — only a post-action, read-only outcome: pre-action observed
   an exact published current-authority predecessor, Release Please was still
   invoked, `release_created=false`, no relevant release ID appeared or
   disappeared, and protected history remained equal. It means “this run has
   no release to materialize,” not “skip Release Please.” Release Please may
   have created or refreshed the next release PR during that invocation.

Any stale empty draft, non-empty draft, generated placeholder, partial asset
set, populated or divergent registry state, unexpected ref, ambiguous release,
malformed API response, authority drift, or blocked tuple fails closed before
the action. There is no automatic quarantine, `recover`, `deep-recover`,
`resume`, `resume-registry`, lease-tag, canonicalization, replacement, repair,
or manually dispatched release route.

## Explicit change set

### Workflows

- Refactor `.github/workflows/release-please.yml` to the three-route controller,
  current-action set-difference admission, one-shot materialization, and
  publish-last behavior.
- Delete `.github/workflows/release-recovery.yml`.
- Update `.github/workflows/ci.yml` for the renamed/new release tests and
  bootstrap checks.

### Release helpers

- Add `scripts/release-mutation-policy.sh` for the permanent blocked tuple and
  common writer/ref guards.
- Simplify `scripts/resolve-release-descriptor.sh` to `pre-action`,
  `post-action`, and explicit-ID `verify --phase empty|complete`.
- Refactor `scripts/revalidate-release-mutation.sh` around the shared policy,
  exact phase, and adjacent live reads.
- Make `scripts/mutate-release-metadata.sh` publish-only.
- Add `scripts/upload-release-assets.sh` with fixed-order create-only uploads.
- Rename/refactor `scripts/verify-release-resume-state.sh` to
  `scripts/verify-release-evidence.sh`.
- Add `scripts/capture-protected-release-snapshot.sh` and
  `scripts/verify-protected-release-snapshot.sh`.
- Add `scripts/verify-immutable-release-policy.sh` as a read-only,
  fail-closed repository-policy guard. It must not enable or disable policy.
- Add `scripts/verify-immutable-policy-reader-credential.sh` to query only
  authenticated App installation/repository metadata and emit the normalized
  effective-permission proof consumed by the policy guard.
- Add `scripts/verify-immutable-release-proof.sh` to fetch the same numeric
  published release, require `immutable=true`, run release and per-asset
  integrity verification explicitly against the expected tag, and emit only
  canonical allowlisted proof bound to repository, tag, numeric release ID,
  source, asset identity, and digest.
- Delete `scripts/acquire-release-lease.sh` and recovery-only helper branches
  only after call-graph and bootstrap tests prove no callers remain.
- Retain and adapt the asset inventory, registry, GHCR package, OCI evidence,
  referrer closure, release consistency, PR fingerprint, and tag peeling
  helpers.

### Tests and fixtures

- Rewrite resolver, routing, descriptor-schema, mutation-revalidation,
  metadata-mutation, tag-ref, asset, registry, and evidence tests.
- Add current-action ID-set fixtures, stale-empty-draft fixtures,
  overlapping-run visibility fixtures, protected-snapshot schema fixtures, and
  the absent-to-divergent final-ref race fixture.
- Add repository immutability fixtures for enabled, disabled, malformed,
  unauthorized, transport-uncertain, rate-limited, and server-error states,
  effective-token permission fixtures, plus post-publication immutable-release
  and release-attestation fixtures. Add omitted-tag, wrong-tag, and
  latest-points-elsewhere asset-verification fixtures.
- Rename resume-oriented tests and fixtures to evidence-oriented names; do not
  preserve retired route vocabulary as compatibility aliases.

### Operations and release guidance

- Rewrite `docs/operations/backend-release-publishing.md` as the future-only
  release runbook.
- Update `README.md` to link directly to the publication runbook as well as the
  deployment guide.
- Update `docs/production-deployment.md` to distinguish immutable artifact
  publication from VPS deployment and link the publication runbook.
- Recheck linked release evidence in
  `docs/operations/spki-rollover-drill.md`; preserve its valid v1.0.1 and
  no-touch v1.1.0 statements, editing only if it advertises a retired action.
- Update `scripts/verify-release-please-bootstrap.sh` and
  `scripts/audit-default-branch-bootstrap.sh` to require the new workflow,
  helpers, docs, and tests and to reject stale operational guidance.

### Durable evidence

- Add `docs/evidence/MEE2-48-protected-history-v1.json`.
- Add `docs/evidence/MEE2-48-protected-history-v1.json.sha256`.
- Produce a hosted workflow artifact named
  `MEE2-48-v1.2.0-immutability-proof` after publication from read-only
  verification results. It contains canonical JSON plus its SHA-256, never raw
  API responses or credentials.

No Kotlin, runtime configuration, API/DTO, security, TIMEPAD, persistence,
Flyway, Compose, Android, or VPS deployment implementation belongs in the
change.

## Ordered implementation plan

### 1. Freeze the protected-history contract

Implement the snapshot helpers first. Before the infrastructure PR is merged,
capture the live protected state into the committed baseline:

```sh
GH_TOKEN="$GH_TOKEN" \
scripts/capture-protected-release-snapshot.sh \
  --repository "$GITHUB_REPOSITORY" \
  --image ghcr.io/nickolaymamonov/meet-backend-v3 \
  --blocked-release-id 368531227 \
  --blocked-version 1.1.0 \
  --immutable-release-id 367640510 \
  --immutable-version 1.0.1 \
  --output docs/evidence/MEE2-48-protected-history-v1.json

sha256sum docs/evidence/MEE2-48-protected-history-v1.json \
  > docs/evidence/MEE2-48-protected-history-v1.json.sha256

scripts/verify-protected-release-snapshot.sh \
  --snapshot docs/evidence/MEE2-48-protected-history-v1.json
sha256sum -c docs/evidence/MEE2-48-protected-history-v1.json.sha256
```

The baseline is committed in the infrastructure PR. It therefore survives the
infrastructure merge and PR #41 merge without relying on a run-scoped Actions
artifact, job output, cache, local path, or operator workstation. PR #41 must
not edit either baseline file.

Every hosted checkpoint captures a fresh file under `$RUNNER_TEMP`, validates
both files, then compares exact bytes:

```sh
current="$RUNNER_TEMP/MEE2-48-protected-history-current.json"
scripts/capture-protected-release-snapshot.sh \
  --repository "$GITHUB_REPOSITORY" \
  --image ghcr.io/nickolaymamonov/meet-backend-v3 \
  --blocked-release-id 368531227 \
  --blocked-version 1.1.0 \
  --immutable-release-id 367640510 \
  --immutable-version 1.0.1 \
  --output "$current"
scripts/verify-protected-release-snapshot.sh --snapshot "$current"
sha256sum -c docs/evidence/MEE2-48-protected-history-v1.json.sha256
cmp --silent docs/evidence/MEE2-48-protected-history-v1.json "$current"
```

Run that comparison before and after Release Please, after the infrastructure
merge run, before merging PR #41, and after the v1.2.0 run. A mismatch is a
hard blocker and produces only a field-path summary from allowlisted data; it
does not print raw API responses.

### 2. Use one canonical snapshot schema

`MEE2-48-protected-history-v1.json` is UTF-8, LF-only, `jq -S -c` canonical JSON
with one terminal newline and this closed schema:

```text
schema = "meet-backend/protected-release-history/v1"
repository = canonical owner/repository
image = lowercase GHCR repository
objects.blockedV1_1_0
objects.immutableV1_0_1

each object:
  identity:
    releaseId, version, tag, sourceSha
  release:
    id, nodeId, apiUrl, htmlUrl, assetsApiUrl, uploadUrlTemplate,
    tarballUrl, zipballUrl, tagName, name, targetCommitish,
    draft, immutable, prerelease, createdAt, updatedAt, publishedAt,
    bodySha256
    assets[] sorted by name:
      id, nodeId, apiUrl, browserDownloadUrl, name, label, size, state,
      contentType, createdAt, updatedAt, apiDigest, sha256
  gitRef:
    tag, state = absent|present
    when present: objectType, objectSha, peeledCommitSha,
                  annotatedChain[] sorted in peel order
  registry:
    protectedAliasBindings{} sorted by alias, with digest or null
    subjectDigest
    subjectAliases[] sorted
    versions[] sorted by digest:
      id, digest, tags[] sorted
    referrers[] sorted by digest:
      digest, mediaType, size, subjectDigest, artifactType,
      predicateTypes[] sorted, rawManifestSha256
  githubAttestations[] sorted by predicateType then bundleDigest:
    subjectDigest, predicateType, sourceRepository, sourceDigest,
    workflowRef, signerWorkflow, bundleDigest
```

For the blocked object, `sourceSha` is the exact draft
`target_commitish`; its canonical Git ref is recorded as absent. A null
registry binding is evidence and must remain null. For v1.0.1, the ref must be
present and peel to its recorded source.

Asset bytes are downloaded by numeric asset ID and represented only by SHA-256
and allowlisted metadata. Registry versions are limited to each protected
subject digest and its verified OCI/referrer closure, so publishing an unrelated
future digest does not alter the baseline. Protected alias bindings include
the version, `v` version, `sha-<source>`, and `latest`; all aliases attached to
the protected subject are separately captured in `subjectAliases`.

GitHub attestation normalization records stable verified claims and a digest of
the verified bundle. It excludes verification time, API pagination, and local
CLI diagnostics.

`release.immutable` is required and Boolean. `assets[].label` is preserved as
either its exact string or JSON null. `assets[].apiDigest` preserves the exact
API value (including the algorithm prefix, or JSON null when the API has not
assigned one); the independently downloaded byte hash remains
`assets[].sha256`. URLs are normalized only by requiring HTTPS and preserving
their exact stable API value; `upload_url` is stored as the documented
template, not an expanded signed URL.

The allowlist above is closed. Explicit volatile exclusions are:
`assets[].download_count`; release reaction/count aggregates; author,
uploader, actor, and other identity objects; transient permissions; API
pagination/link headers; ETags and request IDs; signed or expiring URL query
parameters; verification timestamps; CLI diagnostics; and server-side
renderings derivable from the captured body. Identity objects are excluded in
full rather than reduced to login or numeric ID, because account rename,
suspension, and profile changes are unrelated to release mutation.

The capture helper constructs the schema directly from allowlisted fields. It
must never persist authorization headers, token values, signed URLs/query
strings, uploader/actor/login/email objects, runner paths, certificate PEM,
OIDC JWT, database/provider credentials, or raw environment values. It must
not capture a full API response and redact afterward.

### 3. Test the future-only contracts before deletion

Add fixtures that prove:

- ordinary PR create/update returns `action`;
- an exact published current release enters `invoke-action` and can return
  `completed` only after the pinned action ran without creating a release;
- blocked ID `368531227`, version `1.1.0`, and tag `v1.1.0` are never mutation
  candidates;
- stale empty drafts, partial assets, generated placeholders, duplicate
  candidates, malformed pages, target/source drift, unexpected refs, populated
  aliases, divergent digests, and `latest` fail closed;
- no writer command is reached in every rejection case;
- the canonical protected snapshot is stable under API ordering changes and
  rejects one-field metadata, asset-byte, ref, alias, digest, referrer, or
  attestation drift;
- a schema-driven drift matrix enumerates every included scalar JSON pointer
  in both protected objects and supplies a fixture that changes only that one
  field. The test fails if an allowlisted field has no drift case, if a drift
  case changes multiple fields, or if an explicitly volatile field affects
  canonical output. Array cases cover one element at a time, including every
  included release field, every included asset field (`label` and
  `apiDigest` included), ref/peel fields, registry bindings and versions,
  referrers, and attestation claims.

Keep the old implementations until these negative tests fail for the intended
reason. Then remove the retired paths without compatibility wrappers.

### 4. Serialize the full controller and bind freshness by set difference

Put non-cancelling concurrency at workflow scope, not only on the publish job:

```yaml
concurrency:
  group: backend-release-controller-${{ github.repository }}-dev
  queue: max
  cancel-in-progress: false
```

This group covers pre-action classification, the pinned Release Please action,
post-action admission, gates, and publication. `cancel-in-progress: false`
alone is insufficient because the default `queue: single` replaces an older
pending run. `queue: max` opts into GitHub's supported multi-pending queue
(currently up to 100 waiters), so a newer push neither cancels the active run
nor replaces an older pending run. The implementation must fail static
validation if `queue` is absent, is not `max`, or is combined with
`cancel-in-progress: true`. Retain package-scoped non-cancelling concurrency
as defense in depth if other approved package writers exist.

Immediately before invoking Release Please, `pre-action` validates all release
pages and emits a canonical sorted set of positive numeric **relevant release
IDs**. Relevance is resolver-owned and deterministic: the blocked historical
tuple is recognized but excluded from candidate selection; current/future
SemVer objects, canonical current tag/source objects, and malformed objects
that could collide with current authority are included or cause failure.
Store the canonical set and its SHA-256 under `$RUNNER_TEMP`; do not print or
upload the raw release enumeration.

`post-action` receives:

- the exact pre-action relevant-ID set and digest;
- official Release Please `release_created`, `tag_name`, `version`, and `sha`
  outputs;
- a fresh complete release enumeration.

For `release_created=true`, require:

1. exact Boolean `true`;
2. official tag `vVERSION`, canonical version, and lowercase 40-character SHA;
3. no pre-action relevant ID disappeared;
4. `postRelevantIds - preRelevantIds` contains exactly one positive ID;
5. that new ID resolves to exactly one draft with the official tag, version,
   source/target SHA, `prerelease=false`, `published_at=null`, empty assets,
   and absent canonical tag ref;
6. no other relevant current-authority draft exists.

The new numeric ID is derived only from the set difference. The action has no
release-ID output and the implementation must not infer an ID from a URL.

For `release_created=false`, require no newly relevant ID and return only
`action` or `completed`; an existing empty draft is stale and rejected, never
adopted. Non-Boolean output fails.

Tests include:

- a stale empty draft present in both pre and post sets while the action says
  true;
- action true with zero, two, malformed, or removed IDs;
- a new ID whose object disagrees with any official action output;
- simulated run A `pre=[]`, `post=[N]`, followed by run B `pre=[N]`,
  `post=[N]`, proving B cannot claim N;
- the exact three-push release-merge fixture: run A is active in the controller
  group, run B is the PR #41 release-merge push and is pending, then push C
  arrives. Assert A remains active, B remains pending ahead of C rather than
  being cancelled/replaced, all three runs eventually enter the controller
  one at a time, and B still invokes Release Please. The fixture records B as
  waiting before C is dispatched, matching GitHub's FIFO-by-wait-start
  contract; it does not assume dispatch order alone determines queue order.
  B may derive only the release ID newly added across B's own pre/post
  snapshots; C observes that ID in its pre-set and cannot claim or
  rematerialize it;
- static workflow assertions that concurrency is workflow-scoped,
  `queue: max`, `cancel-in-progress: false`, and Release Please plus every gate
  and writer are inside the serialized boundary. The fixture models GitHub's
  queue contract and the hosted rollout records the three run IDs/statuses
  whenever three real pushes overlap; no synthetic production commit is made
  solely to force overlap.

### 5. Preserve future PR creation after publication

`pre-action` must model a matching published release as
`entry=invoke-action, currentPublication=published`. It still captures the
release-ID and release-PR fingerprints and invokes the pinned Release Please
action. It must not emit `completed`, short-circuit the action step, or gate the
action with `if: route != completed`.

After the action:

- `release_created=true` follows the fresh-ID `materialize` contract;
- `release_created=false` with unchanged relevant release IDs and a previously
  published current authority emits post-action `completed`, after any future
  PR create/update work;
- `release_created=false` without that published predecessor emits `action`;
- any release-ID disappearance, partial current object, or action/output
  ambiguity fails.

Add a post-publication fixture beginning with published v1.2.0 plus a new
`fix:` commit. Assert pre-action invokes Release Please, the future release PR
for v1.2.1 is create/update reachable, no v1.2.0 writer is called, and only
after the action may the run terminate `completed`. Add the corresponding
`feat:` fixture selecting v1.3.0 and a no-new-commit fixture; all three invoke
the action before terminal classification.

### 6. Centralize mutation and blocked-ref policy

`scripts/release-mutation-policy.sh` owns:

```text
blocked release ID = 368531227
blocked version    = 1.1.0
blocked tag        = v1.1.0
blocked ref        = refs/tags/v1.1.0
```

Every repository-owned release, asset, attestation, registry, or ref-capable
writer invokes it immediately before its write. It rejects a target matching
any blocked field and re-fetches the blocked release and blocked ref to prove
the committed protected snapshot still applies. The Release Please action is
admitted at authority 1.1.0 only with `skip-github-release: true`.

### 7. Reduce helpers to one-shot publication

Refactor the descriptor to one active schema shared by `post-action` and
explicit-ID `verify`. `verify --phase empty` requires the newly created empty
draft. `verify --phase complete` requires exactly the four expected assets and
the original identity tuple.

`upload-release-assets.sh` uploads, in fixed order:

1. `release-manifest.json`;
2. `image-index.json`;
3. `image-inspect.txt`;
4. `SHA256SUMS`.

Before each create-only POST it re-fetches the numeric release, applies the
blocked policy, validates exact ID/tag/version/source/draft state, and proves
the asset inventory equals the already-uploaded prefix. It never deletes,
replaces, overwrites, or retries an uncertain POST.

`verify-release-evidence.sh` retains checksum, manifest, exact alias/digest,
OCI label, linux/amd64, user `10001:10001`, JAR, writable uploads, provenance,
SBOM, referrer closure, GitHub attestation, and tag/source checks without any
resume admission output.

### 8. Require separately approved repository immutability

Read-only inspection on 2026-08-14 returned repository immutable-release
policy `enabled=false` and `enforced_by_owner=false`. Therefore an immutable
v1.2.0 is not currently publishable. MEE2-48's implementation PR may add the
guards below, but it does **not** authorize a workflow, script, bot token, or
implementer to change the repository setting.

After the infrastructure PR is merged and verified, but before PR #41 is
merged, require a separate explicit human approval recorded by the workflow's
normal approval mechanism. That approval authorizes a designated repository
owner/admin to enable immutable releases once through the GitHub repository
settings control or its documented API. The approval must identify the
repository and the intended `disabled -> enabled` change; it must not contain
a credential. The owner/admin browser session or API credential used for this
one enablement remains outside GitHub Actions, repository/environment secrets,
artifacts, and logs. No repository credential with settings-write authority is
added to Actions, and no production helper implements the setting mutation.

Provision one exact hosted read credential before the infrastructure PR is
eligible to merge:

- GitHub App slug: `meet-backend-immutable-policy-reader`;
- installation scope: **Only select repositories**, containing only
  `nickolaymamonov/meet-backend-v3`;
- configurable repository permissions: **Administration: Read-only** and
  every other configurable repository permission set to **No access**;
  GitHub's implicit Metadata read permission is accepted;
- organization and account permissions: **No access**;
- Actions variable: `IMMUTABLE_POLICY_READER_APP_ID`;
- protected `release` environment secret:
  `IMMUTABLE_POLICY_READER_PRIVATE_KEY`.

The App installation is the credential authority; the private key can mint
only installation tokens bounded by that App's read-only permission set. A
pinned `actions/create-github-app-token` step mints a short-lived token for the
current owner and the single repository, explicitly requesting
`permission-administration: read`. Its output is assigned only to the policy
guard step as `GH_TOKEN`, is masked by Actions, is unset after that step, and
is not reused for checkout, Release Please, release/assets, attestations,
packages, refs, or artifact upload. Missing App ID/private key, token issuance
failure, installation mismatch, or any broader effective permission fails
closed before PR #41 merge and before every materialization writer.

Immediately after minting, use that token to call the authenticated
installation metadata endpoint read-only and normalize its effective
permissions. Require:

```text
repository = nickolaymamonov/meet-backend-v3
repositorySelection = selected
permissions.administration = read
all other configurable permissions != write
```

This normalized GitHub authorization result is the hosted proof that the
effective token cannot authorize immutable-policy `PUT` or `DELETE`. Do not
send speculative PUT/DELETE probes to the production repository: a
misprovisioned credential would make such a probe destructive. Instead,
fixture-backed transport tests exercise both methods and require GitHub's 403
denial for an Administration-read token, while static workflow tests prove
the hosted credential is passed only to GET-only helpers. A live permission
result other than the exact allowlist above is treated as write-capable or
unknown and rejected before the policy GET.

After the authorized owner/admin acts, the rollout performs a fresh read-only
policy query and requires a valid response with exact Boolean
`enabled=true`. `enforced_by_owner` is captured as policy provenance but may be
either Boolean value: direct repository enablement is acceptable, and a later
owner-enforced enablement is stronger. The sanitized policy result, approval
reference, observation time, repository, and hosted run URL are retained in
the rollout evidence; owner identity, headers, tokens, and raw credential
material are not.

If approval is withheld, the setting mutation fails, or the read is disabled
or uncertain, stop before merging PR #41 and before any v1.2.0 external write.
The infrastructure PR may remain merged because authority 1.1.0 is PR-only.
There is no automated rollback of repository policy. If the approval is
withdrawn before any v1.2.0 write, an authorized owner/admin may separately
decide to disable it and MEE2-48 remains blocked. After any v1.2.0 write, and
especially after publication, disabling immutable releases is not this
ticket's rollback path; the repository setting remains enabled unless a
separate policy change is approved.

Add `scripts/verify-immutable-release-policy.sh` as a read-only guard around
the documented repository immutable-releases settings endpoint. It accepts
only the dedicated App installation token, a preceding exact effective-
permission proof, HTTP success, valid expected schema, and exact
`enabled=true`. Its HTTP transport allowlists method `GET` and the one
repository settings endpoint; attempting to configure `PUT`, `PATCH`, or
`DELETE` is a local hard failure before network I/O. It emits only normalized
non-secret fields and fails closed for:

- `enabled=false`, missing `enabled`, non-Boolean values, or malformed JSON;
- 401/403/404, authorization ambiguity, rate limiting, and 5xx responses;
- transport failure, timeout, truncated body, or an unexpected redirect;
- repository mismatch or an unavailable/unknown endpoint;
- unavailable App inputs/token, wrong installation/repository selection,
  Administration permission other than exact `read`, or any effective
  configurable permission equal to `write`.

Run this live guard:

1. after the separate approval and before PR #41 is eligible to merge;
2. at `materialize` admission, before CI can lead to any v1.2.0 external write;
3. immediately before every release/asset/attestation/registry/ref-capable
   writer, alongside the blocked-tuple guard;
4. inside the publish-only helper immediately adjacent to the final Release
   PATCH, after payload construction and all other live ref/release checks.

An earlier successful observation is never cached as publication authority.
Disabled or uncertain policy reaches no materialization writer and, at the
final boundary, reaches no PATCH. If policy becomes unavailable after an
earlier write, stop with the unpublished terminal-partial procedure; do not
publish a mutable release or attempt repair.

Tests use fixtures, never the live setting, for enabled direct-repository,
enabled owner-enforced, disabled, missing/non-Boolean field, malformed body,
401/403/404/429/5xx, timeout/transport failure, and enabled-then-disabled race
states. Credential fixtures cover missing App variable/secret, issuance
failure, wrong repository selection, Administration `none`/missing/write,
another effective `write` permission, exact Administration read plus implicit
Metadata read, local PUT/PATCH/DELETE rejection before transport, and
GitHub-denied PUT/DELETE responses for an Administration-read token. Each
negative case proves the policy result is not admitted and the writer/PATCH
fixture has zero calls. The enabled cases prove the normalized policy and
effective-permission observations are passed into release evidence without
granting any settings-write capability.

### 9. Implement the linear publish job

The only admitted job performs:

1. fresh `enabled=true` immutable-release policy admission;
2. full Backend CI gates against `SOURCE_SHA`;
3. exact empty draft, empty three-alias registry, and absent `latest` checks;
4. adjacent immutable-policy and mutation-policy revalidation;
5. one linux/amd64 BuildKit push producing one digest under exactly
   `v1.2.0`, `1.2.0`, and `sha-SOURCE_SHA`;
6. registry, runtime, OCI, provenance, and SBOM verification;
7. generation of the four deterministic evidence assets;
8. adjacent immutable-policy and release-policy revalidation before creating
   the workflow's GitHub artifact attestation;
9. artifact-attestation verification;
10. four fixed-order create-only asset uploads;
11. complete pre-publication evidence verification;
12. the adjacent immutable-policy/ref/release boundary and publish PATCH;
13. read-only proof that the published release itself is immutable and has
    GitHub's immutable-release attestation;
14. upload only the normalized hosted immutability-proof artifact. No later
    repository-owned release, ref, package, release-asset, attestation, or
    repository-policy writer is permitted.

The post-PATCH writer prohibition applies to repository-owned workflow steps,
scripts, credentials, and operator actions. It deliberately does not prohibit
GitHub's server-side generation of the automatic immutable-release attestation
caused by the publication PATCH; that platform-generated object is expected,
bounded-read retried for propagation, and then consumed read-only. The
workflow must not invoke an attestation creation command after PATCH.

Any failure after any external write leaves an unpublished terminal partial
draft. Future controller runs reject it.

### 10. Define the separately authorized terminal-partial transition

This ticket does **not** automatically convert an arbitrary partial current
release into an action route. A newly observed partial tuple remains a hard
stop: Release Please and every writer are skipped, and the tuple is neither
adopted nor mutated.

Continuation requires a separate product-authorized incident/follow-up PR that
changes policy explicitly. That transition must:

1. capture and commit a canonical read-only snapshot and SHA-256 for the exact
   partial tuple: numeric release ID, version, tag, source SHA, release/ref
   metadata, asset IDs/metadata/bytes, aliases/digests/referrers, and
   attestations;
2. add that exact tuple—not a version range or discovery rule—to the permanent
   writer denylist and resolver quarantine allowlist;
3. permit only `entry=invoke-action` with `skip-github-release: true` while
   manifest authority still equals the quarantined version, so Release Please
   can create or refresh a distinct future SemVer PR but cannot create,
   publish, repair, or adopt the quarantined release;
4. require exact snapshot equality before and after every action invocation;
5. after the distinct future release PR advances manifest authority, permit
   normal release-capable Release Please only for that new version/source;
6. retain the quarantined tuple's permanent writer deny and snapshot checks
   after authority advances.

The separately authorized PR must add fixtures proving: no authorization means
hard rejection before Release Please; exact authorization enables action-only
PR creation/update; `release_created=true` while still on quarantined authority
is rejected; the quarantined numeric ID can never be returned by set
difference, `verify`, materialization, asset upload, registry/tag mutation,
attestation, or publication; one-field snapshot drift blocks the action; and a
distinct future tuple is admitted only after its release PR advances manifest
authority. MEE2-48 itself includes the no-authorization hard-stop fixtures and
must not claim that normal Release Please can resume immediately after a
partial incident.

### 11. Close the final tag/ref and immutable-policy boundary

Choose **absence only** as the acceptable pre-publication state for
`refs/tags/v1.2.0`. There is no acceptable pre-existing lightweight,
annotated, source-identical, or divergent v1.2.0 ref.

Inside the publish-only metadata helper, assemble the deterministic payload
first. Then, immediately adjacent to and after all other complete-phase checks:

1. re-fetch repository immutable-release policy and require exact
   `enabled=true`;
2. re-fetch `refs/tags/v1.1.0` and require HTTP 404/absence;
3. re-fetch `refs/tags/v1.2.0` and require HTTP 404/absence;
4. re-fetch release ID and complete asset fingerprint;
5. re-run the shared blocked tuple policy;
6. issue the one same-ID PATCH as the next command, with canonical metadata,
   `draft=false`,
   `prerelease=false`, and `make_latest=false`.

No intervening step or shell command may occur between the last live
policy/ref/release guard and the PATCH. Treat disabled policy,
authentication, transport, 403/404, rate-limit, and 5xx responses as
uncertainty or rejection, never as authority to publish.

After the PATCH response passes same-ID metadata and unchanged-asset checks:

```sh
scripts/verify-immutable-release-policy.sh \
  --repository "$GITHUB_REPOSITORY"

scripts/verify-release-tag-ref.sh \
  --repository "$GITHUB_REPOSITORY" \
  --tag v1.2.0 \
  --source-sha "$SOURCE_SHA"
```

Then fetch the same numeric release through the API and require exact
`immutable=true`, `draft=false`, the expected tag/source, and unchanged four
asset IDs/digests. Verify GitHub's automatic immutable-release attestation for
the release/tag/source and verify each of the four release assets against that
release attestation using a pinned GitHub CLI version that supports release
integrity verification. Every `gh release verify-asset` invocation must pass
the exact expected tag as its first positional argument; the omitted-tag form
is forbidden because GitHub CLI resolves it against the latest release, while
this publication intentionally uses `make_latest=false`. This is distinct from
the workflow-created artifact attestation verified before publication.

The hosted evidence records normalized, non-secret proof containing the
release ID, tag, source SHA, API `immutable=true`, policy `enabled=true`,
effective hosted credential permission `administration=read`,
release-attestation verification result and bundle/claim digest when exposed,
and each expected asset name/API digest/downloaded SHA-256 with successful
immutable-release asset verification. For each asset the normalized result
must repeat the canonical repository, expected tag `v1.2.0`, expected numeric
release ID, release-attestation/bundle identity exposed by the pinned CLI,
asset name, API digest, and downloaded SHA-256. The wrapper rejects CLI output
that cannot be associated with that same expected release tuple; it does not
infer association from command success alone. A bounded read-only retry is
permitted only for documented post-publication attestation propagation; it
never reissues PATCH or any other repository write. Missing, invalid,
ambiguous, wrong-release, or unverifiable immutable-release attestation fails
the run and invokes the terminal incident procedure without modifying the
published release.

Finally re-prove `refs/tags/v1.1.0` is absent and the protected-history
snapshot is equal. Canonicalize that allowlisted result, write its SHA-256, and
upload the pair as the hosted
`MEE2-48-v1.2.0-immutability-proof` Actions artifact. This evidence-artifact
upload is the only allowed post-publication control-plane write; no release,
ref, package, release asset, workflow-created attestation, or
repository-policy mutation follows. GitHub's automatic immutable-release
attestation is a server-side consequence of PATCH, not a repository-owned
post-PATCH writer.

The race fixture drives two API observations: the earlier verifier sees
v1.2.0 absent, but the mutator's adjacent fetch sees a divergent ref. The test
must prove the PATCH fixture was never invoked. Companion fixtures cover
source-identical existing refs, blocked v1.1.0 appearing, API uncertainty, and
successful absent-to-published peeling. Add adjacent-policy fixtures where an
earlier read is enabled but the final read is disabled, malformed, forbidden,
rate-limited, timed out, or 5xx; every case reaches no PATCH. Post-publication
fixtures cover `immutable=false`, missing/non-Boolean `immutable`, wrong
release/tag/source, missing release attestation, invalid attestation, one
unverified asset, successful delayed read-only propagation, and the complete
`immutable=true` success case. Asset-verification fixtures additionally prove
that an omitted tag is rejected before invoking GitHub CLI, a wrong explicit
tag is rejected, and a simulated latest release of v1.0.1 cannot satisfy an
expected v1.2.0 verification. The success fixture asserts the exact argv
`gh release verify-asset v1.2.0 <asset-path> --repo <repository>` for all four
assets and the normalized expected repository/tag/numeric-release/attestation/
asset/digest binding.

### 12. Rewrite operator guidance and reject stale instructions

The publication runbook must describe only:

- ordinary Release Please PR creation/update;
- current-action fresh-draft admission;
- one-shot materialization and publish-last;
- completed read-only no-op;
- protected-history comparison;
- the separate approval and owner/admin enablement prerequisite;
- live policy guarding and post-publication immutable-release proof;
- rollout monitoring and terminal-partial incident handling.

The future-only terminal-partial procedure is:

1. stop the run and do not rerun it;
2. collect allowlisted read-only release/ref/GHCR/attestation evidence and the
   Actions run URL;
3. do not publish, delete, retag, replace, canonicalize, or add missing state;
4. leave the draft and any external objects unchanged;
5. open separately authorized incident/follow-up work;
6. normal Release Please remains blocked while the partial tuple is current
   authority; a new Conventional Commit alone is insufficient;
7. if product owners choose to continue releasing, complete the explicit
   quarantine-policy transition above, then use its read-only action-only mode
   to create a distinct future SemVer/source PR, never reuse or repair the
   partial tuple.

The runbook explicitly states that the old v1.1.0 object is not the terminal
partial to remediate; it is permanently no-touch.

Bootstrap tests must reject these exact stale constructs in workflows, scripts,
and release guidance:

```text
release-recovery.yml
workflow_dispatch release recovery
route=recover
route=deep-recover
route=resume
route=resume-registry
mutate-release-metadata.sh canonicalize
acquire-release-lease.sh
release-lease-v
generated placeholder publication
```

Do not globally reject the English word “recovery,” because database backup
and disaster-recovery documentation is valid. Scope static rejection to the
release controller/runbook and exact retired symbols.

`audit-default-branch-bootstrap.sh` must require the recovery workflow and
lease helper to be absent from both `master` and `dev`, require the future-only
workflow/helpers/docs to match when promotion is expected, and reject an active
default-branch recovery workflow. `verify-release-please-bootstrap.sh` must
require the new runbook sections and README/deployment links and fail against
the current stale document.

### 13. Local and hosted verification

Run focused shell/static verification:

```sh
bash -n scripts/*.sh
shellcheck --severity=warning scripts/*.sh
scripts/test-release-asset-inventory.sh
scripts/test-release-registry-state.sh
scripts/test-release-evidence.sh
scripts/test-immutable-policy-reader-credential.sh
scripts/test-immutable-release-policy.sh
scripts/test-immutable-release-proof.sh
scripts/test-release-mutation-policy.sh
scripts/test-release-mutation-revalidation.sh
scripts/test-release-current-action-freshness.sh
scripts/test-release-controller-queue.sh
scripts/test-release-post-publication-routing.sh
scripts/test-release-preaction-routing.sh
scripts/test-resolve-release-descriptor.sh
bash scripts/test-release-descriptor-schema.sh
scripts/test-release-metadata-mutation.sh
scripts/test-release-protected-snapshot.sh
scripts/test-ghcr-package-inventory.sh
scripts/test-ghcr-package-normalization.sh
scripts/test-oci-referrer-closure.sh
scripts/test-release-pr-fingerprint.sh
scripts/test-release-tag-ref.sh
scripts/verify-release-please-bootstrap.sh --auto-state
```

Hosted post-publication verification runs the implementation's normalized
wrapper, whose underlying pinned CLI contract is equivalent to:

```sh
gh release verify v1.2.0 --repo "$GITHUB_REPOSITORY"
gh release download v1.2.0 \
  --repo "$GITHUB_REPOSITORY" \
  --dir "$RUNNER_TEMP/v1.2.0-assets"
for asset in release-manifest.json image-index.json image-inspect.txt SHA256SUMS
do
  gh release verify-asset \
    v1.2.0 \
    "$RUNNER_TEMP/v1.2.0-assets/$asset" \
    --repo "$GITHUB_REPOSITORY"
done
```

The wrapper additionally fetches the same numeric Release API object and
requires `immutable=true`, expected tag/source, expected four asset IDs and
digests, and exact downloaded SHA-256 values before producing the canonical
hosted proof. It accepts an explicit expected repository, tag, numeric release
ID, and source SHA; resolves the tag back to that same numeric ID; invokes the
pinned CLI only with the explicit tag; and normalizes each successful result
with the expected release/attestation and asset identity. Tests stub the API
and CLI; they do not publish a release. They fail if the tag argument is
omitted, differs from `v1.2.0`, resolves to another numeric release, or if the
repository's latest release remains v1.0.1.

Run the default-branch audit with read-only credentials against a testable
fixture or the live repository only when its expected branch state matches the
rollout phase:

```sh
GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
GH_TOKEN="$GH_TOKEN" \
scripts/audit-default-branch-bootstrap.sh
```

Run backend regression checks even though no backend source change is planned:

```sh
./gradlew test
./gradlew clean build
```

If Docker/PostgreSQL prerequisites prevent the clean build, record the exact
environment blocker and require hosted Backend CI to run the equivalent
database-backed tests. Also run `git diff --check`, inspect `git diff --stat`,
and prove no Kotlin, resource, Flyway, Compose, API, Android, or deployment
behavior changed.

Hosted verification requires Backend CI and independent QA, code, and
compliance review.

### 14. Approved two-merge rollout

1. Open the release-infrastructure-only PR.
2. Refresh and commit the protected-history baseline, then compare it live
   immediately before merge.
3. Cancel and block any stale hosted run before it can mutate release state.
4. Merge infrastructure normally while dev authority remains 1.1.0.
5. Observe the serialized merge-triggered controller. It must run Release
   Please PR-only, must not create a tag/release, and must compare protected
   history equal before and after the action.
6. Obtain the separate human approval for the repository immutable-releases
   setting. An authorized repository owner/admin enables it; no workflow or
   production helper performs the setting mutation.
7. Provision/install `meet-backend-immutable-policy-reader` with only
   Administration read on this repository, add the exact App ID variable and
   protected-environment private-key secret, mint a repository-scoped token,
   and retain normalized proof that its effective Administration permission is
   exact `read` with no configurable write permission. Missing or broader
   authority blocks rollout.
8. Use only that short-lived token to read the live setting and require
   `enabled=true`; retain the sanitized approval/policy/credential-permission
   observation. Disabled or uncertain state blocks rollout.
9. Allow Release Please to refresh PR #41.
10. Verify PR #41 is open, targets `dev`, selects 1.2.0, and changes exactly
   `.release-please-manifest.json`, `CHANGELOG.md`, and `version.json`.
11. Mint a fresh read-only App token, re-prove its effective permission,
    re-fetch policy, recompare protected history, and merge PR #41 normally
    only while `enabled=true`.
12. Observe the single queued v1.2.0 controller through live policy admission,
    new-ID admission, gates, registry write, evidence, assets, adjacent
    immutable-policy/absent-ref guard, final PATCH, API `immutable=true`,
    immutable-release attestation/explicit-v1.2.0 asset verification, and tag
    peel.
13. Capture final read-only v1.2.0 evidence, compare the protected-history
    baseline again, and retain the canonical hosted
    `MEE2-48-v1.2.0-immutability-proof` artifact plus checksum.
14. For any natural third push overlapping run A and the pending PR #41 merge
    run B, record concurrency-group membership/status read-only and prove B was
    not replaced by run C. If no third push naturally overlaps, rely on the
    deterministic three-push fixture; do not manufacture an unrelated
    production commit.

## Acceptance criteria

- Workflow-scoped concurrency uses `queue: max` with
  `cancel-in-progress: false` and encloses pre-action, Release Please,
  post-action, gates, and publication. The three-push fixture proves a pending
  release-PR merge run survives a later push and still performs its own
  freshness calculation.
- `materialize` can name only the one positive release ID newly added between
  the current action invocation's canonical pre/post relevant-ID sets and
  matching all official action outputs.
- Stale empty drafts and overlapping-run observations cannot be adopted.
- A published current release never suppresses the Release Please action.
  Published v1.2.0 plus later `fix:`/`feat:` commits can create or refresh
  v1.2.1/v1.3.0 PRs; `completed` is emitted only after that action invocation
  when no release was created.
- Only `action`, fresh `materialize`, and published `completed` are reachable.
  Retired recovery/manual/resume/canonicalization/lease paths and files are
  absent.
- Every writer applies the shared blocked tuple/ref policy and exact live
  release/version/tag/source/phase guard immediately before writing.
- The infrastructure workflow contains no repository-settings writer. A
  separate recorded human approval authorizes a designated repository
  owner/admin to enable immutable releases after the infrastructure merge and
  before PR #41 merges. Without that approval and a live exact
  `enabled=true` read, rollout stops before any v1.2.0 materialization write.
- Hosted immutable-policy GETs use only the dedicated
  `meet-backend-immutable-policy-reader` installation token, scoped to this
  repository with effective Administration `read`, implicit Metadata read,
  and no configurable write permission. Missing/mis-scoped credentials fail
  closed; normalized installation-permission evidence proves the token cannot
  authorize policy PUT/DELETE, fixture tests receive 403 for both methods, and
  the helper rejects non-GET methods before network I/O. The separate
  owner/admin enablement credential never enters Actions.
- Live immutable-policy guards run at admission, before each external writer,
  and immediately adjacent to the final PATCH. Disabled, malformed,
  unauthorized, rate-limited, server-error, timeout, or otherwise uncertain
  states invoke neither the materialization writer nor the final PATCH; the
  enabled-direct and enabled-owner-enforced fixtures pass.
- Immediately before final publication both v1.1.0 and v1.2.0 refs are absent;
  any existing v1.2.0 ref fails. After publication v1.2.0 peels exactly to
  `SOURCE_SHA`, v1.1.0 remains absent, and no later release-state write occurs.
- The committed canonical snapshot and SHA-256 survive both merges. Exact
  byte comparison proves release `368531227`, its four asset bytes/metadata,
  its absent ref, protected GHCR aliases/digests/referrers/attestations, and
  immutable v1.0.1 are unchanged. The closed schema includes release
  `immutable`, all other listed stable release fields, and asset `label` and
  API `digest`; a one-field drift case exists for every included scalar field,
  while download counters and identity objects are proven excluded.
- Public v1.2.0 binds to PR #41's source, has one linux/amd64 digest, exactly
  `v1.2.0`, `1.2.0`, and `sha-SOURCE_SHA`, no `latest`, expected OCI
  labels/user/JAR/uploads behavior, provenance, SBOM, verified GitHub
  attestation, and exactly four valid evidence assets.
- The published release API object reports exact `immutable=true`; GitHub's
  automatic immutable-release attestation verifies the expected tag/source
  and all four release assets. Every per-asset CLI invocation explicitly names
  `v1.2.0`; omitted, wrong, or latest-resolved tags fail. The hosted
  `MEE2-48-v1.2.0-immutability-proof` artifact contains normalized policy,
  credential-permission, release, attestation, and per-asset evidence bound to
  the expected repository, tag, numeric release ID, attestation/bundle, asset
  name, API digest, and downloaded SHA-256, plus checksum evidence, with no
  secrets or raw API payloads.
- GitHub Release publication is the final release/ref/package mutation. The
  only later repository-owned control-plane write is the normalized hosted
  proof artifact. GitHub's server-side automatic immutable-release attestation
  is the expected consequence of publication and is consumed read-only; no
  workflow-created attestation follows PATCH. Any partial future draft is
  terminal and has no in-ticket repair path. It blocks Release Please until a
  separately authorized exact-tuple quarantine policy is implemented; that
  transition is action-only until authority advances and can never adopt or
  mutate the partial tuple.
- The publication runbook and linked README/deployment guidance describe only
  the future-only flow and terminal-partial procedure. Bootstrap/audit checks
  fail against stale legacy guidance.
- Shell/static tests, protected-snapshot fixtures, ref-race fixtures,
  immutable-policy disabled/uncertain/no-PATCH fixtures,
  least-privilege credential/PUT/DELETE-denial fixtures, explicit-tag asset
  verification fixtures, post-publication `immutable=true` and
  release-attestation fixtures, Gradle verification where practical, hosted
  Backend CI, and independent QA/code/compliance review pass.
- No Android API, DTO, admin security, TIMEPAD, idempotency, JPA, Flyway,
  database, Compose, VPS deployment, or secret-handling behavior changes.

## Rollback and non-goals

Before any v1.2.0 draft/ref/GHCR/attestation/asset write, the infrastructure PR
may be reverted normally after confirming protected-history equality. Once any
v1.2.0 external object exists, do not rerun, roll back to recovery code,
publish, delete, retag, overwrite, replace, canonicalize, or repair it. Follow
the terminal-partial procedure and seek separate authorization.

Enabling immutable releases is a separately approved repository-policy
prerequisite, not an implementation side effect. If that approval is withdrawn
before any v1.2.0 external write, abort rollout; an authorized owner/admin may
make any policy rollback only under a separate decision. After publication,
MEE2-48 neither disables the setting nor treats disabling it as release
rollback. The v1.2.0 immutability proof and automatic release attestation must
remain valid.

This ticket does not recover or publish v1.1.0, mutate v1.0.1, redesign SemVer,
deploy to the VPS, change Android/backend behavior, alter database schema/data,
or provide a general-purpose historical release repair tool.
