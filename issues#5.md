# Homework Report #5: Подключаем БД и систему кэширования

> Цель ДЗ: научиться проектировать работу приложений с СУБД в отказоустойчивом режиме, реализовать distributed-паттерны (Rate Limiter, распределённый мьютекс) и проверить поведение системы при отказе узлов кластера.

---

## Как читать этот отчёт

Для каждого пункта ниже указано:

1. **Что было сделано** — описание решения.
2. **Где это в коде** — пути к файлам и номера строк.
3. **Как проверить руками** — команды для воспроизведения.

---

## 1. Цель домашнего задания

| № | Требование | Статус |
|---|-----------|--------|
| 1 | Подключить СУБД в отказоустойчивом режиме (PostgreSQL, MongoDB, Redis, etcd) | ✅ |
| 2 | Реализовать Rate Limiter | ✅ |
| 3 | Реализовать распределённый мьютекс | ✅ |
| 4 | Тесты по отказам узлов СУБД с нагрузкой на микросервисы | ✅ |

---

## 2. Итоговая схема решения

```text
                    ┌──────────────────────────┐
                    │   Client (HTTPS + JWT)   │
                    └────────────┬─────────────┘
                                 │
                         ┌───────▼────────┐
                         │ shop-gateway   │  ← Rate Limiter (Redis)
                         │ + Retry Logic  │  ← Exponential Backoff (2-32s)
                         └───┬────┬───┬───┘
                             │    │   │
              ┌──────────────┘    │   └──────────────┐
              │                   │                  │
       ┌──────▼──────┐    ┌───────▼────────┐  ┌──────▼──────┐
       │ auth-service│    │ proxy-service  │  │ cart-service│
       │   (mTLS)    │    │ (gRPC proxy)   │  │ + Mutex     │
       └──────┬──────┘    └───────┬────────┘  └──────┬──────┘
              │                   │                  │
              │            ┌──────▼─────────┐        │
              │            │ catalog-service│        │
              │            │     (Redis     │        │
              │            │      cache)    │        │
              │            └──────┬─────────┘        │
              │                   │                  │
   ┌──────────▼───────────────────▼─────┐    ┌──────▼──────┐
   │    PostgreSQL (Patroni HA)         │    │  MongoDB    │
   │  ┌──────┐ ┌──────┐ ┌──────┐        │    │  ReplicaSet │
   │  │patro1│ │patro2│ │patro3│        │    │  3 nodes    │
   │  └───┬──┘ └───┬──┘ └───┬──┘        │    └─────────────┘
   │      └────┬───┴────┬───┘           │
   │     ┌─────▼────────▼─────┐         │    ┌─────────────┐
   │     │  HAProxy (5432)    │         │    │   Redis     │
   │     └────────────────────┘         │    │ (lock+rate) │
   │                                    │    └─────────────┘
   │  ┌──────┐ ┌──────┐ ┌──────┐        │
   │  │etcd1 │ │etcd2 │ │etcd3 │        │
   │  └──────┘ └──────┘ └──────┘        │
   └────────────────────────────────────┘
```

---

## 3. Подключение СУБД в отказоустойчивом режиме

### 3.1 PostgreSQL — кластер на Patroni + etcd + HAProxy

**Что сделано:**
- 3 узла PostgreSQL под управлением Patroni (autofailover).
- 3 узла etcd для согласованного хранения метаданных кластера (Raft consensus).
- HAProxy на порту `5432` направляет writes в primary, опрашивая `/leader` API Patroni.

**Где в коде:**
- `shop-platform/deploy/docker-compose.yml` — секции `etcd1..3`, `patroni1..3`, `postgres-haproxy`.
- `shop-platform/infra/patroni/patroni{1,2,3}.yml` — конфигурации узлов Patroni.
- `shop-platform/infra/haproxy/postgres-haproxy.cfg` — конфигурация балансировщика.

**Как проверить:**
```bash
docker compose -f shop-platform/deploy/docker-compose.yml up -d etcd1 etcd2 etcd3 patroni1 patroni2 patroni3 postgres-haproxy

# Состояние кластера
curl -s http://localhost:18008/cluster | jq

# Принудительный failover
docker stop patroni1
curl -s http://localhost:28008/leader  # patroni2/3 становится лидером
```

### 3.2 MongoDB — ReplicaSet `rs0`

**Что сделано:**
- 3 узла Mongo (`mongo1`, `mongo2`, `mongo3`) запускаются с флагом `--replSet rs0`.
- Сервис `mongo-init` идемпотентно инициализирует replica set с приоритетами (mongo1=2, остальные=1).
- Cart-service использует connection string со всеми тремя узлами:
  ```yaml
  uri: mongodb://mongo1:27017,mongo2:27017,mongo3:27017/?replicaSet=rs0
  ```

**Где в коде:**
- `shop-platform/deploy/docker-compose.yml` — секции `mongo1..3`, `mongo-init` (строки 268-340).
- `shop-cart-service/config/config.docker.yaml` — connection string.

**Как проверить:**
```bash
docker exec mongo1 mongosh --eval "rs.status().members.forEach(m => print(m.name, m.stateStr))"
# mongo1:27017 PRIMARY
# mongo2:27017 SECONDARY
# mongo3:27017 SECONDARY

# Failover
docker stop mongo1
docker exec mongo2 mongosh --eval "rs.status().members.forEach(m => print(m.name, m.stateStr))"
# mongo2 → PRIMARY автоматически
```

### 3.3 Redis

**Что сделано:**
- Redis 7-alpine на порту `6379`.
- Используется в gateway (rate-limiter), catalog-service (cache), cart-service (distributed lock).
- Healthcheck через `redis-cli ping`.

**Где в коде:**
- `shop-platform/deploy/docker-compose.yml` — секция `redis` (строки 127-138).

### 3.4 etcd

**Что сделано:**
- 3-узловой кластер etcd v3.5 (Raft).
- Используется Patroni для leader election и хранения configuration.
- Token: `shop-etcd-cluster`.

**Где в коде:**
- `shop-platform/deploy/docker-compose.yml` — секции `etcd1..3` (строки 141-196).

---

## 4. Шаблон Rate Limiter

### 4.1 Идея

**Sliding Window** алгоритм через Redis Sorted Set:
- Ключ — IP-адрес клиента (или userID).
- Score — timestamp в наносекундах.
- При запросе:
  1. Удаляем записи старше окна (`ZREMRANGEBYSCORE`).
  2. Считаем количество (`ZCARD`).
  3. Если < лимита — `ZADD` + `PEXPIRE`, разрешаем.
  4. Иначе — отказываем (HTTP 429).

Вся операция — атомарная **через Lua-скрипт** (нет race condition между шагами).

### 4.2 Где в коде

| Файл | Назначение |
|------|-----------|
| `shop-gateway/internal/ratelimit/limiter.go` | Реализация лимитера + Lua-скрипт |
| `shop-gateway/internal/transport/http/v1/middleware/ratelimit.go` | HTTP middleware |
| `shop-gateway/internal/config/config.go` | `RateLimitConfig` (limit + window) |
| `shop-gateway/config/config.docker.yaml` | `rate_limit: {limit: 100, window: 1m}` |
| `shop-gateway/internal/app/app.go` | Подключение лимитера в роутер |

### 4.3 Lua-скрипт

```lua
local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])

redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
local count = tonumber(redis.call('ZCARD', key))

if count < limit then
    redis.call('ZADD', key, now, now)
    redis.call('PEXPIRE', key, window)
    return 1
end
return 0
```

### 4.4 Как проверить

```bash
# 100 запросов в минуту разрешено, 101-й — отказ:
for i in $(seq 1 105); do
  curl -k -s -o /dev/null -w "%{http_code}\n" https://localhost:8083/products
done | sort | uniq -c
#  100 200
#    5 429
```

---

## 5. Распределённый мьютекс

### 5.1 Идея

Используем **Redis SET NX EX** (set-if-not-exists с TTL):

1. **Lock**: пытаемся `SET cart:lock:{userID} {uuid} NX EX 30`.
   - Если получилось — мы владельцы замка.
   - Если нет — ждём `retry_interval` и повторяем (до `max_retries`).
2. **Unlock**: атомарно через **Lua-скрипт** проверяем что `lockValue` совпадает с нашим UUID (защита от удаления чужого замка после истечения TTL).
3. **TTL = 30s** — защита от deadlock при падении процесса.

### 5.2 Где в коде

| Файл | Назначение |
|------|-----------|
| `shop-cart-service/internal/lock/distributed_lock.go` | Реализация Lock/Unlock |
| `shop-cart-service/internal/repository/mongodb/repository.go` | Использование в `AddItem`, `RemoveItem`, `UpdateItem`, `ClearCart` |
| `shop-cart-service/internal/config/config.go` | `LockConfig` (TTL, RetryInterval, MaxRetries) |
| `shop-cart-service/config/config.docker.yaml` | `lock: {ttl: 30s, retry_interval: 100ms, max_retries: 50}` |
| `shop-cart-service/internal/app/app.go` | Инициализация Redis и DistributedLock |

### 5.3 Lua-скрипт безопасного Unlock

```lua
if redis.call("GET", KEYS[1]) == ARGV[1] then
    return redis.call("DEL", KEYS[1])
else
    return 0
end
```

> Проверка `GET == lockValue` И `DEL` выполняются атомарно — между ними замок не может измениться.

### 5.4 Применение в репозитории

```go
func (c *cartRepository) AddItem(ctx context.Context, userID string, item domain.CartItem) error {
    lockValue, err := c.lock.Lock(ctx, userID)
    if err != nil {
        return fmt.Errorf("lock cart: %w", err)
    }
    defer c.lock.Unlock(ctx, userID, lockValue)

    // ... модификация корзины в MongoDB ...
}
```

> `GetCart` намеренно **без** мьютекса — это read-операция, и блокировки сильно ударили бы по latency.

### 5.5 Как проверить

```bash
# Создаём 20 параллельных AddItem от одного user_id
for i in $(seq 1 20); do
  curl -k -s -X POST https://localhost:8083/cart/items \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"product_id":"P-1","quantity":1,"price_snapshot":100}' &
done
wait

# Проверяем количество:
curl -k -s -H "Authorization: Bearer $TOKEN" https://localhost:8083/cart | jq '.items[0].quantity'
# 20 ← без потерь, race condition не произошёл
```

---

## 6. Бонус: Retry Logic с Exponential Backoff

Помимо явных требований ДЗ, реализован паттерн **Retry с экспоненциальной задержкой** — он отлично дополняет работу с распределёнными СУБД (gRPC-клиенты к auth/catalog/cart часто стартуют до того, как зависимый сервис принимает соединения).

### 6.1 Алгоритм

| Попытка | Задержка перед следующей |
|---------|--------------------------|
| 0 | 2s |
| 1 | 4s |
| 2 | 8s |
| 3 | 16s |
| 4 | 32s (cap) |
| 5 | — (последняя, без задержки) |

### 6.2 Где в коде

- `shop-gateway/internal/app/retry.go` — функция `retryWithExponentialBackoff`.
- `shop-gateway/internal/app/app.go` — обёрнуты вызовы создания всех трёх gRPC-клиентов.
- `shop-gateway/config/config.docker.yaml`:
  ```yaml
  retry:
    max_retries: 6
    initial_interval: 2s
    max_interval: 32s
  ```

---

## 7. Тесты по отказам узлов СУБД с нагрузкой

### 7.1 Сценарий А: отказ primary PostgreSQL

**Шаги:**
1. Запускаем нагрузку через `shop-platform/load`:
   ```bash
   cd shop-platform/load && go run . -rate 50 -duration 60s
   ```
2. На 20-й секунде убиваем лидер:
   ```bash
   docker stop patroni1
   ```

**Результат:**
- Patroni за **2-3 секунды** выбирает нового лидера через etcd.
- HAProxy через `httpchk /leader` обнаруживает смену и переключает trafic.
- В логах нагрузочного теста видна короткая полоса `502 Bad Gateway` (~3 сек), затем восстановление.
- **Потерь записей нет** благодаря synchronous replication.

### 7.2 Сценарий Б: отказ primary MongoDB

**Шаги:**
1. Параллельная нагрузка `AddItem` на cart-service.
2. `docker stop mongo1` (primary).

**Результат:**
- MongoDB driver на клиенте автоматически переподключается к новому primary (mongo2 → PRIMARY).
- Период недоступности: **~5 секунд** (election + driver reconnect).
- Distributed lock в Redis при этом не теряется (Redis работает независимо).

### 7.3 Сценарий В: потеря кворума etcd

**Шаги:**
1. `docker stop etcd2 etcd3` (остаётся 1 из 3 узлов).

**Результат:**
- etcd **переходит в read-only**: writes невозможны.
- Patroni не может обновлять leader-key → primary продолжает работать (демократия Patroni: пока ключ не expired, primary остаётся).
- Через ~30 секунд (TTL ключа) Patroni переводит primary в read-only режим — **защита от split-brain**.
- Восстановление узлов etcd → автоматическое возвращение в работу без вмешательства.

**Вывод:** правильный подход — **3 узла etcd обязательны**, 2 из 3 = кворум. Если допустить потерю двух — кластер встанет.

### 7.4 Сценарий Г: отказ Redis (rate limiter + lock)

**Шаги:**
1. `docker stop redis`

**Результат:**
- Rate limiter возвращает ошибку → запросы пропускаются с warning в логах (fail-open для rate limit).
- Distributed lock падает с ошибкой → cart-методы возвращают 5xx.
- В production стоит вынести rate-limiter в **Redis Cluster / Sentinel** (3+ узла).

---

## 8. ⭐ Задача со звездочкой: сравнение альтернативных решений

### 8.1 Rate Limiter: Redis Sorted Set vs. Token Bucket vs. In-memory

| Решение | Плюсы | Минусы | Когда применять |
|---------|-------|--------|-----------------|
| **Redis Sorted Set (мой выбор)** | Точное sliding window; атомарность через Lua; работает в кластере | Требует Redis; +1 RTT на запрос | Микросервисы, балансировка |
| **Token Bucket в Redis** | Меньше памяти (1 ключ на пользователя); проще | Менее точный (всплески пропускает) | Высоконагруженные API |
| **In-memory (golang.org/x/time/rate)** | Нулевая latency; нет внешних зависимостей | Не работает между инстансами | Single-pod, sidecar |

**Вывод:** для микросервисов с горизонтальным масштабированием **Sliding Window в Redis** — оптимальный баланс точности и распределённости.

### 8.2 Distributed Lock: Redis SET NX vs. etcd lease vs. Postgres advisory lock

| Решение | Плюсы | Минусы | Когда применять |
|---------|-------|--------|-----------------|
| **Redis SET NX (мой выбор)** | Очень быстрый (<1ms); простой API; уже есть Redis | Не linearizable при partition; вопрос с Redlock | Корзины, idempotency keys |
| **etcd lease** | Linearizable (Raft); auto-renew lease; watch-нотификации | Высокая latency (~10ms); сложнее API | Leader election, configuration |
| **Postgres advisory lock** | Транзакционен с данными; нет внешних зависимостей | Только для PG-related операций; проблемы при HA | Транзакции внутри одной БД |

**Вывод:** для **операций над корзиной** Redis-lock достаточен — критичной linearizability не требуется, а скорость важна. Для leader-election (например, scheduled jobs в одном инстансе) — лучше etcd.

### 8.3 In-memory СУБД: Redis vs. Valkey vs. Tarantool/Picodata

| Решение | Плюсы | Минусы | Когда применять |
|---------|-------|--------|-----------------|
| **Redis (мой выбор)** | Огромная экосистема; Lua, Streams, Pub/Sub | BSL-лицензия начиная с 7.4 | Cache, Locks, Rate Limit |
| **Valkey** | Форк Redis, BSD-лицензия, drop-in replacement | Молодой проект (2024) | Production без legal-рисков |
| **Tarantool / Picodata** | In-memory + persistent; SQL + Lua-stored procedures; шардинг из коробки | Меньше готовых библиотек; нужен Lua для процедур | Сценарии с heavy-логикой на стороне БД |

**Вывод:** в данном проекте Redis выбран из-за **готовых библиотек** (`go-redis/v9`) и широкой поддержки в OpenTelemetry. Для миграции на Valkey достаточно сменить образ.

---

## 9. Скриншоты (см. `shop-platform/images/`)

| Файл | Описание |
|------|----------|
| `image.png` — `image-3.png` | Patroni cluster status и failover |
| `image-4.png` — `image-6.png` | MongoDB ReplicaSet статус |
| `image-7.png` — `image-9.png` | Swagger UI / Rate Limiter (HTTP 429) |
| `image-10.png` — `image-11.png` | Grafana дашборд с метриками distributed lock |

> Все скриншоты лежат в `shop-platform/images/`.

---

## 10. Как запустить весь стек

```bash
cd shop-platform/deploy
docker compose up -d

# Если миграции упали (БД ещё не была готова):
docker compose up -d auth-migrate catalog-migrate

# Проверка:
curl -k https://localhost:8083/ready          # 200 OK
open https://localhost:8083/swagger/          # Swagger UI
open http://localhost:3000                    # Grafana
open http://localhost:16686                   # Jaeger
open http://localhost:5601                    # Kibana
```

**Регистрация и тест Rate Limiter / Mutex:**
1. Swagger → `/auth/register` → получить токен.
2. `/auth/login` → токен в "Authorize" в Swagger.
3. Бомбить `/cart/items` параллельно — увидеть как mutex сериализует записи.
4. Бомбить любой endpoint > 100/min — увидеть HTTP 429.

---

## 11. Чеклист критериев приёмки

| Критерий | Статус | Где проверить |
|----------|:------:|---------------|
| Результат в виде PR | ✅ | См. PR в репозиторий |
| `README.md` в корне | ✅ | `shop-platform/README.md` |
| Локальная сборка без ошибок | ✅ | `docker compose build` |
| CI/CD без ошибок | ✅ | GitHub Actions |
| Тестирование СУБД под нагрузкой | ✅ | Раздел 7 |
| Поведение без кворума | ✅ | Раздел 7.3 |
| Rate Limiter | ✅ | Раздел 4 |
| Distributed Mutex | ✅ | Раздел 5 |
| ⭐ Сравнение альтернатив | ✅ | Раздел 8 |

---

## 12. Компетенции, отработанные в ДЗ

- ✅ Выбор подходящих систем хранения для микросервисов (PostgreSQL для транзакций, MongoDB для cart, Redis для cache/locks).
- ✅ Использование in-memory решений (Redis sorted sets для rate-limit, SET NX для lock).
- ✅ Применение Redis (3 разных паттерна в одном проекте).
- ✅ Особенности etcd (Raft consensus, кворум, использование в Patroni).
- ✅ Понимание различий Tarantool / Picodata vs Redis (раздел 8.3).
