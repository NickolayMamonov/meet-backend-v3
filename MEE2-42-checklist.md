# MEE2-42 release visibility checklist

- [x] Implement supplied-release admission for mutation revalidation and resume verification.
- [x] Keep metadata mutation in the sole helper, with one PATCH and direct response validation.
- [x] Split materialize and deep-recovery resolver visibility from GITHUB_TOKEN evidence and mutations.
- [x] Bind exact numeric, digest-checked, same-job release snapshots without artifacting.
- [x] Keep manual recovery unchanged and PAT-free.
- [x] Preserve canonical-empty materialize, complete-only deep recovery, lease, assets, aliases,
  attestations, and publish-last contracts.
- [x] Run focused fixtures and Gradle verification; ShellCheck is unavailable in this environment.
- [ ] Require ordinary hosted CI.
- [ ] Inspect the reviewed merge-triggered run and hosted release/registry evidence read-only.
