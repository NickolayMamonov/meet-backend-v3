## MEE2-39 implementation checklist

### Local proof

- [ ] Confirm the worktree starts at baseline `36ffd11ea4d35147f1df9c1cafa6a330300c1339`.
- [ ] Run Bash syntax checks over every touched shell script.
- [ ] Run `scripts/test-resolve-release-descriptor.sh`, including post-action
      success, exact tuple binding, positive numeric ID, cardinality, state,
      pagination, asset, ref, and empty-failure-stdout cases.
- [ ] Run unchanged `scripts/test-release-preaction-routing.sh`.
- [ ] Run `scripts/verify-release-please-bootstrap.sh --release-state v1.1.0`.
- [ ] Run every other touched release suite, `git diff --check`, clean-status
      review, and focused release-only scope review.
- [ ] Run relevant Gradle tests and `./gradlew clean build` when practical;
      record exact environmental blockers rather than claiming a pass.

### Hosted preflight and read-only QA

- [ ] Before hosted QA, recheck Docker/Compose, PostgreSQL/Testcontainers,
      GHCR access, and Actions/release permissions.
- [ ] Before merge, do not mutate hosted release, tag, asset, package, or
      Release Please PR state.
- [ ] After the reviewed merge, confirm the merge-triggered run finds draft
      `368531227` and uses normal recovery.
- [ ] Read-only verify exact source
      `36ffd11ea4d35147f1df9c1cafa6a330300c1339`, tag peeling, one digest,
      aliases `v1.1.0`, `1.1.0`, and
      `sha-36ffd11ea4d35147f1df9c1cafa6a330300c1339`, with no `latest`.
- [ ] Read-only verify exactly four assets/checksums, runtime/OCI identity,
      provenance, SBOM, attestation, and publish-last ordering.
- [ ] Compare the immutable v1.0.1 release, tag, assets, digest, aliases,
      provenance, SBOM, and attestation and confirm it is unchanged.

### Rollback and scope

- [ ] If the reviewed code fails verification, roll back code through a
      reviewed normal commit or revert only.
- [ ] Never manually repair, replace, retag, delete, or recreate the draft,
      tag, assets, GHCR state, or Release Please PR.
- [ ] Keep the final diff limited to release workflow/tooling, focused
      fixtures/bootstrap assertions, operations guidance, and this checklist;
      no application, API/Android, Timepad, database/Flyway, deployment, or
      hosted-state changes.
