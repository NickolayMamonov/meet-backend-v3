-- Read-only stable identity proof for the populated closed-beta catalog.
-- The psql caller appends the final LF when comparing this JSONB text with
-- scripts/fixtures/test-vps-beta-demo/canonical-stable-proof.json.
WITH
expected_roots(kind, catalog_key, id, time_ms, date_text, ends_at, person_host, community_host) AS (
    VALUES
        ('tag', 'closed-beta-demo/tag/networking', 1::bigint, NULL::bigint, NULL::text, NULL::bigint, NULL::text, NULL::text),
        ('tag', 'closed-beta-demo/tag/walks', 2::bigint, NULL, NULL, NULL, NULL, NULL),
        ('tag', 'closed-beta-demo/tag/board-games', 3::bigint, NULL, NULL, NULL, NULL, NULL),
        ('tag', 'closed-beta-demo/tag/public-speaking', 4::bigint, NULL, NULL, NULL, NULL, NULL),
        ('tag', 'closed-beta-demo/tag/organizing', 5::bigint, NULL, NULL, NULL, NULL, NULL),
        ('tag', 'closed-beta-demo/tag/online', 6::bigint, NULL, NULL, NULL, NULL, NULL),
        ('user', 'closed-beta-demo/user/01', 2::bigint, NULL, NULL, NULL, NULL, NULL),
        ('user', 'closed-beta-demo/user/02', 3::bigint, NULL, NULL, NULL, NULL, NULL),
        ('user', 'closed-beta-demo/user/03', 4::bigint, NULL, NULL, NULL, NULL, NULL),
        ('user', 'closed-beta-demo/user/04', 5::bigint, NULL, NULL, NULL, NULL, NULL),
        ('user', 'closed-beta-demo/user/05', 6::bigint, NULL, NULL, NULL, NULL, NULL),
        ('user', 'closed-beta-demo/user/06', 7::bigint, NULL, NULL, NULL, NULL, NULL),
        ('community', 'closed-beta-demo/community/moscow-meets', 1::bigint, NULL, NULL, NULL, NULL, NULL),
        ('community', 'closed-beta-demo/community/city-walks', 2::bigint, NULL, NULL, NULL, NULL, NULL),
        ('community', 'closed-beta-demo/community/online-club', 3::bigint, NULL, NULL, NULL, NULL, NULL),
        ('meeting', 'closed-beta-demo/meeting/welcome', 1::bigint, 1790006400000, '21.09.2026', 1790013600000, 'closed-beta-demo/user/01', 'closed-beta-demo/community/moscow-meets'),
        ('meeting', 'closed-beta-demo/meeting/organize-online', 2::bigint, 1790269200000, '24.09.2026', 1790274600000, 'closed-beta-demo/user/05', 'closed-beta-demo/community/online-club'),
        ('meeting', 'closed-beta-demo/meeting/board-games', 3::bigint, 1790613000000, '28.09.2026', 1790622000000, 'closed-beta-demo/user/04', 'closed-beta-demo/community/moscow-meets'),
        ('meeting', 'closed-beta-demo/meeting/vdnkh-walk', 4::bigint, 1791187200000, '05.10.2026', 1791194400000, 'closed-beta-demo/user/02', 'closed-beta-demo/community/city-walks'),
        ('meeting', 'closed-beta-demo/meeting/networking-online', 5::bigint, 1791478800000, '08.10.2026', 1791484200000, 'closed-beta-demo/user/03', 'closed-beta-demo/community/online-club'),
        ('meeting', 'closed-beta-demo/meeting/public-speaking', 6::bigint, 1791993600000, '14.10.2026', 1792000800000, 'closed-beta-demo/user/03', 'closed-beta-demo/community/moscow-meets'),
        ('ad', 'closed-beta-demo/ad/communities', 1::bigint, NULL, NULL, NULL, NULL, NULL),
        ('ad', 'closed-beta-demo/ad/interests', 2::bigint, NULL, NULL, NULL, NULL, NULL),
        ('ad', 'closed-beta-demo/ad/people', 3::bigint, NULL, NULL, NULL, NULL, NULL)
),
expected_relationships(kind, left_key, right_key) AS (
    VALUES
        ('userInterests', 'closed-beta-demo/user/01', 'closed-beta-demo/tag/networking'),
        ('userInterests', 'closed-beta-demo/user/01', 'closed-beta-demo/tag/organizing'),
        ('userInterests', 'closed-beta-demo/user/02', 'closed-beta-demo/tag/networking'),
        ('userInterests', 'closed-beta-demo/user/02', 'closed-beta-demo/tag/walks'),
        ('userInterests', 'closed-beta-demo/user/03', 'closed-beta-demo/tag/networking'),
        ('userInterests', 'closed-beta-demo/user/03', 'closed-beta-demo/tag/public-speaking'),
        ('userInterests', 'closed-beta-demo/user/04', 'closed-beta-demo/tag/board-games'),
        ('userInterests', 'closed-beta-demo/user/04', 'closed-beta-demo/tag/networking'),
        ('userInterests', 'closed-beta-demo/user/05', 'closed-beta-demo/tag/online'),
        ('userInterests', 'closed-beta-demo/user/05', 'closed-beta-demo/tag/organizing'),
        ('userInterests', 'closed-beta-demo/user/06', 'closed-beta-demo/tag/networking'),
        ('userInterests', 'closed-beta-demo/user/06', 'closed-beta-demo/tag/online'),
        ('communityTags', 'closed-beta-demo/community/city-walks', 'closed-beta-demo/tag/networking'),
        ('communityTags', 'closed-beta-demo/community/city-walks', 'closed-beta-demo/tag/walks'),
        ('communityTags', 'closed-beta-demo/community/moscow-meets', 'closed-beta-demo/tag/networking'),
        ('communityTags', 'closed-beta-demo/community/moscow-meets', 'closed-beta-demo/tag/organizing'),
        ('communityTags', 'closed-beta-demo/community/online-club', 'closed-beta-demo/tag/networking'),
        ('communityTags', 'closed-beta-demo/community/online-club', 'closed-beta-demo/tag/online'),
        ('communityTags', 'closed-beta-demo/community/online-club', 'closed-beta-demo/tag/organizing'),
        ('communitySubscribers', 'closed-beta-demo/community/city-walks', 'closed-beta-demo/user/02'),
        ('communitySubscribers', 'closed-beta-demo/community/city-walks', 'closed-beta-demo/user/04'),
        ('communitySubscribers', 'closed-beta-demo/community/city-walks', 'closed-beta-demo/user/06'),
        ('communitySubscribers', 'closed-beta-demo/community/moscow-meets', 'closed-beta-demo/user/01'),
        ('communitySubscribers', 'closed-beta-demo/community/moscow-meets', 'closed-beta-demo/user/03'),
        ('communitySubscribers', 'closed-beta-demo/community/moscow-meets', 'closed-beta-demo/user/06'),
        ('communitySubscribers', 'closed-beta-demo/community/online-club', 'closed-beta-demo/user/01'),
        ('communitySubscribers', 'closed-beta-demo/community/online-club', 'closed-beta-demo/user/05'),
        ('communitySubscribers', 'closed-beta-demo/community/online-club', 'closed-beta-demo/user/06'),
        ('meetingTags', 'closed-beta-demo/meeting/board-games', 'closed-beta-demo/tag/board-games'),
        ('meetingTags', 'closed-beta-demo/meeting/board-games', 'closed-beta-demo/tag/networking'),
        ('meetingTags', 'closed-beta-demo/meeting/networking-online', 'closed-beta-demo/tag/networking'),
        ('meetingTags', 'closed-beta-demo/meeting/networking-online', 'closed-beta-demo/tag/online'),
        ('meetingTags', 'closed-beta-demo/meeting/organize-online', 'closed-beta-demo/tag/online'),
        ('meetingTags', 'closed-beta-demo/meeting/organize-online', 'closed-beta-demo/tag/organizing'),
        ('meetingTags', 'closed-beta-demo/meeting/public-speaking', 'closed-beta-demo/tag/networking'),
        ('meetingTags', 'closed-beta-demo/meeting/public-speaking', 'closed-beta-demo/tag/public-speaking'),
        ('meetingTags', 'closed-beta-demo/meeting/vdnkh-walk', 'closed-beta-demo/tag/networking'),
        ('meetingTags', 'closed-beta-demo/meeting/vdnkh-walk', 'closed-beta-demo/tag/walks'),
        ('meetingTags', 'closed-beta-demo/meeting/welcome', 'closed-beta-demo/tag/networking'),
        ('meetingTags', 'closed-beta-demo/meeting/welcome', 'closed-beta-demo/tag/organizing'),
        ('meetingParticipants', 'closed-beta-demo/meeting/board-games', 'closed-beta-demo/user/02'),
        ('meetingParticipants', 'closed-beta-demo/meeting/board-games', 'closed-beta-demo/user/05'),
        ('meetingParticipants', 'closed-beta-demo/meeting/board-games', 'closed-beta-demo/user/06'),
        ('meetingParticipants', 'closed-beta-demo/meeting/networking-online', 'closed-beta-demo/user/01'),
        ('meetingParticipants', 'closed-beta-demo/meeting/networking-online', 'closed-beta-demo/user/02'),
        ('meetingParticipants', 'closed-beta-demo/meeting/networking-online', 'closed-beta-demo/user/05'),
        ('meetingParticipants', 'closed-beta-demo/meeting/organize-online', 'closed-beta-demo/user/01'),
        ('meetingParticipants', 'closed-beta-demo/meeting/organize-online', 'closed-beta-demo/user/03'),
        ('meetingParticipants', 'closed-beta-demo/meeting/organize-online', 'closed-beta-demo/user/06'),
        ('meetingParticipants', 'closed-beta-demo/meeting/public-speaking', 'closed-beta-demo/user/01'),
        ('meetingParticipants', 'closed-beta-demo/meeting/public-speaking', 'closed-beta-demo/user/04'),
        ('meetingParticipants', 'closed-beta-demo/meeting/public-speaking', 'closed-beta-demo/user/06'),
        ('meetingParticipants', 'closed-beta-demo/meeting/vdnkh-walk', 'closed-beta-demo/user/01'),
        ('meetingParticipants', 'closed-beta-demo/meeting/vdnkh-walk', 'closed-beta-demo/user/04'),
        ('meetingParticipants', 'closed-beta-demo/meeting/vdnkh-walk', 'closed-beta-demo/user/06'),
        ('meetingParticipants', 'closed-beta-demo/meeting/welcome', 'closed-beta-demo/user/02'),
        ('meetingParticipants', 'closed-beta-demo/meeting/welcome', 'closed-beta-demo/user/03'),
        ('meetingParticipants', 'closed-beta-demo/meeting/welcome', 'closed-beta-demo/user/06'),
        ('adBlockCommunities', 'closed-beta-demo/ad/communities', 'closed-beta-demo/community/city-walks'),
        ('adBlockCommunities', 'closed-beta-demo/ad/communities', 'closed-beta-demo/community/moscow-meets'),
        ('adBlockCommunities', 'closed-beta-demo/ad/communities', 'closed-beta-demo/community/online-club'),
        ('adBlockUsers', 'closed-beta-demo/ad/people', 'closed-beta-demo/user/01'),
        ('adBlockUsers', 'closed-beta-demo/ad/people', 'closed-beta-demo/user/02'),
        ('adBlockUsers', 'closed-beta-demo/ad/people', 'closed-beta-demo/user/03'),
        ('adBlockUsers', 'closed-beta-demo/ad/people', 'closed-beta-demo/user/05')
),
actual_roots AS (
    SELECT
        (SELECT jsonb_agg(jsonb_build_array(demo_catalog_key, id) ORDER BY demo_catalog_key)
           FROM tags WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS tags,
        (SELECT jsonb_agg(jsonb_build_array(demo_catalog_key, id) ORDER BY demo_catalog_key)
           FROM users WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS users,
        (SELECT jsonb_agg(jsonb_build_array(demo_catalog_key, id) ORDER BY demo_catalog_key)
           FROM ad_blocks WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS "adBlocks",
        (SELECT jsonb_agg(jsonb_build_array(demo_catalog_key, id, time, date, ends_at,
                    (SELECT demo_catalog_key FROM users WHERE id = m.person_host_id),
                    (SELECT demo_catalog_key FROM communities WHERE id = m.community_host_id)
                ) ORDER BY demo_catalog_key)
           FROM meetings m WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS meetings,
        (SELECT jsonb_agg(jsonb_build_array(demo_catalog_key, id) ORDER BY demo_catalog_key)
           FROM communities WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS communities
),
expected_root_json AS (
    SELECT jsonb_build_object(
        'tags', (SELECT jsonb_agg(jsonb_build_array(catalog_key, id) ORDER BY catalog_key) FROM expected_roots WHERE kind = 'tag'),
        'users', (SELECT jsonb_agg(jsonb_build_array(catalog_key, id) ORDER BY catalog_key) FROM expected_roots WHERE kind = 'user'),
        'adBlocks', (SELECT jsonb_agg(jsonb_build_array(catalog_key, id) ORDER BY catalog_key) FROM expected_roots WHERE kind = 'ad'),
        'meetings', (SELECT jsonb_agg(jsonb_build_array(catalog_key, id, time_ms, date_text, ends_at, person_host, community_host) ORDER BY catalog_key) FROM expected_roots WHERE kind = 'meeting'),
        'communities', (SELECT jsonb_agg(jsonb_build_array(catalog_key, id) ORDER BY catalog_key) FROM expected_roots WHERE kind = 'community')
    ) AS value
),
actual_relationship_json AS (
    SELECT jsonb_build_object(
        'meetingTags', (SELECT jsonb_agg(jsonb_build_array(m.demo_catalog_key, t.demo_catalog_key) ORDER BY m.demo_catalog_key, t.demo_catalog_key) FROM meeting_tags r JOIN meetings m ON m.id = r.meeting_id JOIN tags t ON t.id = r.tag_id WHERE m.demo_catalog_key LIKE 'closed-beta-demo/%'),
        'adBlockUsers', (SELECT jsonb_agg(jsonb_build_array(a.demo_catalog_key, u.demo_catalog_key) ORDER BY a.demo_catalog_key, u.demo_catalog_key) FROM ad_block_users r JOIN ad_blocks a ON a.id = r.ad_block_id JOIN users u ON u.id = r.user_id WHERE a.demo_catalog_key LIKE 'closed-beta-demo/%'),
        'communityTags', (SELECT jsonb_agg(jsonb_build_array(c.demo_catalog_key, t.demo_catalog_key) ORDER BY c.demo_catalog_key, t.demo_catalog_key) FROM community_tags r JOIN communities c ON c.id = r.community_id JOIN tags t ON t.id = r.tag_id WHERE c.demo_catalog_key LIKE 'closed-beta-demo/%'),
        'userInterests', (SELECT jsonb_agg(jsonb_build_array(u.demo_catalog_key, t.demo_catalog_key) ORDER BY u.demo_catalog_key, t.demo_catalog_key) FROM user_interests r JOIN users u ON u.id = r.user_id JOIN tags t ON t.id = r.tag_id WHERE u.demo_catalog_key LIKE 'closed-beta-demo/%'),
        'adBlockCommunities', (SELECT jsonb_agg(jsonb_build_array(a.demo_catalog_key, c.demo_catalog_key) ORDER BY a.demo_catalog_key, c.demo_catalog_key) FROM ad_block_communities r JOIN ad_blocks a ON a.id = r.ad_block_id JOIN communities c ON c.id = r.community_id WHERE a.demo_catalog_key LIKE 'closed-beta-demo/%'),
        'meetingParticipants', (SELECT jsonb_agg(jsonb_build_array(m.demo_catalog_key, u.demo_catalog_key) ORDER BY m.demo_catalog_key, u.demo_catalog_key) FROM meeting_participants r JOIN meetings m ON m.id = r.meeting_id JOIN users u ON u.id = r.user_id WHERE m.demo_catalog_key LIKE 'closed-beta-demo/%'),
        'communitySubscribers', (SELECT jsonb_agg(jsonb_build_array(c.demo_catalog_key, u.demo_catalog_key) ORDER BY c.demo_catalog_key, u.demo_catalog_key) FROM community_subscribers r JOIN communities c ON c.id = r.community_id JOIN users u ON u.id = r.user_id WHERE c.demo_catalog_key LIKE 'closed-beta-demo/%')
    ) AS value
),
expected_relationship_json AS (
    SELECT jsonb_object_agg(kind, values ORDER BY kind) AS value
    FROM (
        SELECT kind, jsonb_agg(jsonb_build_array(left_key, right_key) ORDER BY left_key, right_key) AS values
        FROM expected_relationships
        GROUP BY kind
    ) grouped
),
state AS (
    SELECT *
    FROM demo_catalog_state
    WHERE catalog_name = 'closed-beta-demo'
),
safety AS (
    SELECT
        (SELECT count(*) FROM user_social_media s JOIN users u ON u.id = s.user_id WHERE u.demo_catalog_key LIKE 'closed-beta-demo/%') AS "ownedSocialRows",
        (SELECT count(*) FROM users WHERE demo_catalog_key LIKE 'closed-beta-demo/%' AND (phone IS NOT NULL OR fcm_token IS NOT NULL OR role IS NOT NULL OR deleted_at IS NOT NULL OR auth_version <> 0 OR notifications_enabled)) AS "invalidOwnedUsers",
        (SELECT count(*) FROM refresh_tokens r JOIN users u ON u.id = r.user_id WHERE u.demo_catalog_key LIKE 'closed-beta-demo/%') AS "ownedRefreshTokens",
        (SELECT count(*) FROM expected_roots e LEFT JOIN meetings m ON m.demo_catalog_key = e.catalog_key
          WHERE e.kind = 'meeting' AND (m.id IS NULL OR m.time <> e.time_ms OR m.date <> e.date_text OR m.ends_at <> e.ends_at)) AS "scheduleMismatches",
        (SELECT count(*) FROM auth_identities a JOIN users u ON u.id = a.user_id WHERE u.demo_catalog_key LIKE 'closed-beta-demo/%') AS "ownedAuthIdentities"
),
checks AS (
    SELECT
        (
            SELECT jsonb_build_object(
                'tags', tags,
                'users', users,
                'adBlocks', "adBlocks",
                'meetings', meetings,
                'communities', communities
            )
            FROM actual_roots
        ) = (SELECT value FROM expected_root_json) AS roots_ok,
        (SELECT value FROM actual_relationship_json) = (SELECT value FROM expected_relationship_json) AS relationships_ok,
        (SELECT count(*) FROM state) = 1
            AND (SELECT manifest_version FROM state) = '2026-08-15.v1'
            AND (SELECT schedule_anchor_date FROM state) = DATE '2026-09-14'
            AND (SELECT catalog_valid_through FROM state) = TIMESTAMPTZ '2026-09-14T00:00:00Z' AS state_ok,
        (SELECT count(*) FROM expected_roots WHERE kind = 'tag') = (SELECT count(*) FROM tags WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS tag_count_ok,
        (SELECT count(*) FROM expected_roots WHERE kind = 'user') = (SELECT count(*) FROM users WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS user_count_ok,
        (SELECT count(*) FROM expected_roots WHERE kind = 'community') = (SELECT count(*) FROM communities WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS community_count_ok,
        (SELECT count(*) FROM expected_roots WHERE kind = 'meeting') = (SELECT count(*) FROM meetings WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS meeting_count_ok,
        (SELECT count(*) FROM expected_roots WHERE kind = 'ad') = (SELECT count(*) FROM ad_blocks WHERE demo_catalog_key LIKE 'closed-beta-demo/%') AS ad_count_ok,
        (SELECT count(*) FROM safety WHERE "ownedSocialRows" = 0 AND "invalidOwnedUsers" = 0 AND "ownedRefreshTokens" = 0 AND "scheduleMismatches" = 0 AND "ownedAuthIdentities" = 0) = 1 AS safety_ok
)
SELECT CASE WHEN (
    SELECT bool_and(entries.value::boolean)
    FROM jsonb_each_text(to_jsonb(checks)) AS entries(key, value)
)
    THEN jsonb_build_object(
        'roots', (
            SELECT jsonb_build_object(
                'tags', tags,
                'users', users,
                'adBlocks', "adBlocks",
                'meetings', meetings,
                'communities', communities
            )
            FROM actual_roots
        ),
        'state', jsonb_build_object(
            'catalogName', (SELECT catalog_name FROM state),
            'manifestVersion', (SELECT manifest_version FROM state),
            'scheduleAnchorDate', (SELECT schedule_anchor_date FROM state),
            'catalogValidThrough', to_char(
                (SELECT catalog_valid_through FROM state) AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS"+00:00"'
            )
        ),
        'safety', (SELECT to_jsonb(safety.*) FROM safety),
        'relationships', (SELECT value FROM actual_relationship_json)
    )::text
    ELSE NULL END
FROM checks;
