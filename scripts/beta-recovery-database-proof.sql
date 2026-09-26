-- Read-only, path-free database proof for the closed-beta recovery drill.
-- The result is one canonical PostgreSQL JSONB document. Keep every value
-- aggregate-only: this output is safe to compare between source and restore.
--
-- The final WHERE clause is intentional: an invalid database produces no
-- proof row at all. The capture and restore callers already require one
-- canonical proof row, so neither can publish an invalid proof.
WITH
expected_tables(table_name) AS (
    VALUES
        ('tags'), ('users'), ('user_interests'), ('user_social_media'),
        ('communities'), ('community_tags'), ('community_subscribers'),
        ('meetings'), ('meeting_tags'), ('meeting_participants'),
        ('ad_blocks'), ('ad_block_communities'), ('ad_block_users'),
        ('otp_codes'), ('refresh_tokens'), ('ingestion_runs'),
        ('otp_rate_limit_attempts'), ('auth_identities'), ('demo_catalog_state'),
        ('real_catalog_revisions'), ('real_catalog_state')
),
expected_indexes(index_name, unique_index, predicate_pattern, key_columns) AS (
    VALUES
        ('uq_meetings_source_external', true, 'source_external_id[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL',
         ARRAY['source', 'source_external_id']::text[]),
        ('uq_refresh_tokens_token_hash', true, '', ARRAY['token_hash']::text[]),
        ('uq_otp_codes_active', true, 'status.*ACTIVE', ARRAY['channel', 'identifier']::text[]),
        ('idx_otp_codes_expires_id', false, '', ARRAY['expires_at', 'id']::text[]),
        ('uq_users_demo_catalog_key', true, 'demo_catalog_key[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL',
         ARRAY['demo_catalog_key']::text[]),
        ('uq_communities_demo_catalog_key', true, 'demo_catalog_key[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL',
         ARRAY['demo_catalog_key']::text[]),
        ('uq_meetings_demo_catalog_key', true, 'demo_catalog_key[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL',
         ARRAY['demo_catalog_key']::text[]),
        ('uq_tags_demo_catalog_key', true, 'demo_catalog_key[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL',
         ARRAY['demo_catalog_key']::text[]),
        ('uq_ad_blocks_demo_catalog_key', true, 'demo_catalog_key[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL',
         ARRAY['demo_catalog_key']::text[]),
        ('uq_meetings_real_catalog_item', true, 'real_catalog_key[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL',
         ARRAY['real_catalog_key', 'real_catalog_item_key']::text[]),
        ('uq_communities_real_catalog_item', true, 'real_catalog_key[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL',
         ARRAY['real_catalog_key', 'real_catalog_item_key']::text[]),
        ('idx_real_catalog_state_cutoff', false, '', ARRAY['discoverable_until', 'catalog_key']::text[]),
        ('idx_meetings_real_catalog_discovery', false, '', ARRAY['real_catalog_key', 'real_catalog_active', 'status', 'time', 'id']::text[]),
        ('idx_communities_real_catalog_discovery', false, '', ARRAY['real_catalog_key', 'real_catalog_active', 'id']::text[])
),
expected_constraints(constraint_name) AS (
    VALUES
        ('tags_pkey'), ('tags_text_key'),
        ('users_pkey'), ('users_phone_key'),
        ('user_interests_pkey'), ('user_interests_user_id_fkey'), ('user_interests_tag_id_fkey'),
        ('user_social_media_pkey'), ('user_social_media_user_id_fkey'),
        ('user_social_media_user_id_platform_key'),
        ('communities_pkey'),
        ('community_tags_pkey'), ('community_tags_community_id_fkey'), ('community_tags_tag_id_fkey'),
        ('community_subscribers_pkey'), ('community_subscribers_community_id_fkey'),
        ('community_subscribers_user_id_fkey'),
        ('meetings_pkey'), ('meetings_person_host_id_fkey'), ('meetings_community_host_id_fkey'),
        ('meeting_tags_pkey'), ('meeting_tags_meeting_id_fkey'), ('meeting_tags_tag_id_fkey'),
        ('meeting_participants_pkey'), ('meeting_participants_meeting_id_fkey'),
        ('meeting_participants_user_id_fkey'),
        ('ad_blocks_pkey'),
        ('ad_block_communities_pkey'), ('ad_block_communities_ad_block_id_fkey'),
        ('ad_block_communities_community_id_fkey'),
        ('ad_block_users_pkey'), ('ad_block_users_ad_block_id_fkey'), ('ad_block_users_user_id_fkey'),
        ('otp_codes_pkey'),
        ('refresh_tokens_pkey'), ('refresh_tokens_user_id_fkey'),
        ('ingestion_runs_pkey'),
        ('otp_rate_limit_attempts_pkey'),
        ('auth_identities_pkey'), ('auth_identities_user_id_fkey'),
        ('chk_refresh_tokens_token_hash'),
        ('uq_refresh_tokens_token_hash'),
        ('chk_otp_rate_limit_scope'),
        ('chk_otp_codes_channel'),
        ('chk_otp_codes_status'),
        ('chk_otp_codes_identifier_nonblank'),
        ('chk_otp_codes_hash_length'),
        ('chk_otp_codes_salt_length'),
        ('chk_otp_codes_hash_key_id'),
        ('chk_otp_codes_attempts'),
        ('chk_auth_identities_type'),
        ('chk_auth_identities_identifier_nonblank'),
        ('uq_auth_identities_type_identifier'),
        ('uq_auth_identities_user_type'),
        ('ck_users_demo_catalog_key_nonblank'),
        ('ck_communities_demo_catalog_key_nonblank'),
        ('ck_meetings_demo_catalog_key_nonblank'),
        ('ck_tags_demo_catalog_key_nonblank'),
        ('ck_ad_blocks_demo_catalog_key_nonblank'),
        ('demo_catalog_state_pkey'),
        ('real_catalog_revisions_pkey'), ('real_catalog_state_pkey'),
        ('uq_real_catalog_revision_label'),
        ('fk_real_catalog_revision_predecessor'),
        ('fk_real_catalog_state_revision'),
        ('fk_meetings_real_catalog_state'), ('fk_communities_real_catalog_state'),
        ('ck_real_catalog_revision_digest'), ('ck_real_catalog_revision_intent'),
        ('ck_real_catalog_revision_generation'), ('ck_real_catalog_revision_window'),
        ('ck_real_catalog_revision_review'), ('ck_real_catalog_revision_next_review'),
        ('ck_real_catalog_revision_cutoff'),
        ('ck_real_catalog_state_intent'), ('ck_real_catalog_state_generation'),
        ('ck_real_catalog_state_window'), ('ck_real_catalog_state_review'),
        ('ck_real_catalog_state_next_review'), ('ck_real_catalog_state_cutoff'),
        ('ck_meetings_real_catalog_ownership'), ('ck_communities_real_catalog_ownership')
),
table_counts AS (
    SELECT jsonb_build_object(
        'ad_block_communities', (SELECT count(*) FROM ad_block_communities),
        'ad_block_users', (SELECT count(*) FROM ad_block_users),
        'ad_blocks', (SELECT count(*) FROM ad_blocks),
        'auth_identities', (SELECT count(*) FROM auth_identities),
        'communities', (SELECT count(*) FROM communities),
        'community_subscribers', (SELECT count(*) FROM community_subscribers),
        'community_tags', (SELECT count(*) FROM community_tags),
        'demo_catalog_state', (SELECT count(*) FROM demo_catalog_state),
        'ingestion_runs', (SELECT count(*) FROM ingestion_runs),
        'meeting_participants', (SELECT count(*) FROM meeting_participants),
        'meeting_tags', (SELECT count(*) FROM meeting_tags),
        'meetings', (SELECT count(*) FROM meetings),
        'otp_codes', (SELECT count(*) FROM otp_codes),
        'otp_rate_limit_attempts', (SELECT count(*) FROM otp_rate_limit_attempts),
        'refresh_tokens', (SELECT count(*) FROM refresh_tokens),
        'real_catalog_revisions', (SELECT count(*) FROM real_catalog_revisions),
        'real_catalog_state', (SELECT count(*) FROM real_catalog_state),
        'tags', (SELECT count(*) FROM tags),
        'user_interests', (SELECT count(*) FROM user_interests),
        'user_social_media', (SELECT count(*) FROM user_social_media),
        'users', (SELECT count(*) FROM users)
    ) AS value
),
schema_checks AS (
    SELECT
        (SELECT count(*) FROM expected_tables expected
         JOIN information_schema.tables actual
           ON actual.table_schema = current_schema()
          AND actual.table_name = expected.table_name
          AND actual.table_type = 'BASE TABLE') = 21
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'refresh_tokens'
               AND column_name = 'token_hash') = 1
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'refresh_tokens'
               AND column_name = 'token') = 0
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'otp_codes'
               AND column_name IN ('identifier', 'channel', 'code_hash', 'hash_salt', 'hash_key_id', 'status',
                                   'failed_attempts', 'max_attempts', 'activated_at', 'consumed_at')) = 10
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'otp_codes'
               AND column_name IN ('phone', 'code', 'is_used')) = 0
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name IN ('users', 'communities', 'meetings', 'tags', 'ad_blocks')
               AND column_name = 'demo_catalog_key') = 5
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'users'
               AND column_name = 'auth_version') = 1
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'refresh_tokens'
               AND column_name = 'auth_version') = 1
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'meetings'
               AND column_name = 'ends_at') = 1
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'real_catalog_revisions'
               AND column_name IN (
                   'digest', 'catalog_key', 'revision_label', 'schema_version', 'intent',
                   'predecessor_digest', 'manifest_bytes', 'resolved_snapshot',
                   'invitation_at', 'window_end_at', 'review_at', 'next_review_at',
                   'discoverable_until', 'content_approval_ref', 'mutation_approval_ref',
                   'recovery_point_ref', 'applied_at', 'generation'
               )) = 18
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'real_catalog_state'
               AND column_name IN (
                   'catalog_key', 'current_digest', 'generation', 'current_intent',
                   'invitation_at', 'window_end_at', 'review_at', 'next_review_at',
                   'discoverable_until', 'owner_role'
               )) = 10
        AND (SELECT count(*)
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name IN ('meetings', 'communities')
               AND column_name IN (
                   'real_catalog_key', 'real_catalog_item_key',
                   'real_catalog_active', 'real_catalog_fingerprint'
               )) = 8 AS required_tables_and_columns,
        (SELECT count(*)
         FROM information_schema.tables
         WHERE table_schema = current_schema()
           AND table_type = 'BASE TABLE'
           AND table_name <> 'flyway_schema_history'
           AND table_name NOT IN (
               'push_installations',
               'meeting_reminder_claims',
               'meeting_reminder_targets'
           )) = 21 AS exact_required_table_count,
        (SELECT count(*)
         FROM expected_indexes expected
         JOIN pg_class index_class
           ON index_class.relname = expected.index_name
         JOIN pg_namespace namespace
           ON namespace.oid = index_class.relnamespace
          AND namespace.nspname = current_schema()
         JOIN pg_index index_row
           ON index_row.indexrelid = index_class.oid
          AND index_row.indisvalid
          AND index_row.indisready
          AND index_row.indisunique = expected.unique_index
          AND index_row.indnatts = cardinality(expected.key_columns)
          AND index_row.indnkeyatts = cardinality(expected.key_columns)
          AND (
              SELECT array_agg(pg_get_indexdef(index_row.indexrelid, key_number, true)
                               ORDER BY key_number)
              FROM generate_series(1, index_row.indnkeyatts) key_number
          ) = expected.key_columns
          AND (
              (expected.predicate_pattern = '' AND index_row.indpred IS NULL)
              OR (
                  expected.predicate_pattern <> ''
                  AND pg_get_expr(index_row.indpred, index_row.indrelid) ~ expected.predicate_pattern
              )
          )) = (SELECT count(*) FROM expected_indexes) AS required_indexes,
        (SELECT count(*)
         FROM expected_constraints expected
         JOIN pg_constraint constraint_row
           ON constraint_row.conname = expected.constraint_name
         JOIN pg_class table_row
           ON table_row.oid = constraint_row.conrelid
         JOIN pg_namespace namespace
           ON namespace.oid = table_row.relnamespace
          AND namespace.nspname = current_schema()
         WHERE constraint_row.convalidated) = (SELECT count(*) FROM expected_constraints) AS required_constraints,
        NOT EXISTS (
            SELECT 1
            FROM pg_constraint constraint_row
            JOIN pg_class table_row ON table_row.oid = constraint_row.conrelid
            JOIN pg_namespace namespace ON namespace.oid = table_row.relnamespace
            WHERE namespace.nspname = current_schema()
              AND NOT constraint_row.convalidated
        ) AS validated_constraints,
        NOT EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND (
                  (table_name = 'refresh_tokens' AND column_name = 'token')
                  OR (table_name = 'otp_codes' AND column_name IN ('phone', 'code', 'is_used'))
              )
        ) AS legacy_plaintext_columns_absent
),
flyway_check AS (
    SELECT COALESCE((
        count(*) FILTER (WHERE success AND version::int <= 11) = 11
        AND count(*) FILTER (WHERE NOT success AND version::int <= 11) = 0
        AND array_agg(version ORDER BY installed_rank)
            FILTER (WHERE success AND version::int <= 11) =
                ARRAY['1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11']::varchar[]
        AND array_agg(installed_rank ORDER BY installed_rank)
            FILTER (WHERE success AND version::int <= 11) =
                ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]::integer[]
        AND count(*) FILTER (WHERE success AND version::int <= 11 AND type = 'SQL') = 11
    ), false) AS valid
    FROM flyway_schema_history
),
relationship_checks AS (
    SELECT
        (SELECT count(*) FROM user_interests edge
         LEFT JOIN users user_row ON user_row.id = edge.user_id
         LEFT JOIN tags tag_row ON tag_row.id = edge.tag_id
         WHERE user_row.id IS NULL OR tag_row.id IS NULL) AS user_interest_orphans,
        (SELECT count(*) FROM community_tags edge
         LEFT JOIN communities community_row ON community_row.id = edge.community_id
         LEFT JOIN tags tag_row ON tag_row.id = edge.tag_id
         WHERE community_row.id IS NULL OR tag_row.id IS NULL) AS community_tag_orphans,
        (SELECT count(*) FROM community_subscribers edge
         LEFT JOIN communities community_row ON community_row.id = edge.community_id
         LEFT JOIN users user_row ON user_row.id = edge.user_id
         WHERE community_row.id IS NULL OR user_row.id IS NULL) AS subscriber_orphans,
        (SELECT count(*) FROM meeting_tags edge
         LEFT JOIN meetings meeting_row ON meeting_row.id = edge.meeting_id
         LEFT JOIN tags tag_row ON tag_row.id = edge.tag_id
         WHERE meeting_row.id IS NULL OR tag_row.id IS NULL) AS meeting_tag_orphans,
        (SELECT count(*) FROM meeting_participants edge
         LEFT JOIN meetings meeting_row ON meeting_row.id = edge.meeting_id
         LEFT JOIN users user_row ON user_row.id = edge.user_id
         WHERE meeting_row.id IS NULL OR user_row.id IS NULL) AS participant_orphans,
        (SELECT count(*) FROM ad_block_communities edge
         LEFT JOIN ad_blocks ad_row ON ad_row.id = edge.ad_block_id
         LEFT JOIN communities community_row ON community_row.id = edge.community_id
         WHERE ad_row.id IS NULL OR community_row.id IS NULL) AS ad_community_orphans,
        (SELECT count(*) FROM ad_block_users edge
         LEFT JOIN ad_blocks ad_row ON ad_row.id = edge.ad_block_id
         LEFT JOIN users user_row ON user_row.id = edge.user_id
         WHERE ad_row.id IS NULL OR user_row.id IS NULL) AS ad_user_orphans,
        (SELECT count(*) FROM user_social_media edge
         LEFT JOIN users user_row ON user_row.id = edge.user_id
         WHERE user_row.id IS NULL) AS user_social_media_orphans,
        (SELECT count(*) FROM meetings meeting_row
         LEFT JOIN users user_row ON user_row.id = meeting_row.person_host_id
         WHERE meeting_row.person_host_id IS NOT NULL AND user_row.id IS NULL) AS person_host_orphans,
        (SELECT count(*) FROM meetings meeting_row
         LEFT JOIN communities community_row ON community_row.id = meeting_row.community_host_id
         WHERE meeting_row.community_host_id IS NOT NULL AND community_row.id IS NULL) AS community_host_orphans,
        (SELECT count(*) FROM (
             SELECT source, source_external_id
             FROM meetings
             WHERE source_external_id IS NOT NULL
             GROUP BY source, source_external_id
             HAVING count(*) > 1
         ) duplicates) AS duplicate_source_keys,
        (SELECT COALESCE(sum(duplicate_rows), 0)
         FROM (
             SELECT count(*) - 1 AS duplicate_rows
             FROM user_interests
             GROUP BY user_id, tag_id
             HAVING count(*) > 1
             UNION ALL
             SELECT count(*) - 1
             FROM community_tags
             GROUP BY community_id, tag_id
             HAVING count(*) > 1
             UNION ALL
             SELECT count(*) - 1
             FROM community_subscribers
             GROUP BY community_id, user_id
             HAVING count(*) > 1
             UNION ALL
             SELECT count(*) - 1
             FROM meeting_tags
             GROUP BY meeting_id, tag_id
             HAVING count(*) > 1
             UNION ALL
             SELECT count(*) - 1
             FROM meeting_participants
             GROUP BY meeting_id, user_id
             HAVING count(*) > 1
             UNION ALL
             SELECT count(*) - 1
             FROM ad_block_communities
             GROUP BY ad_block_id, community_id
             HAVING count(*) > 1
             UNION ALL
             SELECT count(*) - 1
             FROM ad_block_users
             GROUP BY ad_block_id, user_id
             HAVING count(*) > 1
         ) duplicates) AS duplicate_edge_rows
),
auth_checks AS (
    SELECT
        (SELECT count(*) FROM refresh_tokens
         WHERE token_hash IS NULL OR token_hash !~ '^[0-9a-f]{64}$') AS invalid_refresh_hashes,
        (SELECT count(*) FROM otp_codes
         WHERE identifier IS NULL
            OR btrim(identifier) = ''
            OR channel IS NULL
            OR channel NOT IN ('PHONE', 'EMAIL')
            OR code_hash IS NULL
            OR octet_length(code_hash) <> 32
            OR hash_salt IS NULL
            OR octet_length(hash_salt) <> 16
            OR hash_key_id IS NULL
            OR hash_key_id !~ '^[A-Za-z0-9._~-]{1,32}$'
            OR status IS NULL
            OR status NOT IN ('PENDING', 'ACTIVE', 'CONSUMED', 'EXHAUSTED', 'EXPIRED', 'SUPERSEDED', 'DELIVERY_FAILED')
            OR failed_attempts IS NULL
            OR failed_attempts < 0
            OR max_attempts IS NULL
            OR max_attempts NOT BETWEEN 1 AND 10
            OR failed_attempts > max_attempts) AS invalid_otp_rows,
        (SELECT count(*) FROM auth_identities
         WHERE type IS NULL
            OR type NOT IN ('PHONE', 'EMAIL')
            OR normalized_identifier IS NULL
            OR btrim(normalized_identifier) = '') AS invalid_identity_rows,
        (SELECT count(*) FROM auth_identities identity_row
         LEFT JOIN users user_row ON user_row.id = identity_row.user_id
         WHERE user_row.id IS NULL) AS identity_user_orphans,
        (SELECT count(*) FROM auth_identities first_row
         JOIN auth_identities second_row
           ON first_row.id < second_row.id
          AND first_row.type = second_row.type
          AND first_row.normalized_identifier = second_row.normalized_identifier) AS duplicate_identity_rows
),
demo_checks AS (
    SELECT
        (SELECT count(*) FROM demo_catalog_state) AS state_rows,
        (SELECT count(*) FROM demo_catalog_state
         WHERE catalog_name = 'closed-beta-demo'
           AND manifest_version = '2026-08-15.v1') AS matching_state_rows,
        (SELECT count(*) FROM (
             SELECT demo_catalog_key FROM users
             UNION ALL SELECT demo_catalog_key FROM communities
             UNION ALL SELECT demo_catalog_key FROM meetings
             UNION ALL SELECT demo_catalog_key FROM tags
             UNION ALL SELECT demo_catalog_key FROM ad_blocks
         ) owned
         WHERE demo_catalog_key IS NOT NULL
           AND (
               btrim(demo_catalog_key) = ''
               OR demo_catalog_key !~ '^closed-beta-demo/(tag|user|community|meeting|ad)/[a-z0-9-]+$'
           )) AS ownership_key_violations,
        (SELECT count(*) FROM users
         WHERE demo_catalog_key IS NOT NULL
           AND demo_catalog_key !~ '^closed-beta-demo/user/[a-z0-9-]+$')
        + (SELECT count(*) FROM communities
           WHERE demo_catalog_key IS NOT NULL
             AND demo_catalog_key !~ '^closed-beta-demo/community/[a-z0-9-]+$')
        + (SELECT count(*) FROM meetings
           WHERE demo_catalog_key IS NOT NULL
             AND demo_catalog_key !~ '^closed-beta-demo/meeting/[a-z0-9-]+$')
        + (SELECT count(*) FROM tags
           WHERE demo_catalog_key IS NOT NULL
             AND demo_catalog_key !~ '^closed-beta-demo/tag/[a-z0-9-]+$')
        + (SELECT count(*) FROM ad_blocks
           WHERE demo_catalog_key IS NOT NULL
             AND demo_catalog_key !~ '^closed-beta-demo/ad/[a-z0-9-]+$')
            AS ownership_type_violations,
        (SELECT count(*) FROM users WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS owned_users,
        (SELECT count(*) FROM communities WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS owned_communities,
        (SELECT count(*) FROM meetings WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS owned_meetings,
        (SELECT count(*) FROM tags WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS owned_tags,
        (SELECT count(*) FROM ad_blocks WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS owned_ad_blocks
),
media_checks AS (
    SELECT
        count(*) FILTER (WHERE image_url IS NULL) AS null_required_references,
        count(*) FILTER (
            WHERE image_url = 'https://api.whysoezzy.online/demo-assets/v1'
               OR image_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%'
        ) AS managed_references,
        count(*) FILTER (
            WHERE (
                image_url = 'https://api.whysoezzy.online/demo-assets/v1'
                OR image_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%'
            )
              AND (
                  image_url = 'https://api.whysoezzy.online/demo-assets/v1'
                  OR
                  image_url !~ '^https://api[.]whysoezzy[.]online/demo-assets/v1/[^[:space:]#?@\\/]+(/[^[:space:]#?@\\/]+)*$'
                  OR substring(image_url FROM 'demo-assets/v1/(.*)$') ~ '(^|/)[.][.]?(/|$)'
              )
        ) AS unsafe_managed_references
    FROM (
        SELECT avatar_url AS image_url FROM users WHERE avatar_url IS NOT NULL
        UNION ALL
        SELECT image_url FROM communities
        UNION ALL
        SELECT image_url FROM meetings
    ) media_refs
),
real_catalog_checks AS (
    SELECT
        (SELECT count(*) FROM real_catalog_state) AS state_rows,
        (SELECT count(*) FROM real_catalog_revisions) AS revision_rows,
        (SELECT count(*) FROM real_catalog_revisions revision_row
         WHERE encode(digest(revision_row.manifest_bytes, 'sha256'), 'hex') <> revision_row.digest) AS manifest_hash_violations,
        (SELECT count(*) FROM real_catalog_revisions revision_row
         LEFT JOIN real_catalog_revisions predecessor
           ON predecessor.digest = revision_row.predecessor_digest
         WHERE revision_row.predecessor_digest IS NOT NULL
           AND (predecessor.digest IS NULL
                OR predecessor.catalog_key <> revision_row.catalog_key
                OR predecessor.generation >= revision_row.generation)) AS predecessor_violations,
        (SELECT count(*) FROM real_catalog_state state_row
         LEFT JOIN real_catalog_revisions revision_row ON revision_row.digest = state_row.current_digest
         WHERE revision_row.digest IS NULL
            OR revision_row.catalog_key <> state_row.catalog_key
            OR revision_row.generation <> state_row.generation
            OR revision_row.intent::text <> state_row.current_intent
            OR revision_row.discoverable_until <> state_row.discoverable_until
            OR revision_row.invitation_at <> state_row.invitation_at
            OR revision_row.window_end_at <> state_row.window_end_at
            OR revision_row.review_at <> state_row.review_at
            OR state_row.next_review_at <> state_row.review_at + INTERVAL '7 days') AS state_violations,
        (SELECT count(*) FROM real_catalog_revisions revision_row
         WHERE jsonb_typeof(revision_row.resolved_snapshot::jsonb) <> 'object'
            OR jsonb_typeof((revision_row.resolved_snapshot::jsonb)->'communities') <> 'array'
            OR jsonb_typeof((revision_row.resolved_snapshot::jsonb)->'meetings') <> 'array'
            OR CASE WHEN jsonb_typeof((revision_row.resolved_snapshot::jsonb)->'communities') = 'array'
                THEN jsonb_array_length((revision_row.resolved_snapshot::jsonb)->'communities') > 50
                ELSE false
            END
            OR CASE WHEN jsonb_typeof((revision_row.resolved_snapshot::jsonb)->'meetings') = 'array'
                THEN jsonb_array_length((revision_row.resolved_snapshot::jsonb)->'meetings') > 100
                ELSE false
            END
            OR CASE WHEN jsonb_typeof((revision_row.resolved_snapshot::jsonb)->'communities') = 'array'
                THEN EXISTS (
                SELECT 1
                FROM jsonb_array_elements((revision_row.resolved_snapshot::jsonb)->'communities') item
                WHERE jsonb_typeof(item) <> 'object'
                   OR NOT (item ?& ARRAY['kind', 'logicalKey', 'entityId', 'membership', 'fingerprint'])
                   OR EXISTS (
                       SELECT 1
                       FROM jsonb_object_keys(item) field_name
                       WHERE field_name NOT IN ('kind', 'logicalKey', 'entityId', 'membership', 'fingerprint')
                   )
                   OR item->>'kind' <> 'COMMUNITY'
                   OR jsonb_typeof(item->'logicalKey') <> 'string'
                   OR COALESCE(item->>'membership', '') NOT IN ('ACTIVE', 'RETIRED')
                   OR COALESCE(jsonb_typeof(item->'entityId'), '') NOT IN ('number', 'null')
                   OR COALESCE(item->>'fingerprint', '') !~ '^[0-9a-f]{64}$'
                )
                OR EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements((revision_row.resolved_snapshot::jsonb)->'communities') item
                    GROUP BY item->>'kind', item->>'logicalKey'
                    HAVING count(*) > 1
                )
                ELSE false
            END
            OR CASE WHEN jsonb_typeof((revision_row.resolved_snapshot::jsonb)->'meetings') = 'array'
                THEN EXISTS (
                SELECT 1
                FROM jsonb_array_elements((revision_row.resolved_snapshot::jsonb)->'meetings') item
                WHERE jsonb_typeof(item) <> 'object'
                   OR NOT (item ?& ARRAY['kind', 'logicalKey', 'entityId', 'membership', 'fingerprint', 'communityKey'])
                   OR EXISTS (
                       SELECT 1
                       FROM jsonb_object_keys(item) field_name
                       WHERE field_name NOT IN ('kind', 'logicalKey', 'entityId', 'membership', 'fingerprint', 'communityKey')
                   )
                   OR item->>'kind' <> 'MEETING'
                   OR jsonb_typeof(item->'logicalKey') <> 'string'
                   OR COALESCE(item->>'membership', '') NOT IN ('ACTIVE', 'RETIRED')
                   OR COALESCE(jsonb_typeof(item->'entityId'), '') NOT IN ('number', 'null')
                   OR COALESCE(item->>'fingerprint', '') !~ '^[0-9a-f]{64}$'
                   OR COALESCE(jsonb_typeof(item->'communityKey'), '') NOT IN ('string', 'null')
                )
                OR EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements((revision_row.resolved_snapshot::jsonb)->'meetings') item
                    GROUP BY item->>'kind', item->>'logicalKey'
                    HAVING count(*) > 1
                )
                ELSE false
            END) AS snapshot_violations,
        (SELECT count(*)
         FROM (
             SELECT 1
             FROM real_catalog_state state_row
             JOIN real_catalog_revisions revision_row
               ON revision_row.digest = state_row.current_digest
             JOIN communities community_row
               ON community_row.real_catalog_key = state_row.catalog_key
             WHERE NOT EXISTS (
                 SELECT 1
                 FROM jsonb_array_elements((revision_row.resolved_snapshot::jsonb)->'communities') item
                 WHERE item->>'kind' = 'COMMUNITY'
                   AND item->>'logicalKey' = community_row.real_catalog_item_key
                   AND item->>'entityId' = community_row.id::text
                   AND item->>'membership' = CASE WHEN community_row.real_catalog_active
                                                   THEN 'ACTIVE' ELSE 'RETIRED' END
                   AND item->>'fingerprint' = community_row.real_catalog_fingerprint
             )
             UNION ALL
             SELECT 1
             FROM real_catalog_state state_row
             JOIN real_catalog_revisions revision_row
               ON revision_row.digest = state_row.current_digest
             JOIN meetings meeting_row
               ON meeting_row.real_catalog_key = state_row.catalog_key
             LEFT JOIN communities community_row
               ON community_row.id = meeting_row.community_host_id
             WHERE NOT EXISTS (
                 SELECT 1
                 FROM jsonb_array_elements((revision_row.resolved_snapshot::jsonb)->'meetings') item
                 WHERE item->>'kind' = 'MEETING'
                   AND item->>'logicalKey' = meeting_row.real_catalog_item_key
                   AND item->>'entityId' = meeting_row.id::text
                   AND item->>'membership' = CASE WHEN meeting_row.real_catalog_active
                                                   THEN 'ACTIVE' ELSE 'RETIRED' END
                   AND item->>'fingerprint' = meeting_row.real_catalog_fingerprint
                   AND item->>'communityKey' IS NOT DISTINCT FROM community_row.real_catalog_item_key
             )
             UNION ALL
             SELECT 1
             FROM real_catalog_state state_row
             JOIN real_catalog_revisions revision_row
               ON revision_row.digest = state_row.current_digest
             CROSS JOIN LATERAL jsonb_array_elements((revision_row.resolved_snapshot::jsonb)->'communities') item
             WHERE item->>'kind' = 'COMMUNITY'
               AND NOT EXISTS (
                   SELECT 1
                   FROM communities community_row
                   WHERE community_row.real_catalog_key = state_row.catalog_key
                     AND community_row.real_catalog_item_key = item->>'logicalKey'
               )
             UNION ALL
             SELECT 1
             FROM real_catalog_state state_row
             JOIN real_catalog_revisions revision_row
               ON revision_row.digest = state_row.current_digest
             CROSS JOIN LATERAL jsonb_array_elements((revision_row.resolved_snapshot::jsonb)->'meetings') item
             WHERE item->>'kind' = 'MEETING'
               AND NOT EXISTS (
                   SELECT 1
                   FROM meetings meeting_row
                   WHERE meeting_row.real_catalog_key = state_row.catalog_key
                     AND meeting_row.real_catalog_item_key = item->>'logicalKey'
               )
         ) linkage_violations) AS snapshot_root_linkage_violations,
        (SELECT count(*) FROM meetings meeting_row
         LEFT JOIN real_catalog_state state_row ON state_row.catalog_key = meeting_row.real_catalog_key
         LEFT JOIN communities community_row ON community_row.id = meeting_row.community_host_id
         WHERE meeting_row.real_catalog_key IS NOT NULL
           AND (state_row.catalog_key IS NULL
                OR meeting_row.demo_catalog_key IS NOT NULL
                OR meeting_row.real_catalog_item_key IS NULL
                OR meeting_row.real_catalog_active IS NULL
                OR meeting_row.real_catalog_fingerprint !~ '^[0-9a-f]{64}$'
                OR community_row.id IS NULL
                OR community_row.real_catalog_key <> meeting_row.real_catalog_key
                OR (meeting_row.real_catalog_active AND NOT COALESCE(community_row.real_catalog_active, false)))) AS meeting_ownership_violations,
        (SELECT count(*) FROM communities community_row
         LEFT JOIN real_catalog_state state_row ON state_row.catalog_key = community_row.real_catalog_key
         WHERE community_row.real_catalog_key IS NOT NULL
           AND (state_row.catalog_key IS NULL
                OR community_row.demo_catalog_key IS NOT NULL
                OR community_row.real_catalog_item_key IS NULL
                OR community_row.real_catalog_active IS NULL
                OR community_row.real_catalog_fingerprint !~ '^[0-9a-f]{64}$')) AS community_ownership_violations,
        (SELECT count(*) FROM meetings meeting_row
         WHERE meeting_row.real_catalog_key IS NOT NULL
           AND (meeting_row.source::text <> 'MANUAL'
                OR meeting_row.source_external_id IS NULL
                OR meeting_row.source_external_id <> 'closed-beta-real:' || meeting_row.real_catalog_item_key)
        ) AS source_identity_violations,
        (SELECT count(*) FROM real_catalog_revisions revision_row
         LEFT JOIN real_catalog_revisions predecessor ON predecessor.digest = revision_row.predecessor_digest
         WHERE revision_row.intent = 'CORRECT'
           AND predecessor.digest IS NOT NULL
           AND (revision_row.discoverable_until > predecessor.discoverable_until
                OR revision_row.invitation_at <> predecessor.invitation_at
                OR revision_row.window_end_at <> predecessor.window_end_at
                OR revision_row.review_at <> predecessor.review_at)) AS correction_violations
),
catalog_commitments AS (
    SELECT
        encode(digest(COALESCE((
            SELECT string_agg(
                jsonb_build_array(
                    jsonb_build_object('type', 'int8', 'value', meeting_row.id),
                    jsonb_build_object('type', 'text', 'length', length(meeting_row.real_catalog_key), 'value', meeting_row.real_catalog_key),
                    jsonb_build_object('type', 'text', 'length', length(meeting_row.real_catalog_item_key), 'value', meeting_row.real_catalog_item_key),
                    jsonb_build_object('type', 'bool', 'value', meeting_row.real_catalog_active),
                    jsonb_build_object('type', 'text', 'length', length(meeting_row.real_catalog_fingerprint), 'value', meeting_row.real_catalog_fingerprint),
                    jsonb_build_object('type', 'enum', 'length', length(meeting_row.source::text), 'value', meeting_row.source::text),
                    jsonb_build_object('type', 'text', 'length', length(meeting_row.source_external_id), 'value', meeting_row.source_external_id),
                    jsonb_build_object('type', 'int8', 'value', meeting_row.community_host_id)
                )::text,
                E'\n' ORDER BY meeting_row.id
            )
            FROM meetings meeting_row
            WHERE meeting_row.real_catalog_key IS NOT NULL
        ), ''), 'sha256'), 'hex') AS meeting_roots_sha256,
        encode(digest(COALESCE((
            SELECT string_agg(
                jsonb_build_array(
                    jsonb_build_object('type', 'int8', 'value', community_row.id),
                    jsonb_build_object('type', 'text', 'length', length(community_row.real_catalog_key), 'value', community_row.real_catalog_key),
                    jsonb_build_object('type', 'text', 'length', length(community_row.real_catalog_item_key), 'value', community_row.real_catalog_item_key),
                    jsonb_build_object('type', 'bool', 'value', community_row.real_catalog_active),
                    jsonb_build_object('type', 'text', 'length', length(community_row.real_catalog_fingerprint), 'value', community_row.real_catalog_fingerprint)
                )::text,
                E'\n' ORDER BY community_row.id
            )
            FROM communities community_row
            WHERE community_row.real_catalog_key IS NOT NULL
        ), ''), 'sha256'), 'hex') AS community_roots_sha256,
        encode(digest(COALESCE((
            SELECT string_agg(edge_value, E'\n' ORDER BY edge_value)
            FROM (
                SELECT jsonb_build_array(
                    jsonb_build_object('type', 'text', 'length', length('community-tag'), 'value', 'community-tag'),
                    jsonb_build_object('type', 'int8', 'value', community_id),
                    jsonb_build_object('type', 'int8', 'value', tag_id)
                )::text AS edge_value
                FROM community_tags
                UNION ALL
                SELECT jsonb_build_array(
                    jsonb_build_object('type', 'text', 'length', length('community-subscriber'), 'value', 'community-subscriber'),
                    jsonb_build_object('type', 'int8', 'value', community_id),
                    jsonb_build_object('type', 'int8', 'value', user_id)
                )::text
                FROM community_subscribers
                UNION ALL
                SELECT jsonb_build_array(
                    jsonb_build_object('type', 'text', 'length', length('meeting-tag'), 'value', 'meeting-tag'),
                    jsonb_build_object('type', 'int8', 'value', meeting_id),
                    jsonb_build_object('type', 'int8', 'value', tag_id)
                )::text
                FROM meeting_tags
                UNION ALL
                SELECT jsonb_build_array(
                    jsonb_build_object('type', 'text', 'length', length('meeting-participant'), 'value', 'meeting-participant'),
                    jsonb_build_object('type', 'int8', 'value', meeting_id),
                    jsonb_build_object('type', 'int8', 'value', user_id)
                )::text
                FROM meeting_participants
            ) edges
        ), ''), 'sha256'), 'hex') AS relationship_edges_sha256
),
validity AS (
    SELECT
        (SELECT valid FROM flyway_check) AS flyway,
        (SELECT required_tables_and_columns FROM schema_checks) AS schema,
        (SELECT exact_required_table_count FROM schema_checks) AS tables,
        (SELECT required_indexes FROM schema_checks) AS indexes,
        (SELECT required_constraints AND validated_constraints FROM schema_checks) AS constraints,
        (SELECT user_interest_orphans + community_tag_orphans + subscriber_orphans +
                    meeting_tag_orphans + participant_orphans + ad_community_orphans + ad_user_orphans +
                    user_social_media_orphans + person_host_orphans + community_host_orphans = 0
                AND duplicate_source_keys + duplicate_edge_rows = 0
             FROM relationship_checks) AS relationships,
        (SELECT invalid_refresh_hashes + invalid_otp_rows + invalid_identity_rows +
                    identity_user_orphans + duplicate_identity_rows = 0
             FROM auth_checks) AS auth,
        (SELECT state_rows <= 1
                    AND matching_state_rows = state_rows
                    AND ownership_key_violations = 0
                    AND ownership_type_violations = 0
                    AND (
                        (state_rows = 0
                         AND owned_users = 0
                         AND owned_communities = 0
                         AND owned_meetings = 0
                         AND owned_tags = 0
                         AND owned_ad_blocks = 0)
                        OR
                        (state_rows = 1
                         AND owned_users = 6
                         AND owned_communities = 3
                         AND owned_meetings = 6
                         AND owned_tags = 6
                         AND owned_ad_blocks = 3)
                    )
             FROM demo_checks) AS demo_catalog,
        (SELECT null_required_references + unsafe_managed_references = 0 FROM media_checks) AS media_references,
        (SELECT state_rows <= 1
                    AND (state_rows > 0 OR revision_rows = 0)
                    AND manifest_hash_violations = 0
                    AND predecessor_violations = 0
                    AND state_violations = 0
                    AND snapshot_violations = 0
                    AND snapshot_root_linkage_violations = 0
                    AND meeting_ownership_violations = 0
                    AND community_ownership_violations = 0
                    AND source_identity_violations = 0
                    AND correction_violations = 0
                FROM real_catalog_checks) AS real_catalog
),
validity_summary AS (
    SELECT validity.*,
        flyway AND schema AND tables AND indexes AND constraints AND relationships AND auth AND
            demo_catalog AND media_references AND real_catalog AS valid
    FROM validity
),
proof_document AS (
    SELECT jsonb_build_object(
        'schema', 'meet-backend/closed-beta-database-proof/v2',
        'valid', (SELECT valid FROM validity_summary),
        'validity', jsonb_build_object(
            'flyway', (SELECT flyway FROM validity),
            'schema', (SELECT schema FROM validity),
            'tables', (SELECT tables FROM validity),
            'indexes', (SELECT indexes FROM validity),
            'constraints', (SELECT constraints FROM validity),
            'relationships', (SELECT relationships FROM validity),
            'auth', (SELECT auth FROM validity),
            'demoCatalog', (SELECT demo_catalog FROM validity),
            'mediaReferences', (SELECT media_references FROM validity),
            'realCatalog', (SELECT real_catalog FROM validity)
        ),
        'flyway', jsonb_build_object(
            'successfulVersionCount', (SELECT count(*) FROM flyway_schema_history WHERE success),
            'orderedV1ToV11', (SELECT valid FROM flyway_check)
        ),
        'schemaChecks', jsonb_build_object(
            'requiredTablesAndColumns', (SELECT required_tables_and_columns FROM schema_checks),
            'requiredTableCount', 21,
            'exactRequiredTableCount', (SELECT exact_required_table_count FROM schema_checks),
            'requiredIndexes', (SELECT required_indexes FROM schema_checks),
            'requiredConstraints', (SELECT required_constraints FROM schema_checks),
            'validatedConstraints', (SELECT validated_constraints FROM schema_checks),
            'legacyPlaintextColumnsAbsent', (SELECT legacy_plaintext_columns_absent FROM schema_checks)
        ),
        'rows', (SELECT value FROM table_counts),
        'realCatalog', jsonb_build_object(
            'stateRows', (SELECT state_rows FROM real_catalog_checks),
            'revisionRows', (SELECT revision_rows FROM real_catalog_checks),
            'manifestHashViolations', (SELECT manifest_hash_violations FROM real_catalog_checks),
            'predecessorViolations', (SELECT predecessor_violations FROM real_catalog_checks),
            'stateViolations', (SELECT state_violations FROM real_catalog_checks),
            'snapshotViolations', (SELECT snapshot_violations FROM real_catalog_checks),
            'snapshotRootLinkageViolations', (SELECT snapshot_root_linkage_violations FROM real_catalog_checks),
            'meetingOwnershipViolations', (SELECT meeting_ownership_violations FROM real_catalog_checks),
            'communityOwnershipViolations', (SELECT community_ownership_violations FROM real_catalog_checks),
            'sourceIdentityViolations', (SELECT source_identity_violations FROM real_catalog_checks),
            'correctionViolations', (SELECT correction_violations FROM real_catalog_checks),
            'meetingRootsSha256', (SELECT meeting_roots_sha256 FROM catalog_commitments),
            'communityRootsSha256', (SELECT community_roots_sha256 FROM catalog_commitments),
            'relationshipEdgesSha256', (SELECT relationship_edges_sha256 FROM catalog_commitments)
        ),
        'relationships', jsonb_build_object(
            'userInterests', (SELECT count(*) FROM user_interests),
            'communityTags', (SELECT count(*) FROM community_tags),
            'communitySubscribers', (SELECT count(*) FROM community_subscribers),
            'meetingTags', (SELECT count(*) FROM meeting_tags),
            'meetingParticipants', (SELECT count(*) FROM meeting_participants),
            'adBlockCommunities', (SELECT count(*) FROM ad_block_communities),
            'adBlockUsers', (SELECT count(*) FROM ad_block_users),
            'orphanRows', (SELECT user_interest_orphans + community_tag_orphans + subscriber_orphans +
                                  meeting_tag_orphans + participant_orphans + ad_community_orphans + ad_user_orphans +
                                  user_social_media_orphans + person_host_orphans + community_host_orphans
                           FROM relationship_checks),
            'duplicateSourceKeys', (SELECT duplicate_source_keys FROM relationship_checks),
            'duplicateEdgeRows', (SELECT duplicate_edge_rows FROM relationship_checks)
        ),
        'authStorage', jsonb_build_object(
            'invalidRefreshHashes', (SELECT invalid_refresh_hashes FROM auth_checks),
            'invalidOtpRows', (SELECT invalid_otp_rows FROM auth_checks),
            'invalidIdentityRows', (SELECT invalid_identity_rows FROM auth_checks),
            'identityUserOrphans', (SELECT identity_user_orphans FROM auth_checks),
            'blankIdentityRows', (SELECT count(*) FROM auth_identities WHERE btrim(normalized_identifier) = ''),
            'duplicateIdentityRows', (SELECT duplicate_identity_rows FROM auth_checks),
            'legacyPlaintextColumnsAbsent', (SELECT legacy_plaintext_columns_absent FROM schema_checks)
        ),
        'demoCatalog', jsonb_build_object(
            'stateRows', (SELECT state_rows FROM demo_checks),
            'matchingStateRows', (SELECT matching_state_rows FROM demo_checks),
            'stateCoherent', (SELECT demo_catalog FROM validity),
            'ownershipKeyViolations', (SELECT ownership_key_violations FROM demo_checks),
            'ownershipTypeViolations', (SELECT ownership_type_violations FROM demo_checks)
        ),
        'mediaReferences', jsonb_build_object(
            'nullRequiredReferences', (SELECT null_required_references FROM media_checks),
            'managedReferences', (SELECT managed_references FROM media_checks),
            'unsafeManagedReferences', (SELECT unsafe_managed_references FROM media_checks)
        )
    ) AS proof
)
SELECT proof::text
FROM proof_document
WHERE (SELECT valid FROM validity_summary);
