-- V2__Test_data.sql

-- Tags
INSERT INTO tags (text) VALUES
('Android'), ('Kotlin'), ('Compose'), ('Backend'),
('iOS'), ('UI/UX'), ('DevOps'), ('Data Science'),
('Flutter'), ('React Native'), ('JavaScript'), ('Python');

-- Test user (ID=1)
INSERT INTO users (id, name, surname, phone, email, city, bio, avatar_url) VALUES
(1, 'Тест', 'Пользователь', '+79991234567', 'test@example.com', 'Москва',
 'Android разработчик', 'https://i.pravatar.cc/300?img=1');

-- Communities
INSERT INTO communities (id, name, description, image_url) VALUES
(1, 'Android Developers Moscow', 'Сообщество Android разработчиков Москвы', 
 'https://picsum.photos/400/300?random=1'),
(2, 'Kotlin Users Group', 'Все о Kotlin и современной разработке', 
 'https://picsum.photos/400/300?random=2'),
(3, 'Mobile Design Community', 'UI/UX дизайн для мобильных приложений', 
 'https://picsum.photos/400/300?random=3');

-- Community tags
INSERT INTO community_tags (community_id, tag_id) VALUES
(1, 1), (1, 2),  -- Android Dev: Android, Kotlin
(2, 2), (2, 4),  -- Kotlin UG: Kotlin, Backend
(3, 6);          -- Mobile Design: UI/UX

-- Meetings (time in milliseconds)
INSERT INTO meetings (id, title, description, image_url, time, date, 
                      address, latitude, longitude, capacity, 
                      person_host_id, community_host_id, status) VALUES
(1, 'Jetpack Compose Workshop',
 'Практический воркшоп по созданию UI с Jetpack Compose. Изучим основы декларативного подхода.',
 'https://picsum.photos/800/400?random=1',
 1738339200000, '01.02.2025',
 'Москва, ул. Тверская, 12', 55.7558, 37.6173, 50,
 1, 1, 'ACTIVE'),

(2, 'Kotlin Coroutines Deep Dive',
 'Глубокое погружение в корутины Kotlin. Channels, flows, structured concurrency.',
 'https://picsum.photos/800/400?random=2',
 1738425600000, '02.02.2025',
 'Москва, Красная площадь, 1', 55.7539, 37.6208, 100,
 1, 2, 'ACTIVE'),

(3, 'Clean Architecture in Android',
 'Обсудим применение Clean Architecture в Android. MVVM, MVI, репозитории, use cases.',
 'https://picsum.photos/800/400?random=3',
 1738512000000, '03.02.2025',
 'Москва, ул. Арбат, 25', 55.7520, 37.5954, 75,
 1, 1, 'ACTIVE'),

(4, 'Material Design 3 Best Practices',
 'Новые паттерны Material Design 3 для Android приложений.',
 'https://picsum.photos/800/400?random=4',
 1738598400000, '04.02.2025',
 'Москва, ул. Ленина, 5', 55.7500, 37.6200, 60,
 1, 3, 'ACTIVE'),

(5, 'Kotlin Multiplatform Mobile',
 'Создаем кроссплатформенные приложения с KMM. Практический опыт.',
 'https://picsum.photos/800/400?random=5',
 1738684800000, '05.02.2025',
 'Москва, Парк Культуры', 55.7350, 37.5950, 80,
 1, 2, 'ACTIVE');

-- Meeting tags
INSERT INTO meeting_tags (meeting_id, tag_id) VALUES
(1, 1), (1, 2), (1, 3),  -- Compose
(2, 2), (2, 4),          -- Coroutines
(3, 1), (3, 2), (3, 6),  -- Clean Arch
(4, 1), (4, 6),          -- Material Design
(5, 1), (5, 2), (5, 5);  -- KMM

-- User interests
INSERT INTO user_interests (user_id, tag_id) VALUES
(1, 1), (1, 2), (1, 3);

-- Set sequences
SELECT setval('users_id_seq', 1);
SELECT setval('communities_id_seq', 3);
SELECT setval('meetings_id_seq', 5);
