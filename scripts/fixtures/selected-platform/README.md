# Selected-platform fixture

`image-index.json` is the public v1.6.0 release index. The original immutable
asset has **no terminal newline**; this checkout fixture has one for normal
text-file tooling.

Tests recover its exact 857 bytes with
`read_bytes().removesuffix(b"\n")` and assert SHA-256
`1f2c56da34fa905553739f79bf91647d0087ec72159efc40828ba91622033d4b`.
Production proof hashing must use the supplied raw bytes without normalization.

The index binds the unique linux/amd64 manifest `9178741b…` independently of
Docker's local reference aliases or the image store's Engine-ID semantics.
