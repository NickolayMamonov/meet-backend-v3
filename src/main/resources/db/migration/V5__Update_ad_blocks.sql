-- V5__Update_ad_blocks.sql

-- Удаляем старые поля
ALTER TABLE ad_blocks DROP COLUMN IF EXISTS community_id;
ALTER TABLE ad_blocks DROP COLUMN IF EXISTS image_url;
ALTER TABLE ad_blocks DROP COLUMN IF EXISTS background_color;

-- Создаём связующие таблицы
CREATE TABLE ad_block_communities (
    ad_block_id BIGINT NOT NULL REFERENCES ad_blocks(id) ON DELETE CASCADE,
    community_id BIGINT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    PRIMARY KEY (ad_block_id, community_id)
);

CREATE TABLE ad_block_users (
    ad_block_id BIGINT NOT NULL REFERENCES ad_blocks(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (ad_block_id, user_id)
);

-- Очистить старые тестовые данные
DELETE FROM ad_blocks;

-- Добавить новые тестовые данные
-- AdBlock #1: Communities (список сообществ)
INSERT INTO ad_blocks (id, type, title, description, is_active) VALUES
(1, 'COMMUNITIES', 'Сообщества для тестировщиков',
 'Присоединяйтесь к сообществам по вашим интересам', true);

INSERT INTO ad_block_communities (ad_block_id, community_id) VALUES
(1, 1), (1, 2), (1, 3);

-- AdBlock #2: Text
INSERT INTO ad_blocks (id, type, title, description, action_text, action_url, is_active) VALUES
(2, 'TEXT',
 'Определите свои интересы',
 'Расскажите нам о ваших увлечениях, и мы подберём встречи специально для вас!',
 'Указать интересы',
 '/profile/interests',
 true);

-- AdBlock #3: People (список пользователей)
INSERT INTO ad_blocks (id, type, title, description, is_active) VALUES
(3, 'PEOPLE', 'Вы можете их знать',
 'Познакомьтесь с людьми со схожими интересами', true);

INSERT INTO ad_block_users (ad_block_id, user_id) VALUES
(3, 1);

-- Обновим bio пользователей чтобы они были ролями
INSERT INTO users (id, name, surname, phone, email, city, bio, avatar_url) VALUES
(2, 'Анна', 'Смирнова', '+79991234568', 'anna@example.com', 'Москва',
 'iOS разработка', 'https://i.pravatar.cc/300?img=2'),
(3, 'Дмитрий', 'Иванов', '+79991234569', 'dmitry@example.com', 'Москва',
 'Backend разработка', 'https://i.pravatar.cc/300?img=3'),
(4, 'Елена', 'Петрова', '+79991234570', 'elena@example.com', 'Москва',
 'UX дизайн', 'https://i.pravatar.cc/300?img=4')
ON CONFLICT (phone) DO UPDATE SET bio = EXCLUDED.bio;

-- Или добавь интересы пользователям
INSERT INTO user_interests (user_id, tag_id) VALUES
(2, 5),  -- iOS
(3, 4),  -- Backend
(4, 6)   -- UI/UX
ON CONFLICT DO NOTHING;

INSERT INTO ad_block_users (ad_block_id, user_id) VALUES
(3, 2), (3, 3), (3, 4);

-- Обновить sequence
SELECT setval('ad_blocks_id_seq', 3);
SELECT setval('users_id_seq', 4);