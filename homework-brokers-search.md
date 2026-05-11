# Домашнее задание: брокеры сообщений и Elasticsearch

В этом этапе в проект добавлены брокеры сообщений и отдельный поисковый микросервис. Ниже описано только то, что реализовано в текущем workspace.

## Что реализовано

1. Подключен RabbitMQ для событий уведомлений.
2. Подключен Kafka для событий каталога.
3. Добавлен `shop-notification-service`, который читает события из RabbitMQ и отправляет email через SMTP.
4. Добавлен `shop-search-service`, который читает события из Kafka, индексирует товары в Elasticsearch и предоставляет HTTP API поиска.
5. Добавлен Elasticsearch в общий compose-стенд.
6. Настроен ELK-пайплайн логов: Filebeat -> Kafka -> Logstash -> Elasticsearch -> Kibana.
7. Для Kafka подготовлен отдельный multi-node стенд с 3 брокерами, replication factor 3 и min ISR 2.
8. Добавлены unit-тесты для новых частей notification/search.

## RabbitMQ

RabbitMQ подключен в `shop-platform/deploy/docker-compose.yml`:

- сервис `rabbitmq`;
- AMQP порт `5672`;
- management UI порт `15672`;
- durable volume `rabbitmq_data`;
- healthcheck через `rabbitmq-diagnostics`.

RabbitMQ используется в связке:

```text
auth-service
  -> outbox_events
  -> AMQP publisher with confirms
  -> RabbitMQ exchange shop.events
  -> notification-service
  -> SMTP/MailHog
```

Реализация по проектам:

- `shop-auth/sso/internal/services/auth/auth.go` — при регистрации пользователя создается outbox-событие для email-уведомления.
- `shop-auth/sso/internal/storage/postgres/outbox.go` — outbox-событие сохраняется в той же транзакции, что и пользователь.
- `shop-auth/sso/internal/messaging/publisher.go` — AMQP publisher с RabbitMQ Publisher Confirms.
- `shop-auth/sso/internal/messaging/outbox_worker.go` — фоновый worker читает pending-события и публикует их в RabbitMQ.
- `shop-notification-service/internal/events/topology.go` — объявляет exchange, queue, DLX и DLQ.
- `shop-notification-service/internal/events/consumer.go` — consumer читает RabbitMQ queue, валидирует payload, делает ack/retry/DLQ.
- `shop-notification-service/internal/events/handlers.go` — dispatcher рендерит шаблон и отправляет email.
- `shop-notification-service/internal/mailer/` — SMTP provider и HTML-шаблоны писем.

Топология RabbitMQ:

```text
exchange: shop.events
  queue: notification.email
    bindings: auth.*
    dead-letter-exchange: shop.events.dlx

exchange: shop.events.dlx
  queue: notification.email.dlq
    bindings: #
```

Для локальной проверки SMTP в compose добавлен `mailhog`:

- SMTP порт `1025`;
- Web UI порт `8025`.

## Kafka

Kafka подключена в основном compose-стенде `shop-platform/deploy/docker-compose.yml` и используется для событий каталога.

Поток данных:

```text
catalog-service
  -> outbox_events
  -> Kafka topic catalog.products.v1
  -> search-service
  -> Elasticsearch index products
```

Реализация по проектам:

- `shop-catalog-service/internal/repository/postgres/product_repository.go` — при изменениях товаров создаются outbox-события.
- `shop-catalog-service/internal/outbox/publisher.go` — фоновый publisher читает pending-события из outbox и отправляет их в Kafka.
- `shop-catalog-service/internal/events/producer.go` — Kafka producer публикует события в `catalog.products.v1`.
- `shop-search-service/internal/events/consumer.go` — Kafka consumer читает `catalog.products.v1` и индексирует товары.

Для проверки масштабирования Kafka подготовлен отдельный файл:

- `shop-platform/deploy/docker-compose.brokers.yml`.

В нем описан Kafka KRaft cluster из трех брокеров:

- `kafka-1`;
- `kafka-2`;
- `kafka-3`;
- `kafka-ui`;
- `kafka-init`.

Топики создаются через `kafka-init`:

- `catalog.products.v1` — 6 partitions, replication factor 3, min ISR 2;
- `catalog.products.v1.dlq` — 3 partitions, replication factor 3.

Такая конфигурация позволяет проверять обработку при масштабировании consumers и при отключении отдельного Kafka broker.

## Elasticsearch и поиск

Elasticsearch подключен в `shop-platform/deploy/docker-compose.yml`:

- сервис `elasticsearch`;
- порт `9200`;
- volume `esdata`;
- Kibana на порту `5601`.

Поисковый микросервис:

- проект `shop-search-service`;
- HTTP порт `8087`;
- readiness проверяет доступность Elasticsearch;
- при старте сервис делает `Ping` Elasticsearch и создает индекс, если его нет.

Реализация:

- `shop-search-service/internal/search/index.go` — mapping индекса `products`, `EnsureIndex`, `Ping`.
- `shop-search-service/internal/search/indexer.go` — index/delete операций для документов товаров.
- `shop-search-service/internal/search/searcher.go` — full-text поиск, фильтры по цене и наличию, получение товара по id.
- `shop-search-service/internal/transport/http/router.go` — HTTP endpoints.

Endpoints:

```text
GET  /health
GET  /ready
GET  /metrics
POST /search
GET  /products/{id}
```

Пример тела запроса:

```json
{
  "q": "phone",
  "min_price_cents": 1000,
  "max_price_cents": 100000,
  "in_stock_only": true,
  "page": 0,
  "size": 20
}
```

## Elasticsearch для логов

Помимо поиска товаров, Elasticsearch используется в observability-пайплайне:

```text
Docker logs
  -> Filebeat
  -> Kafka topic logs.v1
  -> Logstash
  -> Elasticsearch index app-logs-local-*
  -> Kibana
```

Файлы:

- `shop-platform/infra/filebeat/filebeat.yml` — читает container logs, декодирует JSON и отправляет события в Kafka.
- `shop-platform/infra/logstash/pipeline/logstash.conf` — читает `logs.v1` из Kafka и пишет в Elasticsearch.
- `shop-platform/deploy/docker-compose.yml` — поднимает Kafka, Filebeat, Logstash, Elasticsearch и Kibana.

## Нагрузочная проверка микросервисов

Для HTTP-нагрузки подготовлен k6 smoke/load сценарий:

- `shop-platform/load/gateway_smoke.js`.

Сценарий:

- регистрирует пользователя;
- логинится;
- ходит в gateway;
- вызывает список товаров;
- вызывает получение товара по id;
- проверяет процент ошибок и p95 latency.

Параметры k6:

- ramp-up до 10 VU за 30 секунд;
- ramp-up до 30 VU за 1 минуту;
- ramp-down до 0 за 30 секунд;
- threshold `http_req_failed < 5%`;
- threshold `p95 < 800ms`.

## Тесты, добавленные в этом этапе

Добавлены unit-тесты без поднятия Docker-зависимостей.

`shop-notification-service`:

- `internal/events/types_test.go` — валидация `EmailEvent`.
- `internal/events/consumer_test.go` — retry count, invalid JSON -> DLQ, successful handler -> ack, max retries -> DLQ.
- `internal/events/handlers_test.go` — render/send flow и ошибки renderer/provider.
- `internal/mailer/provider_test.go` — валидация email-сообщений.
- `internal/mailer/templates_test.go` — рендер HTML-шаблонов и HTML escaping.

`shop-search-service`:

- `internal/search/index_test.go` — создание индекса, пропуск существующего индекса, ошибка ping.
- `internal/search/indexer_test.go` — index/delete запросы к Elasticsearch через fake HTTP transport.
- `internal/search/searcher_test.go` — построение search DSL, pagination defaults, decode результатов, get by id.

Проверенные команды:

```bash
go test ./...
```

Успешно пройдены:

- `shop-notification-service`;
- `shop-search-service`;
- `shop-catalog-service`;
- `shop-cart-service`;
- `shop-gateway`;
- `shop-proxy`;
- `shop-contracts`.

