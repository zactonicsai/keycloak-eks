#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$#" -ne 1 ]; then
  printf 'Usage: CONFIRM_RESTORE=YES %s backups/<backup-file>.dump\n' "$0" >&2
  exit 2
fi

if [ "${CONFIRM_RESTORE:-NO}" != "YES" ]; then
  printf 'Refusing destructive restore. Re-run with CONFIRM_RESTORE=YES.\n' >&2
  exit 2
fi

BACKUP_FILE="$1"
if [ ! -s "$BACKUP_FILE" ]; then
  printf 'Backup file not found or empty: %s\n' "$BACKUP_FILE" >&2
  exit 2
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

POSTGRES_DB="${POSTGRES_DB:-keycloak}"
POSTGRES_USER="${POSTGRES_USER:-keycloak}"

printf 'Stopping Keycloak...\n'
docker compose stop keycloak 2>/dev/null || true

printf 'Recreating database %s...\n' "$POSTGRES_DB"
docker compose exec -T postgres dropdb --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"
docker compose exec -T postgres createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$POSTGRES_DB"

printf 'Restoring %s...\n' "$BACKUP_FILE"
docker compose exec -T postgres \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
  < "$BACKUP_FILE"

printf 'Database restore complete. Restore the old Keycloak 20 Dockerfile and Compose file before starting Keycloak 20.\n'
