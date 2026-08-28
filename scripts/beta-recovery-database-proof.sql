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
        ('otp_rate_limit_attempts'), ('auth_identities'), ('demo_catalog_state')
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
         ARRAY['demo_catalog_key']::text[])
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
        ('demo_catalog_state_pkey')
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
          AND actual.table_type = 'BASE TABLE') = 19
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
               AND column_name = 'ends_at') = 1 AS required_tables_and_columns,
        (SELECT count(*)
         FROM information_schema.tables
         WHERE table_schema = current_schema()
           AND table_type = 'BASE TABLE'
           AND table_name <> 'flyway_schema_history') = 19 AS exact_required_table_count,
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
        count(*) FILTER (WHERE success) = 9
        AND count(*) FILTER (WHERE NOT success) = 0
        AND array_agg(version ORDER BY installed_rank)
            FILTER (WHERE success) = ARRAY['1', '2', '3', '4', '5', '6', '7', '8', '9']::varchar[]
        AND array_agg(installed_rank ORDER BY installed_rank)
            FILTER (WHERE success) = ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 9]::integer[]
        AND count(*) FILTER (WHERE success AND type = 'SQL') = 9
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
        (SELECT null_required_references + unsafe_managed_references = 0 FROM media_checks) AS media_references
),
validity_summary AS (
    SELECT validity.*,
        flyway AND schema AND tables AND indexes AND constraints AND relationships AND auth AND
            demo_catalog AND media_references AS valid
    FROM validity
),
proof_document AS (
    SELECT jsonb_build_object(
        'schema', 'meet-backend/closed-beta-database-proof/v1',
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
            'mediaReferences', (SELECT media_references FROM validity)
        ),
        'flyway', jsonb_build_object(
            'successfulVersionCount', (SELECT count(*) FROM flyway_schema_history WHERE success),
            'orderedV1ToV9', (SELECT valid FROM flyway_check)
        ),
        'schemaChecks', jsonb_build_object(
            'requiredTablesAndColumns', (SELECT required_tables_and_columns FROM schema_checks),
            'requiredTableCount', 19,
            'exactRequiredTableCount', (SELECT exact_required_table_count FROM schema_checks),
            'requiredIndexes', (SELECT required_indexes FROM schema_checks),
            'requiredConstraints', (SELECT required_constraints FROM schema_checks),
            'validatedConstraints', (SELECT validated_constraints FROM schema_checks),
            'legacyPlaintextColumnsAbsent', (SELECT legacy_plaintext_columns_absent FROM schema_checks)
        ),
        'rows', (SELECT value FROM table_counts),
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
