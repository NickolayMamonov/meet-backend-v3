# MEE2-61 Protected Attestation Source — Implementation Record

This record documents the implementation boundary for the approved
MEE2-61 plan. It is intentionally limited to protected-image admission and
does not authorize a promotion dispatch, release mutation, VPS mutation, or
rerun of run `32663874992`.

## Boundary

- `scripts/resolve-image-attestation-authority.sh` is the network-free policy
  resolver. It keeps release source, certificate source, and signer commits
  distinct and selects storage by the exact historical tuple.
- `scripts/verify-image-attestation-authority.sh` is the shared cryptographic
  verifier. It is the only new protected-image module that invokes
  `gh attestation verify`; it enforces the storage union, exact subject,
  certificate, signer workflow, issuer, predicate, and atomic v2 evidence
  publication.
- `scripts/verify-oci-referrer-closure.sh` can emit one digest/size-checked
  Sigstore bundle for registry-backed authorities.
- Reader, admission, protected-state capture/layout, promotion, and
  test-VPS deployment consume the boundary before writers or host trust.

## Historical storage policy

- v1.0.1 (`367640510`) remains registry-bundle backed.
- v1.2.0 (`371012814`) remains immutable-release/API-workflow-artifact backed,
  including the exact four release assets and pinned workflow bundle digest.
  It does not claim a GHCR Sigstore bundle.
- The guarded candidate remains registry-bundle backed and derives its
  authority from the already authorized source and one digest-checked OCI
  index.

## Verification and rollout controls

Focused resolver/verifier and consumer fixtures are run locally before the
complete verification set. Backend CI registers the authority, verifier,
reader, protected-state, layout, admission, promotion-ordering,
script-execution, and frozen protected-snapshot fixtures. The complete proof
still requires exact-head Backend CI, independent QA/code/compliance/release
review, and an approved read-only twice-live capture. The promotion workflow
registration check remains byte-based and must pass before any dispatch.

Verification placeholders:

- [x] On August 25, 2026, the exact narrowed local suite passed: Bash syntax;
      promotion workflow; authority resolver; authority verifier with exact `gh`
      argv; OCI closure full matrix; image readers; image admission;
      protected-state; layout; and test-VPS workflow.
- [x] The canonical plan SHA-256 is
      `9bbe036ab2a71b64966bd74c2a885f2e7e56bb315b014cba078679f265bf49f9`.
- [x] Local `actionlint` and `shellcheck` are unavailable; they remain
      hosted-CI obligations.
- [x] The no-touch/no-rerun record for run `32663874992` is preserved; no
      dispatch, deploy, publication, release mutation, or VPS mutation occurred.

Pending verification and rollout controls:

- [ ] Exact-head hosted CI.
- [ ] Independent QA, code, compliance, release, and autoreview.
- [ ] Approved twice-byte-identical live read-only capture.
- [ ] Any later operator-authorized dispatch.
No raw attestation result, certificate, token, bundle, signed URL, private
configuration, or live capture is committed by this record.
