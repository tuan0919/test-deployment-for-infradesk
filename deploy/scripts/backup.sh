#!/usr/bin/env bash
set -euo pipefail

: "${DATA_ROOT:?Set DATA_ROOT to the host runtime directory}"
: "${BACKUP_ROOT:?Set BACKUP_ROOT to the host backup directory}"
: "${POSTGRES_USER:?Set POSTGRES_USER}"
: "${POSTGRES_DB:?Set POSTGRES_DB}"

BACKUP_ID="${BACKUP_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
DEST="${BACKUP_ROOT%/}/${BACKUP_ID}"
mkdir -p "$DEST"

echo "Backing up to ${DEST}"

docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "${DEST}/database.sql"
tar -C "$DATA_ROOT" -czf "${DEST}/uploads.tgz" uploads

{
  echo "backup_id=${BACKUP_ID}"
  echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "data_root=${DATA_ROOT}"
  echo "image_tag=${IMAGE_TAG:-unknown}"
} > "${DEST}/manifest.txt"

echo "backup complete: ${BACKUP_ID}"
