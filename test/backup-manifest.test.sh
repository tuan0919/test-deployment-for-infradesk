#!/usr/bin/env bash
set -euo pipefail

# test/backup-manifest.test.sh
# Automated test suite for deploy/scripts/kopia-backup.sh, deploy/scripts/backup.sh,
# manifest JSON schema validation, and backup.yaml pipeline definition.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KOPIA_BACKUP_SCRIPT="${REPO_DIR}/deploy/scripts/kopia-backup.sh"
BACKUP_SCRIPT="${REPO_DIR}/deploy/scripts/backup.sh"
BACKUP_YAML="${REPO_DIR}/backup.yaml"

TEST_TMP_DIR=$(mktemp -d -t backup-test-XXXXXXXX)
cleanup() {
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
echo "Running Backup Manifest & Pipeline Artifacts Test Suite"
echo "================================================================"

# ----------------------------------------------------------------
# Category 1: Bash Syntax Checks
# ----------------------------------------------------------------
echo ""
echo "--- Category 1: Bash Syntax Checks ---"

assert_test "Syntax check: kopia-backup.sh" \
  "bash -n '$KOPIA_BACKUP_SCRIPT'" \
  "bash -n failed on kopia-backup.sh"

assert_test "Syntax check: backup.sh" \
  "bash -n '$BACKUP_SCRIPT'" \
  "bash -n failed on backup.sh"

assert_test "Syntax check: download-backup-manifest.sh" \
  "bash -n '${REPO_DIR}/deploy/scripts/download-backup-manifest.sh'" \
  "bash -n failed on download-backup-manifest.sh"

assert_test "Script is executable: kopia-backup.sh" \
  "[ -x '$KOPIA_BACKUP_SCRIPT' ]" \
  "kopia-backup.sh is not executable"

assert_test "Script is executable: backup.sh" \
  "[ -x '$BACKUP_SCRIPT' ]" \
  "backup.sh is not executable"

# ----------------------------------------------------------------
# Category 2: Input Validation in kopia-backup.sh
# ----------------------------------------------------------------
echo ""
echo "--- Category 2: Input Validation ---"

(
  set +e
  "$KOPIA_BACKUP_SCRIPT" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Missing target directory argument rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code when target dir is missing"
)

(
  set +e
  "$KOPIA_BACKUP_SCRIPT" "${TEST_TMP_DIR}/nonexistent-dir" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Non-existent target directory rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code for non-existent target dir"
)

(
  TARGET_FIXTURE="${TEST_TMP_DIR}/target-fixture"
  mkdir -p "$TARGET_FIXTURE"
  set +e
  unset POSTGRES_DB 2>/dev/null || true
  "$KOPIA_BACKUP_SCRIPT" "$TARGET_FIXTURE" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
  assert_test "Missing POSTGRES_DB rejected" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected non-zero exit code when POSTGRES_DB is unset"
)

# ----------------------------------------------------------------
# Setup Mock Kopia Environment
# ----------------------------------------------------------------
MOCK_BIN_DIR="${TEST_TMP_DIR}/mock_bin"
mkdir -p "$MOCK_BIN_DIR"
MOCK_KOPIA="${MOCK_BIN_DIR}/kopia"

cat <<'EOF' > "$MOCK_KOPIA"
#!/usr/bin/env bash
set -eu

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

# Handle snapshot create
if [ "${1:-}" = "snapshot" ] && [ "${2:-}" = "create" ]; then
  if [ "$ACTION" = "fail_snapshot" ]; then
    echo "Mock Kopia: snapshot creation failed" >&2
    exit 1
  fi
  if [ "$ACTION" = "empty_id" ]; then
    echo '{"id":"","description":"empty id"}'
    exit 0
  fi
  if [ "$ACTION" = "missing_id" ]; then
    echo '{"description":"no id field"}'
    exit 0
  fi
  if [ "$ACTION" = "invalid_json" ]; then
    echo 'not-valid-json'
    exit 0
  fi

  # Success: output valid JSON with snapshot ID
  SNAPSHOT_ID="${MOCK_KOPIA_SNAPSHOT_ID:-mock-snapshot-id-default}"
  echo "Mock Kopia: progress logging to stderr" >&2
  cat <<JSON
{"id":"${SNAPSHOT_ID}","source":{"host":"mock-host","userName":"mock-user","path":"${3:-/tmp}"},"startTime":"2026-09-14T03:00:00Z","endTime":"2026-09-14T03:00:01Z","rootEntry":{"name":"backup","type":"d"}}
JSON
  exit 0
fi

# Default fallback
exit 0
EOF
chmod +x "$MOCK_KOPIA"

# ----------------------------------------------------------------
# Category 3: Kopia Upload Failure Scenarios
# ----------------------------------------------------------------
echo ""
echo "--- Category 3: Upload Failure Scenarios ---"

FIXTURE_BACKUP_DIR="${TEST_TMP_DIR}/fixture-backup"
mkdir -p "$FIXTURE_BACKUP_DIR"
echo "dummy db content" > "${FIXTURE_BACKUP_DIR}/database.sql"

# 3a: Snapshot create failure
(
  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_KOPIA_ACTION="fail_snapshot"
  export POSTGRES_DB="app"
  MANIFEST_TARGET="${TEST_TMP_DIR}/output-3a/backup-reference.json"

  set +e
  "$KOPIA_BACKUP_SCRIPT" "$FIXTURE_BACKUP_DIR" "$MANIFEST_TARGET" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Upload failure: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure exit code when Kopia snapshot fails"

  assert_test "Upload failure: manifest file is NOT published" \
    "[ ! -f '$MANIFEST_TARGET' ]" \
    "Manifest file must not exist after upload failure"

  PART_COUNT=$(find "${TEST_TMP_DIR}/output-3a" -name "*.part.*" 2>/dev/null | wc -l || echo "0")
  assert_test "Upload failure: temporary .part files cleaned up" \
    "[ '$PART_COUNT' -eq 0 ]" \
    "Found $PART_COUNT leftover .part files"
)

# 3b: Stale manifest purge on failure
(
  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_KOPIA_ACTION="fail_snapshot"
  export POSTGRES_DB="app"
  MANIFEST_TARGET="${TEST_TMP_DIR}/output-3b/backup-reference.json"
  mkdir -p "$(dirname "$MANIFEST_TARGET")"
  echo '{"stale":"data"}' > "$MANIFEST_TARGET"

  set +e
  "$KOPIA_BACKUP_SCRIPT" "$FIXTURE_BACKUP_DIR" "$MANIFEST_TARGET" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Stale manifest purge: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure exit code"

  assert_test "Stale manifest purge: pre-existing manifest was removed and not left as fallback" \
    "[ ! -f '$MANIFEST_TARGET' ]" \
    "Pre-existing manifest must not be left behind"
)

# 3c: Connection failure
(
  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_KOPIA_ACTION="fail_connect"
  export KOPIA_SERVER_URL="https://kopia.local:51515"
  export POSTGRES_DB="app"
  MANIFEST_TARGET="${TEST_TMP_DIR}/output-3c/backup-reference.json"

  set +e
  "$KOPIA_BACKUP_SCRIPT" "$FIXTURE_BACKUP_DIR" "$MANIFEST_TARGET" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Server connect failure: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure exit code when server connect fails"

  assert_test "Server connect failure: manifest file is NOT published" \
    "[ ! -f '$MANIFEST_TARGET' ]" \
    "Manifest must not exist when server connect fails"
)

# 3d: Kopia outputs empty snapshot ID
(
  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_KOPIA_ACTION="empty_id"
  export POSTGRES_DB="app"
  MANIFEST_TARGET="${TEST_TMP_DIR}/output-3d/backup-reference.json"

  set +e
  "$KOPIA_BACKUP_SCRIPT" "$FIXTURE_BACKUP_DIR" "$MANIFEST_TARGET" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Empty snapshot ID: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure when snapshot ID is empty"

  assert_test "Empty snapshot ID: manifest file is NOT published" \
    "[ ! -f '$MANIFEST_TARGET' ]" \
    "Manifest must not exist when snapshot ID is empty"
)

# 3e: Kopia outputs invalid JSON
(
  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_KOPIA_ACTION="invalid_json"
  export POSTGRES_DB="app"
  MANIFEST_TARGET="${TEST_TMP_DIR}/output-3e/backup-reference.json"

  set +e
  "$KOPIA_BACKUP_SCRIPT" "$FIXTURE_BACKUP_DIR" "$MANIFEST_TARGET" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e

  assert_test "Invalid JSON: exit code is non-zero" \
    "[ $EXIT_CODE -ne 0 ]" \
    "Expected failure when Kopia outputs non-JSON"

  assert_test "Invalid JSON: manifest file is NOT published" \
    "[ ! -f '$MANIFEST_TARGET' ]" \
    "Manifest must not exist when Kopia outputs non-JSON"
)

# ----------------------------------------------------------------
# Category 4: Successful Backup & Manifest Publishing
# ----------------------------------------------------------------
echo ""
echo "--- Category 4: Successful Backup & Manifest Publishing ---"

(
  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_KOPIA_ACTION="success"
  EXPECTED_SNAP_ID="snap-test-id-9876543210"
  export MOCK_KOPIA_SNAPSHOT_ID="$EXPECTED_SNAP_ID"
  export POSTGRES_DB="production_app_db"
  export CI_COMMIT_SHA="d3adb33f1234567890abcdef1234567890abcdef"
  MANIFEST_TARGET="${TEST_TMP_DIR}/workspace/output/backup-reference.json"

  "$KOPIA_BACKUP_SCRIPT" "$FIXTURE_BACKUP_DIR" "$MANIFEST_TARGET"

  assert_test "Success: manifest file was created" \
    "[ -f '$MANIFEST_TARGET' ]" \
    "Manifest file does not exist at $MANIFEST_TARGET"

  assert_test "Success: temporary .part files cleaned up" \
    "[ \$(find '${TEST_TMP_DIR}/workspace/output' -name '*.part.*' | wc -l) -eq 0 ]" \
    "Found leftover temporary files"

  PARSED_SNAP_ID=$(jq -r '.snapshotId' "$MANIFEST_TARGET")
  assert_test "Success: exact snapshotId matches operation ($EXPECTED_SNAP_ID)" \
    "[ '$PARSED_SNAP_ID' = '$EXPECTED_SNAP_ID' ]" \
    "Parsed snapshotId '$PARSED_SNAP_ID' does not match expected '$EXPECTED_SNAP_ID'"

  PARSED_VERSION=$(jq -r '.schemaVersion' "$MANIFEST_TARGET")
  assert_test "Success: schemaVersion is 1" \
    "[ '$PARSED_VERSION' = '1' ]" \
    "schemaVersion is '$PARSED_VERSION', expected 1"

  PARSED_DB=$(jq -r '.database' "$MANIFEST_TARGET")
  assert_test "Success: database matches POSTGRES_DB" \
    "[ '$PARSED_DB' = 'production_app_db' ]" \
    "database is '$PARSED_DB', expected 'production_app_db'"

  PARSED_COMMIT=$(jq -r '.commitSha' "$MANIFEST_TARGET")
  assert_test "Success: commitSha matches CI_COMMIT_SHA" \
    "[ '$PARSED_COMMIT' = 'd3adb33f1234567890abcdef1234567890abcdef' ]" \
    "commitSha is '$PARSED_COMMIT'"

  PARSED_CREATED_AT=$(jq -r '.createdAt' "$MANIFEST_TARGET")
  ISO_MATCH=$(echo "$PARSED_CREATED_AT" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || true)
  assert_test "Success: createdAt is valid ISO 8601 UTC timestamp ($PARSED_CREATED_AT)" \
    "[ -n '$ISO_MATCH' ]" \
    "createdAt '$PARSED_CREATED_AT' does not match ISO 8601 UTC regex"

  # Validate against Task 1 schema validator
  SCHEMA_VALID=$(jq -e '
    type == "object" and
    .schemaVersion == 1 and
    (.snapshotId | type == "string" and length > 0) and
    (.commitSha | type == "string") and
    (.database | type == "string") and
    (.createdAt | type == "string") and
    ([keys[] | select(test("password|secret|token|command|script"; "i"))] | length == 0)
  ' "$MANIFEST_TARGET" >/dev/null 2>&1 && echo "valid" || echo "invalid")

  assert_test "Success: manifest passes Task 1 schema validation" \
    "[ '$SCHEMA_VALID' = 'valid' ]" \
    "Manifest failed Task 1 schema validation"
)

# ----------------------------------------------------------------
# Category 5: Security & Credential Redaction
# ----------------------------------------------------------------
echo ""
echo "--- Category 5: Security & No Secret Leakage ---"

(
  export PATH="${MOCK_BIN_DIR}:$PATH"
  export MOCK_KOPIA_ACTION="success"
  export MOCK_KOPIA_SNAPSHOT_ID="secure-snap-444"
  export POSTGRES_DB="app"
  export KOPIA_PASSWORD="SUPER_SECRET_PASSWORD_DO_NOT_LEAK"
  export KOPIA_SERVER_URL="https://admin:SECRET_TOKEN@kopia.service:51515"
  export KOPIA_SERVER_FINGERPRINT="FINGERPRINT_VALUE"
  MANIFEST_TARGET="${TEST_TMP_DIR}/output-sec/backup-reference.json"

  "$KOPIA_BACKUP_SCRIPT" "$FIXTURE_BACKUP_DIR" "$MANIFEST_TARGET"

  MANIFEST_CONTENT=$(cat "$MANIFEST_TARGET")

  assert_test "No secret: KOPIA_PASSWORD is NOT in manifest" \
    "! echo '$MANIFEST_CONTENT' | grep -Fq 'SUPER_SECRET_PASSWORD_DO_NOT_LEAK'" \
    "Found secret password inside manifest JSON!"

  assert_test "No secret: Server URL / tokens NOT in manifest" \
    "! echo '$MANIFEST_CONTENT' | grep -Fq 'SECRET_TOKEN'" \
    "Found token inside manifest JSON!"

  KEY_CHECK=$(jq -r '[keys[] | select(test("password|secret|token|command|script|auth|key"; "i"))] | length' "$MANIFEST_TARGET")
  assert_test "No secret: No prohibited or credential keys present" \
    "[ '$KEY_CHECK' -eq 0 ]" \
    "Found prohibited keys in manifest"
)

# ----------------------------------------------------------------
# Category 6: End-to-End backup.sh Flow with Mocked Docker
# ----------------------------------------------------------------
echo ""
echo "--- Category 6: End-to-End backup.sh Flow ---"

(
  # Mock docker command
  MOCK_DOCKER_DIR="${TEST_TMP_DIR}/docker_bin"
  mkdir -p "$MOCK_DOCKER_DIR"
  cat <<'EOF' > "${MOCK_DOCKER_DIR}/docker"
#!/usr/bin/env bash
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "exec" ]; then
  # Simulate pg_dump output
  echo "-- PostgreSQL database dump"
  echo "CREATE TABLE test (id serial, data text);"
  exit 0
fi
echo "Mock docker: unknown args: $*" >&2
exit 0
EOF
  chmod +x "${MOCK_DOCKER_DIR}/docker"

  export PATH="${MOCK_DOCKER_DIR}:${MOCK_BIN_DIR}:$PATH"
  export MOCK_KOPIA_ACTION="success"
  export MOCK_KOPIA_SNAPSHOT_ID="e2e-snap-backup-sh-111"
  export DEPLOY_DIR="${TEST_TMP_DIR}/deploy-runtime"
  export BACKUP_ROOT="${TEST_TMP_DIR}/backups"
  export POSTGRES_USER="test_user"
  export POSTGRES_DB="test_db"
  export BACKUP_ID="backup-test-e2e"
  export IMAGE_TAG="v1.2.3"
  export CI_COMMIT_SHA="abcdef0123456789"
  export MANIFEST_OUTPUT="${TEST_TMP_DIR}/workspace/output/backup-reference.json"

  mkdir -p "${DEPLOY_DIR}/uploads"
  echo "test upload file" > "${DEPLOY_DIR}/uploads/sample.txt"

  # Execute backup.sh
  "$BACKUP_SCRIPT"

  DEST="${BACKUP_ROOT}/${BACKUP_ID}"

  assert_test "backup.sh: database.sql was dumped" \
    "[ -f '${DEST}/database.sql' ] && [ -s '${DEST}/database.sql' ]" \
    "database.sql missing or empty"

  assert_test "backup.sh: uploads.tgz was created" \
    "[ -f '${DEST}/uploads.tgz' ] && [ -s '${DEST}/uploads.tgz' ]" \
    "uploads.tgz missing or empty"

  assert_test "backup.sh: manifest.txt backward compatibility file created" \
    "[ -f '${DEST}/manifest.txt' ]" \
    "manifest.txt missing"

  assert_test "backup.sh: output/backup-reference.json published at MANIFEST_OUTPUT" \
    "[ -f '$MANIFEST_OUTPUT' ]" \
    "backup-reference.json was not created at $MANIFEST_OUTPUT"

  E2E_SNAP_ID=$(jq -r '.snapshotId' "$MANIFEST_OUTPUT")
  assert_test "backup.sh: snapshotId in manifest matches e2e snapshot ($E2E_SNAP_ID)" \
    "[ '$E2E_SNAP_ID' = 'e2e-snap-backup-sh-111' ]" \
    "Expected e2e-snap-backup-sh-111, got $E2E_SNAP_ID"
)

# ----------------------------------------------------------------
# Category 7: Integration with Real Kopia CLI (Local Filesystem Repo)
# ----------------------------------------------------------------
echo ""
echo "--- Category 7: Real Kopia CLI Integration ---"

if command -v /usr/bin/kopia >/dev/null 2>&1; then
  REAL_REPO_DIR="${TEST_TMP_DIR}/real-kopia-repo"
  REAL_BACKUP_DIR="${TEST_TMP_DIR}/real-backup-src"
  REAL_MANIFEST="${TEST_TMP_DIR}/real-output/backup-reference.json"
  mkdir -p "$REAL_REPO_DIR" "$REAL_BACKUP_DIR"
  echo "Real backup content" > "${REAL_BACKUP_DIR}/data.txt"

  REAL_CFG="${TEST_TMP_DIR}/real-kopia-init.cfg"
  export KOPIA_PASSWORD="real-test-password"
  /usr/bin/kopia --config-file="$REAL_CFG" repository create filesystem \
    --path="$REAL_REPO_DIR" \
    --no-check-for-updates >/dev/null 2>&1
  rm -f "$REAL_CFG" "$REAL_CFG".*

  (
    # Unset mock bin from PATH so real /usr/bin/kopia is used
    export KOPIA_REPOSITORY_PATH="$REAL_REPO_DIR"
    export POSTGRES_DB="real_app_db"
    export CI_COMMIT_SHA="real1234567890"

    "$KOPIA_BACKUP_SCRIPT" "$REAL_BACKUP_DIR" "$REAL_MANIFEST"

    assert_test "Real Kopia: manifest file published" \
      "[ -f '$REAL_MANIFEST' ]" \
      "Real Kopia manifest was not published"

    REAL_SNAP_ID=$(jq -r '.snapshotId' "$REAL_MANIFEST")
    assert_test "Real Kopia: snapshotId is non-empty string ($REAL_SNAP_ID)" \
      "[ -n '$REAL_SNAP_ID' ] && [ '$REAL_SNAP_ID' != 'null' ]" \
      "Invalid real snapshot ID: $REAL_SNAP_ID"

    REAL_SCHEMA_VALID=$(jq -e '
      type == "object" and
      .schemaVersion == 1 and
      (.snapshotId | type == "string" and length > 0) and
      (.commitSha | type == "string") and
      (.database | type == "string") and
      (.createdAt | type == "string") and
      ([keys[] | select(test("password|secret|token|command|script"; "i"))] | length == 0)
    ' "$REAL_MANIFEST" >/dev/null 2>&1 && echo "valid" || echo "invalid")

    assert_test "Real Kopia: manifest validates against Task 1 schema" \
      "[ '$REAL_SCHEMA_VALID' = 'valid' ]" \
      "Real Kopia manifest failed schema validation"
  )
else
  echo "  [SKIP] /usr/bin/kopia not found, skipping real Kopia integration test"
fi

# ----------------------------------------------------------------
# Category 8: Pipeline Definition Validation (backup.yaml)
# ----------------------------------------------------------------
echo ""
echo "--- Category 8: Pipeline Definition Validation (backup.yaml) ---"

PARSER_RESULT=$(npx --prefix /home/gmo021/infraDesk tsx -e '
import fs from "fs";
import { parsePipelineDefinition } from "/home/gmo021/infraDesk/packages/pipeline-runtime/src/index";

const yaml = fs.readFileSync(process.argv[1], "utf8");
const result = parsePipelineDefinition(yaml);
console.log(JSON.stringify(result));
' "$BACKUP_YAML" 2>/dev/null || echo '{"ok":false}')

PARSER_OK=$(echo "$PARSER_RESULT" | jq -r '.ok // false')
DIAGNOSTICS_COUNT=$(echo "$PARSER_RESULT" | jq -r '.diagnostics | length // 999')
ARTIFACT_PATHS=$(echo "$PARSER_RESULT" | jq -r '.plan.jobs[] | select(.name == "backup_runtime") | .artifacts.paths[] // empty')
ARTIFACT_EXPIRE=$(echo "$PARSER_RESULT" | jq -r '.plan.jobs[] | select(.name == "backup_runtime") | .artifacts.expireIn.kind // empty')
ARTIFACT_WHEN=$(echo "$PARSER_RESULT" | jq -r '.plan.jobs[] | select(.name == "backup_runtime") | .artifacts.when // empty')

assert_test "backup.yaml parses successfully with parsePipelineDefinition" \
  "[ '$PARSER_OK' = 'true' ]" \
  "parsePipelineDefinition returned ok: false"

assert_test "backup.yaml has 0 diagnostics" \
  "[ '$DIAGNOSTICS_COUNT' -eq 0 ]" \
  "Diagnostics count was $DIAGNOSTICS_COUNT"

assert_test "backup_runtime artifact path contains output/backup-reference.json" \
  "[ '$ARTIFACT_PATHS' = 'output/backup-reference.json' ]" \
  "Expected output/backup-reference.json, got: $ARTIFACT_PATHS"

assert_test "backup_runtime artifact expire_in is 'never'" \
  "[ '$ARTIFACT_EXPIRE' = 'never' ]" \
  "Expected never, got: $ARTIFACT_EXPIRE"

assert_test "backup_runtime artifact when is 'on_success'" \
  "[ '$ARTIFACT_WHEN' = 'on_success' ]" \
  "Expected on_success, got: $ARTIFACT_WHEN"

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
