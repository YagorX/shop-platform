#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# 1. Приватный ключ CA
openssl genrsa -out ca.key 4096

# 2. Самоподписанный корневой сертификат (10 лет)
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/CN=ProjectShop Root CA" -out ca.crt

# Хелпер: серверный серт, подписанный нашим CA.
# $1 = имя файла/роли, $2 = DNS-имя сервиса (оно же ServerName у клиента)
gen_server_cert() {
  local name="$1" dns="$2"
  openssl genrsa -out "${name}.key" 2048
  openssl req -new -key "${name}.key" -subj "/CN=${dns}" -out "${name}.csr"
  openssl x509 -req -in "${name}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 825 -sha256 -out "${name}.crt" \
    -extfile <(printf "subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1" "$dns")
  rm -f "${name}.csr"
}

gen_server_cert catalog-server catalog-service
gen_server_cert cart-server  cart-service
gen_server_cert proxy-server proxy-service
gen_server_cert auth-service auth-service
gen_server_cert gateway-server gateway-service


# Хелпер: клиентский серт (mTLS). SAN не нужен — сервер проверяет только подпись CA.
gen_client_cert() {
  local name="$1"
  openssl genrsa -out "${name}.key" 2048
  openssl req -new -key "${name}.key" -subj "/CN=${name}" -out "${name}.csr"
  openssl x509 -req -in "${name}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 825 -sha256 -out "${name}.crt"
  rm -f "${name}.csr"
}

gen_client_cert gateway-client
gen_client_cert proxy-client

# Серверные/клиентские ключи должны читаться юзером контейнера (uid != владельца bind-mount).
# 644 приемлемо для локального стенда; в проде ключи берутся из Vault и на диск не пишутся.
# ca.key намеренно оставляем 600 — он подписывает серты и наружу не монтируется.
chmod 644 *.crt
chmod 644 *-server.key *-client.key auth-service.key
chmod 600 ca.key