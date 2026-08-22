# MEE2-53 implementation checklist

- [x] Confirm exact current `origin/dev` and preserve MEE2-49 runtime tooling.
- [x] Fix extensionless demo asset checkout identity and add fresh-checkout fixture.
- [x] Add source, admission, protected-state, bootstrap-proof, evidence helpers and fixtures.
- [x] Extend locked deployment with optional closed-beta safety hooks and host-state verifier.
- [x] Add the guarded dev promotion workflow and registration/static policy fixtures.
- [x] Wire CI and operator documentation without changing the published-release path.
- [x] Run focused fixtures, shell syntax/lint, Gradle/Docker checks where available.
- [x] Audit scope, commit, push branch, create PR targeting `dev`, and comment on MEE2-53.

## Approved rework findings

- [x] Serialize GHCR/VPS writers; require explicit same-image redeploy opt-in.
- [x] Fail closed on registry inspection errors and normalize referrer artifact types.
- [x] Capture protected package/release/subject/referrer state before and after admission.
- [x] Publish and verify the same OCI layout that was admitted; add full phase retrieval.
- [x] Wire sanitized success/incident evidence, pinned artifacts, and success-only retention.
- [x] Add exact dispatch/environment/registration proof and focused hosted CI fixtures.
- [ ] Verify origin/master registration, provision the closed-beta Environment, and run authorized live/Yandex re-verification.

## Approved P0 remediation

- [x] Revalidate source authority immediately before every mutating boundary and correct `masterRegistrationSha`.
- [x] Publish the exact admitted OCI layout once, with source-bound signed-attestation/subject validation and fail-closed remote reads.
- [x] Capture canonical protected attestation records, OCI descriptor sizes, artifact types, predicate bindings, and post-write closure.
- [x] Serialize GHCR and test-VPS writers; enforce same-digest opt-in and mandatory distinct-image rollback.
- [x] Keep final probes inside the remote deployment lock/rollback trap and validate fixed phase files before retrieval.
- [x] Verify all 13 frozen demo assets and bind their evidence to the closed success schema.
- [x] Enforce sanitized incident selection, upload-gated retention, direct privileged-job guards, and no-live-mutation policy.
- [x] Use the shared `backend-release-${{ github.repository }}` writer lane for the complete promotion.
- [x] Exclude protected root/platform/referrer subjects before copying a first-time OCI layout.
- [x] Create and verify a pinned signed GitHub OCI attestation for first-time aliases.
- [x] Require the explicit exact-SHA Backend CI job/check allowlist and upload its proof.
- [x] Produce and reuse predecessor, rollback, candidate, and final bootstrap proofs.
- [x] Validate remote phase files against a closed schema and expected image identity before retrieval.
- [x] Preserve blank `ADMIN_API_KEY` disabled behavior without putting the key in process arguments.
- [ ] Rerun exact-head hosted CI and obtain independent QA, code, and compliance PASS evidence.

## Final approved defect remediation

- [x] Validate environment deployment policies from the fetched JSON and retain plural branch membership checks.
- [x] Verify the real public v1.2.0 bootstrap-control introduction SHA and strict legacy predecessor ancestry.
- [x] Bind predecessor/candidate/final evidence identity and bootstrap mode to canonical bootstrap proofs.
- [x] Reuse the canonical predecessor proof for rollback without rebuilding or substituting it.
- [x] Retrieve only fixed remote phase paths and compare downloaded SHA-256 before local evidence validation.
- [x] Add legacy-not-applicable, declared-false, proof-mismatch, and rollback-reuse fixtures.
- [ ] Run exact-head hosted Backend CI and repeat independent QA/compliance review.

## Approved runtime truthfulness remediation

- [x] Add a secret-free aggregate zero-state probe bound to exact image/runtime identity and run it from every locked deployment safety phase.
- [x] Derive closed phase and success evidence from observed probe output; remove workflow hard-coded runtime/probe assertions.
- [x] Add populated and unknown zero-state evidence regression fixtures.
- [x] Rerun focused shell/fixture checks and Gradle clean build for the runtime truthfulness remediation.
- [ ] Rerun exact-head hosted CI, independent QA/code/compliance review, and the required read-only/live gate evidence.

## Approved executable-contract remediation

- [x] Restore reviewed 100755 mode for every tracked shell script used by workflows, callbacks, fixtures, or staged remote tooling.
- [x] Add a deterministic audit for workflow-direct scripts, input-command callbacks, staged remote executables, and incident upload wiring.
- [x] Add an authorization-failure fixture proving no mutation and successful sanitized incident generation/upload selection.
- [ ] Rerun exact-head hosted CI and obtain independent QA/code/compliance PASS evidence.
