-- Read-only, transient database projection of the established anonymous public DTOs.
-- The projection is hashed for equality during admission and is never retained.
WITH
expected_tags(demo_catalog_key, id, text) AS (
    VALUES
        ('closed-beta-demo/tag/networking', 1::bigint, '[ДЕМО] Нетворкинг'),
        ('closed-beta-demo/tag/walks', 2::bigint, '[ДЕМО] Прогулки'),
        ('closed-beta-demo/tag/board-games', 3::bigint, '[ДЕМО] Настольные игры'),
        ('closed-beta-demo/tag/public-speaking', 4::bigint, '[ДЕМО] Публичные выступления'),
        ('closed-beta-demo/tag/organizing', 5::bigint, '[ДЕМО] Организация встреч'),
        ('closed-beta-demo/tag/online', 6::bigint, '[ДЕМО] Онлайн')
),
expected_users(demo_catalog_key, id, name, surname, image_url, bio, interests) AS (
    VALUES
        ('closed-beta-demo/user/01', 2::bigint, '[ДЕМО] Анна', 'Волкова', 'https://api.whysoezzy.online/demo-assets/v1/avatar-01.png', 'Организует дружелюбные встречи для новых знакомств.', ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/organizing']),
        ('closed-beta-demo/user/02', 3::bigint, '[ДЕМО] Михаил', 'Орлов', 'https://api.whysoezzy.online/demo-assets/v1/avatar-02.png', 'Любит городские прогулки и открывать новые места Москвы.', ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/walks']),
        ('closed-beta-demo/user/03', 4::bigint, '[ДЕМО] Елена', 'Соколова', 'https://api.whysoezzy.online/demo-assets/v1/avatar-03.png', 'Помогает уверенно выступать и знакомиться с людьми.', ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/public-speaking']),
        ('closed-beta-demo/user/04', 5::bigint, '[ДЕМО] Павел', 'Морозов', 'https://api.whysoezzy.online/demo-assets/v1/avatar-04.png', 'Собирает компании для современных настольных игр.', ARRAY['closed-beta-demo/tag/board-games','closed-beta-demo/tag/networking']),
        ('closed-beta-demo/user/05', 6::bigint, '[ДЕМО] Софья', 'Лебедева', 'https://api.whysoezzy.online/demo-assets/v1/avatar-05.png', 'Проводит полезные и спокойные онлайн-встречи.', ARRAY['closed-beta-demo/tag/online','closed-beta-demo/tag/organizing']),
        ('closed-beta-demo/user/06', 7::bigint, '[ДЕМО] Илья', 'Кузнецов', 'https://api.whysoezzy.online/demo-assets/v1/avatar-06.png', 'Участник демонстрационного каталога закрытой беты.', ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/online'])
),
expected_communities(demo_catalog_key, id, name, description, image_url, subscriber_count, tags, subscribers) AS (
    VALUES
        ('closed-beta-demo/community/moscow-meets', 1::bigint, '[ДЕМО] Москва знакомится', 'Демонстрационное сообщество закрытой беты для дружелюбных знакомств и небольших встреч в Москве.', 'https://api.whysoezzy.online/demo-assets/v1/community-moscow.png', 3, ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/organizing'], ARRAY['closed-beta-demo/user/01','closed-beta-demo/user/03','closed-beta-demo/user/06']),
        ('closed-beta-demo/community/city-walks', 2::bigint, '[ДЕМО] Городские прогулки', 'Демонстрационные прогулки по известным местам Москвы в небольшой компании.', 'https://api.whysoezzy.online/demo-assets/v1/community-walks.png', 3, ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/walks'], ARRAY['closed-beta-demo/user/02','closed-beta-demo/user/04','closed-beta-demo/user/06']),
        ('closed-beta-demo/community/online-club', 3::bigint, '[ДЕМО] Онлайн-клуб встреч', 'Демонстрационное сообщество для открытых онлайн-встреч без приватных ссылок в каталоге.', 'https://api.whysoezzy.online/demo-assets/v1/community-online.png', 3, ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/online','closed-beta-demo/tag/organizing'], ARRAY['closed-beta-demo/user/01','closed-beta-demo/user/05','closed-beta-demo/user/06'])
),
expected_meetings(
    demo_catalog_key, id, image_url, title, description, time_ms, date_text, address,
    latitude, longitude, capacity, external_url, is_online, person_host_key, community_host_key,
    tags, participants
) AS (
    VALUES
        ('closed-beta-demo/meeting/welcome', 1::bigint, 'https://api.whysoezzy.online/demo-assets/v1/meeting-moscow.png', '[ДЕМО] Знакомство с клубом', 'Демонстрационная встреча для знакомства с приложением и участниками закрытой беты.', 1790006400000::bigint, '21.09.2026', 'Москва, Тверская улица, 13', 55.7647::double precision, 37.6054::double precision, 40, NULL::text, false, 'closed-beta-demo/user/01', 'closed-beta-demo/community/moscow-meets', ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/organizing'], ARRAY['closed-beta-demo/user/02','closed-beta-demo/user/03','closed-beta-demo/user/06']),
        ('closed-beta-demo/meeting/organize-online', 2::bigint, 'https://api.whysoezzy.online/demo-assets/v1/meeting-online.png', '[ДЕМО] Как организовать онлайн-встречу', 'Демонстрационный разбор подготовки понятной и безопасной онлайн-встречи.', 1790269200000::bigint, '24.09.2026', 'Онлайн', 55.7558::double precision, 37.6176::double precision, 100, 'https://api.whysoezzy.online/demo-events/organize-online', true, 'closed-beta-demo/user/05', 'closed-beta-demo/community/online-club', ARRAY['closed-beta-demo/tag/online','closed-beta-demo/tag/organizing'], ARRAY['closed-beta-demo/user/01','closed-beta-demo/user/03','closed-beta-demo/user/06']),
        ('closed-beta-demo/meeting/board-games', 3::bigint, 'https://api.whysoezzy.online/demo-assets/v1/meeting-moscow.png', '[ДЕМО] Вечер настольных игр', 'Демонстрационный игровой вечер для небольшой компании и проверки записи на встречу.', 1790613000000::bigint, '28.09.2026', 'Москва, улица Новый Арбат, 21', 55.7522::double precision, 37.5866::double precision, 36, NULL::text, false, 'closed-beta-demo/user/04', 'closed-beta-demo/community/moscow-meets', ARRAY['closed-beta-demo/tag/board-games','closed-beta-demo/tag/networking'], ARRAY['closed-beta-demo/user/02','closed-beta-demo/user/05','closed-beta-demo/user/06']),
        ('closed-beta-demo/meeting/vdnkh-walk', 4::bigint, 'https://api.whysoezzy.online/demo-assets/v1/meeting-moscow.png', '[ДЕМО] Прогулка по ВДНХ', 'Демонстрационная прогулка по ВДНХ с понятной точкой сбора и ограниченной группой.', 1791187200000::bigint, '05.10.2026', 'Москва, проспект Мира, 119', 55.8298::double precision, 37.6339::double precision, 30, NULL::text, false, 'closed-beta-demo/user/02', 'closed-beta-demo/community/city-walks', ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/walks'], ARRAY['closed-beta-demo/user/01','closed-beta-demo/user/04','closed-beta-demo/user/06']),
        ('closed-beta-demo/meeting/networking-online', 5::bigint, 'https://api.whysoezzy.online/demo-assets/v1/meeting-online.png', '[ДЕМО] Нетворкинг без неловкости', 'Демонстрационная онлайн-встреча с короткими знакомствами и безопасным публичным описанием.', 1791478800000::bigint, '08.10.2026', 'Онлайн', 55.7558::double precision, 37.6176::double precision, 100, 'https://api.whysoezzy.online/demo-events/networking-online', true, 'closed-beta-demo/user/03', 'closed-beta-demo/community/online-club', ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/online'], ARRAY['closed-beta-demo/user/01','closed-beta-demo/user/02','closed-beta-demo/user/05']),
        ('closed-beta-demo/meeting/public-speaking', 6::bigint, 'https://api.whysoezzy.online/demo-assets/v1/meeting-moscow.png', '[ДЕМО] Практикум по публичным выступлениям', 'Демонстрационный практикум с короткими выступлениями и бережной обратной связью.', 1791993600000::bigint, '14.10.2026', 'Москва, улица Покровка, 47', 55.7641::double precision, 37.6527::double precision, 50, NULL::text, false, 'closed-beta-demo/user/03', 'closed-beta-demo/community/moscow-meets', ARRAY['closed-beta-demo/tag/networking','closed-beta-demo/tag/public-speaking'], ARRAY['closed-beta-demo/user/01','closed-beta-demo/user/04','closed-beta-demo/user/06'])
),
expected_ads(demo_catalog_key, id, type, title, description, action_text, action_url, communities, users) AS (
    VALUES
        ('closed-beta-demo/ad/communities', 1::bigint, 'COMMUNITIES', '[ДЕМО] Сообщества для старта', 'Выберите демонстрационное сообщество и проверьте подписку в закрытой бете.', NULL::text, NULL::text, ARRAY['closed-beta-demo/community/city-walks','closed-beta-demo/community/moscow-meets','closed-beta-demo/community/online-club'], ARRAY[]::text[]),
        ('closed-beta-demo/ad/interests', 2::bigint, 'TEXT', '[ДЕМО] Настройте интересы', 'Выберите интересы, чтобы проверить персонализацию демонстрационного каталога.', 'Выбрать интересы', '/profile/interests', ARRAY[]::text[], ARRAY[]::text[]),
        ('closed-beta-demo/ad/people', 3::bigint, 'PEOPLE', '[ДЕМО] Люди со схожими интересами', 'Откройте демонстрационные профили участников закрытой беты.', NULL::text, NULL::text, ARRAY[]::text[], ARRAY['closed-beta-demo/user/01','closed-beta-demo/user/02','closed-beta-demo/user/03','closed-beta-demo/user/05'])
),
meeting_projection AS (
    SELECT jsonb_build_object(
        'id', m.id,
        'imageUrl', m.image_url,
        'title', m.title,
        'description', m.description,
        'time', m.time,
        'date', m.date,
        'address', jsonb_build_object('address', m.address, 'latitude', m.latitude, 'longitude', m.longitude),
        'capacity', m.capacity,
        'tags', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', t.id, 'text', t.text) ORDER BY t.id)
            FROM meeting_tags r JOIN tags t ON t.id = r.tag_id
            WHERE r.meeting_id = m.id
        ), '[]'::jsonb),
        'personHost', (
            SELECT jsonb_build_object('id', u.id, 'name', u.name, 'surname', u.surname,
                                      'description', u.bio, 'imageUrl', COALESCE(u.avatar_url, ''))
            FROM users u WHERE u.id = m.person_host_id
        ),
        'communityHost', (
            SELECT jsonb_build_object(
                'id', c.id, 'title', c.name, 'description', c.description, 'imageUrl', c.image_url,
                'meetingsInfo', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object('id', cm.id, 'title', cm.title,
                                                        'imageUrl', cm.image_url, 'date', cm.date)
                                     ORDER BY cm.id)
                    FROM meetings cm
                    WHERE cm.community_host_id = c.id AND cm.status = 'ACTIVE'
                ), '[]'::jsonb)
            )
            FROM communities c WHERE c.id = m.community_host_id
        ),
        'participants', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'surname', u.surname,
                                                'imageUrl', COALESCE(u.avatar_url, '')) ORDER BY u.id)
            FROM meeting_participants r JOIN users u ON u.id = r.user_id
            WHERE r.meeting_id = m.id
        ), '[]'::jsonb),
        'meetingStatus', m.status,
        'isUserInParticipants', false,
        'source', m.source,
        'externalUrl', m.external_url,
        'isOnline', m.is_online
    ) AS value, m.id
    FROM meetings m
    WHERE m.demo_catalog_key LIKE 'closed-beta-demo/%'
),
community_projection AS (
    SELECT jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'description', c.description,
        'imageUrl', c.image_url,
        'subscribersCount', (SELECT count(*) FROM community_subscribers r WHERE r.community_id = c.id),
        'isSubscribed', false,
        'tags', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', t.id, 'text', t.text) ORDER BY t.id)
            FROM community_tags r JOIN tags t ON t.id = r.tag_id
            WHERE r.community_id = c.id
        ), '[]'::jsonb)
    ) AS value, c.id
    FROM communities c
    WHERE c.demo_catalog_key LIKE 'closed-beta-demo/%'
),
tags_projection AS (
    SELECT jsonb_build_object(
        'success', true,
        'data', COALESCE(jsonb_agg(jsonb_build_object('id', id, 'text', text) ORDER BY id), '[]'::jsonb),
        'message', NULL::text,
        'error', NULL::jsonb
    ) AS value
    FROM tags
    WHERE demo_catalog_key LIKE 'closed-beta-demo/%'
),
ad_projection AS (
    SELECT jsonb_build_object(
        'type', a.type,
        'id', a.id,
        'isActive', a.is_active,
        'title', a.title,
        'description', a.description,
        'communities', CASE WHEN a.type = 'COMMUNITIES' THEN COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', c.id, 'name', c.name, 'description', c.description,
                'imageUrl', c.image_url,
                'subscribersCount', (SELECT count(*) FROM community_subscribers cs WHERE cs.community_id = c.id)
            ) ORDER BY c.id)
            FROM ad_block_communities r JOIN communities c ON c.id = r.community_id
            WHERE r.ad_block_id = a.id
        ), '[]'::jsonb) ELSE NULL::jsonb END,
        'actionText', a.action_text,
        'actionUrl', a.action_url,
        'users', CASE WHEN a.type = 'PEOPLE' THEN COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', u.id, 'name', u.name, 'surname', u.surname,
                'avatarUrl', COALESCE(u.avatar_url, ''), 'bio', u.bio,
                'role', COALESCE(u.role, 'Не указано')
            ) ORDER BY u.id)
            FROM ad_block_users r JOIN users u ON u.id = r.user_id
            WHERE r.ad_block_id = a.id
        ), '[]'::jsonb) ELSE NULL::jsonb END
    ) AS value, a.id
    FROM ad_blocks a
    WHERE a.demo_catalog_key LIKE 'closed-beta-demo/%' AND a.is_active
),
validity AS (
    SELECT
        (SELECT count(*) FROM expected_tags) = (SELECT count(*) FROM tags WHERE demo_catalog_key LIKE 'closed-beta-demo/%')
        AND NOT EXISTS (
            SELECT 1
            FROM expected_tags e
            LEFT JOIN tags t ON t.demo_catalog_key = e.demo_catalog_key
            WHERE t.id IS NULL OR t.id <> e.id OR t.text <> e.text
        )
        AND NOT EXISTS (
            SELECT 1 FROM tags t
            WHERE t.demo_catalog_key LIKE 'closed-beta-demo/%'
              AND NOT EXISTS (SELECT 1 FROM expected_tags e WHERE e.demo_catalog_key = t.demo_catalog_key)
        ) AS tags_ok,
        (SELECT count(*) FROM expected_users) = (SELECT count(*) FROM users WHERE demo_catalog_key LIKE 'closed-beta-demo/%')
        AND NOT EXISTS (
            SELECT 1
            FROM expected_users e
            LEFT JOIN users u ON u.demo_catalog_key = e.demo_catalog_key
            WHERE u.id IS NULL OR u.id <> e.id OR u.name <> e.name OR u.surname <> e.surname
               OR u.avatar_url IS DISTINCT FROM e.image_url OR u.bio <> e.bio
               OR COALESCE((
                   SELECT array_agg(t.demo_catalog_key ORDER BY t.demo_catalog_key)::text[]
                   FROM user_interests r JOIN tags t ON t.id = r.tag_id
                   WHERE r.user_id = u.id
               ), ARRAY[]::text[]) IS DISTINCT FROM e.interests
        )
        AND NOT EXISTS (
            SELECT 1 FROM users u
            WHERE u.demo_catalog_key LIKE 'closed-beta-demo/%'
              AND NOT EXISTS (SELECT 1 FROM expected_users e WHERE e.demo_catalog_key = u.demo_catalog_key)
        ) AS users_ok,
        (SELECT count(*) FROM expected_communities) = (SELECT count(*) FROM communities WHERE demo_catalog_key LIKE 'closed-beta-demo/%')
        AND NOT EXISTS (
            SELECT 1
            FROM expected_communities e
            LEFT JOIN communities c ON c.demo_catalog_key = e.demo_catalog_key
            WHERE c.id IS NULL OR c.id <> e.id OR c.name <> e.name OR c.description <> e.description
               OR c.image_url <> e.image_url
               OR (SELECT count(*) FROM community_subscribers r WHERE r.community_id = c.id) <> e.subscriber_count
               OR COALESCE((
                   SELECT array_agg(t.demo_catalog_key ORDER BY t.demo_catalog_key)::text[]
                   FROM community_tags r JOIN tags t ON t.id = r.tag_id
                   WHERE r.community_id = c.id
               ), ARRAY[]::text[]) IS DISTINCT FROM e.tags
               OR COALESCE((
                   SELECT array_agg(u.demo_catalog_key ORDER BY u.demo_catalog_key)::text[]
                   FROM community_subscribers r JOIN users u ON u.id = r.user_id
                   WHERE r.community_id = c.id
               ), ARRAY[]::text[]) IS DISTINCT FROM e.subscribers
        ) AS communities_ok,
        (SELECT count(*) FROM expected_meetings) = (SELECT count(*) FROM meetings WHERE demo_catalog_key LIKE 'closed-beta-demo/%')
        AND NOT EXISTS (
            SELECT 1
            FROM expected_meetings e
            LEFT JOIN meetings m ON m.demo_catalog_key = e.demo_catalog_key
            LEFT JOIN users host ON host.id = m.person_host_id
            LEFT JOIN communities community ON community.id = m.community_host_id
            WHERE m.id IS NULL OR m.id <> e.id OR m.image_url <> e.image_url OR m.title <> e.title
               OR m.description <> e.description OR m.time <> e.time_ms OR m.date <> e.date_text
               OR m.address <> e.address OR m.latitude <> e.latitude OR m.longitude <> e.longitude
               OR m.capacity <> e.capacity OR m.status <> 'ACTIVE' OR m.source <> 'MANUAL'
               OR m.external_url IS DISTINCT FROM e.external_url OR m.is_online <> e.is_online
               OR host.demo_catalog_key IS DISTINCT FROM e.person_host_key
               OR community.demo_catalog_key IS DISTINCT FROM e.community_host_key
               OR COALESCE(m.ends_at, m.time) < (extract(epoch FROM CURRENT_TIMESTAMP) * 1000)::bigint
               OR COALESCE((
                   SELECT array_agg(t.demo_catalog_key ORDER BY t.demo_catalog_key)::text[]
                   FROM meeting_tags r JOIN tags t ON t.id = r.tag_id
                   WHERE r.meeting_id = m.id
               ), ARRAY[]::text[]) IS DISTINCT FROM e.tags
               OR COALESCE((
                   SELECT array_agg(u.demo_catalog_key ORDER BY u.demo_catalog_key)::text[]
                   FROM meeting_participants r JOIN users u ON u.id = r.user_id
                   WHERE r.meeting_id = m.id
               ), ARRAY[]::text[]) IS DISTINCT FROM e.participants
               OR COALESCE((
                   SELECT array_agg(cm.demo_catalog_key ORDER BY cm.id)::text[]
                   FROM meetings cm
                   WHERE cm.community_host_id = community.id AND cm.status = 'ACTIVE'
               ), ARRAY[]::text[]) IS DISTINCT FROM COALESCE((
                   SELECT array_agg(em.demo_catalog_key ORDER BY em.id)::text[]
                   FROM expected_meetings em
                   WHERE em.community_host_key = e.community_host_key
               ), ARRAY[]::text[])
        ) AS meetings_ok,
        (SELECT count(*) FROM expected_ads) = (SELECT count(*) FROM ad_blocks WHERE demo_catalog_key LIKE 'closed-beta-demo/%' AND is_active)
        AND NOT EXISTS (
            SELECT 1
            FROM expected_ads e
            LEFT JOIN ad_blocks a ON a.demo_catalog_key = e.demo_catalog_key
            WHERE a.id IS NULL OR a.id <> e.id OR a.type <> e.type OR NOT a.is_active
               OR a.title IS DISTINCT FROM e.title OR a.description IS DISTINCT FROM e.description
               OR a.action_text IS DISTINCT FROM e.action_text OR a.action_url IS DISTINCT FROM e.action_url
               OR COALESCE((
                   SELECT array_agg(c.demo_catalog_key ORDER BY c.demo_catalog_key)::text[]
                   FROM ad_block_communities r JOIN communities c ON c.id = r.community_id
                   WHERE r.ad_block_id = a.id
               ), ARRAY[]::text[]) IS DISTINCT FROM e.communities
               OR COALESCE((
                   SELECT array_agg(u.demo_catalog_key ORDER BY u.demo_catalog_key)::text[]
                   FROM ad_block_users r JOIN users u ON u.id = r.user_id
                   WHERE r.ad_block_id = a.id
               ), ARRAY[]::text[]) IS DISTINCT FROM e.users
        ) AS ads_ok,
        (SELECT count(*) FROM meeting_tags r JOIN meetings m ON m.id = r.meeting_id WHERE m.demo_catalog_key LIKE 'closed-beta-demo/%') = 12
        AND (SELECT count(*) FROM meeting_participants r JOIN meetings m ON m.id = r.meeting_id WHERE m.demo_catalog_key LIKE 'closed-beta-demo/%') = 18
        AND (SELECT count(*) FROM community_tags r JOIN communities c ON c.id = r.community_id WHERE c.demo_catalog_key LIKE 'closed-beta-demo/%') = 7
        AND (SELECT count(*) FROM community_subscribers r JOIN communities c ON c.id = r.community_id WHERE c.demo_catalog_key LIKE 'closed-beta-demo/%') = 9
        AND (SELECT count(*) FROM ad_block_communities r JOIN ad_blocks a ON a.id = r.ad_block_id WHERE a.demo_catalog_key LIKE 'closed-beta-demo/%') = 3
        AND (SELECT count(*) FROM ad_block_users r JOIN ad_blocks a ON a.id = r.ad_block_id WHERE a.demo_catalog_key LIKE 'closed-beta-demo/%') = 4
        AND (SELECT count(*) FROM user_interests r JOIN users u ON u.id = r.user_id WHERE u.demo_catalog_key LIKE 'closed-beta-demo/%') = 12 AS relationships_ok
)
SELECT CASE WHEN (SELECT tags_ok AND users_ok AND communities_ok AND meetings_ok AND ads_ok AND relationships_ok FROM validity)
THEN jsonb_build_object(
    'meetings', (SELECT COALESCE(jsonb_agg(value ORDER BY id), '[]'::jsonb) FROM meeting_projection),
    'recommendedCommunities', (SELECT COALESCE(jsonb_agg(value ORDER BY id), '[]'::jsonb) FROM community_projection),
    'tags', (SELECT value FROM tags_projection),
    'ads', (SELECT COALESCE(jsonb_agg(value ORDER BY id), '[]'::jsonb) FROM ad_projection)
)::text ELSE NULL END;
