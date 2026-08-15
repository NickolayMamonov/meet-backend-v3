## MEE2-48 rework checklist

- [x] Fix GitHub App JWT compact serialization and exact credential permission
      allowlist; add three-segment/live-fixture coverage.
- [x] Make protected v1.1.0 boundary future-only and add the Release Please
      PR-only `skip-github-release` guard.
- [x] Wire protected-history snapshot capture, checksum verification, and
      hosted baseline enforcement; expand schema for refs, GHCR closure, and
      attestations.
- [x] Add per-asset live numeric-release, deny-tuple, exact-phase, and prefix
      revalidation immediately before each upload.
- [x] Enforce current-action freshness at draft materialization and preserve
      exact publish PATCH ordering/payload.
- [x] Complete release-manifest fields and require strict proof verification
      results; pin upload-artifact.
- [x] Restore the live candidate GHCR preflight and exact three-alias
      convergence/no-latest guards; bind consistency verification to the
      generated image and preserve the deployment evidence contract.
- [x] Fix hosted ShellCheck findings, tag-based asset upload, descriptor
      schema emission, attestations:read permissions, and protected snapshot
      alias/attestation normalization.
- [x] Expand credential/JWT and protected-snapshot drift fixtures, including
      implicit Metadata handling and the complete included-field matrix.
- [x] Re-run hosted Backend CI/ShellCheck and the local verification gates.
      Hosted run 31856406191 is green across all five jobs; focused release,
      credential, immutable-policy, protected-snapshot, routing, asset,
      syntax, and diff checks passed; Gradle test and clean build passed at
      6e938c2 and hosted Gradle passed again for final 1e125e0. Windows Git
      Bash defers the credential fixture's POSIX-only multiline/negative
      branches to hosted Linux. Independent QA was attempted for final
      1e125e0, but Kent reported that the QA session had no active runtime and
      could not produce a new verdict; the only available QA verdict is the
      stale FAIL for superseded 2641071.
- [ ] Obtain an independent QA verdict for 1e125e0 when the Kent QA runtime is
      available; current status is environment-blocked, not a claimed pass.
- [x] Commit and push the approved rework: final SHA 1e125e0 on MEE2-48 is
      pushed to PR #49, and the Implementation result comment is recorded.
      Task completion is being performed with the independent QA limitation
      explicitly recorded above.
