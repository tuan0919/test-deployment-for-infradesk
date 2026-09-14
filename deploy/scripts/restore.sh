#!/usr/bin/env bash
set -euo pipefail

# deploy/scripts/restore.sh
# Restores application database and uploads from a verified backup manifest via Kopia,
# with fallback support for legacy backup directory restore.
# Usage: ./restore.sh [manifest-file-path | backup-folder-name]

ORIG_UMASK="$(umask)"

: "${DEPLOY_DIR:?Error: Set DEPLOY_DIR to the host runtime directory}"
: "${POSTGRES_USER:?Error: Set POSTGRES_USER}"
: "${POSTGRES_DB:?Error: Set POSTGRES_DB}"

MANIFEST_PATH="${MANIFEST_PATH:-}"
USE_LEGACY_BACKUP_ID=""

if [ $# -ge 1 ] && [ -n "$1" ]; then
  if [ -f "$1" ]; then
    MANIFEST_PATH="$1"
  elif [ -n "${BACKUP_ROOT:-}" ] && [ -d "${BACKUP_ROOT%/}/$1" ]; then
    USE_LEGACY_BACKUP_ID="$1"
  elif [ -d "$1" ]; then
    USE_LEGACY_BACKUP_ID="$1"
  elif [[ "$1" == *.json ]]; then
    echo "Error: Manifest file not found: $1" >&2
    exit 1
  else
    echo "Error: Argument '$1' is neither an existing manifest file nor an existing backup folder" >&2
    exit 1
  fi
elif [ -n "${MANIFEST_PATH}" ]; then
  if [ ! -f "${MANIFEST_PATH}" ]; then
    echo "Error: Manifest file specified in MANIFEST_PATH not found: ${MANIFEST_PATH}" >&2
    exit 1
  fi
elif [ -n "${BACKUP_ID:-}" ]; then
  USE_LEGACY_BACKUP_ID="${BACKUP_ID}"
else
  echo "Usage: $0 <manifest-path> (or set BACKUP_ID in legacy mode)" >&2
  exit 1
fi

RESTORE_SOURCE_DIR=""

if [ -n "$MANIFEST_PATH" ]; then
  echo "Using backup manifest: $MANIFEST_PATH"

  if [ ! -s "$MANIFEST_PATH" ]; then
    echo "Error: Manifest file is empty or missing: $MANIFEST_PATH" >&2
    exit 1
  fi

  # Validate JSON schema and extract required fields without using source or eval
  if ! SCHEMA_VERSION=$(jq -er 'if (.schemaVersion | type == "number") then .schemaVersion else error("missing or non-numeric schemaVersion") end' "$MANIFEST_PATH" 2>/dev/null); then
    echo "Error: Failed to read valid schemaVersion from manifest" >&2
    exit 1
  fi

  if [ "$SCHEMA_VERSION" -ne 1 ]; then
    echo "Error: Unsupported schemaVersion: $SCHEMA_VERSION (expected 1)" >&2
    exit 1
  fi

  if ! SNAPSHOT_ID=$(jq -er 'if (.snapshotId | type == "string" and length > 0) then .snapshotId else error("missing or empty snapshotId") end' "$MANIFEST_PATH" 2>/dev/null); then
    echo "Error: Failed to read valid snapshotId from manifest" >&2
    exit 1
  fi

  # Validate snapshotId format
  if [[ ! "$SNAPSHOT_ID" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "Error: Invalid snapshotId format: $SNAPSHOT_ID" >&2
    exit 1
  fi

  # Validate database compatibility if present in manifest
  MANIFEST_DB=$(jq -r '.database // empty' "$MANIFEST_PATH" 2>/dev/null || true)
  if [ -n "$MANIFEST_DB" ] && [ "$MANIFEST_DB" != "$POSTGRES_DB" ]; then
    echo "Error: Manifest database ($MANIFEST_DB) does not match POSTGRES_DB ($POSTGRES_DB)" >&2
    exit 1
  fi

  # Safely extract and validate optional metadata
  MANIFEST_IMAGE_TAG=$(jq -r '.imageTag // empty' "$MANIFEST_PATH" 2>/dev/null || true)
  if [ -n "$MANIFEST_IMAGE_TAG" ]; then
    if [[ ! "$MANIFEST_IMAGE_TAG" =~ ^[a-zA-Z0-9_.:-]+$ ]]; then
      echo "Error: Invalid imageTag in manifest metadata: $MANIFEST_IMAGE_TAG" >&2
      exit 1
    fi
    IMAGE_TAG="${IMAGE_TAG:-$MANIFEST_IMAGE_TAG}"
    export IMAGE_TAG
  fi

  MANIFEST_BACKUP_ID=$(jq -r '.backupId // empty' "$MANIFEST_PATH" 2>/dev/null || true)
  if [ -n "$MANIFEST_BACKUP_ID" ]; then
    if [[ ! "$MANIFEST_BACKUP_ID" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
      echo "Error: Invalid backupId in manifest metadata: $MANIFEST_BACKUP_ID" >&2
      exit 1
    fi
    BACKUP_ID="${BACKUP_ID:-$MANIFEST_BACKUP_ID}"
  fi
  BACKUP_ID="${BACKUP_ID:-$SNAPSHOT_ID}"
  export BACKUP_ID

  # Security: restrict permissions on config and staging directory
  umask 077

  CFG="$(mktemp -t kopia-cfg-XXXXXXXX)"
  STAGING_DIR="$(mktemp -d -t infradesk-restore-staging-XXXXXXXX)"

  cleanup() {
    if command -v kopia >/dev/null 2>&1; then
      kopia --config-file="$CFG" repository disconnect >/dev/null 2>&1 || true
    fi
    rm -f "$CFG" "$CFG".* 2>/dev/null || true
    if [ -d "$STAGING_DIR" ]; then
      rm -rf "$STAGING_DIR"
    fi
  }
  trap cleanup EXIT INT TERM

  # Ensure KOPIA_PASSWORD is exported if set, without echoing it
  if [ -n "${KOPIA_PASSWORD:-}" ]; then
    export KOPIA_PASSWORD
  fi

  # Connect to Kopia repository if connection options are provided
  if [ -n "${KOPIA_SERVER_URL:-}" ]; then
    echo "Connecting to Kopia server at ${KOPIA_SERVER_URL}..."
    CONNECT_ARGS=(
      --config-file="$CFG"
      --no-persist-credentials
      repository connect server
      --url="$KOPIA_SERVER_URL"
      --no-check-for-updates
    )
    if [ -n "${KOPIA_SERVER_FINGERPRINT:-${KOPIA_FINGERPRINT:-}}" ]; then
      CONNECT_ARGS+=(--server-cert-fingerprint="${KOPIA_SERVER_FINGERPRINT:-$KOPIA_FINGERPRINT}")
    fi
    if [ -n "${KOPIA_USERNAME:-}" ]; then
      CONNECT_ARGS+=(--override-username="$KOPIA_USERNAME")
    fi
    if [ -n "${KOPIA_HOSTNAME:-}" ]; then
      CONNECT_ARGS+=(--override-hostname="$KOPIA_HOSTNAME")
    fi

    if ! kopia "${CONNECT_ARGS[@]}"; then
      echo "Error: Failed to connect to Kopia server" >&2
      exit 1
    fi
  elif [ -n "${KOPIA_REPOSITORY_PATH:-${KOPIA_REPO_PATH:-}}" ]; then
    REPO_PATH="${KOPIA_REPOSITORY_PATH:-$KOPIA_REPO_PATH}"
    echo "Connecting to Kopia filesystem repository at ${REPO_PATH}..."
    if ! kopia --config-file="$CFG" --no-persist-credentials repository connect filesystem \
      --path="$REPO_PATH" \
      --no-check-for-updates; then
      echo "Error: Failed to connect to Kopia filesystem repository" >&2
      exit 1
    fi
  elif [ -n "${KOPIA_CONFIG_PATH:-}" ] && [ -f "$KOPIA_CONFIG_PATH" ]; then
    cp "$KOPIA_CONFIG_PATH" "$CFG"
  fi

  echo "Restoring Kopia snapshot ${SNAPSHOT_ID} into staging directory..."
  if ! kopia --config-file="$CFG" snapshot restore "$SNAPSHOT_ID" "$STAGING_DIR" --delete-extra; then
    echo "Error: Kopia snapshot restore failed for snapshot ${SNAPSHOT_ID}" >&2
    exit 1
  fi

  echo "Verifying restored staging files..."
  if [ ! -s "${STAGING_DIR}/database.sql" ]; then
    echo "Error: Missing or empty database.sql in restored snapshot" >&2
    exit 1
  fi

  if [ ! -s "${STAGING_DIR}/uploads.tgz" ]; then
    echo "Error: Missing or empty uploads.tgz in restored snapshot" >&2
    exit 1
  fi

  if ! tar -tzf "${STAGING_DIR}/uploads.tgz" >/dev/null 2>&1; then
    echo "Error: Corrupted or invalid uploads.tgz archive in restored snapshot" >&2
    exit 1
  fi

  RESTORE_SOURCE_DIR="$STAGING_DIR"

else
  # Legacy mode
  : "${BACKUP_ROOT:?Set BACKUP_ROOT to the host backup directory}"
  BACKUP_ID="${USE_LEGACY_BACKUP_ID}"
  if [[ ! "$BACKUP_ID" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "Error: Invalid BACKUP_ID: $BACKUP_ID" >&2
    exit 1
  fi
  if [ -d "$BACKUP_ID" ]; then
    RESTORE_SOURCE_DIR="$BACKUP_ID"
  else
    RESTORE_SOURCE_DIR="${BACKUP_ROOT%/}/${BACKUP_ID}"
  fi

  if [ ! -s "${RESTORE_SOURCE_DIR}/database.sql" ]; then
    echo "Error: missing or empty ${RESTORE_SOURCE_DIR}/database.sql" >&2
    exit 1
  fi
  if [ ! -s "${RESTORE_SOURCE_DIR}/uploads.tgz" ]; then
    echo "Error: missing or empty ${RESTORE_SOURCE_DIR}/uploads.tgz" >&2
    exit 1
  fi
  if ! tar -tzf "${RESTORE_SOURCE_DIR}/uploads.tgz" >/dev/null 2>&1; then
    echo "Error: Corrupted or invalid uploads.tgz archive in backup" >&2
    exit 1
  fi
  export BACKUP_ID
fi

echo "Restoring from ${RESTORE_SOURCE_DIR}"

# Restore caller umask before creating deployment directories and extracting uploads
umask "${ORIG_UMASK:-022}"

docker compose stop web
mkdir -p "${DEPLOY_DIR}/uploads"
tar -xzf "${RESTORE_SOURCE_DIR}/uploads.tgz" -C "$DEPLOY_DIR"

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "${RESTORE_SOURCE_DIR}/database.sql"
docker compose up -d --remove-orphans

echo "restore complete: ${BACKUP_ID}"
