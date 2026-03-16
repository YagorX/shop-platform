# shop-platform

`shop-platform` — инфраструктурный репозиторий локального стенда для observability и security-проверок всего mini-shop.

Цель репозитория:

1. Поднять единое окружение для `catalog-service`, `auth-service` и `gateway-service`.
2. Дать воспроизводимый compose-стенд с метриками, логами, трейсами и alerting.
3. Позволить проверять не только бизнес-функции, но и эксплуатационные сценарии: health/readiness, TLS, mTLS и monitoring.

## Что поднимается в compose

1. Kafka
2. Elasticsearch
3. Kibana
4. Logstash
5. Filebeat
6. Prometheus
7. Grafana
8. Jaeger
9. PostgreSQL для catalog
10. Redis для catalog cache
11. PostgreSQL для auth
12. `auth-migrate`
13. `catalog-service`
14. `auth-service`
15. `gateway-service`

## Security model стенда

1. Внешний клиентский вход идет через `shop-gateway` по HTTPS.
2. `shop-gateway -> shop-auth` использует gRPC mTLS.
3. `shop-gateway -> shop-catalog-service` использует внутренний gRPC канал.
4. JWT access token используется для auth flow.
5. Пароли хранятся как `bcrypt` hash.
6. Refresh sessions хранят hash refresh token, а не исходное значение.

## Observability model

1. Логи: JSON в stdout -> Filebeat -> Kafka -> Logstash -> Elasticsearch -> Kibana.
2. Метрики: сервисы отдают `/metrics`, Prometheus их скрейпит, Grafana строит dashboards и alerts.
3. Трейсы: сервисы экспортируют OTLP в Jaeger.
4. `gateway-service` скрейпится Prometheus по HTTPS.

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

1. Gateway HTTPS: `https://localhost:8083`
2. Catalog HTTP: `http://localhost:8081`
3. Catalog gRPC: `localhost:9091`
4. Auth HTTP: `http://localhost:8082`
5. Auth gRPC: `localhost:44044`
6. Prometheus: `http://localhost:9090`
7. Grafana: `http://localhost:3000`
8. Kibana: `http://localhost:5601`
9. Jaeger: `http://localhost:16686`
10. Elasticsearch: `http://localhost:9200`

## Проверка логов

1. Сервисы пишут structured JSON logs в stdout.
2. Filebeat читает Docker logs и отправляет их в Kafka.
3. Logstash забирает сообщения из Kafka и пишет в Elasticsearch.
4. В Kibana можно строить Data View по индексам `app-logs-local-*`.

## Проверка метрик

Примеры:

```bash
curl -k https://localhost:8083/metrics
curl http://localhost:8081/metrics
curl http://localhost:8082/metrics
```

Что важно:

1. `gateway-service` скрейпится Prometheus по `https://gateway-service:8083/metrics`.
2. Для dev-certificate в Prometheus включен `insecure_skip_verify`.
3. `catalog-service` и `auth-service` отдают operational HTTP endpoints внутри стенда по HTTP.

## Проверка трейсов

В Jaeger должны быть видны как минимум две цепочки:

1. `gateway -> catalog`
2. `gateway -> auth`

Это позволяет проверить:

1. входящий HTTP span на gateway;
2. service-level spans;
3. исходящий gRPC client span;
4. серверный span во внутреннем сервисе.

## Health / Readiness практика

1. `/health` отвечает только за liveness процесса.
2. `/ready` отвечает за готовность к реальному трафику.
3. Для `gateway-service` readiness зависит от двух gRPC health-check:
   - `catalog-service`
   - `auth-service`
4. Для `catalog-service` и `auth-service` readiness показывает готовность собственных зависимостей.

## Базовый protocol smoke-check

1. `curl -k https://localhost:8083/ready`
2. `curl http://localhost:8081/ready`
3. `curl http://localhost:8082/ready`
4. `curl -k https://localhost:8083/products`
5. `POST https://localhost:8083/auth/register`
6. `POST https://localhost:8083/auth/login`

## Для отчета по ДЗ

Минимальный комплект артефактов:

1. Скриншоты healthy compose-стека.
2. Скриншоты логов из Kibana минимум для двух сервисов.
3. Скриншоты метрик в Prometheus и dashboard/alert rule в Grafana.
4. Скриншоты trace chain в Jaeger.
5. Проверки HTTPS gateway.
6. Проверки mTLS канала `gateway -> auth-service`.
7. Текстовый `protocol.md` с шагами, результатами и выводами.
