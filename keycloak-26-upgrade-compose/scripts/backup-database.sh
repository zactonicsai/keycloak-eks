#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

mkdir -p backups
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="backups/keycloak-before-upgrade-${STAMP}.dump"

POSTGRES_DB="${POSTGRES_DB:-keycloak}"
POSTGRES_USER="${POSTGRES_USER:-keycloak}"

printf 'Starting PostgreSQL if needed...\n'
docker compose up -d postgres

printf 'Waiting for PostgreSQL...\n'
for attempt in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    printf 'ERROR: PostgreSQL did not become ready.\n' >&2
    exit 1
  fi
  sleep 2
done

printf 'Writing %s...\n' "$BACKUP_FILE"
docker compose exec -T postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom \
  > "$BACKUP_FILE"

if [ ! -s "$BACKUP_FILE" ]; then
  printf 'ERROR: Backup file is empty.\n' >&2
  exit 1
fi

printf 'Backup complete: %s\n' "$BACKUP_FILE"
