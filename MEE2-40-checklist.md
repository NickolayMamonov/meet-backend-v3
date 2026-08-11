# MEE2-40 implementation checklist

- [x] Inspect the existing resolver, workflow, fixtures, bootstrap verifier, and release operations docs.
- [x] Add resolver-owned stable admission fingerprint and typed route contracts.
- [x] Route canonical empty drafts to the single materialization pipeline; keep complete recovery isolated.
- [x] Bind fresh/continuation entry proofs and enforce the exact empty-to-complete in-flight transition.
- [x] Enforce generated-placeholder ref absence before/after canonicalization and publish-only tag creation.
- [x] Extend resolver, pre-action, bootstrap, and focused fixture coverage.
- [x] Update release operations documentation with the new contracts and quarantine behavior.
- [x] Run relevant shell, resolver, release, bootstrap, and Gradle verification.
- [ ] Audit scope, review diff, commit, push branch, create PR targeting `dev`.
- [ ] Add the `Implementation result` task comment and complete MEE2-40.
