-- Провижининг БД и ролей для приложений (выполняется до миграций схемы).
-- Идемпотентно: каждый блок создаёт объект только если его ещё нет.
-- \gexec выполняет строку-результат как SQL — так обходим то, что
-- CREATE DATABASE/ROLE не поддерживают syntactic IF NOT EXISTS в одном выражении.

-- Роль для auth-сервиса
SELECT 'CREATE ROLE auth_user LOGIN PASSWORD ''auth_password'''
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'auth_user')\gexec

-- Роль для catalog-сервиса
SELECT 'CREATE ROLE catalog_user LOGIN PASSWORD ''catalog_password'''
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'catalog_user')\gexec

-- База auth во владении postgres: миграции идут под суперюзером (ALTER DEFAULT PRIVILEGES),
-- а права для auth_user выдаёт сама миграция 000002_grant_auth_user_privileges.
-- Роль auth_user должна существовать ДО миграции, иначе её IF EXISTS-гард пропустит гранты.
SELECT 'CREATE DATABASE authdb'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'authdb')\gexec

-- База catalog во владении catalog_user
SELECT 'CREATE DATABASE catalog OWNER catalog_user'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'catalog')\gexec
