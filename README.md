# Meet Backend - Clean Implementation

REST API для Android приложения Meeting - платформы для организации встреч и мероприятий.

## 🚀 Технологии

- **Kotlin** 1.9.25
- **Spring Boot** 3.2.2
- **PostgreSQL** 16
- **Flyway** - миграции БД
- **SpringDoc OpenAPI** - документация API

## 📦 Архитектура

```
meet-backend-clean/
├── domain/
│   ├── entity/          # JPA entities
│   └── repository/      # Spring Data репозитории
├── api/
│   ├── dto/             # Data Transfer Objects
│   └── controller/      # REST контроллеры
├── service/             # Бизнес-логика
└── resources/
    ├── db/migration/    # Flyway миграции
    └── application.yml  # Конфигурация
```

## 🛠️ Запуск

### 1. Запустить PostgreSQL

```bash
cp .env.example .env
docker-compose up -d
```

### 2. Запустить приложение

```bash
SPRING_PROFILES_ACTIVE=dev ./gradlew bootRun
```

Приложение будет доступно на `http://localhost:8080`

### 3. Swagger UI

Откройте в браузере: `http://localhost:8080/swagger-ui.html`

## 📱 Android API Endpoints

### Meetings
```
GET    /meetings/main              # Главные встречи
GET    /meetings/popular           # Популярные
GET    /meetings                   # Все встречи
GET    /meetings/search?query=X    # Поиск
GET    /meetings/{id}              # По ID
POST   /meetings/{id}/join         # Присоединиться
DELETE /meetings/{id}/leave        # Покинуть
GET    /user/meetings              # Встречи пользователя
```

### Communities
```
GET    /communities/recommended
GET    /communities/{id}
POST   /communities/{id}/subscribe
DELETE /communities/{id}/subscribe
GET    /communities/search?query=X
GET    /communities/{id}/meetings
```

### Users
```
GET    /users/profile              # Текущий пользователь (mock ID=1)
GET    /users/{id}
```

### Tags
```
GET    /api/v1/tags
```

## 🔧 Конфигурация

Локальная конфигурация намеренно изолирована в профиле `dev`. Файл `.env` не
коммитится; создайте его из `.env.example` для Docker PostgreSQL. Приложение
локально запускается только с `SPRING_PROFILES_ACTIVE=dev`.

Для production передайте значения через secret manager или переменные окружения:

```text
DB_HOST
DB_PORT                 # optional, defaults to 5432
DB_NAME
DB_USERNAME
DB_PASSWORD
APP_JWT_SECRET          # at least 32 UTF-8 bytes
ADMIN_API_KEY           # optional at startup; a nonblank value enables /admin/** endpoints
```

`APP_FAKE_SMS=true` разрешён только при `SPRING_PROFILES_ACTIVE=dev`. Реальный
SMS-провайдер ещё не реализован, поэтому приложение намеренно не запускается
вне профиля `dev` до его подключения. Не добавляйте значения этих переменных в
`application.yml`, Compose или Git.

## 🧪 Тестовые данные

После первого запуска БД будет содержать:
- **User ID=1** - тестовый пользователь (используется везде)
- **3 сообщества** - Android Dev, Kotlin UG, Mobile Design
- **5 встреч** - с разными тегами и локациями
- **12 тегов** - Android, Kotlin, Compose, и др.

## 📝 Особенности

- ✅ **Без авторизации** - используется mock пользователь (ID=1)
- ✅ **Полное соответствие Android моделям** - все DTO совпадают
- ✅ **Правильные URL paths** - как ожидает Android клиент
- ✅ **Flyway миграции** - версионирование БД
- ✅ **Swagger документация** - автоматическая генерация
- ✅ **Логирование** - kotlin-logging

## 🔜 TODO

- [ ] Добавить JWT авторизацию
- [ ] Добавить валидацию запросов
- [ ] Добавить пагинацию для больших списков
- [ ] Добавить фильтрацию встреч по тегам и датам
- [ ] Добавить загрузку изображений
- [ ] Добавить тесты

## 📄 Лицензия

MIT
