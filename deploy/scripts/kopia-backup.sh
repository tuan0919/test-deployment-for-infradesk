#!/usr/bin/env bash
set -euo pipefail

# deploy/scripts/kopia-backup.sh
# Creates a Kopia snapshot of a backup directory and generates the backup reference manifest JSON.
# Usage: ./kopia-backup.sh <target-dir> [manifest-output-path]

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <target-dir> [manifest-output-path]" >&2
  exit 1
fi

TARGET_DIR="$1"
if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Target directory does not exist or is not a directory: $TARGET_DIR" >&2
  exit 1
fi

MANIFEST_OUTPUT="${2:-${MANIFEST_OUTPUT:-}}"
if [ -z "$MANIFEST_OUTPUT" ]; then
  MANIFEST_OUTPUT="${TARGET_DIR%/}/backup-reference.json"
fi

# Ensure destination directory exists and purge any pre-existing manifest file upfront
mkdir -p "$(dirname "$MANIFEST_OUTPUT")"
rm -f "$MANIFEST_OUTPUT"

: "${POSTGRES_DB:?Error: POSTGRES_DB environment variable is required}"
DATABASE="$POSTGRES_DB"
COMMIT_SHA="${CI_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo "")}"

# Security: restrict permissions on config and temporary files
umask 077

CFG="$(mktemp -t kopia-cfg-XXXXXXXX)"
PART_FILE="${MANIFEST_OUTPUT}.part.$$"

cleanup() {
  if command -v kopia >/dev/null 2>&1; then
    kopia --config-file="$CFG" repository disconnect >/dev/null 2>&1 || true
  fi
  rm -f "$CFG" "$CFG".* 2>/dev/null || true
  rm -f "$PART_FILE" 2>/dev/null || true
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

# Create snapshot and capture JSON output
echo "Creating Kopia snapshot for directory: ${TARGET_DIR}..."
if ! SNAP_OUT=$(kopia --config-file="$CFG" snapshot create --json "$TARGET_DIR"); then
  echo "Error: Kopia snapshot creation failed" >&2
  exit 1
fi

# Parse snapshot ID from JSON output
SNAPSHOT_ID=$(printf '%s' "$SNAP_OUT" | jq -er 'if (.id | type == "string" and length > 0) then .id else error("missing or empty snapshot id") end' 2>/dev/null || true)
if [ -z "$SNAPSHOT_ID" ]; then
  echo "Error: Failed to parse valid snapshot ID from Kopia output" >&2
  exit 1
fi

echo "Kopia snapshot created successfully with ID: ${SNAPSHOT_ID}"

# Generate manifest JSON atomically
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --argjson schemaVersion 1 \
  --arg snapshotId "$SNAPSHOT_ID" \
  --arg commitSha "$COMMIT_SHA" \
  --arg database "$DATABASE" \
  --arg createdAt "$CREATED_AT" \
  '{
    schemaVersion: $schemaVersion,
    snapshotId: $snapshotId,
    commitSha: $commitSha,
    database: $database,
    createdAt: $createdAt
  }' > "$PART_FILE"

# Validate generated manifest schema before publishing
if ! jq -e '
  type == "object" and
  .schemaVersion == 1 and
  (.snapshotId | type == "string" and length > 0) and
  (.commitSha | type == "string") and
  (.database | type == "string") and
  (.createdAt | type == "string") and
  ([keys[] | select(test("password|secret|token|command|script"; "i"))] | length == 0)
' "$PART_FILE" >/dev/null 2>&1; then
  echo "Error: Generated manifest failed JSON schema validation" >&2
  exit 1
fi

# Rename temporary file to final manifest path
mv "$PART_FILE" "$MANIFEST_OUTPUT"
echo "Backup manifest published to ${MANIFEST_OUTPUT}"
