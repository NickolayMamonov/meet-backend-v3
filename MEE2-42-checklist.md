# MEE2-42 release visibility checklist

- [x] Implement supplied-release admission for mutation revalidation and resume verification.
- [x] Keep metadata mutation in the sole helper, with one PATCH and direct response validation.
- [x] Split materialize and deep-recovery resolver visibility from GITHUB_TOKEN evidence and mutations.
- [x] Bind exact numeric, digest-checked, same-job release snapshots without artifacting.
- [x] Keep manual recovery unchanged and PAT-free.
- [x] Preserve canonical-empty materialize, complete-only deep recovery, lease, assets, aliases,
  attestations, and publish-last contracts.
- [x] Run focused fixtures and Gradle verification; ShellCheck is unavailable in this environment.
- [x] Require ordinary hosted CI; PR checks passed including hosted ShellCheck.
- [ ] Inspect the reviewed merge-triggered run and hosted release/registry evidence read-only.

## Rework findings

- [x] Add fresh PAT admission after the materialize lease and immediately before upload.
- [x] Add fresh PAT admission immediately before canonicalize and each final publish mutation.
- [x] Verify `RELEASE_SNAPSHOT_SHA` at every deep-recovery snapshot consumer.
- [x] Add supplied resume, stale-state, mutation-between-boundaries, and ordering coverage.
- [x] Tighten bootstrap assertions to exact named PAT capability blocks.
- [x] Re-run local focused fixtures, shell syntax, bootstrap, Gradle test/build, and unchanged manual recovery checks.
- [x] Re-run local and hosted verification; update PR and implementation result comment.

## Final review findings

- [x] Add and verify the deep-recovery observed-state snapshot digest check.
- [x] Make the PAT upload admission directly adjacent to the materialize upload.
- [x] Ensure response-drift fixtures return a non-empty PATCH response.
- [x] Correct documentation to describe direct PATCH-response validation.
