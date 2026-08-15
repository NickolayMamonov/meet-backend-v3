# MEE2-50 — Beta demo catalog implementation plan

## Planning status

- **Authoritative implementation baseline:** retarget this stale planning worktree from
  `6931e50bbeb9d26c3192c7b0ea86df5b1f855614` to exact
  `27399202b2a9e92d2816749e12965a9f5368b5b3` before any implementation edit. The implementation commit must
  remain that commit or a descendant.
- **Authoritative product artifact:** task comment
  `Operator-approved catalog product artifact (2026-08-15)` (`comment-3215d9eb-15b6-415b-90c6-e6289df7f4a1`).
  The manifest below copies that approval into the durable plan and is frozen for v1. The byte-level public
  resources are frozen in `docs/plans/MEE2-50-public-artifact-v1.md`; that companion is authoritative for PNG
  generation, landing-page bodies, byte lengths, and SHA-256 digests.
- **Planning-node scope:** documentation only. Do not edit production code, migrations, runtime configuration, or
  tests in this node.
- **Implementation boundary:** MEE2-50 owns implementation, CI, merge, deployment with bootstrap disabled, and
  disabled-route/static-asset evidence. It does not invoke the bootstrap against the beta database.

## Planning checklist

- [x] Preserve the reviewed ownership, transaction, scheduling, security, TIMEPAD, and compatibility decisions.
- [x] Freeze the exact v1 catalog metadata, keys, copy, identifiers, fields, assets, schedules, locations,
  relationships, ads, URLs, allowlist, and expected counts.
- [x] Freeze deterministic byte-for-byte generation/content for eleven PNGs and two HTML bodies with expected
  byte lengths and SHA-256 digests before implementation.
- [x] Define complete owned synthetic-user reconciliation and conflict/count behavior, including auth
  contamination preflight and no-auth-mutation rollback proof.
- [x] Separate local PR resource gates from the exact-host probe after disabled deployment.
- [x] Freeze the additive request and response DTO hierarchy and all count semantics.
- [x] Resolve MEE2-50/MEE2-52/MEE4-7 sequencing without requiring unreachable restore evidence in MEE2-50.
- [x] Update implementation slices, verification, rollout gates, acceptance, rollback, and non-goals.
- [x] Publish a revised `Planning result` task comment and complete the planning node.

## Authority and stop conditions

Apply this order:

1. the operator-approved artifact copied below for catalog content and admin response wire behavior;
2. `docs/plans/MEE2-50-public-artifact-v1.md` for exact public bytes and digests;
3. this revised plan for implementation, verification, and rollout sequencing;
4. the reviewed Architecture result for module and transaction boundaries;
5. the earlier Planning result for decisions not superseded here;
6. current `origin/dev` code and tests for preserved behavior.

Stop and return to planning instead of choosing silently if:

- `origin/dev` cannot be fast-forwarded to exact `27399202` before implementation;
- a newer migration has landed and the next migration number is no longer V9;
- a frozen manifest value, URL, relationship, field, or count cannot be represented by the current domain;
- `api.whysoezzy.online` cannot serve the approved checked-in assets and landing pages at the exact paths;
- the existing admin security or sanitized error behavior differs materially on the retargeted baseline;
- implementation would require changing an Android/public DTO, TIMEPAD identity, or applied migration.

## Frozen v1 product manifest

### Metadata, key grammar, and assets

- `catalogName`: `closed-beta-demo`
- `manifestVersion`: `2026-08-15.v1`
- Full logical-key grammar: `closed-beta-demo/<type>/<slug>`.
- Every full key is lowercase ASCII, immutable, nonblank, unique within its root table, and at most 160
  characters.
- Configured media allowlist for this catalog is exactly the singleton set `api.whysoezzy.online`; startup or
  invocation fails safely when the configured set is missing that host or contains an additional host.
- Every media URL is HTTPS, has no user-info or fragment, and is under
  `https://api.whysoezzy.online/demo-assets/v1/`.
- Generate and check in these exact PNG resources according to
  `docs/plans/MEE2-50-public-artifact-v1.md`:
  - `community-moscow.png`
  - `community-walks.png`
  - `community-online.png`
  - `meeting-moscow.png`
  - `meeting-online.png`
  - `avatar-01.png`
  - `avatar-02.png`
  - `avatar-03.png`
  - `avatar-04.png`
  - `avatar-05.png`
  - `avatar-06.png`
- Check in the exact UTF-8 HTML bodies and serve them at these anonymous HTTPS URLs:
  - `https://api.whysoezzy.online/demo-events/organize-online`
  - `https://api.whysoezzy.online/demo-events/networking-online`
- The companion artifact freezes both HTML bodies, including final LF, exact byte lengths, and SHA-256. They do
  not contain a conference-room URL, meeting credential, token, mailbox, phone number, or user-specific data.
- Serve the exact asset and landing paths additively from the backend artifact or its checked-in static-resource
  integration. Do not rely on a third-party placeholder service or an unversioned external asset.
- Tests pin the exact URL set, names, dimensions, byte lengths, bodies, and pre-approved SHA-256 values. A digest
  mismatch fails the PR; implementation must not choose or optimize the public design.

### Tags

| Full key | Exact text |
|---|---|
| `closed-beta-demo/tag/networking` | `[ДЕМО] Нетворкинг` |
| `closed-beta-demo/tag/walks` | `[ДЕМО] Прогулки` |
| `closed-beta-demo/tag/board-games` | `[ДЕМО] Настольные игры` |
| `closed-beta-demo/tag/public-speaking` | `[ДЕМО] Публичные выступления` |
| `closed-beta-demo/tag/organizing` | `[ДЕМО] Организация встреч` |
| `closed-beta-demo/tag/online` | `[ДЕМО] Онлайн` |

### Synthetic users

All six users are non-login records:

- `phone=null`;
- exact email `beta-demo-person-0N@example.invalid`;
- no `auth_identities`, OTP rows, refresh tokens, password, provider token, FCM token, or social-media rows;
- `role=null`, `showCommunities=true`, `showMeetings=true`, `notificationsEnabled=false`, and `deletedAt=null`;
- `authVersion=0` on insertion and must remain zero for a reconcilable owned user;
- names, bios, city, avatar, and interests below are manifest-owned.

| Full key | Name | Surname | Email | City | Exact bio | Exact avatar URL | Interests |
|---|---|---|---|---|---|---|---|
| `closed-beta-demo/user/01` | `[ДЕМО] Анна` | `Волкова` | `beta-demo-person-01@example.invalid` | `Москва` | `Организует дружелюбные встречи для новых знакомств.` | `https://api.whysoezzy.online/demo-assets/v1/avatar-01.png` | networking, organizing |
| `closed-beta-demo/user/02` | `[ДЕМО] Михаил` | `Орлов` | `beta-demo-person-02@example.invalid` | `Москва` | `Любит городские прогулки и открывать новые места Москвы.` | `https://api.whysoezzy.online/demo-assets/v1/avatar-02.png` | walks, networking |
| `closed-beta-demo/user/03` | `[ДЕМО] Елена` | `Соколова` | `beta-demo-person-03@example.invalid` | `Москва` | `Помогает уверенно выступать и знакомиться с людьми.` | `https://api.whysoezzy.online/demo-assets/v1/avatar-03.png` | public-speaking, networking |
| `closed-beta-demo/user/04` | `[ДЕМО] Павел` | `Морозов` | `beta-demo-person-04@example.invalid` | `Москва` | `Собирает компании для современных настольных игр.` | `https://api.whysoezzy.online/demo-assets/v1/avatar-04.png` | board-games, networking |
| `closed-beta-demo/user/05` | `[ДЕМО] Софья` | `Лебедева` | `beta-demo-person-05@example.invalid` | `Онлайн` | `Проводит полезные и спокойные онлайн-встречи.` | `https://api.whysoezzy.online/demo-assets/v1/avatar-05.png` | online, organizing |
| `closed-beta-demo/user/06` | `[ДЕМО] Илья` | `Кузнецов` | `beta-demo-person-06@example.invalid` | `Москва` | `Участник демонстрационного каталога закрытой беты.` | `https://api.whysoezzy.online/demo-assets/v1/avatar-06.png` | networking, online |

### Owned synthetic-user reconciliation matrix

Run this preflight for all six desired users after acquiring the advisory transaction lock and validating the
manifest, but before changing any root, relationship, or `demo_catalog_state` row. One contaminated user aborts
the whole operation with the existing generic sanitized `409 Conflict`; no partial count response is returned.

| Existing owned-user state | Required behavior | Successful root-count effect |
|---|---|---|
| Numeric `id`, `demoCatalogKey`, `createdAt` | Preserve. Ownership is resolved only by exact key; never transfer ownership or replace the row. | Never causes `updated`. |
| `name`, `surname`, `city`, `avatarUrl`, `bio` | Update to the exact manifest value when different. | Any one or more differences classify that user once as `users.updated`. |
| `phone` | Exact allowed value is null. Preserve null. Any non-null value is forbidden auth contamination: generic pre-write conflict; never clear it. | Null never causes `updated`; contamination returns no counts. |
| `email` | Manifest-owned. Update to the exact `example.invalid` value when different, after global user/auth-identity collision preflight. | Difference contributes to one `users.updated`; exact value does not. |
| `fcmToken` | Exact allowed value is null. Preserve null. Any non-null value is forbidden auth/push contamination: generic pre-write conflict; never clear it. | Null never causes `updated`; contamination returns no counts. |
| `auth_identities` rows for the user | Must be absent. Any PHONE or EMAIL identity is forbidden auth contamination: generic pre-write conflict; preserve every row byte-for-byte. | Absence never causes `updated`; contamination returns no counts. |
| `refresh_tokens` rows for the user | Must be absent. Any row, expired or current, is forbidden auth contamination: generic pre-write conflict; preserve every row byte-for-byte. | Absence never causes `updated`; contamination returns no counts. |
| `otp_codes` for the current nonblank email and/or exact synthetic email | Must be absent. Any status/history row for either identifier is forbidden auth contamination: generic pre-write conflict; preserve every row byte-for-byte. | Absence never causes `updated`; contamination returns no counts. |
| `user_social_media` rows | Must be absent. Any row is out-of-manifest identity/profile contamination: generic pre-write conflict; never delete or rewrite it. | Absence never causes `updated`; contamination returns no counts. |
| `role` | Exact allowed value is null. Preserve null. Any non-null role is security-sensitive contamination: generic pre-write conflict; never clear or downgrade it. | Null never causes `updated`; contamination returns no counts. |
| `showCommunities` | Manifest-owned exact value `true`; update when different. | Difference contributes to one `users.updated`. |
| `showMeetings` | Manifest-owned exact value `true`; update when different. | Difference contributes to one `users.updated`. |
| `notificationsEnabled` | Manifest-owned exact value `false`; update when different. | Difference contributes to one `users.updated`. |
| `deletedAt` | Exact allowed value is null. Preserve null. Any non-null value is auth/account-lifecycle contamination: generic pre-write conflict; never resurrect the row. | Null never causes `updated`; contamination returns no counts. |
| `authVersion` | Exact allowed value is `0`. Preserve zero. Any non-zero value is auth-lifecycle contamination: generic pre-write conflict; never reset or decrement it. | Zero never causes `updated`; contamination returns no counts. |
| `updatedAt` | Audit-owned. Let normal JPA behavior change it only when a manifest-owned scalar is actually updated. | Never independently causes `updated`. |
| `interests` | Reconcile under `userInterests`: add desired missing edges; remove stale edges only to demo-owned tags; preserve unrelated shared unowned-tag edges. | Never changes root classification; relationship counts apply. |
| `subscribedCommunities`, `participatingMeetings` | Reconciled from the owning community/meeting side. Preserve unowned real edges under the existing relationship rules. | Never changes root classification. |

Global synthetic-user preflight also rejects, generically and before writes:

- an unowned `users.email` equal to any desired synthetic email;
- any `auth_identities(type=EMAIL, normalized_identifier=<desired email>)` owned by any user;
- duplicate desired emails or contradictory owned keys;
- any forbidden row/state in the matrix for any of the six owned users.

After the complete preflight succeeds, classify each desired user exactly once: absent key is `created`; existing
key with at least one manifest-owned scalar difference is `updated`; otherwise it is `unchanged`. Preserved audit
state and relationships do not affect root classification. A conflict returns no summary, leaves persisted root
counts unchanged, and must not delete, reset, rotate, invalidate, or otherwise mutate auth/profile contamination.

### Communities

| Full key | Exact name | Exact description | Exact image URL | Tags | Subscribers |
|---|---|---|---|---|---|
| `closed-beta-demo/community/moscow-meets` | `[ДЕМО] Москва знакомится` | `Демонстрационное сообщество закрытой беты для дружелюбных знакомств и небольших встреч в Москве.` | `https://api.whysoezzy.online/demo-assets/v1/community-moscow.png` | networking, organizing | 01, 03, 06 |
| `closed-beta-demo/community/city-walks` | `[ДЕМО] Городские прогулки` | `Демонстрационные прогулки по известным местам Москвы в небольшой компании.` | `https://api.whysoezzy.online/demo-assets/v1/community-walks.png` | walks, networking | 02, 04, 06 |
| `closed-beta-demo/community/online-club` | `[ДЕМО] Онлайн-клуб встреч` | `Демонстрационное сообщество для открытых онлайн-встреч без приватных ссылок в каталоге.` | `https://api.whysoezzy.online/demo-assets/v1/community-online.png` | online, organizing, networking | 01, 05, 06 |

### Meetings

All meetings:

- use `Europe/Moscow`;
- have `status=ACTIVE`, `source=MANUAL`, `sourceExternalId=null`, `ingestedAt=null`, and `dedupHash=null`;
- derive `time`, `date` (`dd.MM.yyyy`), and `endsAt` from one zoned start plus the exact duration;
- have exactly one person host and one community host;
- use the shared exact image URLs shown below;
- must start strictly after both the injected current instant and request `catalogValidThrough`.

| Full key | Day/start | Duration | Exact title | Exact description | Exact image URL | Address | Lat/Lon | Capacity | Online / external URL | Person host | Community host | Tags | Participants |
|---|---|---:|---|---|---|---|---|---:|---|---|---|---|---|
| `closed-beta-demo/meeting/welcome` | `anchor + 7`, 19:00 | 120m | `[ДЕМО] Знакомство с клубом` | `Демонстрационная встреча для знакомства с приложением и участниками закрытой беты.` | `https://api.whysoezzy.online/demo-assets/v1/meeting-moscow.png` | `Москва, Тверская улица, 13` | 55.7647, 37.6054 | 40 | false / null | 01 | moscow-meets | networking, organizing | 02, 03, 06 |
| `closed-beta-demo/meeting/organize-online` | `anchor + 10`, 20:00 | 90m | `[ДЕМО] Как организовать онлайн-встречу` | `Демонстрационный разбор подготовки понятной и безопасной онлайн-встречи.` | `https://api.whysoezzy.online/demo-assets/v1/meeting-online.png` | `Онлайн` | 55.7558, 37.6176 | 100 | true / `https://api.whysoezzy.online/demo-events/organize-online` | 05 | online-club | online, organizing | 01, 03, 06 |
| `closed-beta-demo/meeting/board-games` | `anchor + 14`, 19:30 | 150m | `[ДЕМО] Вечер настольных игр` | `Демонстрационный игровой вечер для небольшой компании и проверки записи на встречу.` | `https://api.whysoezzy.online/demo-assets/v1/meeting-moscow.png` | `Москва, улица Новый Арбат, 21` | 55.7522, 37.5866 | 36 | false / null | 04 | moscow-meets | board-games, networking | 02, 05, 06 |
| `closed-beta-demo/meeting/vdnkh-walk` | `anchor + 21`, 11:00 | 120m | `[ДЕМО] Прогулка по ВДНХ` | `Демонстрационная прогулка по ВДНХ с понятной точкой сбора и ограниченной группой.` | `https://api.whysoezzy.online/demo-assets/v1/meeting-moscow.png` | `Москва, проспект Мира, 119` | 55.8298, 37.6339 | 30 | false / null | 02 | city-walks | walks, networking | 01, 04, 06 |
| `closed-beta-demo/meeting/networking-online` | `anchor + 24`, 20:00 | 90m | `[ДЕМО] Нетворкинг без неловкости` | `Демонстрационная онлайн-встреча с короткими знакомствами и безопасным публичным описанием.` | `https://api.whysoezzy.online/demo-assets/v1/meeting-online.png` | `Онлайн` | 55.7558, 37.6176 | 100 | true / `https://api.whysoezzy.online/demo-events/networking-online` | 03 | online-club | online, networking | 01, 02, 05 |
| `closed-beta-demo/meeting/public-speaking` | `anchor + 30`, 19:00 | 120m | `[ДЕМО] Практикум по публичным выступлениям` | `Демонстрационный практикум с короткими выступлениями и бережной обратной связью.` | `https://api.whysoezzy.online/demo-assets/v1/meeting-moscow.png` | `Москва, улица Покровка, 47` | 55.7641, 37.6527 | 50 | false / null | 03 | moscow-meets | public-speaking, networking | 01, 04, 06 |

### Ads

All ads have `isActive=true`.

| Full key / type | Exact title | Exact description | Action | Targets |
|---|---|---|---|---|
| `closed-beta-demo/ad/communities` / `COMMUNITIES` | `[ДЕМО] Сообщества для старта` | `Выберите демонстрационное сообщество и проверьте подписку в закрытой бете.` | `actionText=null`, `actionUrl=null` | moscow-meets, city-walks, online-club |
| `closed-beta-demo/ad/interests` / `TEXT` | `[ДЕМО] Настройте интересы` | `Выберите интересы, чтобы проверить персонализацию демонстрационного каталога.` | `actionText=Выбрать интересы`, `actionUrl=/profile/interests` | no community/user targets |
| `closed-beta-demo/ad/people` / `PEOPLE` | `[ДЕМО] Люди со схожими интересами` | `Откройте демонстрационные профили участников закрытой беты.` | `actionText=null`, `actionUrl=null` | users 01, 02, 03, 05 |

`/profile/interests` is an approved relative client action path. It is not a media URL and is validated as exactly
that value; arbitrary schemes, hosts, or paths are not accepted from this manifest.

### Frozen clean-state counts

Roots:

- `tags=6`
- `users=6`
- `communities=3`
- `meetings=6`
- `adBlocks=3`

Relationships:

- `userInterests=12`
- `communityTags=7`
- `communitySubscribers=9`
- `meetingTags=12`
- `meetingParticipants=18`
- `meetingPersonHosts=6`
- `meetingCommunityHosts=6`
- `adBlockCommunities=3`
- `adBlockUsers=4`

Manifest tests assert the full graph, not only totals: every exact key/value/reference/URL is pinned.

## Frozen additive admin API contract

### Route and request

Expose only:

```text
POST /admin/demo-catalog/bootstrap
```

The route exists only when `app.demo-catalog.bootstrap-enabled=true` and remains under the existing `/admin/**`
ADMIN-key chain.

Request JSON:

```json
{
  "scheduleAnchorDate": "YYYY-MM-DD",
  "catalogValidThrough": "UTC-INSTANT",
  "confirmReschedule": false
}
```

- `scheduleAnchorDate`: required, non-null ISO `LocalDate`.
- `catalogValidThrough`: required, non-null ISO-8601 `Instant`.
- `confirmReschedule`: optional, non-null Boolean, defaults to `false` only when omitted.
- Reject null, malformed, or semantically invalid values with the existing sanitized `400` envelope.
- Reject a changed anchor or valid-through boundary with sanitized `409` unless `confirmReschedule=true`.

### Exact response hierarchy

All objects and fields below are required and always serialized. No category or zero-valued field is omitted or
serialized as null. Every count is a non-negative JSON integer backed by Kotlin `Int`.

```json
{
  "catalogName": "closed-beta-demo",
  "manifestVersion": "2026-08-15.v1",
  "scheduleAnchorDate": "YYYY-MM-DD",
  "catalogValidThrough": "UTC-INSTANT",
  "roots": {
    "tags": {"created": 0, "updated": 0, "unchanged": 0},
    "users": {"created": 0, "updated": 0, "unchanged": 0},
    "communities": {"created": 0, "updated": 0, "unchanged": 0},
    "meetings": {"created": 0, "updated": 0, "unchanged": 0},
    "adBlocks": {"created": 0, "updated": 0, "unchanged": 0}
  },
  "relationships": {
    "userInterests": {"added": 0, "removed": 0, "unchanged": 0},
    "communityTags": {"added": 0, "removed": 0, "unchanged": 0},
    "communitySubscribers": {"added": 0, "removed": 0, "unchanged": 0},
    "meetingTags": {"added": 0, "removed": 0, "unchanged": 0},
    "meetingParticipants": {"added": 0, "removed": 0, "unchanged": 0},
    "meetingPersonHosts": {"added": 0, "removed": 0, "unchanged": 0},
    "meetingCommunityHosts": {"added": 0, "removed": 0, "unchanged": 0},
    "adBlockCommunities": {"added": 0, "removed": 0, "unchanged": 0},
    "adBlockUsers": {"added": 0, "removed": 0, "unchanged": 0}
  }
}
```

The response contains no database IDs, logical keys, user identifiers, copy, URLs, headers, admin key, raw
exception text, OTPs, JWTs, refresh tokens, DB credentials, or provider tokens.

### Count semantics

Root counts classify every desired manifest root exactly once:

- `created`: no row exists with that root's logical key and bootstrap inserts it.
- `updated`: an owned row exists and at least one manifest-owned normalized scalar differs before reconciliation.
- `unchanged`: an owned row already has every manifest-owned normalized scalar, or a tag resolves to an existing
  unowned same-text tag under the approved read-only sharing rule.
- Relationships, generated IDs, timestamps, and `demo_catalog_state.appliedAt` do not make a root `updated`.
- For each root category, `created + updated + unchanged` equals its frozen manifest root count.

Relationship counts classify edge mutations:

- `added`: a desired edge was absent and is inserted or assigned.
- `removed`: an existing stale edge is removed under the ownership rules.
- `unchanged`: a desired edge already exists before reconciliation.
- Preserved out-of-manifest edges to unowned real users or shared unowned tags are intentionally not counted.
- A newly created root's desired edges count as `added`.
- Person/community host FKs are counted as relationships, not meeting scalar updates. A null desired-host slot
  becoming assigned is one `added`; an equal assignment is one `unchanged`; replacing a different host on an
  owned meeting is one `removed` plus one `added`.
- On a clean database, root `created` and relationship `added` values equal the frozen counts above.
- On an identical rerun, root `unchanged` and relationship `unchanged` values equal the frozen counts above and
  every mutation field is zero.
- On confirmed rescheduling with no other drift, `meetings.updated=6`; all other roots and all relationships are
  unchanged.

Implement dedicated DTOs such as `RootMutationCounts`, `RelationshipMutationCounts`,
`DemoCatalogRootCounts`, `DemoCatalogRelationshipCounts`, and `DemoCatalogBootstrapResponse`; do not expose
maps with string keys because the wire hierarchy is a compile-time contract.

## Ordered implementation plan

### 1. Retarget and revalidate

Run:

```sh
git status --short
git fetch origin dev
git merge --ff-only 27399202b2a9e92d2816749e12965a9f5368b5b3
test "$(git rev-parse HEAD)" = 27399202b2a9e92d2816749e12965a9f5368b5b3
git status --short
git ls-tree -r --name-only HEAD src/main/resources/db/migration | sort -V
```

Reconfirm:

- default/prod Flyway uses only `classpath:db/migration`, while dev alone adds `classpath:db/seed`;
- V8 is the latest applied migration before selecting V9;
- discovery still uses `COALESCE(endsAt, time) >= now`;
- `/admin/**` remains protected by `AdminKeyAuthFilter` and ADMIN authorization;
- Timepad ingestion/upsert/purge and `source/sourceExternalId` behavior are unchanged;
- production ingestion, Timepad, and geocoding defaults remain disabled;
- injectable UTC `Clock` and sanitized API exception handling remain available.

### 2. Add monotonic ownership/state migration

Create the actual next migration, expected
`src/main/resources/db/migration/V9__add_demo_catalog_ownership.sql`:

1. Add nullable `demo_catalog_key VARCHAR(160)` to `users`, `communities`, `meetings`, `tags`, and `ad_blocks`.
2. Add named checks allowing null or nonblank trimmed keys.
3. Add named unique partial indexes where `demo_catalog_key IS NOT NULL`.
4. Create `demo_catalog_state`:
   - `catalog_name VARCHAR(80) PRIMARY KEY`
   - `manifest_version VARCHAR(80) NOT NULL`
   - `schedule_anchor_date DATE NOT NULL`
   - `catalog_valid_through TIMESTAMPTZ NOT NULL`
   - `applied_at TIMESTAMPTZ NOT NULL`
5. Keep the migration additive and transactional. Never edit V1–V8 or the dev seed.

Add PostgreSQL migration tests for null/blank/unique behavior, cross-table key independence, state constraints, and
Hibernate validation.

### 3. Map ownership internally

- Add nullable, insert-assignable, `updatable=false` `demoCatalogKey` mappings to `User`, `Community`, `Meeting`,
  `Tag`, and `AdBlock`, with constructor defaults preserving callers.
- Keep ownership out of every Android/public DTO and mapper.
- Add standalone `DemoCatalogState` with string `@Id`; do not extend `BaseEntity`.
- Add its repository and batched `findAllByDemoCatalogKeyIn` methods to the five root repositories.
- Preserve `TagRepository.findByText`, meeting discovery, TIMEPAD lookup, and source-deletion methods.

### 4. Add disabled configuration and exact public static content

- Add registered `DemoCatalogProperties`:
  - `bootstrapEnabled=false`
  - `allowedMediaHosts=emptySet()`
- Add explicit disabled defaults to `application.yml` and `application-prod.yml`.
- Keep production enablement operator-supplied and non-secret.
- Generate the eleven PNGs with the exact approved generator/runtime and copy the two exact HTML bodies from
  `docs/plans/MEE2-50-public-artifact-v1.md` into versioned classpath resources. Verify every byte length and
  pre-approved SHA-256 before committing; do not re-encode or optimize them.
- Expose only the exact public `/demo-assets/v1/**` files and two exact `/demo-events/**` landing paths. If current
  static handling cannot provide extensionless HTML with `text/html`, add a narrow public resource adapter rather
  than broadening unrelated routes.
- Add local byte-level tests for all thirteen resources plus MockMvc tests for anonymous 200, exact content type,
  missing-resource 404, and absence of secrets or private links in HTML.

### 5. Encode the typed frozen manifest

Under `dev.whysoezzy.meet.demo.catalog`, add immutable value types and one
`BetaDemoCatalogManifest` encoding every frozen value above. Use typed references rather than stringly resolving
relationships in persistence code. Do not use SQL, JSON/YAML parsing, runtime content injection, or
implementation-selected copy.

The validator checks exact metadata, keys, all root scalar constraints, reference resolution, full graph counts,
email uniqueness, no phone/login/auth material, enums, positive capacities/durations, coordinates, exact media
host/path set, exact online landing URLs, exact TEXT action path, and duplicate/contradictory relationships.

### 6. Compile schedules deterministically

`DemoCatalogScheduleCompiler` uses injected `Clock` and `ZoneId.of("Europe/Moscow")`. For each frozen local
day/time:

1. build one Moscow `ZonedDateTime` from request anchor plus offset;
2. derive epoch-millisecond `time`;
3. derive `date` using `dd.MM.yyyy`;
4. derive `endsAt` by adding the exact duration.

Reject `endsAt <= time` and starts not strictly after both `clock.instant()` and `catalogValidThrough`.
Current time is a guard only, never a scheduling input.

### 7. Add the transaction advisory lock

Use `JdbcTemplate` inside the active Spring transaction:

```sql
SELECT pg_try_advisory_xact_lock(?, ?)
```

Fixed signed 32-bit keys:

- namespace `1296385364` (`0x4D454554`, `MEET`);
- catalog `1111839809` (`0x42455441`, `BETA`).

False maps to generic `409` before writes. Do not use a session lock or manually managed connection.

### 8. Implement one atomic bootstrap/reconciliation service

`DemoCatalogBootstrapService.bootstrap(command)` is invoked through another Spring bean and is one
`@Transactional` operation:

1. acquire the advisory transaction lock;
2. load state and enforce reschedule confirmation;
3. compile and fully validate the frozen manifest;
4. batch-load all owned roots and all rows needed for collision/auth-contamination checks;
5. resolve owned roots only by logical key and permit only the same-text unowned-tag read-only exception;
6. run the complete synthetic-user matrix and global identifier preflight across all six users, including phone,
   email, FCM, identities, refresh tokens, OTP history, social rows, role, settings, `deletedAt`, and
   `authVersion`;
7. reject any forbidden state, unowned synthetic-email/auth-identity collision, or key/type contradiction with
   generic `409` before changing any root, edge, state row, auth row, or persistence-context entity field;
8. only after every preflight passes, classify roots and upsert them in tag, user, community, meeting, ad order
   using generated IDs;
9. preserve existing owned IDs and apply the matrix's exact update/preserve rules; count each desired root once;
10. keep meetings MANUAL with null source identity/ingestion fields;
11. reconcile all nine frozen relationship categories;
12. preserve unowned real subscribers/participants and shared unowned tags;
13. make person/community host assignments authoritative on owned meetings;
14. remove stale collection edges only when the related root is demo-owned; do not delete roots;
15. flush explicitly and translate uniqueness races to sanitized `409`;
16. write state only after successful root/edge flush;
17. return the exact typed counts and commit atomically.

Any validation, persistence, injected failure, or state failure rolls back roots, edges, and state. Directly
deleted owned roots may be recreated with a new generated numeric ID. Manifest retirement/deletion is not part of
v1. Repositories used for contamination checks are read-only in this module: the bootstrap must not call auth
delete/save/rotate methods, clear forbidden fields, increment/reset `authVersion`, resurrect a deleted user, or
rely on rollback as permission to mutate auth state in memory before failing.

### 9. Add the admin adapter

- Add `POST /admin/demo-catalog/bootstrap` in an isolated conditional controller.
- Use the exact request/response DTO contract above.
- Reuse existing `BadRequestException`, `ConflictException`, `ApiExceptionHandler`, and error envelope.
- Do not modify ingestion `AdminController`.
- Do not change security unless exact public static paths require narrow additive anonymous GET rules.
- Missing/wrong admin key remains `403`; authenticated call while disabled is existing `404`.
- Logs may contain catalog name/version and aggregate counts only.

### 10. Add focused verification

Add:

1. **Manifest tests**
   - exact metadata, all full keys, every copy/identifier/field/URL/reference, singleton host allowlist, exact
     root/edge counts, and resource names;
   - invalid keys, duplicate identifiers, unresolved references, malformed/spoofed hosts, extra allowed host,
     private/tokenized online URL, invalid action URL, auth material, and graph mismatch fail before writes.
2. **Schedule tests**
   - all six exact offsets/start times/durations/capacities;
   - Moscow conversion, `dd.MM.yyyy`, deterministic repetition, boundary and rollover cases.
3. **Migration PostgreSQL tests**
   - V9 objects and constraints.
4. **Bootstrap PostgreSQL tests**
   - clean insert exact matrix/state and exact clean response;
   - identical rerun exact unchanged response and stable IDs/times;
   - each update-owned user scalar/settings field is repaired and six-user root classification remains exactly
     one bucket per user;
   - each preserve field remains unchanged and does not independently cause `users.updated`;
   - separate contamination cases for non-null phone, non-null FCM token, auth identity, refresh token, OTP
     history, social row, non-null role, non-null `deletedAt`, and non-zero `authVersion`;
   - each contamination case returns generic `409` before writes, returns no count summary, and preserves the
     contaminating row/field byte-for-byte;
   - a parameterized PostgreSQL rollback/no-auth-mutation test first introduces otherwise-repairable drift in
     another owned root/edge/state candidate, adds one contamination case, invokes bootstrap, clears the
     persistence context, and proves roots, all nine edge tables, state, user auth fields, `auth_identities`,
     `refresh_tokens`, `otp_codes`, and `user_social_media` equal their pre-call snapshots;
   - global unowned `users.email` and EMAIL-auth-identity collisions for each desired synthetic email fail
     generically before writes;
   - scalar and each relationship-category repair after a clean preflight;
   - confirmed reschedule exact `meetings.updated=6`;
   - rollback after writes but before state;
   - advisory contention with no loser writes;
   - shared unowned tag;
   - generic identifier/key/uniqueness conflict;
   - unrelated MANUAL/TIMEPAD coexistence;
   - real unowned subscriber/participant preservation;
   - clean insert creates no auth/OTP/refresh/social/provider records;
   - reload/restart persistence;
   - direct root recreation without old-ID guarantee.
5. **MockMvc/API tests**
   - exact always-emitted hierarchy and zero fields;
   - clean and rerun count payloads;
   - no additional fields or sensitive values;
   - disabled 404, admin 403, sanitized 400/409/500;
   - unchanged public DTO shapes and all ad types.
6. **Static-resource tests**
   - all eleven exact PNG paths and two exact landing paths;
   - local bytes match the frozen byte lengths and pre-approved SHA-256 values;
   - PNG dimensions match the frozen table and HTML bodies match byte-for-byte including final LF;
   - expected `image/png` or `text/html;charset=UTF-8`, anonymous access, missing 404, and HTML safety.
7. **Post-deployment release media probe**
   - gated by `DEMO_CATALOG_MEDIA_PROBE=true`;
   - probes the exact manifest URL set with bounded redirects/timeouts;
   - requires final HTTPS, exact approved host, 2xx, and expected image content type;
   - never runs inside bootstrap and is not a branch/PR/merge gate;
   - runs only after the same implementation artifact is deployed with bootstrap disabled, and its passing output
     is required to complete MEE2-50.

Run these **PR/merge gates** on the retargeted branch. They are local and do not require
`api.whysoezzy.online` to contain resources that have not been deployed yet:

```sh
./gradlew test -PskipPostgresTests --tests '*DemoCatalogManifestValidatorTest' --tests '*DemoCatalogScheduleCompilerTest' --tests '*DemoCatalogAdminControllerMvcTest' --tests '*DemoCatalogPublicAssetsMvcTest'
./gradlew postgresTest --tests '*DemoCatalogMigrationPostgresTest' --tests '*DemoCatalogBootstrapServicePostgresTest'
./gradlew test
./gradlew postgresTest
./gradlew clean build
git diff --check
git status --short
```

After merge and disabled deployment, run this **MEE2-50 completion gate** against the exact production host:

```sh
DEMO_CATALOG_MEDIA_PROBE=true ./gradlew test -PskipPostgresTests --tests '*DemoCatalogMediaReleaseCheckTest'
```

The release check must fetch all eleven exact asset URLs and both exact landing URLs, verify final host/scheme,
status and content type, then hash response bodies and compare them to the pre-approved digests. A failure blocks
MEE2-50 completion, not the earlier merge. Independent pre-provisioning is neither assumed nor required.

### 11. Document and perform only the MEE2-50 rollout boundary

Add `docs/operations/demo-catalog-bootstrap.md` and link it from production deployment docs. Split it into:

#### MEE2-50 steps — allowed before restore proof

1. record exact source SHA, migration number, and the already-approved thirteen resource digests;
2. inspect table sizes and schedule any index-lock window;
3. deploy schema/code with `DEMO_CATALOG_BOOTSTRAP_ENABLED=false`;
4. keep `DEMO_CATALOG_ALLOWED_MEDIA_HOSTS=api.whysoezzy.online`;
5. verify readiness and unchanged existing public APIs;
6. verify missing/wrong admin key gives `403` and authenticated bootstrap path gives `404`;
7. run the exact-host release media probe after this disabled deployment and prove all thirteen response bodies
   match the frozen digests;
8. retain the probe output as the MEE2-50 completion-gate evidence;
9. record that no demo root/state row exists and no bootstrap request was sent.

MEE2-50 may complete after implementation/CI/merge and this disabled deployment evidence. It must not claim a
non-empty production catalog, idempotent live invocations, live repair, or production data rollback.

#### Post-MEE2-50 gate — owned by MEE2-52

Because MEE2-50 mechanically blocks MEE2-52, completing MEE2-50 makes MEE2-52 reachable. MEE2-52 then creates a
coordinated encrypted off-host PostgreSQL/uploads recovery point and proves isolated restore without touching
active volumes. This evidence is a hard prerequisite for any catalog enablement or invocation.

#### Post-MEE2-52 invocation/client proof — owned by MEE4-7 coordination

Only after MEE2-52 passes:

1. choose and record approved ISO anchor/valid-through values satisfying every future boundary;
2. enable, restart, invoke once, and capture only the safe response;
3. invoke identically and prove exact unchanged counts/IDs/times;
4. exercise supported repair and restart persistence;
5. verify public browse/search/detail/tag/ad and authenticated join/subscribe;
6. disable, restart, and prove the route returns 404 while catalog data remains;
7. let MEE4-7 consume the non-empty catalog for full Android smoke evidence.

This cross-project gate is documented operationally even if Kent cannot express the dependency between the
backend and coordination projects.

## Commit and PR order

1. Schema/model: V9, mappings, state, repositories, migration tests.
2. Core: properties, frozen manifest, validator/compiler, lock, service/reconciler, pure/PostgreSQL tests.
3. API/assets/operations: exact DTO/controller, checked-in assets/pages, MockMvc/resource/release checks, runbook.
4. Fetch current `origin/dev`; if it advanced, integrate normally, renumber only the new unapplied migration when
   necessary, and rerun all affected checks.
5. Open a PR to `dev` with schema-lock, disabled-default, exact manifest/API, security, coexistence, asset, test,
   and rollback-boundary evidence.
6. Merge and deploy disabled only. Do not enable or invoke during MEE2-50.

## Acceptance criteria

1. Implementation starts from exact `27399202` or a descendant, uses the actual next monotonic migration, leaves
   applied migrations/dev seed unchanged, and keeps default/prod Flyway migration-only.
2. Five root tables have internal nullable nonblank/unique-partial ownership keys and the exact state table;
   PostgreSQL and JPA validation pass.
3. Existing Android/public routes, fields, enum values, DTO mapping, meeting discovery, join/subscribe, and
   TIMEPAD `source/sourceExternalId` idempotent behavior are unchanged.
4. The typed manifest equals the frozen v1 artifact byte-for-byte for metadata, full keys, copy, identifiers,
   scalar values, schedules, locations, capacities, relationships, ads, action path, online URLs, media URLs, and
   counts.
5. The eleven PNGs and two HTML pages exactly match the pre-implementation generation/body contract, byte
   lengths, and SHA-256 values; local digest/body tests gate PR/merge, and all thirteen are anonymously reachable
   with matching response-body digests at the exact HTTPS paths after disabled deployment.
6. The configured media allowlist is exactly `api.whysoezzy.online`; malformed, spoofed, extra-host, private, or
   tokenized URLs fail before writes.
7. Schedule compilation deterministically derives coherent `time/date/endsAt` in Moscow and enforces strict
   current-time and valid-through boundaries.
8. One transaction holds the documented advisory transaction lock, completes all ownership/collision/auth
   contamination preflight before mutation, reconciles only permitted owned state, flushes, writes state last,
   and rolls back atomically.
9. The complete synthetic-user matrix is implemented exactly: update-owned differences classify a user once as
   updated; preserved exact values do not; every forbidden phone/FCM/identity/token/OTP/social/role/deletion/auth
   state causes generic pre-write conflict with no count response and no auth/profile mutation.
10. Clean, rerun, repair, reschedule, conflict, coexistence, preservation, restart, auth-table emptiness, and
    PostgreSQL rollback/no-auth-mutation tests pass with the exact count semantics.
11. The admin response has the exact typed hierarchy, emits every zero/category, returns non-negative Int counts,
    and exposes no IDs, keys, identifiers, copy, URLs, credentials, tokens, or raw errors.
12. The conditional route remains admin-gated, disabled by default, and returns authenticated `404` while
    disabled; static demo resources do not broaden admin access.
13. Focused tests, full `test`, mandatory `postgresTest`, local resource digest checks, `clean build`, and
    diff/status checks pass before merge; the exact-host probe passes only after disabled deployment.
14. MEE2-50 evidence ends at merged implementation plus disabled deployment/static checks with zero bootstrap
    invocations and zero production demo rows/state.
15. MEE2-52 restore proof is the reachable post-MEE2-50 prerequisite for live invocation; MEE4-7 owns the later
    full client/public-flow proof.

## Rollback and operational concerns

- The schema is additive; the prior binary tolerates nullable columns and the new state table.
- Partial unique indexes can lock writes; inspect measured production table sizes before migration.
- Disable/restart removes the admin command route but does not remove catalog rows.
- There is no application delete/undo/retire operation.
- After a future invocation, data removal relies on the MEE2-52-verified coordinated restore point.
- MEE2-50 itself performs no invocation, so its deployment rollback is binary rollback with additive schema left
  in place; no demo-data removal is required.

## Explicit non-goals

- No production use or modification of `R__dev_seed.sql`.
- No versioned SQL data seed, startup runner, periodic rescheduling, or runtime remote manifest.
- No fixed numeric IDs, reserved ranges, display-field ownership, ownership transfer, or polymorphic registry.
- No TIMEPAD reuse, ingestion-field population, source purge change, or code outside existing Timepad boundaries.
- No Android/public DTO mutation, auth mechanism change, login-capable demo account, or auth-table writes.
- No arbitrary catalog deletion, retirement, per-entity transactions, partial success, or runtime media fetch.
- No live beta bootstrap, repair drill, client smoke, or restore drill inside MEE2-50.
