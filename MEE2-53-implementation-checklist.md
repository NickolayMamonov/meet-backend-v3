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
