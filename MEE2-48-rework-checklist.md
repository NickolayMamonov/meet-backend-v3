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
- [ ] Re-run focused release suites, hosted/read-only checks when credentials
      are provisioned, protected snapshot/checksum checks, Bash syntax, diff
      checks, Gradle test/build, and ShellCheck when available.
- [ ] Commit and push the approved rework, add the Implementation result
      comment, and complete MEE2-48 with exact evidence.
