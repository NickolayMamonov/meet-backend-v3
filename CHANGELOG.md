# Changelog

## [1.2.0](https://github.com/NickolayMamonov/meet-backend-v3/compare/v1.1.0...v1.2.0) (2026-08-15)


### Features

* **feed:** hide completed meetings ([#39](https://github.com/NickolayMamonov/meet-backend-v3/issues/39)) ([447b016](https://github.com/NickolayMamonov/meet-backend-v3/commit/447b0163e2e5d2d36e690cdf4fdaac8e0eeed875))
* harden future backend release publishing ([2adf2ad](https://github.com/NickolayMamonov/meet-backend-v3/commit/2adf2ade6035737ccc737ee04cbd88b258aa1772))


### Fixes

* **ci:** invoke release fixtures through bash ([da3d8c8](https://github.com/NickolayMamonov/meet-backend-v3/commit/da3d8c8fa8f280854bbcea4e965fe8018fd79b12))
* **ops:** bind SPKI drill to running backend ([ff707d3](https://github.com/NickolayMamonov/meet-backend-v3/commit/ff707d38f85bc0e1abfc09150310ad995f3578a3))
* **ops:** close SPKI drill gate blockers ([a85b5e4](https://github.com/NickolayMamonov/meet-backend-v3/commit/a85b5e4bddff54ab3fc291612a482499ea7f1210))
* **ops:** close SPKI drill review gaps ([0e89ec6](https://github.com/NickolayMamonov/meet-backend-v3/commit/0e89ec6fa7b7d50c430e9a64efe46f0050dfcad7))
* **release:** align image consistency identity ([f7c17b9](https://github.com/NickolayMamonov/meet-backend-v3/commit/f7c17b94dca04333d8e04a5483d989466f729411))
* **release:** align resumed image evidence ([4af9734](https://github.com/NickolayMamonov/meet-backend-v3/commit/4af973437cdbb7c3a7bba457d85e2117a6bc3871))
* **release:** allow published predecessor ([#40](https://github.com/NickolayMamonov/meet-backend-v3/issues/40)) ([0c2e418](https://github.com/NickolayMamonov/meet-backend-v3/commit/0c2e41850a15f55080159b6f37444b049519fe88))
* **release:** avoid shellcheck numeric redirection ([0a6cd5c](https://github.com/NickolayMamonov/meet-backend-v3/commit/0a6cd5c6d42a24a12653f6f77c3e2b383f16e894))
* **release:** bind draft visibility snapshots ([#44](https://github.com/NickolayMamonov/meet-backend-v3/issues/44)) ([457e936](https://github.com/NickolayMamonov/meet-backend-v3/commit/457e936a40a7e2940a25261ca8e6b0f247f25cc7))
* **release:** canonicalize protected body hash ([15bb91a](https://github.com/NickolayMamonov/meet-backend-v3/commit/15bb91a813a69342402f124f3f8733cca0c8726e))
* **release:** canonicalize protected body hash ([0a5a2c5](https://github.com/NickolayMamonov/meet-backend-v3/commit/0a5a2c5c30a0a53077efba8ed377d6d9eb066002))
* **release:** capture live protected history ([6cad4ea](https://github.com/NickolayMamonov/meet-backend-v3/commit/6cad4eaa76fa0f4541f4403203a131e89d51bdd6))
* **release:** capture live protected history ([9f182ea](https://github.com/NickolayMamonov/meet-backend-v3/commit/9f182ea4269977936baf9cbca72202468d634a99))
* **release:** close final publication gates ([61b628b](https://github.com/NickolayMamonov/meet-backend-v3/commit/61b628b18761f28c822d64d978cec3edb927ff11))
* **release:** close prepublication mutation races ([94d50b1](https://github.com/NickolayMamonov/meet-backend-v3/commit/94d50b1ad50e24828122c5ecf2b0022cce6ffbca))
* **release:** close protected v1.2 publication blockers ([2e7ead8](https://github.com/NickolayMamonov/meet-backend-v3/commit/2e7ead84b165f613b2bc3d8eebd3c82f96ea99f5))
* **release:** close publication rework gates ([47f7f4e](https://github.com/NickolayMamonov/meet-backend-v3/commit/47f7f4e8886286c15a5b8a503024845d10902968))
* **release:** correct Release Please bootstrap ([#26](https://github.com/NickolayMamonov/meet-backend-v3/issues/26)) ([85c4c3c](https://github.com/NickolayMamonov/meet-backend-v3/commit/85c4c3c8ad9e305f513eba088cb1f161a029e713))
* **release:** emit prerelease descriptor state ([8598a31](https://github.com/NickolayMamonov/meet-backend-v3/commit/8598a31e60d0bae784bebf43404f3b1e91d603e1))
* **release:** finish verified draft recovery ([#35](https://github.com/NickolayMamonov/meet-backend-v3/issues/35)) ([fe25222](https://github.com/NickolayMamonov/meet-backend-v3/commit/fe252227e5248af68e63448b7c970d7fe575dfd2))
* **release:** harden recovery mutation boundaries ([aeb095a](https://github.com/NickolayMamonov/meet-backend-v3/commit/aeb095a24400422c3529208997d9ff1e4c5e3f3f))
* **release:** inspect resumed image by digest ([#33](https://github.com/NickolayMamonov/meet-backend-v3/issues/33)) ([4bff290](https://github.com/NickolayMamonov/meet-backend-v3/commit/4bff2902511e8e739d7604bf120b121429e60aeb))
* **release:** keep source gates tag-independent ([4413d19](https://github.com/NickolayMamonov/meet-backend-v3/commit/4413d1971f0f855131ef0004961a15efe013825a))
* **release:** make resume fixture executable ([d977e98](https://github.com/NickolayMamonov/meet-backend-v3/commit/d977e98bdbc645eaea73a27c35b331e80cab17ec))
* **release:** make resume verifier executable ([90f7270](https://github.com/NickolayMamonov/meet-backend-v3/commit/90f7270caa3cbca05775ee5cd46d1c8645ed2cc8))
* **release:** mark asset uploader executable ([d1b5ecd](https://github.com/NickolayMamonov/meet-backend-v3/commit/d1b5ecd4111aeb95e52fe7fb0e14a1523ccf2afd))
* **release:** mark release guard scripts executable ([dd164c2](https://github.com/NickolayMamonov/meet-backend-v3/commit/dd164c2441437706aa42302f83cff4804d2c094f))
* **release:** mark upload fixture executable ([79fadb9](https://github.com/NickolayMamonov/meet-backend-v3/commit/79fadb99a1f450820ea4f1d75f08e276b81f908b))
* **release:** normalize empty action result ([d38dd06](https://github.com/NickolayMamonov/meet-backend-v3/commit/d38dd06f8c24ad1cd354f55b634ea39f6cd6e86c))
* **release:** normalize empty action result ([bded4d5](https://github.com/NickolayMamonov/meet-backend-v3/commit/bded4d57ac8c8b8a2bfe9b9cb693875d47ce9a1b))
* **release:** normalize publication fingerprints ([#34](https://github.com/NickolayMamonov/meet-backend-v3/issues/34)) ([d23c421](https://github.com/NickolayMamonov/meet-backend-v3/commit/d23c4215c78ee5e523a067de6b35490dbb81e6e4))
* **release:** recover empty canonical draft ([#43](https://github.com/NickolayMamonov/meet-backend-v3/issues/43)) ([88dd7f5](https://github.com/NickolayMamonov/meet-backend-v3/commit/88dd7f5280bc6dc8271d1ce616982c398adeaad9))
* **release:** recover verified draft releases ([5ef43c6](https://github.com/NickolayMamonov/meet-backend-v3/commit/5ef43c6435cbba5e1b64b2a8eba7cb8281244ad0))
* **release:** recover verified draft releases ([0c09eb5](https://github.com/NickolayMamonov/meet-backend-v3/commit/0c09eb5d616cdeac9c4021dcfbcb261ade301a83))
* **release:** remove stale snapshot variable ([0b704a7](https://github.com/NickolayMamonov/meet-backend-v3/commit/0b704a71a80128d89a69201b8573b4bd0ab578c6))
* **release:** repair quarantined backend release ([#36](https://github.com/NickolayMamonov/meet-backend-v3/issues/36)) ([c6e522c](https://github.com/NickolayMamonov/meet-backend-v3/commit/c6e522ca8a71077604df132f61a5f75547859d77))
* **release:** require release action authority ([#37](https://github.com/NickolayMamonov/meet-backend-v3/issues/37)) ([9d51c94](https://github.com/NickolayMamonov/meet-backend-v3/commit/9d51c943aec10ede74459a62dff8864bf0058efc))
* **release:** resolve created draft identity ([#42](https://github.com/NickolayMamonov/meet-backend-v3/issues/42)) ([e5aa812](https://github.com/NickolayMamonov/meet-backend-v3/commit/e5aa812a48e1af3f8abecfb6c0cdd3179f834350))
* **release:** resolve GHCR actor without user API ([aee7944](https://github.com/NickolayMamonov/meet-backend-v3/commit/aee7944e089523dda886c4eb67279a030ecea2f1))
* **release:** resolve GHCR actor without user API ([d0697a4](https://github.com/NickolayMamonov/meet-backend-v3/commit/d0697a4c9c4003536f9ee5cafb2c01c18060511f))
* **release:** resume evidence after registry writes ([13f8cba](https://github.com/NickolayMamonov/meet-backend-v3/commit/13f8cba8d5f2667e1b3de7bb5fc72b65dde48696))
* **release:** resume interrupted immutable publication ([8832574](https://github.com/NickolayMamonov/meet-backend-v3/commit/8832574979a63cc82c5ab338cd9ecdbb5f86f2fa))
* **release:** route read-only helpers through GitHub token ([f6a3750](https://github.com/NickolayMamonov/meet-backend-v3/commit/f6a37505a1dbe5cc942f12abda1fe0d4340bcfda))
* **release:** satisfy shellcheck fixture runner ([0bb4bd3](https://github.com/NickolayMamonov/meet-backend-v3/commit/0bb4bd3089caf651cc7c438b4af16216a78332f3))
* **release:** unify active descriptors ([#46](https://github.com/NickolayMamonov/meet-backend-v3/issues/46)) ([91e7f68](https://github.com/NickolayMamonov/meet-backend-v3/commit/91e7f688deabb6a54f8f141ae914574c01b1be1a))
* **release:** unify release asset fingerprint ([#38](https://github.com/NickolayMamonov/meet-backend-v3/issues/38)) ([91f4c70](https://github.com/NickolayMamonov/meet-backend-v3/commit/91f4c70a0620e96b75732bd931100baea85a8d31))
* **release:** use job token for protected reads ([8057e85](https://github.com/NickolayMamonov/meet-backend-v3/commit/8057e85711cf398beb2197d88dbc70d8f22fa169))

## [1.1.0](https://github.com/NickolayMamonov/meet-backend-v3/compare/v1.0.1...v1.1.0) (2026-08-11)


### Features

* **feed:** hide completed meetings ([#39](https://github.com/NickolayMamonov/meet-backend-v3/issues/39)) ([447b016](https://github.com/NickolayMamonov/meet-backend-v3/commit/447b0163e2e5d2d36e690cdf4fdaac8e0eeed875))


### Fixes

* **release:** align image consistency identity ([f7c17b9](https://github.com/NickolayMamonov/meet-backend-v3/commit/f7c17b94dca04333d8e04a5483d989466f729411))
* **release:** align resumed image evidence ([4af9734](https://github.com/NickolayMamonov/meet-backend-v3/commit/4af973437cdbb7c3a7bba457d85e2117a6bc3871))
* **release:** allow published predecessor ([#40](https://github.com/NickolayMamonov/meet-backend-v3/issues/40)) ([0c2e418](https://github.com/NickolayMamonov/meet-backend-v3/commit/0c2e41850a15f55080159b6f37444b049519fe88))
* **release:** avoid shellcheck numeric redirection ([0a6cd5c](https://github.com/NickolayMamonov/meet-backend-v3/commit/0a6cd5c6d42a24a12653f6f77c3e2b383f16e894))
* **release:** close prepublication mutation races ([94d50b1](https://github.com/NickolayMamonov/meet-backend-v3/commit/94d50b1ad50e24828122c5ecf2b0022cce6ffbca))
* **release:** finish verified draft recovery ([#35](https://github.com/NickolayMamonov/meet-backend-v3/issues/35)) ([fe25222](https://github.com/NickolayMamonov/meet-backend-v3/commit/fe252227e5248af68e63448b7c970d7fe575dfd2))
* **release:** harden recovery mutation boundaries ([aeb095a](https://github.com/NickolayMamonov/meet-backend-v3/commit/aeb095a24400422c3529208997d9ff1e4c5e3f3f))
* **release:** inspect resumed image by digest ([#33](https://github.com/NickolayMamonov/meet-backend-v3/issues/33)) ([4bff290](https://github.com/NickolayMamonov/meet-backend-v3/commit/4bff2902511e8e739d7604bf120b121429e60aeb))
* **release:** keep source gates tag-independent ([4413d19](https://github.com/NickolayMamonov/meet-backend-v3/commit/4413d1971f0f855131ef0004961a15efe013825a))
* **release:** make resume fixture executable ([d977e98](https://github.com/NickolayMamonov/meet-backend-v3/commit/d977e98bdbc645eaea73a27c35b331e80cab17ec))
* **release:** make resume verifier executable ([90f7270](https://github.com/NickolayMamonov/meet-backend-v3/commit/90f7270caa3cbca05775ee5cd46d1c8645ed2cc8))
* **release:** mark release guard scripts executable ([dd164c2](https://github.com/NickolayMamonov/meet-backend-v3/commit/dd164c2441437706aa42302f83cff4804d2c094f))
* **release:** normalize publication fingerprints ([#34](https://github.com/NickolayMamonov/meet-backend-v3/issues/34)) ([d23c421](https://github.com/NickolayMamonov/meet-backend-v3/commit/d23c4215c78ee5e523a067de6b35490dbb81e6e4))
* **release:** recover verified draft releases ([5ef43c6](https://github.com/NickolayMamonov/meet-backend-v3/commit/5ef43c6435cbba5e1b64b2a8eba7cb8281244ad0))
* **release:** recover verified draft releases ([0c09eb5](https://github.com/NickolayMamonov/meet-backend-v3/commit/0c09eb5d616cdeac9c4021dcfbcb261ade301a83))
* **release:** repair quarantined backend release ([#36](https://github.com/NickolayMamonov/meet-backend-v3/issues/36)) ([c6e522c](https://github.com/NickolayMamonov/meet-backend-v3/commit/c6e522ca8a71077604df132f61a5f75547859d77))
* **release:** require release action authority ([#37](https://github.com/NickolayMamonov/meet-backend-v3/issues/37)) ([9d51c94](https://github.com/NickolayMamonov/meet-backend-v3/commit/9d51c943aec10ede74459a62dff8864bf0058efc))
* **release:** resume evidence after registry writes ([13f8cba](https://github.com/NickolayMamonov/meet-backend-v3/commit/13f8cba8d5f2667e1b3de7bb5fc72b65dde48696))
* **release:** resume interrupted immutable publication ([8832574](https://github.com/NickolayMamonov/meet-backend-v3/commit/8832574979a63cc82c5ab338cd9ecdbb5f86f2fa))
* **release:** satisfy shellcheck fixture runner ([0bb4bd3](https://github.com/NickolayMamonov/meet-backend-v3/commit/0bb4bd3089caf651cc7c438b4af16216a78332f3))
* **release:** unify release asset fingerprint ([#38](https://github.com/NickolayMamonov/meet-backend-v3/issues/38)) ([91f4c70](https://github.com/NickolayMamonov/meet-backend-v3/commit/91f4c70a0620e96b75732bd931100baea85a8d31))

## [1.0.1](https://github.com/NickolayMamonov/meet-backend-v3/compare/v1.0.0...v1.0.1) (2026-08-10)


### Fixes

* **release:** correct Release Please bootstrap ([#26](https://github.com/NickolayMamonov/meet-backend-v3/issues/26)) ([85c4c3c](https://github.com/NickolayMamonov/meet-backend-v3/commit/85c4c3c8ad9e305f513eba088cb1f161a029e713))

## Changelog

All notable backend releases are recorded here by Release Please.
