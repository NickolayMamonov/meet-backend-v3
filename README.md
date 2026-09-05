# Meet Backend

Backend REST API для Android-приложения Meet: встречи, сообщества,
пользователи, авторизация, медиа и интеграции импорта. Этот README — точка
входа для разработчика и оператора закрытого beta-тестирования.

Документ описывает код, уже находящийся в репозитории. Наличие кода,
конфигурации или операционной процедуры здесь не является доказательством
деплоя, запуска процедуры или готовности внешней инфраструктуры.

## Стек и предпосылки

- Kotlin **2.2.21** и JVM **21**.
- Spring Boot **4.1.0**, Spring Web, Validation, Security, Data JPA и
  RestClient.
- Gradle Wrapper **8.14.3**.
- PostgreSQL **16**, Hibernate/JPA и Flyway.
- SpringDoc OpenAPI **3.0.3**.
- JUnit 5, Spring Boot Test и Testcontainers для PostgreSQL-backed тестов.

Для локальной работы нужны JDK 21 и Docker Compose. PostgreSQL запускается
отдельным сервисом из [`docker-compose.yml`](docker-compose.yml).

## Быстрый локальный запуск

```bash
cp .env.example .env
docker compose up -d postgres
SPRING_PROFILES_ACTIVE=dev ./gradlew bootRun
```

После запуска приложение доступно по адресу
`http://localhost:8080`. Команда запуска явно выбирает профиль `dev`; запуск
без профиля или в production-режиме нельзя считать development-safe.

## Конфигурация и секреты

Шаблоны окружения:

- [`.env.example`](.env.example) — локальная конфигурация и имена
  переменных для разработки.
- [`.env.production.example`](.env.production.example) — форма production
  окружения и границы обязательных значений.

Шаблоны содержат только структуру и безопасные заполнители. Не коммитьте
`.env` или `.env.production`, не переносите production-шаблон поверх уже
существующего окружения и не печатайте значения конфигурации в логи,
отчёты или README. База данных, JWT, OTP/HMAC, SMTP, Firebase/provider,
административные, signing и recovery-значения являются защищёнными
входными данными. Сюда также относятся пароли, токены, OTP, JWT и refresh
tokens.

### Классификация runtime

Правила реализованы в `RuntimeConfigurationValidator` и применяются при
старте:

- ровно набор активных профилей `{dev}` — development;
- ровно `{test}` — test;
- любой другой набор, включая отсутствие активного профиля, `{prod}` и
  любой другой профиль, — production mode;
- набор из нескольких профилей, содержащий `dev` или `test`, отклоняется.

Провайдеры и ключи подчиняются той же классификации:

- `APP_SMS_PROVIDER` (`app.sms.provider`) со значением `fake` разрешён
  только при ровно профиле `dev`;
- production требует `APP_EMAIL_PROVIDER` (`app.email.provider`) со
  значением `smtp` и не разрешает fake email;
- OTP HMAC key ring обязателен;
- production отклоняет документированные dev/test OTP HMAC identifiers и
  material;
- если выбран SMTP, SMTP-настройки валидируются всегда: обязательны host,
  credentials и sender, а connect/read/write timeout должны быть в диапазоне
  1–30 секунд. Используются SMTP, authentication, обязательный STARTTLS и
  проверка имени сертификата; JNDI, SMTPS, startup test-connection,
  небезопасные TLS/socket-factory/trust overrides и debug/trace mail-logging
  отклоняются.

Имена `APP_OTP_HMAC_CURRENT_KEY_ID`, `APP_OTP_HMAC_CURRENT_KEY_BASE64` и
опциональной previous-пары обозначают защищённый key ring; их значения не
должны появляться в исходниках, логах или документации.

В production профиль по умолчанию отключает плановые ingestion, geocoder и
Timepad-интеграцию до явного включения оператором. OpenAPI-документация в
production также отключена по умолчанию.

## API и авторизация

OpenAPI:

- JSON-документация: `/api-docs`;
- Swagger UI: `/swagger-ui.html`.

В production обе поверхности отключены по умолчанию настройками профиля
`prod`. Пути `/v3/api-docs/**` и `/swagger-ui/**` также относятся к
OpenAPI-поверхности security-конфигурации.

Основные семейства endpoint'ов:

- **Авторизация:** `/auth/send-otp`, `/auth/verify-otp`,
  `/auth/email/send-otp`, `/auth/email/verify-otp`, `/auth/refresh`,
  `/auth/logout`.
- **Встречи:** `/meetings/main`, `/meetings/popular`, `/meetings`,
  `/meetings/search`, `/meetings/{id}`, `/meetings/{id}/participants`,
  `/meetings/{id}/join`, `/meetings/{id}/leave`, `/user/meetings`.
- **Сообщества:** `/communities/recommended`, `/communities/{id}`,
  `/communities/search`, `/communities/{id}/meetings`,
  `/communities/{id}/subscribers`, а также subscribe/unsubscribe для
  `/communities/{id}/subscribe`.
- **Пользователи и профиль:** `/profile`, `/users/{id}`,
  `/profile/fcm-token`, `/users/{id}/meetings`,
  `/users/{id}/communities`, а также операции удаления профиля.
- **Теги и рекламные блоки:** `/api/v1/tags` и `/api/ads/{id}` вместе с
  коллекцией `/api/ads`.
- **Медиа:** загрузка avatar, meeting и community через
  `POST /media/avatar`, `POST /media/meeting` и `POST /media/community`;
  GET-доступ к сохранённым медиа обслуживается отдельно.
- **Административный импорт и очистка:** `POST /admin/ingest` и
  `DELETE /admin/purge?source=...`.
- **Demo catalog:** `POST /admin/demo-catalog/bootstrap` доступен только
  когда bootstrap явно включён; публичные страницы —
  `/demo-events/organize-online` и `/demo-events/networking-online`.

### Доступ к `/admin/**`

`ADMIN_API_KEY` — защищённый вход, а не значение для публикации. Пустой или
состоящий из пробелов ключ оставляет административные маршруты
недоступными. Для запроса нужен заголовок `X-Admin-Key` с точным
совпадением настроенного ключа; при совпадении `AdminKeyAuthFilter` создаёт
аутентификацию с `ROLE_ADMIN`, которую требует `SecurityConfig`. Отсутствующий
или неверный ключ получает `403 Forbidden`.

`JwtAuthFilter` при валидном пользовательском JWT создаёт только
`ROLE_USER`. Обычный JWT не заменяет `X-Admin-Key` и не может обойти
административный gate. Деструктивные и импортирующие endpoint'ы остаются
защищёнными этим правилом.

## Архитектура и данные

Код организован по слоям:

- `api/controller` — HTTP-маршруты и валидация запросов;
- `api/dto` — контрактные входные и выходные модели API;
- `service` — бизнес-логика;
- `domain/entity` и `domain/repository` — JPA-модель и доступ к данным;
- `ingestion` — общий импорт и upsert;
- `ingestion/timepad` — изолированный Timepad provider;
- `src/main/resources/application*.yml` — конфигурация профилей;
- `src/main/resources/db/migration` — история схемы;
- `src/test` — unit, MVC и PostgreSQL-backed проверки.

Контроллеры **никогда не сериализуют JPA entities напрямую**. Доменные
payload'ы преобразуются в API DTO. При этом контракт не обещает, что каждый
ответ — DTO: endpoint-specific wrappers, `Map`-ответы и бинарные
`ByteArray`-ответы остаются допустимыми формами для соответствующих
маршрутов.

`MeetingDto` и изменения endpoint'ов, потребляемые Android, расширяют
контракт аддитивно. Импорт сохраняет изоляцию Timepad-логики, ограничивает
внешний paging параметрами provider'а и выполняет idempotent upsert по паре
`(source, sourceExternalId)`. Повторная обработка того же внешнего события
не должна создавать дубликаты.

## Миграции и тесты

Flyway-ресурсы находятся в
[`src/main/resources/db/migration`](src/main/resources/db/migration).
Hibernate работает с `ddl-auto: validate`, поэтому схема не создаётся
молчаливой автогенерацией приложения.

Применённые миграции V1–V9 являются неизменяемой историей. Новое изменение
схемы оформляйте следующей монотонной версией; уже применённый файл нельзя
редактировать. План отката должен учитывать, что rollback миграции и
совместимость приложения — отдельные операционные решения.

Обычный набор проверок:

```bash
./gradlew test
./gradlew postgresTest
```

Эти команды перечислены как контракт репозитория; их выполнение не
утверждается этой документацией.

## Операции закрытого beta-тестирования

Операционные документы являются источниками процедур. Перед действием
проверьте их предусловия, права доступа и границы изменения окружения:

- [Production deployment](docs/production-deployment.md)
- [Backend release publishing](docs/operations/backend-release-publishing.md)
- [Test VPS deployment](docs/operations/test-vps-deployment.md)
- [Email OTP](docs/operations/email-otp.md)
- [Demo catalog bootstrap](docs/operations/demo-catalog-bootstrap.md)
- [Closed-beta backup and restore](docs/operations/closed-beta-backup-restore.md)
- [SPKI rollover drill](docs/operations/spki-rollover-drill.md)

Production Compose описан в
[`docker-compose.production.yml`](docker-compose.production.yml). Этот
README не заявляет выполнение деплоя, публикации, bootstrap, backup/restore,
recovery drill или rollout; перед операционным изменением используйте
соответствующую процедуру и её доказательства.
