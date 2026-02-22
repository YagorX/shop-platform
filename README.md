# shop-platform

Инфраструктурный репозиторий локального observability-стенда для учебного проекта `Mini-Shop`.

Задача этого репозитория:
- поднять локально Kafka + ELK + Prometheus/Grafana + Jaeger,
- дать единую среду для проверки логов, метрик и трейсов сервисов,
- не хранить бизнес-логику сервисов (она живет в отдельных репозиториях).

## Что здесь лежит

- `deploy/docker-compose.yml`
  - локальный запуск всех инфраструктурных компонентов.
- `infra/filebeat/filebeat.yml`
  - сбор логов контейнеров Docker и отправка в Kafka (`logs.v1`).
- `infra/logstash/pipeline/logstash.conf`
  - чтение логов из Kafka и запись в Elasticsearch.
- `infra/prometheus/prometheus.yml`
  - scrape-конфиг для Prometheus.
- `bugs/README.md` (локально, не для push)
  - заметки по найденным проблемам и исправлениям.

## Роль каждого компонента

### Kafka

Используется как буфер и шина доставки:
- для логов: `Filebeat -> Kafka(logs.v1) -> Logstash`
- позже для бизнес-событий сервисов (в других репозиториях).

Почему это полезно:
- decoupling (развязка producer/consumer),
- переживание кратковременных падений downstream,
- удобная диагностика (можно проверить offset и consumer groups).

### Filebeat

Собирает stdout/stderr контейнеров Docker из файлов:
- читает `/var/lib/docker/containers/*/*.log`,
- добавляет docker metadata (`container.name`, `container.id`, `image`),
- отбрасывает логи инфраструктурных контейнеров (чтобы не было рекурсии),
- пытается распаковать JSON в поле `message`,
- отправляет всё в Kafka topic `logs.v1`.

Важно:
- сервисы должны писать структурированные JSON-логи в `stdout`,
- Filebeat не должен сам отправлять логи напрямую в Elasticsearch в этом проекте.

### Logstash

Читает `logs.v1` из Kafka и пишет в Elasticsearch:
- `input.kafka` -> берет сообщения из topic `logs.v1`,
- `codec => json` -> декодирует JSON от Filebeat,
- `filter` -> нормализует `@timestamp` (если пришел только `timestamp`) и добавляет `pipeline=logs.v1`,
- `output.elasticsearch` -> пишет в индекс `app-logs-local-YYYY.MM.dd`.

Важно:
- в `output` убран `stdout { codec => rubydebug }`, чтобы не было петли логов.

### Elasticsearch

Хранилище логов:
- принимает документы от Logstash,
- хранит индекс `app-logs-local-*`,
- отдает данные Kibana.

Важно:
- используем префикс `app-logs-*`, а не `logs-*`, чтобы не конфликтовать с built-in data stream шаблонами Elastic.

### Kibana

UI для поиска и анализа логов:
- создается `Data View` по шаблону `app-logs-local-*`,
- в `Discover` ищем по полям (`service`, `level`, `trace_id`, `container.name`, и т.д.).

### Prometheus

Система сбора метрик:
- опрашивает `/metrics` у сервисов,
- хранит метрики локально,
- отдает их Grafana.

Сейчас в MVP:
- сам Prometheus,
- `node-exporter` (если включен и поддерживается локальной средой).

### Grafana

Визуализация метрик Prometheus:
- dashboards по RED/USE,
- позже алерты и уведомления.

### Jaeger

UI и backend для трассировок:
- сервисы будут отправлять трейс-данные через OpenTelemetry (OTLP),
- Jaeger позволит смотреть end-to-end trace.

## Как всё взаимодействует (потоки)

### 1) Логи (основной поток)

1. Сервис пишет JSON в `stdout`
2. Docker сохраняет лог в контейнерный файл
3. Filebeat читает файл
4. Filebeat добавляет docker metadata и парсит JSON (`decode_json_fields`)
5. Filebeat отправляет сообщение в Kafka topic `logs.v1`
6. Logstash читает `logs.v1`
7. Logstash применяет фильтры/нормализацию
8. Logstash пишет документ в Elasticsearch (`app-logs-local-*`)
9. Kibana читает из Elasticsearch и показывает в Discover

### 2) Метрики

1. Сервис отдает `GET /metrics`
2. Prometheus делает scrape по расписанию
3. Grafana читает данные из Prometheus
4. Пользователь смотрит dashboards

### 3) Трейсы

1. Сервис инструментирован OpenTelemetry
2. Сервис экспортирует spans в Jaeger (OTLP)
3. Jaeger UI показывает trace и спаны

## Почему были ошибки и что важно помнить

### Ошибка 1: петля логов (feedback loop)

Причина:
- Filebeat собирал логи `logstash`,
- Logstash печатал обработанные события в stdout (`rubydebug`),
- эти логи снова попадали в Kafka.

Симптомы:
- странные многострочные сообщения в Kafka,
- ошибки JSON parse,
- перегрузка pipeline.

Фикс:
- убрать `stdout { codec => rubydebug }` из Logstash,
- исключить infra-контейнеры в Filebeat (`drop_event`).

### Ошибка 2: single-node Kafka и consumer groups

Причина:
- внутренние Kafka topics (`__consumer_offsets`, transaction state) требовали replication > 1 по умолчанию.

Симптомы:
- consumers не читали сообщения,
- Logstash `events.in = 0`,
- `kafka-console-consumer` не получал сообщения.

Фикс:
- выставить single-node настройки replication/ISR в `docker-compose.yml`.

### Ошибка 3: конфликт с Elastic data stream (`logs-*`)

Причина:
- индекс `logs-local-*` попал под встроенные шаблоны `logs-*-*`.

Симптомы:
- Logstash читал Kafka, но ES отклонял документы,
- ошибки про `op_type=create` / data stream.

Фикс:
- сменить префикс на `app-logs-local-*`.

## Быстрая проверка после запуска

### 1. Поднять инфраструктуру

```powershell
docker compose -f all_project/shop-platform/deploy/docker-compose.yml up -d
```

### 2. Проверить контейнеры

```powershell
docker compose -f all_project/shop-platform/deploy/docker-compose.yml ps
```

### 3. Сгенерировать тестовый лог (JSON в stdout)

```powershell
docker run --rm --name fb-smoke alpine sh -c "echo '{\"@timestamp\":\"2026-02-22T13:40:00Z\",\"level\":\"info\",\"service\":\"fb-smoke\",\"env\":\"local\",\"message\":\"json smoke\",\"trace_id\":\"t1\"}'"
```

### 4. Проверить, что документ дошел до Elasticsearch

```powershell
Invoke-RestMethod -Method Get -Uri "http://localhost:9200/app-logs-local-*/_count"
```

### 5. Проверить pipeline Logstash

```powershell
docker exec logstash curl -s http://localhost:9600/_node/stats/pipelines?pretty
```

Смотреть:
- `pipelines.main.events.in`
- `pipelines.main.events.out`
- `outputs.elasticsearch.documents.successes`

### 6. Kibana Data View

- `Stack Management` -> `Data Views` -> `Create data view`
- Pattern: `app-logs-local-*`
- Timestamp field: `@timestamp`

## Что будет дальше (после платформы)

После стабилизации `shop-platform` подключаем первый сервис:
- `shop-catalog-service` (gRPC + `/metrics` + JSON logs + OTel traces),
- затем `shop-gateway` и `shop-order-service`,
- потом async-сервисы с Kafka бизнес-событиями.

