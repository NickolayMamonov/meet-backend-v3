# Meet Backend - Clean Implementation

REST API для Android приложения Meeting - платформы для организации встреч и мероприятий.

## 🚀 Технологии

- **Kotlin** 2.2.21
- **Spring Boot** 4.1.0
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
APP_EMAIL_PROVIDER      # must be smtp outside exactly dev/test
APP_EMAIL_FROM
APP_EMAIL_FROM_NAME
SPRING_MAIL_HOST
SPRING_MAIL_PORT        # optional, defaults to 587
SPRING_MAIL_USERNAME
SPRING_MAIL_PASSWORD
APP_EMAIL_CONNECT_TIMEOUT_MS
APP_EMAIL_READ_TIMEOUT_MS
APP_EMAIL_WRITE_TIMEOUT_MS
APP_OTP_HMAC_CURRENT_KEY_ID
APP_OTP_HMAC_CURRENT_KEY_BASE64
APP_OTP_HMAC_PREVIOUS_KEY_ID       # optional; configure both previous values
APP_OTP_HMAC_PREVIOUS_KEY_BASE64
APP_HTTP_CLIENT_IP_TRUSTED_PROXY_CIDRS  # optional comma-separated controlled proxy CIDRs
APP_HTTP_CLIENT_IP_MAX_FORWARDED_HOPS   # optional, defaults to 10
```

`APP_SMS_PROVIDER=fake` разрешён только при `SPRING_PROFILES_ACTIVE=dev`.
По умолчанию `APP_SMS_PROVIDER=disabled`: приложение запускается, но
`POST /auth/send-otp` возвращает `503 SMS_UNAVAILABLE` и не сохраняет OTP.
Реальный адаптер SMS ещё не реализован; при его добавлении передавайте
учётные данные через environment/secret manager, не через `application.yml`,
Compose или Git.

Email OTP требует SMTP и отдельный HMAC key ring во всех режимах, кроме ровно
`dev` или ровно `test`. Пустой набор профилей считается production. Смешанные
профили (`prod,dev`, `dev,test`) отклоняются при старте. Production SMTP всегда
использует authentication, обязательный STARTTLS, проверку имени сертификата и
таймауты 1–30 секунд; JNDI, SMTPS, test-connection, mail debug/trace,
trust-all/custom socket factories и ослабляющие overrides запрещены.

Для локального запуска профиль `dev` использует fake email sender, который
ничего не логирует. Для ручной проверки письма переключите dev на SMTP и
используйте локальный inbox (например, Mailpit), не добавляя OTP или адреса в
логи. Production checklist, rotation и rollback описаны в
`docs/operations/email-otp.md`.

### Логирование

Без активного профиля `dev` приложение использует `INFO` для пакета
`dev.whysoezzy` (и для root logger). Профиль `dev` явно повышает уровень
`dev.whysoezzy` до `DEBUG` для локальной диагностики. Production-логи
содержат только безопасные операционные категории и метаданные; не
добавляйте в них значения запросов, адреса, URL/пути файлов, токены, OTP,
секреты, HMAC key IDs/material, SMTP credentials, provider payload/message ID
или тексты provider-исключений/stack trace.

В production- и `dev`-профилях `spring.mvc.log-resolved-exception=false`:
Spring MVC не пишет в лог детали исключений, уже преобразованных в API-ответ.

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

## Integration tests

`ApiMvcIntegrationTest` runs the production Spring context, Flyway migrations, security filters, repositories,
and MockMvc against PostgreSQL. By default it starts `postgres:16-alpine` through Testcontainers:

```bash
./gradlew test --tests dev.whysoezzy.meet.integration.ApiMvcIntegrationTest
```

For CI or a host where Docker is unavailable, point it at an existing disposable PostgreSQL database. The test
creates a unique schema and applies Flyway migrations there:

```bash
TEST_POSTGRES_JDBC_URL=jdbc:postgresql://localhost:5432/postgres \
TEST_POSTGRES_USERNAME=postgres \
TEST_POSTGRES_PASSWORD=postgres \
./gradlew test --tests dev.whysoezzy.meet.integration.ApiMvcIntegrationTest
```
