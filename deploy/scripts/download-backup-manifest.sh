#!/usr/bin/env bash
set -euo pipefail

# download-backup-manifest.sh
# Downloads and verifies a backup manifest artifact from InfraDesk API.
# Usage: ./download-backup-manifest.sh <destination-file-path>

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <destination-file-path>" >&2
  exit 1
fi

DEST="$1"
DEST_DIR="$(dirname "$DEST")"
mkdir -p "$DEST_DIR"

# Ensure pre-existing file at destination is removed upfront
# so that failure can never leave or fallback to stale files.
rm -f "$DEST"

: "${ARTIFACT_API_BASE:?Error: ARTIFACT_API_BASE environment variable is required}"
: "${BACKUP_PIPELINE_ID:?Error: BACKUP_PIPELINE_ID environment variable is required}"
: "${BACKUP_RUN_ID:?Error: BACKUP_RUN_ID environment variable is required}"
: "${BACKUP_MANIFEST_SHA256:?Error: BACKUP_MANIFEST_SHA256 environment variable is required}"

UUID_REGEX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
SHA256_REGEX='^[0-9a-fA-F]{64}$'

if [[ ! "$BACKUP_PIPELINE_ID" =~ $UUID_REGEX ]]; then
  echo "Error: Invalid BACKUP_PIPELINE_ID format (expected UUID): $BACKUP_PIPELINE_ID" >&2
  exit 1
fi

if [[ ! "$BACKUP_RUN_ID" =~ $UUID_REGEX ]]; then
  echo "Error: Invalid BACKUP_RUN_ID format (expected UUID): $BACKUP_RUN_ID" >&2
  exit 1
fi

if [[ ! "$BACKUP_MANIFEST_SHA256" =~ $SHA256_REGEX ]]; then
  echo "Error: Invalid BACKUP_MANIFEST_SHA256 format (expected 64 hex characters): $BACKUP_MANIFEST_SHA256" >&2
  exit 1
fi

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-60}"

TEMP_FILE="${DEST}.part.$$"
cleanup() {
  rm -f "$TEMP_FILE"
}
trap cleanup EXIT INT TERM

DOWNLOAD_URL="${ARTIFACT_API_BASE%/}/api/pipelines/${BACKUP_PIPELINE_ID}/runs/${BACKUP_RUN_ID}/artifacts/download"

echo "Downloading backup manifest from ${DOWNLOAD_URL}..."

if ! curl --fail --silent --show-error --get \
  --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
  --data-urlencode 'job=backup_runtime' \
  --data-urlencode 'path=output/backup-reference.json' \
  "$DOWNLOAD_URL" \
  --output "$TEMP_FILE"; then
  echo "Error: Failed to download artifact from ${DOWNLOAD_URL}" >&2
  exit 1
fi

if [ ! -f "$TEMP_FILE" ]; then
  echo "Error: Downloaded file not found: $TEMP_FILE" >&2
  exit 1
fi

FILE_SIZE=$(wc -c < "$TEMP_FILE" | tr -d '[:space:]')
if [ "$FILE_SIZE" -eq 0 ]; then
  echo "Error: Downloaded manifest is empty (0 bytes)" >&2
  exit 1
fi

if [ "$FILE_SIZE" -gt 262144 ]; then
  echo "Error: Downloaded manifest exceeds size limit of 262144 bytes: $FILE_SIZE bytes" >&2
  exit 1
fi

echo "Verifying SHA256 checksum..."
if ! printf '%s  %s\n' "${BACKUP_MANIFEST_SHA256,,}" "$TEMP_FILE" | sha256sum -c -; then
  echo "Error: SHA256 checksum verification failed for $TEMP_FILE" >&2
  exit 1
fi

echo "Validating manifest JSON schema..."
if ! jq -e '
  type == "object" and
  .schemaVersion == 1 and
  (.snapshotId | type == "string" and length > 0) and
  (.commitSha | type == "string") and
  (.database | type == "string") and
  (.createdAt | type == "string") and
  ([keys[] | select(test("password|secret|token|command|script"; "i"))] | length == 0)
' "$TEMP_FILE" > /dev/null 2>&1; then
  echo "Error: Manifest JSON schema validation failed" >&2
  exit 1
fi

# Replace/move temp file to destination only after all verifications succeed
mv "$TEMP_FILE" "$DEST"
echo "Backup manifest successfully downloaded and verified at $DEST"
exit 0
