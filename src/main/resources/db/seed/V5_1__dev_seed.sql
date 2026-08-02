-- V5_1__dev_seed.sql  (папка db/seed — подключается ТОЛЬКО в dev-профиле)
-- Тестовые данные для локальной разработки. В default/prod-профиле НЕ выполняется.
-- Консолидировано из бывших V2/V4/V5/V6.

-- =========================== Tags ===========================
INSERT INTO tags (text) VALUES
('Android'), ('Kotlin'), ('Compose'), ('Backend'),
('iOS'), ('UI/UX'), ('DevOps'), ('Data Science'),
('Flutter'), ('React Native'), ('JavaScript'), ('Python');

-- =========================== Users ==========================
INSERT INTO users (id, name, surname, phone, email, city, bio, avatar_url) VALUES
(1, 'Тест', 'Пользователь', '+79991234567', 'test@example.com', 'Москва', 'Android разработчик', 'https://i.pravatar.cc/300?img=1'),
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

-- ======================= Communities ========================
INSERT INTO communities (id, name, description, image_url) VALUES
(1, 'Android Developers Moscow', 'Сообщество Android разработчиков Москвы', 'https://picsum.photos/400/300?random=1'),
(2, 'Kotlin Users Group', 'Все о Kotlin и современной разработке', 'https://picsum.photos/400/300?random=2'),
(3, 'Mobile Design Community', 'UI/UX дизайн для мобильных приложений', 'https://picsum.photos/400/300?random=3');

INSERT INTO community_tags (community_id, tag_id) VALUES
(1, 1), (1, 2),
(2, 2), (2, 4),
(3, 6);

-- ========================= Meetings =========================
INSERT INTO meetings (id, title, description, image_url, time, date,
                      address, latitude, longitude, capacity,
                      person_host_id, community_host_id, status) VALUES
(1, 'Jetpack Compose Workshop', 'Практический воркшоп по созданию UI с Jetpack Compose. Изучим основы декларативного подхода.', 'https://picsum.photos/800/400?random=1', 1738339200000, '01.02.2025', 'Москва, ул. Тверская, 12', 55.7558, 37.6173, 50, 1, 1, 'ACTIVE'),
(2, 'Kotlin Coroutines Deep Dive', 'Глубокое погружение в корутины Kotlin. Channels, flows, structured concurrency.', 'https://picsum.photos/800/400?random=2', 1738425600000, '02.02.2025', 'Москва, Красная площадь, 1', 55.7539, 37.6208, 100, 1, 2, 'ACTIVE'),
(3, 'Clean Architecture in Android', 'Обсудим применение Clean Architecture в Android. MVVM, MVI, репозитории, use cases.', 'https://picsum.photos/800/400?random=3', 1738512000000, '03.02.2025', 'Москва, ул. Арбат, 25', 55.7520, 37.5954, 75, 1, 1, 'ACTIVE'),
(4, 'Material Design 3 Best Practices', 'Новые паттерны Material Design 3 для Android приложений.', 'https://picsum.photos/800/400?random=4', 1738598400000, '04.02.2025', 'Москва, ул. Ленина, 5', 55.7500, 37.6200, 60, 1, 3, 'ACTIVE'),
(5, 'Kotlin Multiplatform Mobile', 'Создаем кроссплатформенные приложения с KMM. Практический опыт.', 'https://picsum.photos/800/400?random=5', 1738684800000, '05.02.2025', 'Москва, Парк Культуры', 55.7350, 37.5950, 80, 1, 2, 'ACTIVE'),
(6, 'Android Performance Optimization', 'Оптимизация производительности Android приложений. Профилирование, memory leaks, ANR.', 'https://picsum.photos/800/400?random=6', 1738771200000, '06.02.2025', 'Москва, ул. Пушкина, 10', 55.7600, 37.6100, 40, 1, 1, 'ACTIVE'),
(7, 'Kotlin Flow Best Practices', 'Работа с Flow в реальных проектах. StateFlow, SharedFlow, операторы.', 'https://picsum.photos/800/400?random=7', 1738857600000, '07.02.2025', 'Москва, Кремлёвская набережная', 55.7520, 37.6230, 55, 1, 2, 'ACTIVE'),
(8, 'Dependency Injection with Koin', 'Внедрение зависимостей в Android. Koin vs Dagger Hilt.', 'https://picsum.photos/800/400?random=8', 1738944000000, '08.02.2025', 'Москва, Театральная площадь', 55.7570, 37.6185, 65, 1, 1, 'ACTIVE'),
(9, 'Mobile UX Design Principles', 'Основы UX дизайна для мобильных приложений.', 'https://picsum.photos/800/400?random=9', 1739030400000, '09.02.2025', 'Москва, ул. Никольская, 15', 55.7575, 37.6220, 50, 1, 3, 'ACTIVE'),
(10, 'Testing Android Apps', 'Unit тесты, UI тесты, интеграционные тесты. JUnit, Espresso, MockK.', 'https://picsum.photos/800/400?random=10', 1739116800000, '10.02.2025', 'Москва, Садовое кольцо, 25', 55.7540, 37.6150, 70, 1, 1, 'ACTIVE'),
(11, 'Modern Android Architecture', 'Современная архитектура: Clean + MVVM + Repository + Use Cases.', 'https://picsum.photos/800/400?random=11', 1739203200000, '11.02.2025', 'Москва, Новый Арбат, 12', 55.7530, 37.5980, 80, 1, 1, 'ACTIVE'),
(12, 'Room Database Deep Dive', 'Работа с Room: миграции, отношения, транзакции, Flow.', 'https://picsum.photos/800/400?random=12', 1739289600000, '12.02.2025', 'Москва, ул. Баумана, 8', 55.7585, 37.6195, 45, 1, 1, 'ACTIVE'),
(13, 'Ktor for Backend Development', 'Создание REST API с Ktor. Routing, serialization, authentication.', 'https://picsum.photos/800/400?random=13', 1739376000000, '13.02.2025', 'Москва, Кутузовский проспект, 30', 55.7420, 37.5450, 60, 1, 2, 'ACTIVE'),
(14, 'Mobile CI/CD with GitHub Actions', 'Настройка CI/CD для Android проектов. Автоматизация сборки и тестирования.', 'https://picsum.photos/800/400?random=14', 1739462400000, '14.02.2025', 'Москва, Лубянская площадь', 55.7590, 37.6285, 50, 1, 1, 'ACTIVE'),
(15, 'Jetpack Navigation Component', 'Навигация в Android приложениях. Safe Args, Deep Links, Bottom Navigation.', 'https://picsum.photos/800/400?random=15', 1739548800000, '15.02.2025', 'Москва, Патриаршие пруды', 55.7645, 37.5935, 55, 1, 1, 'ACTIVE'),
(16, 'WorkManager for Background Tasks', 'Фоновые задачи в Android. WorkManager constraints, chaining, testing.', 'https://picsum.photos/800/400?random=16', 1739635200000, '16.02.2025', 'Москва, Чистые пруды', 55.7650, 37.6380, 40, 1, 1, 'ACTIVE'),
(17, 'Kotlin DSL for Gradle', 'Использование Kotlin DSL в Gradle скриптах.', 'https://picsum.photos/800/400?random=17', 1739721600000, '17.02.2025', 'Москва, Трубная площадь', 55.7670, 37.6220, 45, 1, 2, 'ACTIVE'),
(18, 'Android Security Best Practices', 'Безопасность Android приложений. Шифрование, SSL pinning, ProGuard.', 'https://picsum.photos/800/400?random=18', 1739808000000, '18.02.2025', 'Москва, Сретенка', 55.7690, 37.6350, 50, 1, 1, 'ACTIVE'),
(19, 'Reactive Programming with RxJava', 'Реактивное программирование. Observables, Operators, Schedulers.', 'https://picsum.photos/800/400?random=19', 1739894400000, '19.02.2025', 'Москва, Цветной бульвар', 55.7710, 37.6210, 60, 1, 2, 'ACTIVE'),
(20, 'Firebase Integration', 'Интеграция Firebase: Analytics, Crashlytics, Cloud Messaging, Remote Config.', 'https://picsum.photos/800/400?random=20', 1739980800000, '20.02.2025', 'Москва, Маяковская', 55.7700, 37.5950, 70, 1, 1, 'ACTIVE');

INSERT INTO meeting_tags (meeting_id, tag_id) VALUES
(1, 1), (1, 2), (1, 3),
(2, 2), (2, 4),
(3, 1), (3, 2), (3, 6),
(4, 1), (4, 6),
(5, 1), (5, 2), (5, 5),
(6, 1), (6, 2),
(7, 2),
(8, 1), (8, 2),
(9, 6),
(10, 1), (10, 2),
(11, 1), (11, 2),
(12, 1), (12, 2),
(13, 2), (13, 4),
(14, 7),
(15, 1), (15, 2),
(16, 1), (16, 2),
(17, 2),
(18, 1),
(19, 2),
(20, 1), (20, 8);

-- ====================== User interests ======================
INSERT INTO user_interests (user_id, tag_id) VALUES
(1, 1), (1, 2), (1, 3),
(2, 5),  -- iOS
(3, 4),  -- Backend
(4, 6)   -- UI/UX
ON CONFLICT DO NOTHING;

-- ==================== Meeting participants ==================
INSERT INTO meeting_participants (meeting_id, user_id) VALUES
(1, 2), (1, 3), (1, 4), (1, 5), (1, 6), (1, 7), (1, 8), (1, 9), (1, 10), (1, 11), (1, 12), (1, 13), (1, 14), (1, 15),
(2, 2), (2, 4), (2, 6), (2, 8), (2, 10), (2, 12), (2, 14), (2, 16), (2, 18), (2, 20),
(3, 3), (3, 5), (3, 7), (3, 9), (3, 11), (3, 13), (3, 15), (3, 17), (3, 19)
ON CONFLICT DO NOTHING;

-- ========================= User roles =======================
UPDATE users SET role = 'Разработка' WHERE id IN (1, 2, 3);
UPDATE users SET role = 'Дизайн' WHERE id = 4;

-- ========================= Ad blocks ========================
INSERT INTO ad_blocks (id, type, title, description, is_active) VALUES
(1, 'COMMUNITIES', 'Сообщества для тестировщиков', 'Присоединяйтесь к сообществам по вашим интересам', true);
INSERT INTO ad_block_communities (ad_block_id, community_id) VALUES (1, 1), (1, 2), (1, 3);

INSERT INTO ad_blocks (id, type, title, description, action_text, action_url, is_active) VALUES
(2, 'TEXT', 'Определите свои интересы', 'Расскажите нам о ваших увлечениях, и мы подберём встречи специально для вас!', 'Указать интересы', '/profile/interests', true);

INSERT INTO ad_blocks (id, type, title, description, is_active) VALUES
(3, 'PEOPLE', 'Вы можете их знать', 'Познакомьтесь с людьми со схожими интересами', true);
INSERT INTO ad_block_users (ad_block_id, user_id) VALUES (3, 1), (3, 2), (3, 3), (3, 4);

-- ============= Сброс sequences после явных id ===============
SELECT setval('users_id_seq',        (SELECT MAX(id) FROM users));
SELECT setval('communities_id_seq',  (SELECT MAX(id) FROM communities));
SELECT setval('meetings_id_seq',      (SELECT MAX(id) FROM meetings));
SELECT setval('tags_id_seq',          (SELECT MAX(id) FROM tags));
SELECT setval('ad_blocks_id_seq',     (SELECT MAX(id) FROM ad_blocks));
