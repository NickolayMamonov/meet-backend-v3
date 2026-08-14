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
- [ ] Re-run hosted Backend CI/ShellCheck and independent QA; local focused
      suites, protected snapshot/checksum, Bash syntax, diff, Gradle test, and
      clean build are green. Windows Git Bash defers the credential fixture's
      POSIX-only multiline/negative branches to hosted Linux.
- [ ] Commit and push the approved rework, add the Implementation result
      comment, and complete MEE2-48 with exact evidence.
