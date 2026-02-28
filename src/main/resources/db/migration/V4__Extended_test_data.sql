-- V4__Extended_test_data.sql

-- Добавляем больше встреч (6-20)
INSERT INTO meetings (id, title, description, image_url, time, date,
                      address, latitude, longitude, capacity,
                      person_host_id, community_host_id, status) VALUES
(6, 'Android Performance Optimization',
 'Оптимизация производительности Android приложений. Профилирование, memory leaks, ANR.',
 'https://picsum.photos/800/400?random=6',
 1738771200000, '06.02.2025',
 'Москва, ул. Пушкина, 10', 55.7600, 37.6100, 40,
 1, 1, 'ACTIVE'),

(7, 'Kotlin Flow Best Practices',
 'Работа с Flow в реальных проектах. StateFlow, SharedFlow, операторы.',
 'https://picsum.photos/800/400?random=7',
 1738857600000, '07.02.2025',
 'Москва, Кремлёвская набережная', 55.7520, 37.6230, 55,
 1, 2, 'ACTIVE'),

(8, 'Dependency Injection with Koin',
 'Внедрение зависимостей в Android. Koin vs Dagger Hilt.',
 'https://picsum.photos/800/400?random=8',
 1738944000000, '08.02.2025',
 'Москва, Театральная площадь', 55.7570, 37.6185, 65,
 1, 1, 'ACTIVE'),

(9, 'Mobile UX Design Principles',
 'Основы UX дизайна для мобильных приложений.',
 'https://picsum.photos/800/400?random=9',
 1739030400000, '09.02.2025',
 'Москва, ул. Никольская, 15', 55.7575, 37.6220, 50,
 1, 3, 'ACTIVE'),

(10, 'Testing Android Apps',
 'Unit тесты, UI тесты, интеграционные тесты. JUnit, Espresso, MockK.',
 'https://picsum.photos/800/400?random=10',
 1739116800000, '10.02.2025',
 'Москва, Садовое кольцо, 25', 55.7540, 37.6150, 70,
 1, 1, 'ACTIVE'),

(11, 'Modern Android Architecture',
 'Современная архитектура: Clean + MVVM + Repository + Use Cases.',
 'https://picsum.photos/800/400?random=11',
 1739203200000, '11.02.2025',
 'Москва, Новый Арбат, 12', 55.7530, 37.5980, 80,
 1, 1, 'ACTIVE'),

(12, 'Room Database Deep Dive',
 'Работа с Room: миграции, отношения, транзакции, Flow.',
 'https://picsum.photos/800/400?random=12',
 1739289600000, '12.02.2025',
 'Москва, ул. Баумана, 8', 55.7585, 37.6195, 45,
 1, 1, 'ACTIVE'),

(13, 'Ktor for Backend Development',
 'Создание REST API с Ktor. Routing, serialization, authentication.',
 'https://picsum.photos/800/400?random=13',
 1739376000000, '13.02.2025',
 'Москва, Кутузовский проспект, 30', 55.7420, 37.5450, 60,
 1, 2, 'ACTIVE'),

(14, 'Mobile CI/CD with GitHub Actions',
 'Настройка CI/CD для Android проектов. Автоматизация сборки и тестирования.',
 'https://picsum.photos/800/400?random=14',
 1739462400000, '14.02.2025',
 'Москва, Лубянская площадь', 55.7590, 37.6285, 50,
 1, 1, 'ACTIVE'),

(15, 'Jetpack Navigation Component',
 'Навигация в Android приложениях. Safe Args, Deep Links, Bottom Navigation.',
 'https://picsum.photos/800/400?random=15',
 1739548800000, '15.02.2025',
 'Москва, Патриаршие пруды', 55.7645, 37.5935, 55,
 1, 1, 'ACTIVE'),

(16, 'WorkManager for Background Tasks',
 'Фоновые задачи в Android. WorkManager constraints, chaining, testing.',
 'https://picsum.photos/800/400?random=16',
 1739635200000, '16.02.2025',
 'Москва, Чистые пруды', 55.7650, 37.6380, 40,
 1, 1, 'ACTIVE'),

(17, 'Kotlin DSL for Gradle',
 'Использование Kotlin DSL в Gradle скриптах.',
 'https://picsum.photos/800/400?random=17',
 1739721600000, '17.02.2025',
 'Москва, Трубная площадь', 55.7670, 37.6220, 45,
 1, 2, 'ACTIVE'),

(18, 'Android Security Best Practices',
 'Безопасность Android приложений. Шифрование, SSL pinning, ProGuard.',
 'https://picsum.photos/800/400?random=18',
 1739808000000, '18.02.2025',
 'Москва, Сретенка', 55.7690, 37.6350, 50,
 1, 1, 'ACTIVE'),

(19, 'Reactive Programming with RxJava',
 'Реактивное программирование. Observables, Operators, Schedulers.',
 'https://picsum.photos/800/400?random=19',
 1739894400000, '19.02.2025',
 'Москва, Цветной бульвар', 55.7710, 37.6210, 60,
 1, 2, 'ACTIVE'),

(20, 'Firebase Integration',
 'Интеграция Firebase: Analytics, Crashlytics, Cloud Messaging, Remote Config.',
 'https://picsum.photos/800/400?random=20',
 1739980800000, '20.02.2025',
 'Москва, Маяковская', 55.7700, 37.5950, 70,
 1, 1, 'ACTIVE');

-- Meeting tags для новых встреч
INSERT INTO meeting_tags (meeting_id, tag_id) VALUES
(6, 1), (6, 2),           -- Performance
(7, 2),                   -- Flow
(8, 1), (8, 2),           -- DI
(9, 6),                   -- UX
(10, 1), (10, 2),         -- Testing
(11, 1), (11, 2),         -- Architecture
(12, 1), (12, 2),         -- Room
(13, 2), (13, 4),         -- Ktor
(14, 7),                  -- CI/CD
(15, 1), (15, 2),         -- Navigation
(16, 1), (16, 2),         -- WorkManager
(17, 2),                  -- Gradle
(18, 1),                  -- Security
(19, 2),                  -- RxJava
(20, 1), (20, 8);         -- Firebase

-- Тестовые данные для AdBlocks
INSERT INTO ad_blocks (id, type, community_id, is_active) VALUES
(1, 'COMMUNITY', 1, true);

INSERT INTO ad_blocks (id, type, title, description, action_text, action_url, is_active) VALUES
(2, 'TEXT',
 'Определите свои интересы',
 'Расскажите нам о ваших увлечениях, и мы подберём встречи специально для вас!',
 'Указать интересы',
 '/profile/interests',
 true);

INSERT INTO ad_blocks (id, type, title, image_url, action_url, background_color, is_active) VALUES
(3, 'BANNER',
 'Kotlin Conf 2024',
 'https://picsum.photos/800/400?random=101',
 '/events/kotlinconf',
 '#1E88E5',
 true);

INSERT INTO ad_blocks (id, type, community_id, is_active) VALUES
(4, 'COMMUNITY', 2, true);

INSERT INTO ad_blocks (id, type, title, description, action_text, action_url, is_active) VALUES
(5, 'TEXT',
 'Создайте своё сообщество',
 'Соберите единомышленников вокруг своих идей. Создание сообщества займет всего минуту!',
 'Создать сообщество',
 '/communities/create',
 true);

INSERT INTO ad_blocks (id, type, community_id, is_active) VALUES
(6, 'COMMUNITY', 3, true);

-- Update sequences
SELECT setval('meetings_id_seq', 20);
SELECT setval('ad_blocks_id_seq', 6);