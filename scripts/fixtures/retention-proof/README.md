# Retention proof image (disabled)

This directory is deliberately not buildable as checked in. `UBUNTU_BASE_IMAGE`
has no default; a reviewed immutable Ubuntu 24.04 amd64 digest must be supplied
only during separately approved preparation. The package snapshot, exact
package/dependency closure, checksums, Dockerfile digest, Engine version/API
and mount layout, and final image digest must then be committed to
`toolchain.lock.json` with provenance.

Do not build, pull, prepare, or execute an image from this source-only change.
The lock is `enabled: false`; the trusted launcher rejects it. The proof image
contains tools only. Exact reviewed source is exported separately and mounted
read-only, and the token remains host-side.
