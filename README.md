# shop-platform

`shop-platform` — инфраструктурный репозиторий локального observability-стенда для проекта mini-shop.

Цель:

1. Поднять локально ELK, Prometheus/Grafana, Jaeger и сервисные зависимости.
2. Дать единую среду для проверки логов, метрик и трейсов нескольких микросервисов.

## Основные компоненты

1. `deploy/docker-compose.yml` — запуск инфраструктуры и сервисов.
2. `infra/filebeat/filebeat.yml` — сбор контейнерных логов.
3. `infra/logstash/pipeline/logstash.conf` — обработка логов и запись в Elasticsearch.
4. `infra/prometheus/prometheus.yml` — scrape-конфиг метрик.

## Что поднимается в compose

1. Kafka
2. Elasticsearch
3. Kibana
4. Logstash
5. Filebeat
6. Prometheus
7. Grafana
8. Jaeger
9. PostgreSQL
10. Redis
11. `catalog-service`
12. `gateway-service` (порт `8083`)

## Быстрый старт

Из директории `shop-platform/deploy`:

```bash
docker compose up -d --build
```

Проверка статуса:

```bash
docker compose ps
```

## Полезные адреса

1. Gateway: `http://localhost:8083`
2. Catalog HTTP: `http://localhost:8081`
3. Catalog gRPC: `localhost:9091`
4. Prometheus: `http://localhost:9090`
5. Grafana: `http://localhost:3000`
6. Kibana: `http://localhost:5601`
7. Jaeger: `http://localhost:16686`
8. Elasticsearch: `http://localhost:9200`

## Проверка логов (ELK)

1. Сервисы пишут JSON-логи в stdout.
2. Filebeat читает Docker logs и отправляет в Kafka (`logs.v1`).
3. Logstash читает Kafka и пишет в Elasticsearch (индекс `app-logs-local-*`).
4. В Kibana создается Data View: `app-logs-local-*`.

## Проверка метрик

1. Сервисы отдают `/metrics`.
2. Prometheus скрейпит таргеты.
3. Grafana строит dashboards.

Пример проверок:

```bash
curl http://localhost:8083/metrics
curl http://localhost:8081/metrics
```

## Проверка трейсов

1. Сервисы экспортируют OTLP в Jaeger.
2. В Jaeger виден сквозной trace `gateway -> catalog`.

## Health/Readiness практика

1. `/health` — только liveness (процесс жив).
2. `/ready` — готовность обслуживать трафик с учетом зависимостей.
3. Для `gateway-service` readiness основан на gRPC health-check `catalog-service`.

Рекомендация для compose:

1. Добавлять `healthcheck` на `/ready` для прикладных сервисов.
2. В `depends_on` использовать `condition: service_healthy`, где это возможно.

## Для отчета по ДЗ

Минимальный комплект артефактов:

1. Логи из Kibana для 2+ сервисов.
2. Метрики из Prometheus/Grafana.
3. Traces из Jaeger.
4. Скриншоты сработавших alert-правил (email + Telegram).
5. Текстовый `protocol.md` с шагами и результатами проверок.
