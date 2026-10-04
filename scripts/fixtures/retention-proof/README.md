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

The private GHCR publication is currently blocked on package access
configuration. The backend repository is public, and publishing a linked
package with its `GITHUB_TOKEN` would inherit repository access. The operator
requires repository-permission inheritance disabled and explicit
Actions-only access before any package is created or image is published.
GitHub exposes those package settings only in the package settings UI, so they
cannot be prepared before a first publication through the authorized
repository-token path. The toolchain lock remains incomplete and disabled;
ordinary CI's exact-digest pull/provenance check is deferred until the package
exists under the approved access model.

The toolchain lock and registration remain disabled. A local Docker Desktop
build is preparation evidence only, not hosted Ubuntu Engine evidence. The
protected environment is master-only, reviewer protected, and is not
permission to dispatch or approve a proof.

Publishing this tools-only image does not authorize source or fixture execution,
or provider/VPS/backup/restore/prune/deploy/catalog operations. Those remain
separately gated.
