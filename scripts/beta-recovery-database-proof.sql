-- Read-only, path-free database proof for the closed-beta recovery drill.
-- The result is one canonical PostgreSQL JSONB document.  Keep every value
-- aggregate-only: this output is safe to compare between source and restore.
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
               AND table_name = 'meetings'
               AND column_name = 'ends_at') = 1 AS valid,
        (SELECT count(*)
         FROM pg_class index_class
         JOIN pg_namespace namespace ON namespace.oid = index_class.relnamespace
         WHERE namespace.nspname = current_schema()
           AND index_class.relname IN (
               'uq_meetings_source_external', 'uq_refresh_tokens_token_hash',
               'uq_otp_codes_active', 'idx_otp_codes_expires_id',
               'uq_users_demo_catalog_key', 'uq_communities_demo_catalog_key',
               'uq_meetings_demo_catalog_key', 'uq_tags_demo_catalog_key',
               'uq_ad_blocks_demo_catalog_key'
           )) = 9 AS required_indexes,
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
         ) duplicates) AS duplicate_source_keys
),
auth_checks AS (
    SELECT
        (SELECT count(*) FROM refresh_tokens
         WHERE token_hash !~ '^[0-9a-f]{64}$') AS invalid_refresh_hashes,
        (SELECT count(*) FROM otp_codes
         WHERE octet_length(code_hash) <> 32
            OR octet_length(hash_salt) <> 16
            OR hash_key_id !~ '^[A-Za-z0-9._~-]{1,32}$'
            OR failed_attempts < 0
            OR max_attempts NOT BETWEEN 1 AND 10
            OR failed_attempts > max_attempts) AS invalid_otp_rows,
        (SELECT count(*) FROM auth_identities
         WHERE btrim(normalized_identifier) = '') AS blank_identity_rows,
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
           )) AS ownership_key_violations
),
media_checks AS (
    SELECT
        count(*) FILTER (WHERE image_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%') AS managed_references,
        count(*) FILTER (WHERE image_url LIKE 'https://api.whysoezzy.online/demo-assets/v1/%'
                              AND image_url !~ '^https://api[.]whysoezzy[.]online/demo-assets/v1/[^#?@]+$')
            AS unsafe_managed_references
    FROM (
        SELECT avatar_url AS image_url FROM users WHERE avatar_url IS NOT NULL
        UNION ALL
        SELECT image_url FROM communities
        UNION ALL
        SELECT image_url FROM meetings
    ) media_refs
)
SELECT jsonb_build_object(
    'schema', 'meet-backend/closed-beta-database-proof/v1',
    'flyway', jsonb_build_object(
        'successfulVersionCount', (SELECT count(*) FROM flyway_schema_history WHERE success),
        'orderedV1ToV9', (SELECT valid FROM flyway_check)
    ),
    'schemaChecks', jsonb_build_object(
        'requiredTablesAndColumns', (SELECT valid FROM schema_checks),
        'requiredTableCount', 19,
        'requiredIndexes', (SELECT required_indexes FROM schema_checks),
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
                              person_host_orphans + community_host_orphans
                       FROM relationship_checks),
        'duplicateSourceKeys', (SELECT duplicate_source_keys FROM relationship_checks)
    ),
    'authStorage', jsonb_build_object(
        'invalidRefreshHashes', (SELECT invalid_refresh_hashes FROM auth_checks),
        'invalidOtpRows', (SELECT invalid_otp_rows FROM auth_checks),
        'blankIdentityRows', (SELECT blank_identity_rows FROM auth_checks),
        'duplicateIdentityRows', (SELECT duplicate_identity_rows FROM auth_checks),
        'legacyPlaintextColumnsAbsent', (SELECT legacy_plaintext_columns_absent FROM schema_checks)
    ),
    'demoCatalog', jsonb_build_object(
        'stateRows', (SELECT state_rows FROM demo_checks),
        'matchingStateRows', (SELECT matching_state_rows FROM demo_checks),
        'stateCoherent', (SELECT state_rows = matching_state_rows FROM demo_checks),
        'ownershipKeyViolations', (SELECT ownership_key_violations FROM demo_checks)
    ),
    'mediaReferences', jsonb_build_object(
        'managedReferences', (SELECT managed_references FROM media_checks),
        'unsafeManagedReferences', (SELECT unsafe_managed_references FROM media_checks)
    )
)::text AS proof;
