-- V8__Fix_sequences.sql
-- Тестовые данные (V2, V4) вставлялись с явными id, не через sequence.
-- Сбрасываем все sequences на MAX(id) + 1 чтобы избежать duplicate key при вставке новых записей.

SELECT setval('users_id_seq', COALESCE((SELECT MAX(id) FROM users), 0) + 1, false);
SELECT setval('communities_id_seq', COALESCE((SELECT MAX(id) FROM communities), 0) + 1, false);
SELECT setval('meetings_id_seq', COALESCE((SELECT MAX(id) FROM meetings), 0) + 1, false);
SELECT setval('tags_id_seq', COALESCE((SELECT MAX(id) FROM tags), 0) + 1, false);
SELECT setval('user_social_media_id_seq', COALESCE((SELECT MAX(id) FROM user_social_media), 0) + 1, false);
SELECT setval('ad_blocks_id_seq', COALESCE((SELECT MAX(id) FROM ad_blocks), 0) + 1, false);
