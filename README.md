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
docker-compose up -d
```

### 2. Запустить приложение

```bash
./gradlew bootRun
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

Отредактируйте `src/main/resources/application.yml`:

```yaml
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/meet_db
    username: postgres
    password: postgres
```

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
