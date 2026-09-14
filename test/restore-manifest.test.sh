#!/usr/bin/env bash
set -euo pipefail

# test/restore-manifest.test.sh
# Automated test suite for deploy/scripts/restore.sh,
# restore.yaml pipeline definition, snapshot pinning, failure safety,
# staging verification, and integration with download-backup-manifest.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESTORE_SCRIPT="${REPO_DIR}/deploy/scripts/restore.sh"
DOWNLOAD_SCRIPT="${REPO_DIR}/deploy/scripts/download-backup-manifest.sh"
MOCK_SERVER="${SCRIPT_DIR}/mock-artifact-server.js"
RESTORE_YAML="${REPO_DIR}/restore.yaml"

TEST_TMP_DIR=$(mktemp -d -t restore-test-XXXXXXXX)
MOCK_SERVER_PID=""

cleanup() {
  if [ -n "$MOCK_SERVER_PID" ]; then
    kill -TERM "$MOCK_SERVER_PID" 2>/dev/null || true
    wait "$MOCK_SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT INT TERM

touch "${TEST_TMP_DIR}/tests_run.txt" "${TEST_TMP_DIR}/tests_passed.txt" "${TEST_TMP_DIR}/tests_failed.txt"

assert_test() {
  local test_name="$1"
  local condition="$2"
  local error_msg="${3:-}"

  echo 1 >> "${TEST_TMP_DIR}/tests_run.txt"
  if eval "$condition"; then
    echo "  [PASS] $test_name"
    echo 1 >> "${TEST_TMP_DIR}/tests_passed.txt"
  else
    echo "  [FAIL] $test_name"
    if [ -n "$error_msg" ]; then
      echo "         Error: $error_msg"
    fi
    echo 1 >> "${TEST_TMP_DIR}/tests_failed.txt"
  fi
}

echo "================================================================"
echo "Running Restore Manifest & Pipeline Verification Test Suite"
echo "================================================================"

# ----------------------------------------------------------------
# Category 1: Bash Syntax and Executable Checks
# ----------------------------------------------------------------
echo ""
echo "--- Category 1: Bash Syntax and Executable Checks ---"

assert_test "Syntax check: restore.sh" \
  "bash -n '$RESTORE_SCRIPT'" \
  "bash -n failed on restore.sh"

assert_test "Syntax check: download-backup-manifest.sh" \
  "bash -n '$DOWNLOAD_SCRIPT'" \
  "bash -n failed on download-backup-manifest.sh"

assert_test "Syntax check: kopia-backup.sh" \
  "bash -n '${REPO_DIR}/deploy/scripts/kopia-backup.sh'" \
  "bash -n failed on kopia-backup.sh"

assert_test "Syntax check: backup.sh" \
  "bash -n '${REPO_DIR}/deploy/scripts/backup.sh'" \
  "bash -n failed on backup.sh"

assert_test "Script is executable: restore.sh" \
  "[ -x '$RESTORE_SCRIPT' ]" \
  "restore.sh is not executable"

# ----------------------------------------------------------------
# Category 2: Input Validation in restore.sh
# ----------------------------------------------------------------
echo ""
echo "--- Category 2: Input Validation ---"

# 2a: Missing all arguments and environment variables
(
  set +e
  unset MANIFEST_PATH BACKUP_ID DEPLOY_DIR POSTGRES_USER POSTGRES_DB 2>/dev/null || true
  "$RESTORE_SCRIPT" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Missing all arguments and env rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code"
)

# 2b: Missing DEPLOY_DIR
(
  set +e
  export POSTGRES_USER="app" POSTGRES_DB="app"
  unset DEPLOY_DIR 2>/dev/null || true
  "$RESTORE_SCRIPT" "${TEST_TMP_DIR}/dummy.json" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Missing DEPLOY_DIR rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code when DEPLOY_DIR is unset"
)

# 2c: Non-existent manifest file path
(
  set +e
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"
  "$RESTORE_SCRIPT" "${TEST_TMP_DIR}/nonexistent-manifest.json" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Non-existent manifest file rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code for nonexistent manifest"
)

# 2d: Empty manifest file (0 bytes)
(
  EMPTY_MANIFEST="${TEST_TMP_DIR}/empty-manifest.json"
  touch "$EMPTY_MANIFEST"
  set +e
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"
  "$RESTORE_SCRIPT" "$EMPTY_MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Empty manifest file (0 bytes) rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code for empty manifest"
)

# 2e: Malformed JSON manifest
(
  MALFORMED_MANIFEST="${TEST_TMP_DIR}/malformed.json"
  echo "not-json-content" > "$MALFORMED_MANIFEST"
  set +e
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"
  "$RESTORE_SCRIPT" "$MALFORMED_MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Malformed JSON manifest rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code for malformed JSON"
)

# 2f: Missing schemaVersion in manifest
(
  NO_SCHEMA_MANIFEST="${TEST_TMP_DIR}/no-schema.json"
  echo '{"snapshotId":"snap-001"}' > "$NO_SCHEMA_MANIFEST"
  set +e
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"
  "$RESTORE_SCRIPT" "$NO_SCHEMA_MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Missing schemaVersion rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code when schemaVersion is missing"
)

# 2g: Unsupported schemaVersion != 1
(
  WRONG_SCHEMA_MANIFEST="${TEST_TMP_DIR}/wrong-schema.json"
  echo '{"schemaVersion":2,"snapshotId":"snap-001"}' > "$WRONG_SCHEMA_MANIFEST"
  set +e
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"
  "$RESTORE_SCRIPT" "$WRONG_SCHEMA_MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Unsupported schemaVersion (!= 1) rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code for unsupported schemaVersion"
)

# 2h: Missing or empty snapshotId
(
  EMPTY_SNAP_MANIFEST="${TEST_TMP_DIR}/empty-snap.json"
  echo '{"schemaVersion":1,"snapshotId":""}' > "$EMPTY_SNAP_MANIFEST"
  set +e
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"
  "$RESTORE_SCRIPT" "$EMPTY_SNAP_MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Empty snapshotId in manifest rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code when snapshotId is empty"
)

# 2i: Incompatible database in manifest
(
  MISMATCH_DB_MANIFEST="${TEST_TMP_DIR}/mismatch-db.json"
  echo '{"schemaVersion":1,"snapshotId":"snap-001","database":"wrong_db"}' > "$MISMATCH_DB_MANIFEST"
  set +e
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"
  "$RESTORE_SCRIPT" "$MISMATCH_DB_MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Manifest database mismatch rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code when manifest database does not match POSTGRES_DB"
)

# 2j: Malicious / invalid metadata in manifest rejected
(
  INJECTION_MANIFEST="${TEST_TMP_DIR}/injection.json"
  echo '{"schemaVersion":1,"snapshotId":"snap-001","imageTag":"; touch pwned ;","database":"app"}' > "$INJECTION_MANIFEST"
  set +e
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"
  "$RESTORE_SCRIPT" "$INJECTION_MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Malicious characters in imageTag rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code for invalid imageTag format"
)

# 2k: Missing Kopia repository configuration in manifest mode
(
  VALID_MANIFEST="${TEST_TMP_DIR}/valid-manifest-no-repo.json"
  echo '{"schemaVersion":1,"snapshotId":"snap-test-no-repo","database":"app"}' > "$VALID_MANIFEST"
  set +e
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"
  unset KOPIA_SERVER_URL KOPIA_REPOSITORY_PATH KOPIA_REPO_PATH KOPIA_CONFIG_PATH 2>/dev/null || true
  NO_REPO_OUTPUT="${TEST_TMP_DIR}/no-repo.out"
  "$RESTORE_SCRIPT" "$VALID_MANIFEST" > "$NO_REPO_OUTPUT" 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Missing Kopia repository configuration rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code when no Kopia repository is configured"
  assert_test "Missing Kopia repository error message is displayed" \
    "grep -q 'No Kopia repository configured' '$NO_REPO_OUTPUT'" \
    "Expected 'No Kopia repository configured' error message"
)

# ----------------------------------------------------------------
# Category 3: Security - Never Source or Eval Manifest
# ----------------------------------------------------------------
echo ""
echo "--- Category 3: Security - Manifest Sourcing / Eval Prevention ---"

(
  EVAL_TEST_DIR="${TEST_TMP_DIR}/eval-test"
  mkdir -p "$EVAL_TEST_DIR"
  CANARY_FILE="${EVAL_TEST_DIR}/canary.txt"
  EVAL_MANIFEST="${EVAL_TEST_DIR}/exploit-manifest.json"

  cat <<EOF > "$EVAL_MANIFEST"
{
  "schemaVersion": 1,
  "snapshotId": "snap-valid-01",
  "database": "app",
  "commitSha": "\$(touch ${CANARY_FILE})",
  "imageTag": "\$(touch ${CANARY_FILE})"
}
EOF

  set +e
  export DEPLOY_DIR="$EVAL_TEST_DIR" POSTGRES_USER="app" POSTGRES_DB="app"
  "$RESTORE_SCRIPT" "$EVAL_MANIFEST" >/dev/null 2>&1
  set -e

  assert_test "Manifest command substitution was NOT executed" \
    "[ ! -f '$CANARY_FILE' ]" \
    "Canary file was created! Manifest was evaluated or executed via eval/source."
)

# ----------------------------------------------------------------
# Setup Mock Kopia and Mock Docker Environment
# ----------------------------------------------------------------
MOCK_BIN_DIR="${TEST_TMP_DIR}/mock_bin"
mkdir -p "$MOCK_BIN_DIR"
MOCK_KOPIA="${MOCK_BIN_DIR}/kopia"
MOCK_DOCKER="${MOCK_BIN_DIR}/docker"
DOCKER_LOG="${TEST_TMP_DIR}/docker_invocations.log"
KOPIA_LOG="${TEST_TMP_DIR}/kopia_invocations.log"

cat <<'EOF' > "$MOCK_DOCKER"
#!/usr/bin/env bash
set -eu
echo "$*" >> "${MOCK_DOCKER_LOG}"
exit 0
EOF
chmod +x "$MOCK_DOCKER"

cat <<'EOF' > "$MOCK_KOPIA"
#!/usr/bin/env bash
set -eu
echo "$*" >> "${MOCK_KOPIA_LOG}"

ACTION="${MOCK_KOPIA_ACTION:-success}"

# Parse global options
while [ $# -gt 0 ]; do
  case "$1" in
    --config-file=*|--config-file)
      if [ "$1" = "--config-file" ]; then shift; fi
      shift
      ;;
    --no-persist-credentials)
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [ "${1:-}" = "repository" ]; then
  subcmd="${2:-}"
  if [ "$subcmd" = "connect" ]; then
    if [ "$ACTION" = "fail_connect" ]; then
      echo "Mock Kopia: connection failed" >&2
      exit 1
    fi
    exit 0
  fi
  if [ "$subcmd" = "disconnect" ]; then
    exit 0
  fi
fi

if [ "${1:-}" = "snapshot" ] && [ "${2:-}" = "restore" ]; then
  SNAP_ID="${3:-}"
  TARGET_DIR="${4:-}"

  if [ "$ACTION" = "fail_restore" ]; then
    echo "Mock Kopia: snapshot restore failed" >&2
    exit 1
  fi

  if [ "$ACTION" = "missing_db" ]; then
    mkdir -p "$TARGET_DIR"
    echo "uploads content" > "${TARGET_DIR}/uploads.tgz"
    exit 0
  fi

  if [ "$ACTION" = "empty_db" ]; then
    mkdir -p "$TARGET_DIR"
    touch "${TARGET_DIR}/database.sql"
    echo "uploads content" > "${TARGET_DIR}/uploads.tgz"
    exit 0
  fi

  if [ "$ACTION" = "missing_uploads" ]; then
    mkdir -p "$TARGET_DIR"
    echo "database content" > "${TARGET_DIR}/database.sql"
    exit 0
  fi

  if [ "$ACTION" = "empty_uploads" ]; then
    mkdir -p "$TARGET_DIR"
    echo "database content" > "${TARGET_DIR}/database.sql"
    touch "${TARGET_DIR}/uploads.tgz"
    exit 0
  fi

  if [ "$ACTION" = "corrupted_uploads" ]; then
    mkdir -p "$TARGET_DIR"
    echo "database content" > "${TARGET_DIR}/database.sql"
    echo "not-a-valid-gzip-tar-archive" > "${TARGET_DIR}/uploads.tgz"
    exit 0
  fi

  if [ "$ACTION" = "pin_test" ]; then
    mkdir -p "$TARGET_DIR"
    echo "db-from-snapshot-${SNAP_ID}" > "${TARGET_DIR}/database.sql"
    tar -czf "${TARGET_DIR}/uploads.tgz" -C "${MOCK_UPLOADS_SRC:-/tmp}" . 2>/dev/null || touch "${TARGET_DIR}/uploads.tgz"
    exit 0
  fi

  # Default success
  mkdir -p "$TARGET_DIR"
  echo "mock database dump sql" > "${TARGET_DIR}/database.sql"
  tar -czf "${TARGET_DIR}/uploads.tgz" -C "${MOCK_UPLOADS_SRC:-/tmp}" . 2>/dev/null || echo "mock-upload-content" > "${TARGET_DIR}/uploads.tgz"
  exit 0
fi

exit 0
EOF
chmod +x "$MOCK_KOPIA"

# Create mock uploads source for tar
MOCK_UPLOADS_DIR="${TEST_TMP_DIR}/mock_uploads_source"
mkdir -p "${MOCK_UPLOADS_DIR}/uploads"
echo "upload-file-1" > "${MOCK_UPLOADS_DIR}/uploads/file1.txt"

# Default mock Kopia repository path for mock tests
export KOPIA_REPOSITORY_PATH="${TEST_TMP_DIR}/mock_kopia_repo"

# ----------------------------------------------------------------
# Category 4: Failure Safety - Kopia Errors Must Abort Before Touching Target
# ----------------------------------------------------------------
echo ""
echo "--- Category 4: Failure Safety & Target Protection ---"

# 4a: Kopia repository connection failure
(
  TEST_DIR="${TEST_TMP_DIR}/safety-4a"
  mkdir -p "$TEST_DIR/deploy"
  DOCKER_LOG_4A="${TEST_DIR}/docker.log"
  KOPIA_LOG_4A="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_4A" "$KOPIA_LOG_4A"

  MANIFEST="${TEST_DIR}/manifest.json"
  echo '{"schemaVersion":1,"snapshotId":"snap-safety-4a","database":"app"}' > "$MANIFEST"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_4A"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_4A"
  export MOCK_KOPIA_ACTION="fail_connect"
  export KOPIA_SERVER_URL="https://kopia.local:51515"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  set +e
  "$RESTORE_SCRIPT" "$MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Kopia connect failure: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure exit code on connection failure"

  assert_test "Kopia connect failure: docker compose stop was NOT called" \
    "! grep -q 'compose stop' '$DOCKER_LOG_4A'" \
    "docker compose stop was unexpectedly called"

  assert_test "Kopia connect failure: DROP SCHEMA was NOT executed" \
    "! grep -q 'DROP SCHEMA' '$DOCKER_LOG_4A'" \
    "Database DROP SCHEMA was unexpectedly executed"
)

# 4b: Kopia snapshot restore failure
(
  TEST_DIR="${TEST_TMP_DIR}/safety-4b"
  mkdir -p "$TEST_DIR/deploy"
  DOCKER_LOG_4B="${TEST_DIR}/docker.log"
  KOPIA_LOG_4B="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_4B" "$KOPIA_LOG_4B"

  MANIFEST="${TEST_DIR}/manifest.json"
  echo '{"schemaVersion":1,"snapshotId":"snap-missing-4b","database":"app"}' > "$MANIFEST"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_4B"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_4B"
  export MOCK_KOPIA_ACTION="fail_restore"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  set +e
  "$RESTORE_SCRIPT" "$MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Kopia snapshot restore failure: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure exit code on restore failure"

  assert_test "Kopia restore failure: docker compose stop was NOT called" \
    "! grep -q 'compose stop' '$DOCKER_LOG_4B'" \
    "docker compose stop was unexpectedly called"

  assert_test "Kopia restore failure: DROP SCHEMA was NOT executed" \
    "! grep -q 'DROP SCHEMA' '$DOCKER_LOG_4B'" \
    "DROP SCHEMA was unexpectedly executed"
)

# 4c: Missing database.sql in staging
(
  TEST_DIR="${TEST_TMP_DIR}/safety-4c"
  mkdir -p "$TEST_DIR/deploy"
  DOCKER_LOG_4C="${TEST_DIR}/docker.log"
  KOPIA_LOG_4C="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_4C" "$KOPIA_LOG_4C"

  MANIFEST="${TEST_DIR}/manifest.json"
  echo '{"schemaVersion":1,"snapshotId":"snap-no-db-4c","database":"app"}' > "$MANIFEST"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_4C"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_4C"
  export MOCK_KOPIA_ACTION="missing_db"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  set +e
  "$RESTORE_SCRIPT" "$MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Missing database.sql in staging: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure exit code when database.sql is missing"

  assert_test "Missing database.sql: target untouched (no docker stop)" \
    "! grep -q 'compose stop' '$DOCKER_LOG_4C'" \
    "docker compose stop was called"

  assert_test "Missing database.sql: target untouched (no DROP SCHEMA)" \
    "! grep -q 'DROP SCHEMA' '$DOCKER_LOG_4C'" \
    "DROP SCHEMA was executed"
)

# 4d: Empty (0-byte) database.sql in staging
(
  TEST_DIR="${TEST_TMP_DIR}/safety-4d"
  mkdir -p "$TEST_DIR/deploy"
  DOCKER_LOG_4D="${TEST_DIR}/docker.log"
  KOPIA_LOG_4D="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_4D" "$KOPIA_LOG_4D"

  MANIFEST="${TEST_DIR}/manifest.json"
  echo '{"schemaVersion":1,"snapshotId":"snap-empty-db-4d","database":"app"}' > "$MANIFEST"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_4D"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_4D"
  export MOCK_KOPIA_ACTION="empty_db"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  set +e
  "$RESTORE_SCRIPT" "$MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Empty database.sql in staging: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure exit code when database.sql is 0 bytes"

  assert_test "Empty database.sql: target untouched" \
    "! grep -q 'compose stop' '$DOCKER_LOG_4D'" \
    "docker compose stop was called"
)

# 4e: Missing uploads.tgz in staging
(
  TEST_DIR="${TEST_TMP_DIR}/safety-4e"
  mkdir -p "$TEST_DIR/deploy"
  DOCKER_LOG_4E="${TEST_DIR}/docker.log"
  KOPIA_LOG_4E="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_4E" "$KOPIA_LOG_4E"

  MANIFEST="${TEST_DIR}/manifest.json"
  echo '{"schemaVersion":1,"snapshotId":"snap-no-up-4e","database":"app"}' > "$MANIFEST"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_4E"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_4E"
  export MOCK_KOPIA_ACTION="missing_uploads"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  set +e
  "$RESTORE_SCRIPT" "$MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Missing uploads.tgz in staging: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure exit code when uploads.tgz is missing"

  assert_test "Missing uploads.tgz: target untouched" \
    "! grep -q 'compose stop' '$DOCKER_LOG_4E'" \
    "docker compose stop was called"
)

# 4f: Corrupted uploads.tgz in staging
(
  TEST_DIR="${TEST_TMP_DIR}/safety-4f"
  mkdir -p "$TEST_DIR/deploy"
  DOCKER_LOG_4F="${TEST_DIR}/docker.log"
  KOPIA_LOG_4F="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_4F" "$KOPIA_LOG_4F"

  MANIFEST="${TEST_DIR}/manifest.json"
  echo '{"schemaVersion":1,"snapshotId":"snap-corrupt-up-4f","database":"app"}' > "$MANIFEST"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_4F"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_4F"
  export MOCK_KOPIA_ACTION="corrupted_uploads"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  set +e
  "$RESTORE_SCRIPT" "$MANIFEST" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Corrupted uploads.tgz in staging: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure exit code when uploads.tgz is corrupted"

  assert_test "Corrupted uploads.tgz: target untouched (no docker stop)" \
    "! grep -q 'compose stop' '$DOCKER_LOG_4F'" \
    "docker compose stop was called"

  assert_test "Corrupted uploads.tgz: target untouched (no DROP SCHEMA)" \
    "! grep -q 'DROP SCHEMA' '$DOCKER_LOG_4F'" \
    "DROP SCHEMA was executed"
)

# ----------------------------------------------------------------
# Category 5: Snapshot Pinning / Selection (Snapshot A vs Snapshot B)
# ----------------------------------------------------------------
echo ""
echo "--- Category 5: Snapshot Pinning / Selection ---"

(
  TEST_DIR="${TEST_TMP_DIR}/pinning"
  mkdir -p "$TEST_DIR/deploy"
  DOCKER_LOG_PIN="${TEST_DIR}/docker.log"
  KOPIA_LOG_PIN="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_PIN" "$KOPIA_LOG_PIN"

  # Snapshot A is the older pin, Snapshot B is newer
  SNAP_A="snapshot-aaa-pin-20260914-0100"
  SNAP_B="snapshot-bbb-newer-20260914-0200"

  MANIFEST_A="${TEST_DIR}/manifest-pin-a.json"
  cat <<EOF > "$MANIFEST_A"
{
  "schemaVersion": 1,
  "snapshotId": "${SNAP_A}",
  "commitSha": "commit-a-sha",
  "database": "app",
  "createdAt": "2026-09-14T01:00:00Z"
}
EOF

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_PIN"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_PIN"
  export MOCK_KOPIA_ACTION="pin_test"
  export MOCK_UPLOADS_SRC="$MOCK_UPLOADS_DIR"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  "$RESTORE_SCRIPT" "$MANIFEST_A" > "${TEST_DIR}/restore.out" 2>&1

  assert_test "Snapshot Pin: restore called with exact Snapshot A (${SNAP_A})" \
    "grep -q 'snapshot restore ${SNAP_A}' '$KOPIA_LOG_PIN'" \
    "Kopia was not invoked with Snapshot A ($SNAP_A)"

  assert_test "Snapshot Pin: Snapshot B was NEVER selected" \
    "! grep -q '${SNAP_B}' '$KOPIA_LOG_PIN'" \
    "Newer Snapshot B was unexpectedly selected"

  assert_test "Snapshot Pin: restore complete logged with Snapshot A" \
    "grep -q 'restore complete: ${SNAP_A}' '${TEST_DIR}/restore.out'" \
    "Restore complete message did not include Snapshot A"
)

# ----------------------------------------------------------------
# Category 6: Producer Download Phase Failure Safety
# ----------------------------------------------------------------
echo ""
echo "--- Category 6: Producer Download Phase Failure Safety ---"

# Start mock artifact server for download tests
PORT_FILE="${TEST_TMP_DIR}/mock_server_port.txt"
node "$MOCK_SERVER" > "$PORT_FILE" 2>&1 &
MOCK_SERVER_PID=$!

PORT=""
for _ in $(seq 1 50); do
  if [ -s "$PORT_FILE" ]; then
    PORT=$(grep -o 'PORT=[0-9]*' "$PORT_FILE" | cut -d= -f2 || true)
    if [ -n "$PORT" ]; then break; fi
  fi
  sleep 0.1
done

if [ -z "$PORT" ]; then
  echo "Error: Mock artifact server failed to start" >&2
  exit 1
fi

MOCK_API_BASE="http://127.0.0.1:${PORT}"
TEST_PIPELINE_ID="11111111-1111-1111-1111-111111111111"

# 6a: Producer 404 - download fails, restore never called
(
  TEST_DIR="${TEST_TMP_DIR}/download-404"
  mkdir -p "$TEST_DIR/input" "$TEST_DIR/deploy"
  DEST_MANIFEST="$TEST_DIR/input/backup-reference.json"
  DOCKER_LOG_6A="${TEST_DIR}/docker.log"
  KOPIA_LOG_6A="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_6A" "$KOPIA_LOG_6A"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_6A"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_6A"
  export ARTIFACT_API_BASE="$MOCK_API_BASE"
  export BACKUP_PIPELINE_ID="$TEST_PIPELINE_ID"
  export BACKUP_RUN_ID="40444444-4444-4444-4444-444444444444"
  export BACKUP_MANIFEST_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  # Simulate pipeline execution block
  DOWNLOAD_FAILED=0
  "$DOWNLOAD_SCRIPT" "$DEST_MANIFEST" >/dev/null 2>&1 || DOWNLOAD_FAILED=1

  assert_test "Producer 404: download script failed" \
    "[ $DOWNLOAD_FAILED -eq 1 ]" \
    "Expected download to fail on 404"

  assert_test "Producer 404: manifest was NOT downloaded" \
    "[ ! -f '$DEST_MANIFEST' ]" \
    "Manifest file exists after 404"

  # If pipeline stopped here (as it does with set -e), restore is never called
  assert_test "Producer 404: Kopia restore was NEVER called" \
    "[ ! -s '$KOPIA_LOG_6A' ]" \
    "Kopia was invoked despite 404 download failure"

  assert_test "Producer 404: Database was NEVER touched" \
    "[ ! -s '$DOCKER_LOG_6A' ]" \
    "Docker/database was touched despite 404 download failure"
)

# 6b: Checksum mismatch - download fails, restore never called
(
  TEST_DIR="${TEST_TMP_DIR}/download-checksum"
  mkdir -p "$TEST_DIR/input" "$TEST_DIR/deploy"
  DEST_MANIFEST="$TEST_DIR/input/backup-reference.json"
  DOCKER_LOG_6B="${TEST_DIR}/docker.log"
  KOPIA_LOG_6B="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_6B" "$KOPIA_LOG_6B"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_6B"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_6B"
  export ARTIFACT_API_BASE="$MOCK_API_BASE"
  export BACKUP_PIPELINE_ID="$TEST_PIPELINE_ID"
  export BACKUP_RUN_ID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  export BACKUP_MANIFEST_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  DOWNLOAD_FAILED=0
  "$DOWNLOAD_SCRIPT" "$DEST_MANIFEST" >/dev/null 2>&1 || DOWNLOAD_FAILED=1

  assert_test "Checksum mismatch: download script failed" \
    "[ $DOWNLOAD_FAILED -eq 1 ]" \
    "Expected download to fail on checksum mismatch"

  assert_test "Checksum mismatch: manifest was NOT written" \
    "[ ! -f '$DEST_MANIFEST' ]" \
    "Corrupt manifest was saved"

  assert_test "Checksum mismatch: Kopia restore was NEVER called" \
    "[ ! -s '$KOPIA_LOG_6B' ]" \
    "Kopia was invoked despite checksum mismatch"

  assert_test "Checksum mismatch: Database was NEVER touched" \
    "[ ! -s '$DOCKER_LOG_6B' ]" \
    "Docker/database was touched despite checksum mismatch"
)

# ----------------------------------------------------------------
# Category 7: End-to-End Success Flow with Mock Environment
# ----------------------------------------------------------------
echo ""
echo "--- Category 7: End-to-End Success Flow ---"

(
  TEST_DIR="${TEST_TMP_DIR}/e2e-success"
  mkdir -p "$TEST_DIR/input" "$TEST_DIR/deploy"
  umask 022
  DEST_MANIFEST="$TEST_DIR/input/backup-reference.json"
  DOCKER_LOG_E2E="${TEST_DIR}/docker.log"
  KOPIA_LOG_E2E="${TEST_DIR}/kopia.log"
  touch "$DOCKER_LOG_E2E" "$KOPIA_LOG_E2E"

  # Fetch payload from mock server to get valid SHA256
  VALID_RUN_ID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  PAYLOAD=$(curl -s --get --data-urlencode 'job=backup_runtime' --data-urlencode 'path=output/backup-reference.json' "${MOCK_API_BASE}/api/pipelines/${TEST_PIPELINE_ID}/runs/${VALID_RUN_ID}/artifacts/download")
  VALID_SHA256=$(printf '%s' "$PAYLOAD" | sha256sum | awk '{print $1}')

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_E2E"
  export MOCK_KOPIA_LOG="$KOPIA_LOG_E2E"
  export MOCK_KOPIA_ACTION="success"
  export MOCK_UPLOADS_SRC="$MOCK_UPLOADS_DIR"
  export ARTIFACT_API_BASE="$MOCK_API_BASE"
  export BACKUP_PIPELINE_ID="$TEST_PIPELINE_ID"
  export BACKUP_RUN_ID="$VALID_RUN_ID"
  export BACKUP_MANIFEST_SHA256="$VALID_SHA256"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  # Step 1: Download manifest
  "$DOWNLOAD_SCRIPT" "$DEST_MANIFEST" >/dev/null 2>&1

  assert_test "E2E: manifest successfully downloaded" \
    "[ -f '$DEST_MANIFEST' ]" \
    "Manifest was not downloaded"

  SNAP_ID_EXPECTED=$(jq -r .snapshotId "$DEST_MANIFEST")

  # Step 2: Run restore.sh
  RESTORE_OUTPUT="${TEST_DIR}/restore.out"
  "$RESTORE_SCRIPT" "$DEST_MANIFEST" > "$RESTORE_OUTPUT" 2>&1

  assert_test "E2E: Kopia snapshot restore was called with $SNAP_ID_EXPECTED" \
    "grep -q 'snapshot restore ${SNAP_ID_EXPECTED}' '$KOPIA_LOG_E2E'" \
    "Kopia restore not called with expected snapshot ID"

  assert_test "E2E: docker compose stop web was called" \
    "grep -q 'compose stop web' '$DOCKER_LOG_E2E'" \
    "docker compose stop web was not called"

  assert_test "E2E: uploads directory was extracted" \
    "[ -d '${TEST_DIR}/deploy/uploads' ]" \
    "deploy/uploads was not created"

  assert_test "E2E: DROP SCHEMA was executed on database" \
    "grep -q 'DROP SCHEMA public CASCADE' '$DOCKER_LOG_E2E'" \
    "DROP SCHEMA was not executed"

  assert_test "E2E: database dump was imported" \
    "grep -q 'psql -v ON_ERROR_STOP=1 -U app -d app' '$DOCKER_LOG_E2E'" \
    "database dump import command not found in docker invocations"

  assert_test "E2E: docker compose up -d was called" \
    "grep -q 'compose up -d --remove-orphans' '$DOCKER_LOG_E2E'" \
    "docker compose up was not called"

  assert_test "E2E: restore complete reported" \
    "grep -q 'restore complete: ${SNAP_ID_EXPECTED}' '$RESTORE_OUTPUT'" \
    "Restore complete message not found"

  # Step 3: Verify permissions and umask restoration
  UPLOADS_PERM=$(stat -c "%a" "${TEST_DIR}/deploy/uploads")
  assert_test "E2E: umask restored - deploy/uploads directory has mode 755 ($UPLOADS_PERM)" \
    "[ '$UPLOADS_PERM' = '755' ]" \
    "Expected 755, got $UPLOADS_PERM (umask 077 was not restored)"
)

# ----------------------------------------------------------------
# Category 8: Legacy Fallback Flow
# ----------------------------------------------------------------
echo ""
echo "--- Category 8: Legacy Fallback Flow ---"

(
  TEST_DIR="${TEST_TMP_DIR}/legacy"
  BACKUP_DIR="${TEST_DIR}/backups/legacy-backup-123"
  mkdir -p "$BACKUP_DIR" "${TEST_DIR}/deploy"
  echo "legacy db sql" > "${BACKUP_DIR}/database.sql"
  tar -czf "${BACKUP_DIR}/uploads.tgz" -C "$MOCK_UPLOADS_DIR" .

  DOCKER_LOG_LEGACY="${TEST_DIR}/docker.log"
  touch "$DOCKER_LOG_LEGACY"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_LEGACY"
  export BACKUP_ROOT="${TEST_DIR}/backups"
  export BACKUP_ID="legacy-backup-123"
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  RESTORE_OUTPUT="${TEST_DIR}/restore.out"
  "$RESTORE_SCRIPT" > "$RESTORE_OUTPUT" 2>&1

  assert_test "Legacy: docker compose stop web called" \
    "grep -q 'compose stop web' '$DOCKER_LOG_LEGACY'" \
    "docker compose stop web was not called in legacy mode"

  assert_test "Legacy: database drop and recreate executed" \
    "grep -q 'DROP SCHEMA public CASCADE' '$DOCKER_LOG_LEGACY'" \
    "DROP SCHEMA not executed in legacy mode"

  assert_test "Legacy: docker compose up called" \
    "grep -q 'compose up -d --remove-orphans' '$DOCKER_LOG_LEGACY'" \
    "docker compose up not called in legacy mode"

  assert_test "Legacy: restore complete reported with BACKUP_ID" \
    "grep -q 'restore complete: legacy-backup-123' '$RESTORE_OUTPUT'" \
    "Restore complete message not found in legacy mode"
)

# 8b: Legacy restore with directory path containing slashes
(
  TEST_DIR="${TEST_TMP_DIR}/legacy-slashes"
  BACKUP_DIR="${TEST_DIR}/custom/backups/path-with-slashes-20260914-0100"
  mkdir -p "$BACKUP_DIR" "${TEST_DIR}/deploy"
  echo "legacy db sql with slashes" > "${BACKUP_DIR}/database.sql"
  tar -czf "${BACKUP_DIR}/uploads.tgz" -C "$MOCK_UPLOADS_DIR" .

  DOCKER_LOG_LEGACY_SLASH="${TEST_DIR}/docker.log"
  touch "$DOCKER_LOG_LEGACY_SLASH"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_LEGACY_SLASH"
  unset BACKUP_ROOT BACKUP_ID 2>/dev/null || true
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  RESTORE_OUTPUT="${TEST_DIR}/restore.out"
  "$RESTORE_SCRIPT" "$BACKUP_DIR" > "$RESTORE_OUTPUT" 2>&1

  assert_test "Legacy slashes: restore with directory path containing slashes succeeds" \
    "grep -q 'restore complete: ${BACKUP_DIR}' '$RESTORE_OUTPUT'" \
    "Legacy restore with directory path containing slashes failed"

  assert_test "Legacy slashes: docker compose stop web called" \
    "grep -q 'compose stop web' '$DOCKER_LOG_LEGACY_SLASH'" \
    "docker compose stop web was not called in legacy slashes mode"

  assert_test "Legacy slashes: database drop and recreate executed" \
    "grep -q 'DROP SCHEMA public CASCADE' '$DOCKER_LOG_LEGACY_SLASH'" \
    "DROP SCHEMA not executed in legacy slashes mode"
)

# 8c: Legacy restore with relative directory path containing slashes
(
  TEST_DIR="${TEST_TMP_DIR}/legacy-rel-slashes"
  mkdir -p "${TEST_DIR}/relative-backups/run-01" "${TEST_DIR}/deploy"
  echo "legacy db sql relative" > "${TEST_DIR}/relative-backups/run-01/database.sql"
  tar -czf "${TEST_DIR}/relative-backups/run-01/uploads.tgz" -C "$MOCK_UPLOADS_DIR" .

  DOCKER_LOG_LEGACY_REL="${TEST_DIR}/docker.log"
  touch "$DOCKER_LOG_LEGACY_REL"

  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_DOCKER_LOG="$DOCKER_LOG_LEGACY_REL"
  unset BACKUP_ROOT BACKUP_ID 2>/dev/null || true
  export DEPLOY_DIR="${TEST_DIR}/deploy" POSTGRES_USER="app" POSTGRES_DB="app"

  RESTORE_OUTPUT="${TEST_DIR}/restore.out"
  (
    cd "$TEST_DIR"
    "$RESTORE_SCRIPT" "relative-backups/run-01" > "$RESTORE_OUTPUT" 2>&1
  )

  assert_test "Legacy relative slashes: restore with relative directory path succeeds" \
    "grep -q 'restore complete: relative-backups/run-01' '$RESTORE_OUTPUT'" \
    "Legacy restore with relative directory path containing slashes failed"
)

# ----------------------------------------------------------------
# Category 9: Real Kopia CLI Integration (when available)
# ----------------------------------------------------------------
echo ""
echo "--- Category 9: Real Kopia CLI Integration ---"

if command -v kopia >/dev/null 2>&1; then
  (
    REAL_DIR="${TEST_TMP_DIR}/real-kopia"
    REAL_REPO="${REAL_DIR}/repo"
    REAL_SRC_A="${REAL_DIR}/src-a"
    REAL_SRC_B="${REAL_DIR}/src-b"
    REAL_DEPLOY="${REAL_DIR}/deploy"
    REAL_MANIFEST="${REAL_DIR}/manifest.json"
    mkdir -p "$REAL_REPO" "$REAL_SRC_A" "$REAL_SRC_B" "$REAL_DEPLOY"

    echo "SELECT 'snapshot-a-real-data';" > "${REAL_SRC_A}/database.sql"
    tar -czf "${REAL_SRC_A}/uploads.tgz" -C "$MOCK_UPLOADS_DIR" .

    echo "SELECT 'snapshot-b-newer-data';" > "${REAL_SRC_B}/database.sql"
    tar -czf "${REAL_SRC_B}/uploads.tgz" -C "$MOCK_UPLOADS_DIR" .

    export KOPIA_PASSWORD="real-test-password-456"
    REAL_CFG="${REAL_DIR}/init-cfg"
    kopia --config-file="$REAL_CFG" repository create filesystem --path="$REAL_REPO" --no-check-for-updates >/dev/null 2>&1

    # Create Snapshot A (pinned)
    SNAP_A_JSON=$(kopia --config-file="$REAL_CFG" snapshot create --json "$REAL_SRC_A" 2>/dev/null)
    REAL_SNAP_A_ID=$(echo "$SNAP_A_JSON" | jq -r .id)

    # Create Snapshot B (newer)
    SNAP_B_JSON=$(kopia --config-file="$REAL_CFG" snapshot create --json "$REAL_SRC_B" 2>/dev/null)
    REAL_SNAP_B_ID=$(echo "$SNAP_B_JSON" | jq -r .id)

    rm -f "$REAL_CFG" "$REAL_CFG".*

    # Write manifest pointing to Snapshot A
    cat <<EOF > "$REAL_MANIFEST"
{
  "schemaVersion": 1,
  "snapshotId": "${REAL_SNAP_A_ID}",
  "commitSha": "commit-real-a",
  "database": "app",
  "createdAt": "2026-09-14T02:00:00Z"
}
EOF

    # Capture docker commands with mock docker
    DOCKER_LOG_REAL="${REAL_DIR}/docker.log"
    touch "$DOCKER_LOG_REAL"
    REAL_MOCK_DOCKER_DIR="${REAL_DIR}/mock_docker"
    mkdir -p "$REAL_MOCK_DOCKER_DIR"
    cp "$MOCK_DOCKER" "$REAL_MOCK_DOCKER_DIR/docker"

    REAL_KOPIA_BIN_DIR=$(dirname "$(command -v kopia)")
    export PATH="${REAL_MOCK_DOCKER_DIR}:${REAL_KOPIA_BIN_DIR}:$PATH"
    export MOCK_DOCKER_LOG="$DOCKER_LOG_REAL"
    export KOPIA_REPOSITORY_PATH="$REAL_REPO"
    export DEPLOY_DIR="$REAL_DEPLOY" POSTGRES_USER="app" POSTGRES_DB="app"

    RESTORE_REAL_OUT="${REAL_DIR}/restore.out"
    RESTORE_EXIT=0
    "$RESTORE_SCRIPT" "$REAL_MANIFEST" > "$RESTORE_REAL_OUT" 2>&1 || RESTORE_EXIT=$?

    assert_test "Real Kopia: restore.sh succeeded with exit code 0" \
      "[ $RESTORE_EXIT -eq 0 ]" \
      "restore.sh failed on real Kopia repo with exit $RESTORE_EXIT"

    assert_test "Real Kopia: restore complete logged with real snapshot ID (${REAL_SNAP_A_ID})" \
      "grep -q 'restore complete: ${REAL_SNAP_A_ID}' '$RESTORE_REAL_OUT'" \
      "Real snapshot ID not found in completion output"

    assert_test "Real Kopia: docker commands executed" \
      "grep -q 'compose stop web' '$DOCKER_LOG_REAL' && grep -q 'DROP SCHEMA' '$DOCKER_LOG_REAL'" \
      "Expected docker compose and schema drop commands"
  )
else
  echo "  [SKIP] kopia binary not found, skipping real Kopia integration test"
fi

# ----------------------------------------------------------------
# Category 10: Pipeline Definition Validation (restore.yaml)
# ----------------------------------------------------------------
echo ""
echo "--- Category 10: Pipeline Definition Validation (restore.yaml) ---"

PARSER_RESULT=$(npx --prefix /home/gmo021/infraDesk tsx -e '
import fs from "fs";
import { parsePipelineDefinition } from "/home/gmo021/infraDesk/packages/pipeline-runtime/src/index";

const yaml = fs.readFileSync(process.argv[1], "utf8");
const result = parsePipelineDefinition(yaml);
console.log(JSON.stringify(result));
' "$RESTORE_YAML" 2>/dev/null || echo '{"ok":false}')

PARSER_OK=$(echo "$PARSER_RESULT" | jq -r '.ok // false')
DIAGNOSTICS_COUNT=$(echo "$PARSER_RESULT" | jq -r '.diagnostics | length // 999')

assert_test "restore.yaml parses successfully with parsePipelineDefinition" \
  "[ '$PARSER_OK' = 'true' ]" \
  "parsePipelineDefinition returned ok: false"

assert_test "restore.yaml has 0 diagnostics" \
  "[ '$DIAGNOSTICS_COUNT' -eq 0 ]" \
  "Diagnostics count was $DIAGNOSTICS_COUNT"

# Variables checks
VAR_BASE=$(echo "$PARSER_RESULT" | jq -r '.plan.variables.ARTIFACT_API_BASE // "missing"')
VAR_PIPE=$(echo "$PARSER_RESULT" | jq -r '.plan.variables.BACKUP_PIPELINE_ID // "missing"')
VAR_RUN=$(echo "$PARSER_RESULT" | jq -r '.plan.variables.BACKUP_RUN_ID // "missing"')
VAR_SHA=$(echo "$PARSER_RESULT" | jq -r '.plan.variables.BACKUP_MANIFEST_SHA256 // "missing"')

assert_test "restore.yaml declares ARTIFACT_API_BASE variable" \
  "[ '$VAR_BASE' != 'missing' ]" \
  "ARTIFACT_API_BASE was missing"

assert_test "restore.yaml declares BACKUP_PIPELINE_ID variable" \
  "[ '$VAR_PIPE' != 'missing' ]" \
  "BACKUP_PIPELINE_ID was missing"

assert_test "restore.yaml declares BACKUP_RUN_ID variable" \
  "[ '$VAR_RUN' != 'missing' ]" \
  "BACKUP_RUN_ID was missing"

assert_test "restore.yaml declares BACKUP_MANIFEST_SHA256 variable" \
  "[ '$VAR_SHA' != 'missing' ]" \
  "BACKUP_MANIFEST_SHA256 was missing"

# Rules checks
RULE_IF=$(echo "$PARSER_RESULT" | jq -r '.plan.jobs[] | select(.name == "restore_runtime") | .rules[0].if // empty')
RULE_WHEN=$(echo "$PARSER_RESULT" | jq -r '.plan.jobs[] | select(.name == "restore_runtime") | .rules[0].when // empty')
RULE_ALLOW_FAIL=$(echo "$PARSER_RESULT" | jq -r '.plan.jobs[] | select(.name == "restore_runtime") | .rules[0].allowFailure')

assert_test "restore_runtime rule requires BACKUP_RUN_ID ($RULE_IF)" \
  "echo '$RULE_IF' | grep -q 'BACKUP_RUN_ID'" \
  "Rule did not require BACKUP_RUN_ID"

assert_test "restore_runtime rule when is manual" \
  "[ '$RULE_WHEN' = 'manual' ]" \
  "Expected when: manual, got: $RULE_WHEN"

assert_test "restore_runtime rule allow_failure is false" \
  "[ '$RULE_ALLOW_FAIL' = 'false' ]" \
  "Expected allowFailure: false, got: $RULE_ALLOW_FAIL"

# Script content checks
BEFORE_SCRIPT=$(echo "$PARSER_RESULT" | jq -r '.plan.jobs[] | select(.name == "restore_runtime") | .beforeScript[0] // empty')
SCRIPT_CONTENT=$(echo "$PARSER_RESULT" | jq -r '.plan.jobs[] | select(.name == "restore_runtime") | .script[0] // empty')

assert_test "before_script verifies BACKUP_RUN_ID is non-empty" \
  "echo '$BEFORE_SCRIPT' | grep -q 'BACKUP_RUN_ID'" \
  "before_script did not check BACKUP_RUN_ID"

assert_test "script creates input directory" \
  "echo '$SCRIPT_CONTENT' | grep -q 'mkdir -p input'" \
  "script does not create input dir"

assert_test "script downloads manifest before restore" \
  "echo '$SCRIPT_CONTENT' | grep -q 'download-backup-manifest.sh'" \
  "script does not call download-backup-manifest.sh"

assert_test "script invokes restore.sh with MANIFEST_PATH" \
  "echo '$SCRIPT_CONTENT' | grep -q 'restore.sh \"\$MANIFEST_PATH\"'" \
  "script does not invoke restore.sh with MANIFEST_PATH"

assert_test "script preserves docker compose up -d --remove-orphans" \
  "echo '$SCRIPT_CONTENT' | grep -q 'docker compose up -d --remove-orphans'" \
  "script does not preserve docker compose up"

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------
TESTS_RUN=$(wc -l < "${TEST_TMP_DIR}/tests_run.txt" 2>/dev/null || echo 0)
TESTS_PASSED=$(wc -l < "${TEST_TMP_DIR}/tests_passed.txt" 2>/dev/null || echo 0)
TESTS_FAILED=$(wc -l < "${TEST_TMP_DIR}/tests_failed.txt" 2>/dev/null || echo 0)

echo ""
echo "================================================================"
echo "Test Summary:"
echo "  Total:  $TESTS_RUN"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo "================================================================"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi

exit 0
