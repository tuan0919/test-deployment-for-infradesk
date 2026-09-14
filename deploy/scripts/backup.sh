#!/usr/bin/env bash
set -euo pipefail

: "${DEPLOY_DIR:?Set DEPLOY_DIR to the host runtime directory}"
: "${BACKUP_ROOT:?Set BACKUP_ROOT to the host backup directory}"
: "${POSTGRES_USER:?Set POSTGRES_USER}"
: "${POSTGRES_DB:?Set POSTGRES_DB}"

BACKUP_ID="${BACKUP_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
DEST="${BACKUP_ROOT%/}/${BACKUP_ID}"
mkdir -p "$DEST"

echo "Backing up to ${DEST}"

docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "${DEST}/database.sql"
tar -C "$DEPLOY_DIR" -czf "${DEST}/uploads.tgz" uploads

{
  echo "backup_id=${BACKUP_ID}"
  echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "data_root=${DEPLOY_DIR}"
  echo "image_tag=${IMAGE_TAG:-unknown}"
} > "${DEST}/manifest.txt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DEST="${MANIFEST_OUTPUT:-${DEST}/backup-reference.json}"

echo "Uploading backup to Kopia and publishing manifest..."
"${SCRIPT_DIR}/kopia-backup.sh" "$DEST" "$MANIFEST_DEST"

echo "backup complete: ${BACKUP_ID}"
