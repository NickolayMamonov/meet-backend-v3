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

-- Добавляем больше тестовых пользователей (участников встреч)
INSERT INTO users (id, name, surname, phone, email, city, bio, avatar_url) VALUES
(2, 'Анна', 'Иванова', '+79991234568', 'anna.ivanova@example.com', 'Москва', 'UX Designer', 'https://i.pravatar.cc/300?img=2'),
(3, 'Петр', 'Петров', '+79991234569', 'petr.petrov@example.com', 'Москва', 'Android Developer', 'https://i.pravatar.cc/300?img=3'),
(4, 'Мария', 'Сидорова', '+79991234570', 'maria.sidorova@example.com', 'Москва', 'Product Manager', 'https://i.pravatar.cc/300?img=4'),
(5, 'Алексей', 'Козлов', '+79991234571', 'alexey.kozlov@example.com', 'Москва', 'Data Analyst', 'https://i.pravatar.cc/300?img=5'),
(6, 'Ольга', 'Новикова', '+79991234572', 'olga.novikova@example.com', 'Москва', 'QA Engineer', 'https://i.pravatar.cc/300?img=6'),
(7, 'Дмитрий', 'Кузнецов', '+79991234573', 'dmitry.kuznetsov@example.com', 'Москва', 'Backend Dev', 'https://i.pravatar.cc/300?img=7'),
(8, 'Елена', 'Федорова', '+79991234574', 'elena.fedorova@example.com', 'Москва', 'iOS Dev', 'https://i.pravatar.cc/300?img=8'),
(9, 'Максим', 'Орлов', '+79991234575', 'maxim.orlov@example.com', 'Москва', 'DevOps', 'https://i.pravatar.cc/300?img=9'),
(10, 'Наталья', 'Ковалева', '+79991234576', 'natalia.kovaleva@example.com', 'Москва', 'Team Lead', 'https://i.pravatar.cc/300?img=10'),
(11, 'Сергей', 'Морозов', '+79991234577', 'sergey.morozov@example.com', 'Москва', 'Frontend', 'https://i.pravatar.cc/300?img=11'),
(12, 'Татьяна', 'Соколова', '+79991234578', 'tatiana.sokolova@example.com', 'Москва', 'Designer', 'https://i.pravatar.cc/300?img=12'),
(13, 'Владимир', 'Попов', '+79991234579', 'vladimir.popov@example.com', 'Москва', 'Architect', 'https://i.pravatar.cc/300?img=13'),
(14, 'Ирина', 'Лебедева', '+79991234580', 'irina.lebedeva@example.com', 'Москва', 'Scrum Master', 'https://i.pravatar.cc/300?img=14'),
(15, 'Андрей', 'Волков', '+79991234581', 'andrey.volkov@example.com', 'Москва', 'Full Stack', 'https://i.pravatar.cc/300?img=15'),
(16, 'Екатерина', 'Соловьева', '+79991234582', 'ekaterina.solovieva@example.com', 'Москва', 'Content Manager', 'https://i.pravatar.cc/300?img=16'),
(17, 'Николай', 'Васильев', '+79991234583', 'nikolay.vasiliev@example.com', 'Москва', 'ML Engineer', 'https://i.pravatar.cc/300?img=17'),
(18, 'Светлана', 'Павлова', '+79991234584', 'svetlana.pavlova@example.com', 'Москва', 'BA', 'https://i.pravatar.cc/300?img=18'),
(19, 'Игорь', 'Семенов', '+79991234585', 'igor.semenov@example.com', 'Москва', 'Security', 'https://i.pravatar.cc/300?img=19'),
(20, 'Юлия', 'Егорова', '+79991234586', 'yulia.egorova@example.com', 'Москва', 'Recruiter', 'https://i.pravatar.cc/300?img=20')
ON CONFLICT (phone) DO NOTHING;

-- Обновляем последовательность для users
SELECT setval('users_id_seq', (SELECT MAX(id) FROM users));

-- Добавляем участников к встрече #1 (Jetpack Compose Workshop)
INSERT INTO meeting_participants (meeting_id, user_id) VALUES
(1, 2), (1, 3), (1, 4), (1, 5), (1, 6),
(1, 7), (1, 8), (1, 9), (1, 10), (1, 11),
(1, 12), (1, 13), (1, 14), (1, 15)
ON CONFLICT DO NOTHING;

-- Добавляем участников к встрече #2 (Kotlin Coroutines)
INSERT INTO meeting_participants (meeting_id, user_id) VALUES
(2, 2), (2, 4), (2, 6), (2, 8), (2, 10),
(2, 12), (2, 14), (2, 16), (2, 18), (2, 20)
ON CONFLICT DO NOTHING;

-- Добавляем участников к встрече #3 (Clean Architecture)
INSERT INTO meeting_participants (meeting_id, user_id) VALUES
(3, 3), (3, 5), (3, 7), (3, 9), (3, 11),
(3, 13), (3, 15), (3, 17), (3, 19)
ON CONFLICT DO NOTHING;