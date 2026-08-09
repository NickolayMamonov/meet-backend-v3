# Changelog

## [1.1.0](https://github.com/NickolayMamonov/meet-backend-v3/compare/meet-backend-v1.0.0...meet-backend-v1.1.0) (2026-08-09)


### Features

* **api:** add admin endpoint to trigger ingestion manually ([422f901](https://github.com/NickolayMamonov/meet-backend-v3/commit/422f901e1861266e49a22a255de670d6ea41b0ec))
* **api:** add structured error handling ([5c4de03](https://github.com/NickolayMamonov/meet-backend-v3/commit/5c4de035848ebe4436e48be76344b296483c37f9))
* **api:** expose source/externalUrl/isOnline in MeetingDto ([09993e2](https://github.com/NickolayMamonov/meet-backend-v3/commit/09993e23120825b63e751fe61aff6532e26951d7))
* **api:** populate mapImageUrl in MeetingDto mapper ([d055988](https://github.com/NickolayMamonov/meet-backend-v3/commit/d0559880d6187ecfa44664a0174b9b809e5cbab9))
* **api:** proxy endpoint GET /meetings/{id}/map.png ([7c53e37](https://github.com/NickolayMamonov/meet-backend-v3/commit/7c53e37e4b28e067cc6a48581ab542480332e9d2))
* **auth:** add persistent OTP rate limiting ([#14](https://github.com/NickolayMamonov/meet-backend-v3/issues/14)) ([ba473db](https://github.com/NickolayMamonov/meet-backend-v3/commit/ba473db5bbd578114233aed24f3817bf4eb9300a))
* **auth:** add SMS provider boundary ([#13](https://github.com/NickolayMamonov/meet-backend-v3/issues/13)) ([2af7d04](https://github.com/NickolayMamonov/meet-backend-v3/commit/2af7d040e5204b8a817a38268edcdc0fa47e4e1a))
* **auth:** rotate refresh tokens ([#7](https://github.com/NickolayMamonov/meet-backend-v3/issues/7)) ([ffaf651](https://github.com/NickolayMamonov/meet-backend-v3/commit/ffaf651eb70fcc6e1255b1ad6a21d5d5cc032f7d))
* **config:** add TimepadProperties ([e12b80f](https://github.com/NickolayMamonov/meet-backend-v3/commit/e12b80f99fdac3594d5b2abff079d08ea5763116))
* **db:** V10 create ingestion_runs table ([cf568fc](https://github.com/NickolayMamonov/meet-backend-v3/commit/cf568fc8b38937fff4dd5b8407f857f8ac508f82))
* **db:** V9 add external event columns and source dedup index ([70bac5c](https://github.com/NickolayMamonov/meet-backend-v3/commit/70bac5ca12b429a2fccd77a685a160dc3f937e3c))
* **domain:** add external-source fields and EventSource enum to Meeting ([6b843fc](https://github.com/NickolayMamonov/meet-backend-v3/commit/6b843fcefdef038602ca0b5b71b4780ac338a739))
* **domain:** add findBySourceAndSourceExternalId for upsert ([a8bffcc](https://github.com/NickolayMamonov/meet-backend-v3/commit/a8bffccdd29b96b4305c492d4ce8f05bef1d0510))
* **domain:** add IngestionRun entity and repository ([3465c9b](https://github.com/NickolayMamonov/meet-backend-v3/commit/3465c9bde3486bed61b2596e483c19d0abad7efe))
* **geocoder:** switch request to LocationIQ /v1/search ([c53a0ef](https://github.com/NickolayMamonov/meet-backend-v3/commit/c53a0efb344ebb317f925e241aef213e43e21e45))
* **ingestion:** add IngestionService orchestrator with run journaling ([49051ac](https://github.com/NickolayMamonov/meet-backend-v3/commit/49051accb413094656c2a6173b543b0f0e88e3ea))
* **ingestion:** add keyword TopicClassifier ([f3fa40e](https://github.com/NickolayMamonov/meet-backend-v3/commit/f3fa40e620e7e94c2a1c87e1cbb715331f2b8f39))
* **ingestion:** add RawEvent and EventProvider abstraction ([06b35ac](https://github.com/NickolayMamonov/meet-backend-v3/commit/06b35ac67e1dad78dea4dcb87c2d5ab858c7796c))
* **ingestion:** add Timepad API response DTOs ([4fe8bde](https://github.com/NickolayMamonov/meet-backend-v3/commit/4fe8bdeaa614f2738a172b8ce998e3927a4eb814))
* **ingestion:** add transactional MeetingUpsertService ([e035eb6](https://github.com/NickolayMamonov/meet-backend-v3/commit/e035eb63738301f74fdb8f42dfdcd4d34f9a3487))
* **ingestion:** finer-grained stack tags with IT as fallback ([e04d764](https://github.com/NickolayMamonov/meet-backend-v3/commit/e04d76436fdf4e45de7d9cc6124f6c3cf5e09a41))
* **ingestion:** implement TimepadProvider via RestClient ([4675ad0](https://github.com/NickolayMamonov/meet-backend-v3/commit/4675ad00321f2d9702f69bcd543097ec4353ad7f))
* **ingestion:** purge past external events on each ingest run ([41c5d59](https://github.com/NickolayMamonov/meet-backend-v3/commit/41c5d590c7ba9797c213e88292c9950dc458b4af))
* **ingestion:** schedule daily ingestion run ([ef60ef1](https://github.com/NickolayMamonov/meet-backend-v3/commit/ef60ef154b5233eb4ec10ab9587c65dc1b820d85))
* **ingestion:** tag and filter events by topic on upsert ([0c659c1](https://github.com/NickolayMamonov/meet-backend-v3/commit/0c659c18ee5b0466389d6fdb5429e5a9b439d819))
* **release:** publish backend releases ([99d8dc3](https://github.com/NickolayMamonov/meet-backend-v3/commit/99d8dc30605bd58430c59f14d800e5a66a8fbd76))
* **release:** publish backend releases ([#24](https://github.com/NickolayMamonov/meet-backend-v3/issues/24)) ([bea6672](https://github.com/NickolayMamonov/meet-backend-v3/commit/bea6672443c16ee7be2297cc39ad5cd4e2a077c4))
* **security:** permit /admin/** (gated by X-Admin-Key header) ([00c3dde](https://github.com/NickolayMamonov/meet-backend-v3/commit/00c3ddeebb80338c7675248b4b974186d48ff779))
* **staticmap:** add StaticMapProperties ([24b394f](https://github.com/NickolayMamonov/meet-backend-v3/commit/24b394fc791972970a64e85986e1c1ba9c40e284))
* **staticmap:** add StaticMapService with per-coordinate cache ([7357865](https://github.com/NickolayMamonov/meet-backend-v3/commit/7357865db63ac16a88f5b6876e257097aed77776))


### Fixes

* **api:** align error response shape with client ([6138103](https://github.com/NickolayMamonov/meet-backend-v3/commit/61381039e577a1a1f1f839c64161e8cb61e045d2))
* **api:** consolidate typed exceptions ([e5b085c](https://github.com/NickolayMamonov/meet-backend-v3/commit/e5b085c5ef6aeb806b7d33c0e397e1b271f1e2ef))
* **api:** normalize unmatched route errors ([829652f](https://github.com/NickolayMamonov/meet-backend-v3/commit/829652f3c4b051b149ab5cccd9b6ee3e8414ea1d))
* **api:** report full meeting as conflict ([5809127](https://github.com/NickolayMamonov/meet-backend-v3/commit/5809127fd5a0063385981f9b2ea897742eef295b))
* **api:** report missing parameters as bad requests ([43b04a4](https://github.com/NickolayMamonov/meet-backend-v3/commit/43b04a48f8db9d9073275bb41f9288edff1b5646))
* **api:** validate admin purge source ([c2aa124](https://github.com/NickolayMamonov/meet-backend-v3/commit/c2aa1247e2e181b155cfc20c397358a90639008e))
* **auth:** generate secure six-digit OTPs ([#12](https://github.com/NickolayMamonov/meet-backend-v3/issues/12)) ([956dfba](https://github.com/NickolayMamonov/meet-backend-v3/commit/956dfba126c005347533ae641326c380fa6fdcde))
* **ci:** correct Docker label templates ([3c94b9a](https://github.com/NickolayMamonov/meet-backend-v3/commit/3c94b9ae62ca6ab148508a117bb4d55c25a065f5))
* **config:** register Geocoder/StaticMap properties via @EnableConfigurationProperties ([5a9b915](https://github.com/NickolayMamonov/meet-backend-v3/commit/5a9b9158dd137b23b60c955409cb86895b26a490))
* **config:** repoint geocoder from Yandex to LocationIQ + add public-base-url ([851eaf3](https://github.com/NickolayMamonov/meet-backend-v3/commit/851eaf31cf667c077816d2ec3f4465da95b888f2))
* **deploy:** preflight curl readiness dependency ([687fdcc](https://github.com/NickolayMamonov/meet-backend-v3/commit/687fdcc470fc619b93d5c128491311f97cdb1ba7))
* **release:** close publication identity gaps ([3d08473](https://github.com/NickolayMamonov/meet-backend-v3/commit/3d0847356ed0e64f2641dffc0d7209cc98a3d85d))
* **release:** close registry and deployment race gaps ([7273f95](https://github.com/NickolayMamonov/meet-backend-v3/commit/7273f959b191eec322932b4c9b4f8f3f26737939))
* **release:** verify SBOM and canonical identity ([3236996](https://github.com/NickolayMamonov/meet-backend-v3/commit/3236996de97371ebec17703b0dfb22789871254d))
* **security:** centralize admin key authorization ([#11](https://github.com/NickolayMamonov/meet-backend-v3/issues/11)) ([c20be8e](https://github.com/NickolayMamonov/meet-backend-v3/commit/c20be8e24634f13b91dde000e93deb32b6b320f4))
* **security:** permit public GET /api/v1/tags ([4c08287](https://github.com/NickolayMamonov/meet-backend-v3/commit/4c08287d78617a4ce8de71591680901b301072b3))
* **staticmap:** do not cache null render results ([3df6daa](https://github.com/NickolayMamonov/meet-backend-v3/commit/3df6daa707a88826728ef37495fb02af9e79b547))


### Refactoring

* **web:** drop dead null-checks, 503 on render failure ([62a1c30](https://github.com/NickolayMamonov/meet-backend-v3/commit/62a1c30a8022dec40b8e0b4ae2a134ba5444f003))
* **web:** drop dead null-checks, 503 on render failure ([07cfe62](https://github.com/NickolayMamonov/meet-backend-v3/commit/07cfe625e95b6c9ed1a04b1ec27c0f7b3e741755))

## Changelog

All notable backend releases are recorded here by Release Please.
