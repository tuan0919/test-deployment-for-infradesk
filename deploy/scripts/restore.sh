#!/usr/bin/env bash
set -euo pipefail

: "${DEPLOY_DIR:?Set DEPLOY_DIR to the host runtime directory}"
: "${BACKUP_ROOT:?Set BACKUP_ROOT to the host backup directory}"
: "${BACKUP_ID:?Set BACKUP_ID to the backup folder name}"
: "${POSTGRES_USER:?Set POSTGRES_USER}"
: "${POSTGRES_DB:?Set POSTGRES_DB}"

DEST="${BACKUP_ROOT%/}/${BACKUP_ID}"
test -f "${DEST}/database.sql" || { echo "missing ${DEST}/database.sql"; exit 1; }
test -f "${DEST}/uploads.tgz" || { echo "missing ${DEST}/uploads.tgz"; exit 1; }

echo "Restoring from ${DEST}"

docker compose stop web
mkdir -p "${DEPLOY_DIR}/uploads"
tar -xzf "${DEST}/uploads.tgz" -C "$DEPLOY_DIR"

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "${DEST}/database.sql"
docker compose up -d --remove-orphans

echo "restore complete: ${BACKUP_ID}"
