# Changelog

## [1.4.0](https://github.com/NickolayMamonov/meet-backend-v3/compare/v1.3.0...v1.4.0) (2026-09-05)


### Features

* prove beta backup restore ([47ab2ef](https://github.com/NickolayMamonov/meet-backend-v3/commit/47ab2efbe26dfb2e77040e2b7ff605a174219a4d))
* prove beta backup restore ([66f2882](https://github.com/NickolayMamonov/meet-backend-v3/commit/66f2882fbaf076a9ad9d1fdc854b5bff6c772eb0))


### Fixes

* bind restore capacity and authority contracts ([1df09d0](https://github.com/NickolayMamonov/meet-backend-v3/commit/1df09d0e8787bf68d29b29595c704fdac7925a03))
* close beta recovery rework blockers ([f7dd646](https://github.com/NickolayMamonov/meet-backend-v3/commit/f7dd646f0b2813ad1cd2a7a67fa4519d3c0abb3d))
* close beta recovery rework blockers ([b763d01](https://github.com/NickolayMamonov/meet-backend-v3/commit/b763d01dc13044bb33e145f7b27797de986a9b25))
* close beta recovery rework gaps ([64dbbd1](https://github.com/NickolayMamonov/meet-backend-v3/commit/64dbbd16995a89f2baf245f8b567b955d656a855))
* close beta recovery rework gaps ([589190d](https://github.com/NickolayMamonov/meet-backend-v3/commit/589190d44be03fd81e2a5ecb4d7fa598523dbe99))
* close beta recovery security gaps ([950a35b](https://github.com/NickolayMamonov/meet-backend-v3/commit/950a35b30d3fe1c61f59c900acdacd853f7af380))
* close recovery journal and residue gaps ([a40f26a](https://github.com/NickolayMamonov/meet-backend-v3/commit/a40f26a8eb13743847bc7c83299f477edc1c9264))
* close release publication races ([65b4f4f](https://github.com/NickolayMamonov/meet-backend-v3/commit/65b4f4f31623cf126544663e9800fa8fb7a57ac0))
* gate recovery evidence on final cleanup ([17e7cf1](https://github.com/NickolayMamonov/meet-backend-v3/commit/17e7cf1921a84557fb10e6a31c8f4451472268d3))
* harden beta backup restore proof ([8fd02e3](https://github.com/NickolayMamonov/meet-backend-v3/commit/8fd02e399ba1762f4b148551d39d83c63fc8074e))
* harden v1.3.0 release recovery ([af499d1](https://github.com/NickolayMamonov/meet-backend-v3/commit/af499d160718dcd285c9e419e21da6066ea0afc6))
* recover exact v1.3.0 release draft ([79263bf](https://github.com/NickolayMamonov/meet-backend-v3/commit/79263bfed6427dc1a45900e338805c52dbd5f59d))
* recover exact v1.3.0 release draft ([25adf8f](https://github.com/NickolayMamonov/meet-backend-v3/commit/25adf8f0d481ede59fa30d1a03f67168a4c8f9cb))
* **recovery:** close cleanup admission race ([7185e3b](https://github.com/NickolayMamonov/meet-backend-v3/commit/7185e3bf74f17a0ebbdbc8fd63317389e28c8b85))
* rework beta recovery proof gates ([c5fa114](https://github.com/NickolayMamonov/meet-backend-v3/commit/c5fa1140dd8cc14dc2e03b06a0422c25e3017e7d))
* satisfy shellcheck for recovery authorization ([8a3e17d](https://github.com/NickolayMamonov/meet-backend-v3/commit/8a3e17d0ecfd4d901cc1e276a8b94028495a252b))
* tolerate artifact retention rounding ([bbaec8b](https://github.com/NickolayMamonov/meet-backend-v3/commit/bbaec8b7ae60794cf1e0ebfa2ec2a5f1db3f5dbc))
* tolerate artifact retention rounding ([f29ceec](https://github.com/NickolayMamonov/meet-backend-v3/commit/f29ceec9a7e17539c80169ebe185d501dd246146))

## [1.3.0](https://github.com/NickolayMamonov/meet-backend-v3/compare/v1.2.0...v1.3.0) (2026-08-23)


### Features

* add exact dev test VPS promotion path ([cc4d840](https://github.com/NickolayMamonov/meet-backend-v3/commit/cc4d840cb0248e66666f98674ce035b66de04d3d))
* **deploy:** add durable Yandex SMTP rollout ([4680658](https://github.com/NickolayMamonov/meet-backend-v3/commit/46806584aceb86423b044463b1a096af9d9ddd93))
* **deploy:** add guarded test VPS promotion ([c8fc32b](https://github.com/NickolayMamonov/meet-backend-v3/commit/c8fc32bf627857123c34c5c198983078bfea344c))
* **deploy:** add guarded test VPS promotion ([9a89692](https://github.com/NickolayMamonov/meet-backend-v3/commit/9a89692bf12099734f2106ca6b4402e400f6bb9a))


### Fixes

* bind promotion evidence to predecessor proofs ([e30fe72](https://github.com/NickolayMamonov/meet-backend-v3/commit/e30fe72fbab3582d8d6f167fa2b9e74f6b8b8bf2))
* centralize dev promotion authorization ([adbae1f](https://github.com/NickolayMamonov/meet-backend-v3/commit/adbae1f36207317c21ca35ca1f8ed57fdabaed31))
* **ci:** enforce promotion script execution contract ([f27299a](https://github.com/NickolayMamonov/meet-backend-v3/commit/f27299a6a7230be9adaeefe02ca36dddcf90be1e))
* **ci:** keep workflow validation parser-focused ([62d72f4](https://github.com/NickolayMamonov/meet-backend-v3/commit/62d72f4856af4bb5018c6ef999dbe69dd3159018))
* **ci:** mark workflow validator executable ([4bedd7e](https://github.com/NickolayMamonov/meet-backend-v3/commit/4bedd7e510116c93cd59338d6c8b8760c6c1e981))
* **ci:** validate promotion environment policy shape ([172459d](https://github.com/NickolayMamonov/meet-backend-v3/commit/172459d02c30a1b0c483722ace2ff0e31c6e791a))
* **ci:** validate promotion environment policy shape ([da400c9](https://github.com/NickolayMamonov/meet-backend-v3/commit/da400c9837c84af128eeee12ac2977b7a963b567))
* **ci:** validate promotion workflow syntax ([46f47df](https://github.com/NickolayMamonov/meet-backend-v3/commit/46f47df88c328a12d312245e07bf705ae4f38cd9))
* close dev promotion admission and evidence gates ([fa7f147](https://github.com/NickolayMamonov/meet-backend-v3/commit/fa7f1472056fff26b4bdbde13fbca4e4dbba94c3))
* close dev promotion rework gates ([13ee040](https://github.com/NickolayMamonov/meet-backend-v3/commit/13ee04040c55c66cf9a5b7d53cf89caa6c6d6232))
* close promotion QA gates ([5617591](https://github.com/NickolayMamonov/meet-backend-v3/commit/56175912be93522e3164257a9c20ab4d22907610))
* close remaining promotion review gates ([55b933d](https://github.com/NickolayMamonov/meet-backend-v3/commit/55b933d830f7d5917a6d54c65995ba9ed5e54615))
* **deploy:** accept aligned image digest evidence ([ae83bf1](https://github.com/NickolayMamonov/meet-backend-v3/commit/ae83bf160902338657b7164fe1b1e8d18c9a5122))
* **deploy:** accept aligned image digest evidence ([10ca6b2](https://github.com/NickolayMamonov/meet-backend-v3/commit/10ca6b27f5299e403390609158a83f9821609107))
* **deploy:** bind promotion evidence to runtime probes ([a1b81d0](https://github.com/NickolayMamonov/meet-backend-v3/commit/a1b81d0a59f32daaa548f5d94d6ca23dde0e9b54))
* **deploy:** bound test VPS retention ([2739920](https://github.com/NickolayMamonov/meet-backend-v3/commit/27399202b2a9e92d2816749e12965a9f5368b5b3))
* **deploy:** bound test VPS retention ([2cfd63c](https://github.com/NickolayMamonov/meet-backend-v3/commit/2cfd63c5e8bf7dace7a3f4a3ffb952811743164d))
* **deploy:** close SMTP rollback findings ([31167dd](https://github.com/NickolayMamonov/meet-backend-v3/commit/31167ddf3664b3497d3b3a8bf77746c7290de514))
* **deploy:** close SMTP startup evidence gaps ([8d7194c](https://github.com/NickolayMamonov/meet-backend-v3/commit/8d7194c492b7fd8d99dd2c792415f543f8867940))
* **deploy:** close SMTP transaction findings ([b43fb54](https://github.com/NickolayMamonov/meet-backend-v3/commit/b43fb54ca39819d0154fc6999fe2820df72a2259))
* **deploy:** harden SMTP recovery state ([7d1898f](https://github.com/NickolayMamonov/meet-backend-v3/commit/7d1898fdfb37a9a1c81a90c608eb20cca87acc1a))
* **deploy:** harden SMTP transaction recovery ([cf3fdd0](https://github.com/NickolayMamonov/meet-backend-v3/commit/cf3fdd0b6a0cb7ec63cde0431c5f108893727159))
* **deploy:** mark SMTP tooling executable ([f74ec26](https://github.com/NickolayMamonov/meet-backend-v3/commit/f74ec26aa0a22b956e4adc78a0a5ed2a25bfdfdb))
* **deploy:** normalize Docker mount records ([fc1a00b](https://github.com/NickolayMamonov/meet-backend-v3/commit/fc1a00b07c338d821733b02112e30f350e6d063b))
* **deploy:** normalize Docker mount records ([47f5ac9](https://github.com/NickolayMamonov/meet-backend-v3/commit/47f5ac98a6ecbf26dfa8873faf25b75a0d7ea446))
* **deploy:** preserve observed promotion evidence ([b28f107](https://github.com/NickolayMamonov/meet-backend-v3/commit/b28f107b82120553ee180cfae9766c093f469ef6))
* **deploy:** reconcile SMTP transaction findings ([1f119f5](https://github.com/NickolayMamonov/meet-backend-v3/commit/1f119f5d90a44f86bd166c451e528b0ea5d5fc4f))
* **deploy:** restore SMTP rollback verification ([662f03e](https://github.com/NickolayMamonov/meet-backend-v3/commit/662f03e431128d3778e58b677ac229896413d494))
* **deploy:** satisfy probe shell validation ([06ec1e7](https://github.com/NickolayMamonov/meet-backend-v3/commit/06ec1e702f5c261d7fb7502de49b7094feb6f8f8))
* **deploy:** verify runtime Compose labels ([14dd6b8](https://github.com/NickolayMamonov/meet-backend-v3/commit/14dd6b85f8fba49752dc2bd58523c1a6ba38c0d1))
* **deploy:** verify runtime Compose labels ([4d4cf51](https://github.com/NickolayMamonov/meet-backend-v3/commit/4d4cf51593cebf1f4253449d1afab52cdf437e85))
* model paginated GitHub check responses ([7f42a2c](https://github.com/NickolayMamonov/meet-backend-v3/commit/7f42a2ce87d8b6fa21dbe27fa1ef3b277e6809c9))
* quote promotion refspecs for shellcheck ([113a6cb](https://github.com/NickolayMamonov/meet-backend-v3/commit/113a6cbecc15369b198b9d44cfb13a5c4adffcbd))
* **release:** anchor tooling fixtures ([5f59a61](https://github.com/NickolayMamonov/meet-backend-v3/commit/5f59a6162e6f8045aacd61d168c904b4af9273e6))
* **release:** anchor tooling fixtures ([328405f](https://github.com/NickolayMamonov/meet-backend-v3/commit/328405f4ffaa762ce8ea11dcb01fa2537f630ab1))
* **release:** continue exact empty v1.2.0 draft ([eadad24](https://github.com/NickolayMamonov/meet-backend-v3/commit/eadad246a0c394bf99b6616683577ec05987049c))
* **release:** continue exact empty v1.2.0 draft ([d152c3b](https://github.com/NickolayMamonov/meet-backend-v3/commit/d152c3ba1fe2685b57f6e232a1acbb46baa7e637))
* **release:** provision attestation buildx ([9af0723](https://github.com/NickolayMamonov/meet-backend-v3/commit/9af0723444f918594101999a4338b418607cbd01))
* **release:** provision attestation buildx ([4c69fb0](https://github.com/NickolayMamonov/meet-backend-v3/commit/4c69fb044b89d1304fdb1c77eab9a966959a4599))
* **release:** verify immutable attestations v0.2 ([a437707](https://github.com/NickolayMamonov/meet-backend-v3/commit/a437707f6b9491edb93cef5b41bc225fc0224f16))
* **release:** verify immutable attestations v0.2 ([0d60805](https://github.com/NickolayMamonov/meet-backend-v3/commit/0d60805acf4ce76d349b26ed728e937db3754411))
* run promotion shims through bash ([7dd4150](https://github.com/NickolayMamonov/meet-backend-v3/commit/7dd415052f198fff6350c12ff4bca767a6d02ea4))
* satisfy promotion shell lint ([7e51ebf](https://github.com/NickolayMamonov/meet-backend-v3/commit/7e51ebfad71b767338c4bd79fdab44ed20ac2824))
* validate promotion environment policies ([ec92451](https://github.com/NickolayMamonov/meet-backend-v3/commit/ec92451bb7901982c8cc253313d974b62ab5c3b6))

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
