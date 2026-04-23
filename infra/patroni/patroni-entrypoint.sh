#!/bin/sh
set -e

PGDATA_DIR="${PGDATA:-/var/lib/postgresql/data}"

mkdir -p "$PGDATA_DIR" /var/run/postgresql
chown -R postgres:postgres "$PGDATA_DIR" /var/run/postgresql
chmod 3775 /var/run/postgresql
chmod 700 "$PGDATA_DIR"


exec gosu postgres patroni "$@"
