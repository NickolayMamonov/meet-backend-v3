# Retention proof toolchain (inactive)

The proof image is based on the immutable Ubuntu 24.04 amd64 manifest
`ubuntu:24.04@sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b`.
Its package inputs come from the authenticated Ubuntu archive snapshot
`20260918T000000Z`; the lock records every installed package version and the
SHA-256 from the snapshot's signed package metadata.

The Dockerfile installs only Ubuntu packages required by the fixture and its
runtime. It does not copy or execute the retention fixture or candidate source.
The source is exported separately and mounted read-only by the trusted
supervisor. No GitHub token, provider credential, or host secret enters the
image or proof container.

The approved package identity is the public
`ghcr.io/nickolaymamonov/retention-proof-tools`; consumers use only its
immutable digest. Public visibility is an intentional disclosure: once made
public, it cannot be changed back to private, and deleting the package cannot
retract copies already downloaded. An authorized administrator must confirm
the package identity and public-disclosure decision in GitHub's package
settings UI and verify the resulting Public state. Repository linkage or
inherited access does not prove visibility. If authorized UI access is
unavailable, publication remains unaccepted until an administrator completes
that manual step; no settings-API workaround is permitted.

The publication workflow is manual-only and separate from the protected proof.
It publishes only the tools image, records its returned immutable digest and
signed provenance, and never runs the image entrypoint or fixture. CI verifies
prepared images with a fresh anonymous digest pull, isolated from any
attestation-verification token. Both the toolchain lock and proof registration
remain disabled. Publication does not authorize source or fixture execution,
or provider/VPS/backup/restore/prune/deploy/catalog/live operations.

The toolchain lock and registration remain disabled. A local Docker Desktop
build is preparation evidence only, not hosted Ubuntu Engine evidence. The
protected environment is master-only and reviewer-protected; it is not
permission to dispatch or approve a proof.
