# Домашнее задание: анализ архитектуры микросервисов

## Цель

Провести анализ текущей архитектуры mini-shop микросервисов и предложить улучшения в части масштабируемости, надежности, CQRS, саг и DDD.

Проект уже разделен на несколько сервисов:

- `shop-gateway` — внешний HTTP API gateway.
- `shop-auth/sso` — аутентификация, регистрация, JWT, refresh sessions.
- `shop-catalog-service` — каталог товаров.
- `shop-cart-service` — корзина.
- `shop-search-service` — поисковая read model на Elasticsearch.
- `shop-notification-service` — email-уведомления через RabbitMQ.
- `shop-proxy` — proxy-service для управляемой задержки и traffic metrics.
- `shop-platform` — общий docker-compose стенд с инфраструктурой.

## Текущее состояние архитектуры

### Межсервисное взаимодействие

В проекте используются разные типы взаимодействия:

1. Синхронное взаимодействие:
   - `shop-gateway -> shop-auth` через gRPC.
   - `shop-gateway -> shop-catalog-service` через gRPC.
   - `shop-gateway -> shop-cart-service` через gRPC.
   - `shop-gateway -> shop-proxy -> shop-catalog-service` для сценариев с proxy.

2. Асинхронное взаимодействие:
   - `shop-auth/sso -> RabbitMQ -> shop-notification-service`.
   - `shop-catalog-service -> Kafka -> shop-search-service`.

3. Observability-взаимодействие:
   - сервисы отдают `/metrics` для Prometheus;
   - сервисы пишут JSON logs;
   - Filebeat отправляет логи в Kafka;
   - Logstash перекладывает логи из Kafka в Elasticsearch;
   - Jaeger собирает traces.

Такой подход уже снижает связанность между сервисами: регистрация пользователя не зависит напрямую от email-отправки, а изменения каталога не требуют синхронного обновления поискового индекса.

## CQRS

### Что уже реализовано

В проекте частично реализован CQRS для каталога:

```text
Write side:
shop-catalog-service
  -> PostgreSQL
  -> outbox_events
  -> Kafka topic catalog.products.v1

Read side:
shop-search-service
  -> Kafka consumer
  -> Elasticsearch index products
  -> POST /search
  -> GET /products/{id}
```

Где находится реализация:

- `shop-catalog-service/internal/repository/postgres/product_repository.go` — write model каталога и запись событий в outbox.
- `shop-catalog-service/internal/outbox/publisher.go` — публикация событий из outbox в Kafka.
- `shop-catalog-service/internal/events/producer.go` — Kafka producer.
- `shop-search-service/internal/events/consumer.go` — consumer событий каталога.
- `shop-search-service/internal/search/indexer.go` — обновление read model в Elasticsearch.
- `shop-search-service/internal/search/searcher.go` — чтение из read model.

### Что стоит улучшить

1. Явно разделить command API и query API.

Сейчас каталог все еще умеет и читать, и изменять товары. Для CQRS можно закрепить правило:

- commands: create/update/stock change идут только в `shop-catalog-service`;
- queries: поиск, фильтры и быстрые read-сценарии идут в `shop-search-service`.

2. Добавить версионирование событий.

События каталога уже идут через `catalog.products.v1`, но в payload полезно явно хранить:

- `schema_version`;
- `event_id`;
- `event_type`;
- `occurred_at`;
- `producer`;
- `trace_id` / `correlation_id`.

3. Добавить идемпотентность на стороне read model.

Для `shop-search-service` стоит хранить последнюю обработанную версию документа или `event_id`, чтобы повторная доставка Kafka-сообщений не могла откатить состояние товара старым событием.

4. Добавить DLQ-обработку для search consumer.

Для битых или несовместимых событий можно использовать `catalog.products.v1.dlq`, который уже предусмотрен в Kafka HA compose.

## Саги и Temporal

### Где саги нужны

Саги нужны для бизнес-процессов, которые затрагивают несколько сервисов и не могут быть надежно выполнены одной транзакцией.

Подходящие сценарии для mini-shop:

```text
Checkout / Order flow:
1. Проверить пользователя.
2. Проверить корзину.
3. Зарезервировать остатки товара.
4. Создать заказ.
5. Провести оплату.
6. Очистить корзину.
7. Отправить уведомление.
```

Если один шаг падает, нужны компенсирующие действия:

- если оплата не прошла — снять резерв товара;
- если создание заказа не удалось — не списывать корзину;
- если email не отправился — не откатывать заказ, а повторить уведомление отдельно.

### Предложение по Temporal

Для orchestration-based saga можно добавить отдельный сервис:

```text
shop-order-service
  -> Temporal workflow: CheckoutWorkflow
  -> activities:
       ValidateUser
       GetCart
       ReserveStock
       CreateOrder
       ChargePayment
       ClearCart
       PublishNotification
```

Temporal даст:

- durable workflow state;
- retries с backoff;
- таймауты на activity;
- compensation logic;
- visibility по выполнению саг;
- безопасное продолжение workflow после рестарта worker.

Предлагаемая структура:

```text
shop-order-service/
  internal/domain/order/
  internal/application/checkout/
  internal/workflows/checkout_workflow.go
  internal/activities/
    auth.go
    cart.go
    catalog.go
    payment.go
    notification.go
```

На первом этапе Temporal можно подключить только к checkout flow, не переписывая существующие сервисы.

## Распределенная надежная архитектура

### Что уже сделано

В проекте уже есть несколько элементов надежной распределенной архитектуры:

1. Gateway как единая внешняя точка входа.
2. Health/readiness endpoints во всех основных сервисах.
3. Prometheus metrics для сервисов.
4. Structured JSON logs.
5. Jaeger tracing.
6. Kafka для событий каталога.
7. RabbitMQ для уведомлений.
8. Outbox pattern в `shop-auth/sso`.
9. Outbox pattern в `shop-catalog-service`.
10. RabbitMQ Publisher Confirms для надежной публикации email-событий.
11. Retry и DLQ в `shop-notification-service`.
12. Elasticsearch read model для поиска.
13. Redis cache для каталога.
14. MongoDB replica set для cart-service.
15. Patroni + etcd + HAProxy для PostgreSQL HA стенда.
16. Отдельный `shop-proxy` для проверки задержек и traffic metrics.

### Что стоит улучшить

1. Ввести единый envelope для всех событий.

Сейчас события разных сервисов похожи, но лучше закрепить общий формат:

```json
{
  "event_id": "...",
  "event_type": "...",
  "schema_version": 1,
  "occurred_at": "...",
  "producer": "catalog-service",
  "correlation_id": "...",
  "payload": {}
}
```

2. Добавить idempotency store для consumers.

Для `notification-service` и `search-service` стоит хранить обработанные `event_id`.

3. Добавить DLQ management API.

Для DLQ полезны operator endpoints:

- посмотреть DLQ-сообщения;
- переотправить сообщение;
- пометить сообщение как обработанное;
- выгрузить ошибку обработки.

4. Улучшить retry policies.

Сейчас retry есть на уровне RabbitMQ consumer и отдельных клиентов. Можно унифицировать:

- exponential backoff;
- jitter;
- max elapsed time;
- разделение retryable/non-retryable ошибок.

5. Добавить circuit breaker для gateway clients.

Для `shop-gateway` полезно добавить circuit breaker на gRPC-клиенты:

- auth;
- catalog;
- cart.

Это защитит gateway от долгих зависаний при деградации внутренних сервисов.

6. Добавить graceful degradation.

Например:

- если `search-service` недоступен, gateway может временно читать базовый список товаров из `catalog-service`;
- если `notification-service` недоступен, регистрация пользователя не должна падать, потому что событие уже лежит в outbox.

7. Добавить contract tests.

Для Kafka/RabbitMQ событий и gRPC API полезны contract tests:

- проверка совместимости event schema;
- проверка backward compatibility;
- проверка обязательных полей.

## DDD-рефакторинг

### Что уже похоже на DDD

В проекте уже есть элементы DDD:

- `internal/domain` в сервисах;
- отдельные application/service слои;
- repository interfaces;
- transport adapters;
- infrastructure adapters;
- domain errors;
- commands для операций каталога.

Примеры:

- `shop-catalog-service/internal/domain/product.go`;
- `shop-catalog-service/internal/service/catalog/catalog.go`;
- `shop-cart-service/internal/domain/product.go`;
- `shop-cart-service/internal/service/cart/cart_service.go`;
- `shop-auth/sso/internal/domain/models/`.

### Что стоит зарефакторить

1. Явно выделить bounded contexts.

Текущие bounded contexts:

- Identity and Access — `shop-auth/sso`;
- Catalog — `shop-catalog-service`;
- Cart — `shop-cart-service`;
- Search — `shop-search-service`;
- Notification — `shop-notification-service`;
- Gateway/BFF — `shop-gateway`.

В будущем можно добавить:

- Orders;
- Payments;
- Delivery.

2. Разделить domain и application use cases.

Рекомендуемая структура для сервисов:

```text
internal/
  domain/
    product.go
    errors.go
    events.go
  application/
    commands/
    queries/
    ports.go
  infrastructure/
    postgres/
    kafka/
    rabbitmq/
    elasticsearch/
  transport/
    http/
    grpc/
```

3. Убрать инфраструктурные детали из domain/application.

Domain не должен знать про:

- Kafka;
- RabbitMQ;
- Elasticsearch;
- HTTP;
- gRPC;
- SQL-драйверы.

4. Оформить domain events как часть domain слоя.

Для каталога:

```text
ProductCreated
ProductUpdated
ProductStockChanged
```

Domain/application слой создает событие, infrastructure слой публикует через outbox.

5. Сделать anti-corruption layer между gateway и внутренними сервисами.

`shop-gateway/internal/adapters/*` уже выполняют роль адаптеров. Их можно усилить:

- не отдавать наружу proto-модели;
- маппить gRPC errors в HTTP errors;
- централизовать retry/circuit breaker/timeout.

6. Вынести общие контракты в `shop-contracts`.

Сейчас proto/openapi/event contracts уже лежат в `shop-contracts`. Для DDD это правильно: сервисы общаются через контракты, но не импортируют внутренние domain-модели друг друга.

## Предлагаемая целевая схема

```text
Client
  -> shop-gateway
      -> auth-service
      -> cart-service
      -> catalog-service
      -> search-service

catalog-service
  -> Postgres
  -> outbox
  -> Kafka
  -> search-service
  -> Elasticsearch

auth-service
  -> Postgres
  -> outbox
  -> RabbitMQ
  -> notification-service
  -> SMTP/MailHog

order-service
  -> Temporal Workflow
  -> auth/cart/catalog/payment/notification activities

observability
  -> Prometheus
  -> Jaeger
  -> Filebeat
  -> Kafka logs.v1
  -> Logstash
  -> Elasticsearch
  -> Kibana
```

## Итог

Текущая архитектура уже движется в сторону надежной микросервисной системы:

- есть gateway;
- есть синхронные gRPC API;
- есть асинхронные события через Kafka и RabbitMQ;
- есть outbox pattern;
- есть read model на Elasticsearch;
- есть observability;
- есть HA-инфраструктура для части хранилищ.

Главные следующие улучшения:

1. Довести CQRS до явного разделения command/query API.
2. Добавить idempotency для consumers.
3. Добавить DLQ management.
4. Ввести единый event envelope.
5. Добавить Temporal для checkout/order saga.
6. Усилить gateway через circuit breaker и graceful degradation.
7. Провести DDD-рефакторинг по bounded contexts, application use cases и infrastructure adapters.
