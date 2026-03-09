# Observability Homework Report

Файл сделан как маршрут для проверяющего: каждый пункт ДЗ разбит на блоки `Реализация`, `Как проверить`, `Скриншоты`, `Результат`.

---

## 0. Общая информация

Проект:

1. `shop-platform` — инфраструктура observability
2. `shop-gateway` — HTTP gateway (`:8083`)
3. `shop-catalog-service` — catalog service (HTTP `:8081`, gRPC `:9091`)

Ключевые URL:

1. Grafana: `http://localhost:3000`
2. Prometheus: `http://localhost:9090`
3. Kibana: `http://localhost:5601`
4. Jaeger: `http://localhost:16686`
5. Gateway: `http://localhost:8083`
6. Catalog: `http://localhost:8081`

---

## 1. Сбор логов локально и в ELK с нескольких микросервисов

### 1.1 Реализация

1. Логи сервисов пишутся в JSON в `stdout`.
2. Настроен pipeline: `Filebeat -> Kafka -> Logstash -> Elasticsearch`.
3. Используется индекс `app-logs-local-*`.
4. В логах видны минимум 2 сервиса:
   - `gateway-service`
   - `catalog-service`

### 1.2 Как проверить

```bash
cd shop-platform/deploy
docker compose up -d --build
docker compose ps
```

Сгенерировать трафик:

```bash
curl "http://127.0.0.1:8083/products?limit=2&offset=0"
curl "http://127.0.0.1:8083/products/prod-001"
```

Проверить индексы:

```bash
curl "http://127.0.0.1:9200/_cat/indices?v"
curl "http://127.0.0.1:9200/app-logs-local-*/_count"
```

В Kibana (`Discover`) фильтры:

1. `service: "gateway-service"`
2. `service: "catalog-service"`

### 1.3 Скриншоты

1. `screenshots/01-kibana-gateway.png`
![alt text](image.png)
2. `screenshots/02-kibana-catalog.png`
![alt text](image-1.png)


### 1.4 Результат

Статус: `DONE`

---

## 2. Сбор бизнес-метрик в Prometheus

### 2.1 Реализация

Добавлены/используются метрики:

1. Gateway:
   - `gateway_http_requests_total`
   - `gateway_http_request_duration_seconds`
   - `gateway_service_requests_total`
   - `gateway_service_request_duration_seconds`
   - `gateway_grpc_requests_total`
   - `gateway_grpc_request_duration_seconds`
2. Catalog:
   - `catalog_service_requests_total`
   - `catalog_service_request_duration_seconds`
   - `catalog_grpc_requests_total`
   - `catalog_grpc_request_duration_seconds`
   - `catalog_cache_requests_total`
   - `catalog_cache_request_duration_seconds`

### 2.2 Как проверить

Проверить targets:

```bash
curl "http://127.0.0.1:9090/api/v1/targets"
```

Проверить запросами:

```bash
curl "http://127.0.0.1:9090/api/v1/query?query=gateway_http_requests_total"
curl "http://127.0.0.1:9090/api/v1/query?query=gateway_grpc_requests_total"
curl "http://127.0.0.1:9090/api/v1/query?query=catalog_service_requests_total"
```

### 2.3 Скриншоты

1. ![alt text](image-2.png)
2. ![alt text](image-3.png)
3. ![alt text](image-4.png)

### 2.4 Результат

Статус: `DONE`

---

## 3. Алертинг с отправкой сообщений в Telegram

### 3.1 Реализация

1. Настроен Grafana Alerting.
2. Настроен Telegram `Contact point`.
3. `Default notification policy` направлена в Telegram.
4. Создан тестовый алерт `GatewayDownTest`:
   - Query: `up{job="gateway-service"} == 0`
   - Evaluate every: `30s`
   - For: `1m`
5. Проверена доставка `Firing` и `Resolved` в Telegram.

### 3.2 Как проверить

Проверка Telegram:

```bash
docker compose stop gateway-service
```

Подождать 1-2 минуты, затем:

```bash
docker compose start gateway-service
```

Ожидание:

1. Сообщение `Firing` в Telegram.
2. Сообщение `Resolved` в Telegram.

### 3.3 Скриншоты

![alt text](image-5.png)

![alt text](image-6.png)


---

## 4. Телеметрия нескольких сервисов и БД + проверка под нагрузкой

### 4.1 Реализация

1. Трейсинг:
   - `gateway-service` и `catalog-service` отправляют трейсинг в Jaeger.
   - Виден межсервисный путь `gateway -> catalog`.
2. Метрики:
   - сервисные метрики доступны в Prometheus/Grafana.
3. БД:
   - В стек подняты PostgreSQL и Redis.
   - Нагрузка на сервисы отражается в их метриках и логах.

### 4.2 Как проверить

Сгенерировать нагрузку сценарием из прошлого ДЗ (указать команду ниже):

```bash
# TODO: вставить фактическую команду нагрузочного теста
# пример: k6 run scripts/load.js
```

Во время нагрузки зафиксировать:

1. Grafana: RPS, p95, 5xx.
2. Prometheus: рост счетчиков запросов.
3. Jaeger: traces на горячем пути.
4. Логи в Kibana.
5. Поведение Postgres/Redis (по доступным метрикам/логам).

### 4.3 Скриншоты

До нагрузки:
![alt text](image-7.png)

После:

---

## 5. Протокол проверок (текстовый)

### 5.1 Последовательность

1. Поднят стек `docker compose up -d --build`.
2. Проверены сервисы (`docker compose ps`).
3. Сгенерирован трафик на gateway.
4. Проверены логи в ELK.
5. Проверены метрики в Prometheus и дашборде Grafana.
6. Проверен alerting в Telegram.
7. Проверены traces в Jaeger.
8. Выполнен/будет выполнен нагрузочный прогон.

### 5.2 Команды (копипаст)

```bash
cd shop-platform/deploy
docker compose up -d --build
docker compose ps

curl "http://127.0.0.1:8083/products?limit=2&offset=0"
curl "http://127.0.0.1:8083/products/prod-001"
curl "http://127.0.0.1:8083/health"
curl "http://127.0.0.1:8083/ready"

curl "http://127.0.0.1:9090/api/v1/targets"
curl "http://127.0.0.1:9090/api/v1/query?query=gateway_http_requests_total"
curl "http://127.0.0.1:9200/app-logs-local-*/_count"
```

---

