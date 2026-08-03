#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

TARGET_VERSION="${KEYCLOAK_VERSION:-26.7.0}"

printf '\n1. Creating a PostgreSQL backup...\n'
./scripts/backup-database.sh

printf '\n2. Stopping Keycloak 20 without deleting PostgreSQL...\n'
docker compose stop keycloak 2>/dev/null || true

docker rm -f keycloak20 2>/dev/null || true

printf '\n3. Building Keycloak %s from the official ZIP...\n' "$TARGET_VERSION"
KEYCLOAK_VERSION="$TARGET_VERSION" docker compose build --no-cache keycloak

printf '\n4. Starting PostgreSQL and Keycloak %s...\n' "$TARGET_VERSION"
docker compose up -d postgres keycloak

printf '\n5. Current container status:\n'
docker compose ps

cat <<MSG

Upgrade startup has begun.

Follow the migration logs with:
  docker compose logs -f keycloak

Check readiness with:
  curl http://localhost:9000/health/ready

Do not remove the database backup until login, clients, realms, and applications
have been tested successfully.
MSG
