#!/usr/bin/env bash
set -euo pipefail

# test/download-backup-manifest.test.sh
# Automated test suite for deploy/scripts/download-backup-manifest.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOWNLOAD_SCRIPT="${REPO_DIR}/deploy/scripts/download-backup-manifest.sh"
MOCK_SERVER="${SCRIPT_DIR}/mock-artifact-server.js"

TEST_TMP_DIR=$(mktemp -d)
PORT_FILE="${TEST_TMP_DIR}/mock_server_port.txt"
MOCK_SERVER_PID=""

cleanup() {
  if [ -n "$MOCK_SERVER_PID" ]; then
    kill -TERM "$MOCK_SERVER_PID" 2>/dev/null || true
    wait "$MOCK_SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT INT TERM

echo "Starting mock artifact server..."
node "$MOCK_SERVER" > "$PORT_FILE" 2>&1 &
MOCK_SERVER_PID=$!

# Wait for server port
PORT=""
for _ in $(seq 1 50); do
  if [ -s "$PORT_FILE" ]; then
    PORT=$(grep -o 'PORT=[0-9]*' "$PORT_FILE" | cut -d= -f2 || true)
    if [ -n "$PORT" ]; then
      break
    fi
  fi
  sleep 0.1
done

if [ -z "$PORT" ]; then
  echo "Error: Mock artifact server failed to start. Logs:" >&2
  cat "$PORT_FILE" >&2
  exit 1
fi

echo "Mock artifact server listening on port $PORT"
export ARTIFACT_API_BASE="http://127.0.0.1:${PORT}"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_test() {
  local test_name="$1"
  local condition="$2"
  local error_msg="${3:-}"

  TESTS_RUN=$((TESTS_RUN + 1))
  if eval "$condition"; then
    echo "  [PASS] $test_name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "  [FAIL] $test_name: $error_msg" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo "=== Running download-backup-manifest.sh test suite ==="

# -------------------------------------------------------------
# 1. Success case A: valid download, matching checksum, valid JSON schema
# -------------------------------------------------------------
echo "Test 1: Success case A (valid download, matching checksum, valid schema)"
DEST_1="${TEST_TMP_DIR}/test1_dest.json"
ARTIFACT_ID_1="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PAYLOAD_1=$(curl -s "${ARTIFACT_API_BASE}/api/artifacts/${ARTIFACT_ID_1}/download")
SHA256_1=$(printf '%s' "$PAYLOAD_1" | sha256sum | awk '{print $1}')

EXIT_CODE_1=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_1" \
BACKUP_MANIFEST_SHA256="$SHA256_1" \
"$DOWNLOAD_SCRIPT" "$DEST_1" > /dev/null 2>&1 || EXIT_CODE_1=$?

assert_test "1.1 returns exit code 0" '[ "$EXIT_CODE_1" -eq 0 ]' "expected 0, got $EXIT_CODE_1"
assert_test "1.2 destination file exists" '[ -f "$DEST_1" ]' "destination file not found"
assert_test "1.3 destination file has valid snapshotId" '[ "$(jq -r .snapshotId "$DEST_1" 2>/dev/null)" = "snap-test-success-001" ]' "wrong snapshotId"
assert_test "1.4 destination file has schemaVersion 1" '[ "$(jq -r .schemaVersion "$DEST_1" 2>/dev/null)" = "1" ]' "wrong schemaVersion"
assert_test "1.5 no temp .part.* files remaining" '[ $(ls "${TEST_TMP_DIR}"/test1_dest.json.part.* 2>/dev/null | wc -l) -eq 0 ]' "temp files left behind"

# -------------------------------------------------------------
# 2. HTTP 404
# -------------------------------------------------------------
echo "Test 2: HTTP 404 Not Found"
DEST_2="${TEST_TMP_DIR}/test2_dest.json"
ARTIFACT_ID_2="40444444-4444-4444-4444-444444444444"
DUMMY_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

EXIT_CODE_2=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_2" \
BACKUP_MANIFEST_SHA256="$DUMMY_SHA" \
"$DOWNLOAD_SCRIPT" "$DEST_2" > /dev/null 2>&1 || EXIT_CODE_2=$?

assert_test "2.1 returns non-zero on 404" '[ "$EXIT_CODE_2" -ne 0 ]' "expected non-zero, got $EXIT_CODE_2"
assert_test "2.2 destination file does NOT exist" '[ ! -e "$DEST_2" ]' "destination file should not exist"
assert_test "2.3 no temp .part.* files remaining" '[ $(ls "${TEST_TMP_DIR}"/test2_dest.json.part.* 2>/dev/null | wc -l) -eq 0 ]' "temp files left behind"

# -------------------------------------------------------------
# 3. Connection / request timeout
# -------------------------------------------------------------
echo "Test 3: Connection / request timeout"
DEST_3="${TEST_TMP_DIR}/test3_dest.json"
ARTIFACT_ID_3="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
DUMMY_SHA_3="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

EXIT_CODE_3=0
CURL_MAX_TIME=1 \
CURL_CONNECT_TIMEOUT=1 \
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_3" \
BACKUP_MANIFEST_SHA256="$DUMMY_SHA_3" \
"$DOWNLOAD_SCRIPT" "$DEST_3" > /dev/null 2>&1 || EXIT_CODE_3=$?

assert_test "3.1 returns non-zero on timeout" '[ "$EXIT_CODE_3" -ne 0 ]' "expected non-zero, got $EXIT_CODE_3"
assert_test "3.2 destination file does NOT exist" '[ ! -e "$DEST_3" ]' "destination file should not exist"
assert_test "3.3 no temp .part.* files remaining" '[ $(ls "${TEST_TMP_DIR}"/test3_dest.json.part.* 2>/dev/null | wc -l) -eq 0 ]' "temp files left behind"

# -------------------------------------------------------------
# 4. Checksum mismatch
# -------------------------------------------------------------
echo "Test 4: Checksum mismatch"
DEST_4="${TEST_TMP_DIR}/test4_dest.json"
ARTIFACT_ID_4="cccccccc-cccc-cccc-cccc-cccccccccccc"
MISMATCHED_SHA="0000000000000000000000000000000000000000000000000000000000000000"

EXIT_CODE_4=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_4" \
BACKUP_MANIFEST_SHA256="$MISMATCHED_SHA" \
"$DOWNLOAD_SCRIPT" "$DEST_4" > /dev/null 2>&1 || EXIT_CODE_4=$?

assert_test "4.1 returns non-zero on checksum mismatch" '[ "$EXIT_CODE_4" -ne 0 ]' "expected non-zero, got $EXIT_CODE_4"
assert_test "4.2 destination file does NOT exist" '[ ! -e "$DEST_4" ]' "destination file should not exist"
assert_test "4.3 no temp .part.* files remaining" '[ $(ls "${TEST_TMP_DIR}"/test4_dest.json.part.* 2>/dev/null | wc -l) -eq 0 ]' "temp files left behind"

# -------------------------------------------------------------
# 5. Malformed JSON or invalid schema
# -------------------------------------------------------------
echo "Test 5: Malformed JSON and schema violations"

# 5a: Syntax error
DEST_5A="${TEST_TMP_DIR}/test5a_dest.json"
STDERR_5A="${TEST_TMP_DIR}/test5a_stderr.log"
ARTIFACT_ID_5A="55555555-5555-5555-5555-000000000001"
PAYLOAD_5A=$(curl -s "${ARTIFACT_API_BASE}/api/artifacts/${ARTIFACT_ID_5A}/download")
SHA256_5A=$(printf '%s' "$PAYLOAD_5A" | sha256sum | awk '{print $1}')

EXIT_CODE_5A=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_5A" \
BACKUP_MANIFEST_SHA256="$SHA256_5A" \
"$DOWNLOAD_SCRIPT" "$DEST_5A" > /dev/null 2> "$STDERR_5A" || EXIT_CODE_5A=$?

assert_test "5a.1 rejects malformed JSON syntax" '[ "$EXIT_CODE_5A" -ne 0 ]' "expected non-zero, got $EXIT_CODE_5A"
assert_test "5a.2 destination file does NOT exist" '[ ! -e "$DEST_5A" ]' "destination file should not exist"
assert_test "5a.3 jq error message is visible on stderr" 'grep -qi "parse error" "$STDERR_5A"' "jq parse error not visible on stderr"

# 5b: Missing snapshotId
DEST_5B="${TEST_TMP_DIR}/test5b_dest.json"
ARTIFACT_ID_5B="55555555-5555-5555-5555-000000000002"
PAYLOAD_5B=$(curl -s "${ARTIFACT_API_BASE}/api/artifacts/${ARTIFACT_ID_5B}/download")
SHA256_5B=$(printf '%s' "$PAYLOAD_5B" | sha256sum | awk '{print $1}')

EXIT_CODE_5B=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_5B" \
BACKUP_MANIFEST_SHA256="$SHA256_5B" \
"$DOWNLOAD_SCRIPT" "$DEST_5B" > /dev/null 2>&1 || EXIT_CODE_5B=$?

assert_test "5b.1 rejects missing snapshotId" '[ "$EXIT_CODE_5B" -ne 0 ]' "expected non-zero, got $EXIT_CODE_5B"
assert_test "5b.2 destination file does NOT exist" '[ ! -e "$DEST_5B" ]' "destination file should not exist"

# 5c: Empty snapshotId
DEST_5C="${TEST_TMP_DIR}/test5c_dest.json"
ARTIFACT_ID_5C="55555555-5555-5555-5555-000000000003"
PAYLOAD_5C=$(curl -s "${ARTIFACT_API_BASE}/api/artifacts/${ARTIFACT_ID_5C}/download")
SHA256_5C=$(printf '%s' "$PAYLOAD_5C" | sha256sum | awk '{print $1}')

EXIT_CODE_5C=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_5C" \
BACKUP_MANIFEST_SHA256="$SHA256_5C" \
"$DOWNLOAD_SCRIPT" "$DEST_5C" > /dev/null 2>&1 || EXIT_CODE_5C=$?

assert_test "5c.1 rejects empty snapshotId" '[ "$EXIT_CODE_5C" -ne 0 ]' "expected non-zero, got $EXIT_CODE_5C"
assert_test "5c.2 destination file does NOT exist" '[ ! -e "$DEST_5C" ]' "destination file should not exist"

# 5d: Wrong schemaVersion
DEST_5D="${TEST_TMP_DIR}/test5d_dest.json"
ARTIFACT_ID_5D="55555555-5555-5555-5555-000000000004"
PAYLOAD_5D=$(curl -s "${ARTIFACT_API_BASE}/api/artifacts/${ARTIFACT_ID_5D}/download")
SHA256_5D=$(printf '%s' "$PAYLOAD_5D" | sha256sum | awk '{print $1}')

EXIT_CODE_5D=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_5D" \
BACKUP_MANIFEST_SHA256="$SHA256_5D" \
"$DOWNLOAD_SCRIPT" "$DEST_5D" > /dev/null 2>&1 || EXIT_CODE_5D=$?

assert_test "5d.1 rejects wrong schemaVersion" '[ "$EXIT_CODE_5D" -ne 0 ]' "expected non-zero, got $EXIT_CODE_5D"
assert_test "5d.2 destination file does NOT exist" '[ ! -e "$DEST_5D" ]' "destination file should not exist"

# 5e: Missing required string fields
DEST_5E="${TEST_TMP_DIR}/test5e_dest.json"
ARTIFACT_ID_5E="55555555-5555-5555-5555-000000000005"
PAYLOAD_5E=$(curl -s "${ARTIFACT_API_BASE}/api/artifacts/${ARTIFACT_ID_5E}/download")
SHA256_5E=$(printf '%s' "$PAYLOAD_5E" | sha256sum | awk '{print $1}')

EXIT_CODE_5E=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_5E" \
BACKUP_MANIFEST_SHA256="$SHA256_5E" \
"$DOWNLOAD_SCRIPT" "$DEST_5E" > /dev/null 2>&1 || EXIT_CODE_5E=$?

assert_test "5e.1 rejects missing required string fields" '[ "$EXIT_CODE_5E" -ne 0 ]' "expected non-zero, got $EXIT_CODE_5E"
assert_test "5e.2 destination file does NOT exist" '[ ! -e "$DEST_5E" ]' "destination file should not exist"

# 5f: Prohibited credentials/command fields
DEST_5F="${TEST_TMP_DIR}/test5f_dest.json"
ARTIFACT_ID_5F="55555555-5555-5555-5555-000000000006"
PAYLOAD_5F=$(curl -s "${ARTIFACT_API_BASE}/api/artifacts/${ARTIFACT_ID_5F}/download")
SHA256_5F=$(printf '%s' "$PAYLOAD_5F" | sha256sum | awk '{print $1}')

EXIT_CODE_5F=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_5F" \
BACKUP_MANIFEST_SHA256="$SHA256_5F" \
"$DOWNLOAD_SCRIPT" "$DEST_5F" > /dev/null 2>&1 || EXIT_CODE_5F=$?

assert_test "5f.1 rejects JSON containing prohibited credential/command fields" '[ "$EXIT_CODE_5F" -ne 0 ]' "expected non-zero, got $EXIT_CODE_5F"
assert_test "5f.2 destination file does NOT exist" '[ ! -e "$DEST_5F" ]' "destination file should not exist"

# 5g: Prohibited nested credentials/command fields
DEST_5G="${TEST_TMP_DIR}/test5g_dest.json"
ARTIFACT_ID_5G="55555555-5555-5555-5555-000000000007"
PAYLOAD_5G=$(curl -s "${ARTIFACT_API_BASE}/api/artifacts/${ARTIFACT_ID_5G}/download")
SHA256_5G=$(printf '%s' "$PAYLOAD_5G" | sha256sum | awk '{print $1}')

EXIT_CODE_5G=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_5G" \
BACKUP_MANIFEST_SHA256="$SHA256_5G" \
"$DOWNLOAD_SCRIPT" "$DEST_5G" > /dev/null 2>&1 || EXIT_CODE_5G=$?

assert_test "5g.1 rejects JSON containing prohibited nested credential/command fields" '[ "$EXIT_CODE_5G" -ne 0 ]' "expected non-zero, got $EXIT_CODE_5G"
assert_test "5g.2 destination file does NOT exist" '[ ! -e "$DEST_5G" ]' "destination file should not exist"


# -------------------------------------------------------------
# 6. Existing old file at destination (must not be used as fallback on failure)
# -------------------------------------------------------------
echo "Test 6: Existing old file at destination"

# 6a: 404 with pre-existing file
DEST_6A="${TEST_TMP_DIR}/test6a_old_file.json"
echo '{"schemaVersion": 1, "snapshotId": "stale-old-backup"}' > "$DEST_6A"

EXIT_CODE_6A=0
BACKUP_ARTIFACT_ID="40444444-4444-4444-4444-444444444444" \
BACKUP_MANIFEST_SHA256="$DUMMY_SHA" \
"$DOWNLOAD_SCRIPT" "$DEST_6A" > /dev/null 2>&1 || EXIT_CODE_6A=$?

assert_test "6a.1 returns non-zero on 404 with pre-existing file" '[ "$EXIT_CODE_6A" -ne 0 ]' "expected non-zero, got $EXIT_CODE_6A"
assert_test "6a.2 pre-existing file was eliminated (not retained as fallback)" '[ ! -e "$DEST_6A" ]' "stale file was retained!"

# 6b: Checksum mismatch with pre-existing file
DEST_6B="${TEST_TMP_DIR}/test6b_old_file.json"
echo '{"schemaVersion": 1, "snapshotId": "stale-old-backup"}' > "$DEST_6B"

EXIT_CODE_6B=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_4" \
BACKUP_MANIFEST_SHA256="$MISMATCHED_SHA" \
"$DOWNLOAD_SCRIPT" "$DEST_6B" > /dev/null 2>&1 || EXIT_CODE_6B=$?

assert_test "6b.1 returns non-zero on checksum mismatch with pre-existing file" '[ "$EXIT_CODE_6B" -ne 0 ]' "expected non-zero, got $EXIT_CODE_6B"
assert_test "6b.2 pre-existing file was eliminated" '[ ! -e "$DEST_6B" ]' "stale file was retained!"

# 6c: Invalid schema with pre-existing file
DEST_6C="${TEST_TMP_DIR}/test6c_old_file.json"
echo '{"schemaVersion": 1, "snapshotId": "stale-old-backup"}' > "$DEST_6C"

EXIT_CODE_6C=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_5B" \
BACKUP_MANIFEST_SHA256="$SHA256_5B" \
"$DOWNLOAD_SCRIPT" "$DEST_6C" > /dev/null 2>&1 || EXIT_CODE_6C=$?

assert_test "6c.1 returns non-zero on schema error with pre-existing file" '[ "$EXIT_CODE_6C" -ne 0 ]' "expected non-zero, got $EXIT_CODE_6C"
assert_test "6c.2 pre-existing file was eliminated" '[ ! -e "$DEST_6C" ]' "stale file was retained!"

# -------------------------------------------------------------
# 7. File size limit exceeded (> 256 KiB = 262144 bytes)
# -------------------------------------------------------------
echo "Test 7: File size limit (> 256 KiB)"
DEST_7="${TEST_TMP_DIR}/test7_dest.json"
ARTIFACT_ID_7="77777777-7777-7777-7777-777777777777"
PAYLOAD_7=$(curl -s "${ARTIFACT_API_BASE}/api/artifacts/${ARTIFACT_ID_7}/download")
SHA256_7=$(printf '%s' "$PAYLOAD_7" | sha256sum | awk '{print $1}')

EXIT_CODE_7=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_7" \
BACKUP_MANIFEST_SHA256="$SHA256_7" \
"$DOWNLOAD_SCRIPT" "$DEST_7" > /dev/null 2>&1 || EXIT_CODE_7=$?

assert_test "7.1 returns non-zero when artifact exceeds 256 KiB" '[ "$EXIT_CODE_7" -ne 0 ]' "expected non-zero, got $EXIT_CODE_7"
assert_test "7.2 destination file does NOT exist" '[ ! -e "$DEST_7" ]' "destination file should not exist"

# -------------------------------------------------------------
# 8. Input validation (UUID, SHA256, required env vars, CLI args)
# -------------------------------------------------------------
echo "Test 8: Input validation"

DEST_8="${TEST_TMP_DIR}/test8_dest.json"

# 8a: Invalid BACKUP_ARTIFACT_ID format
EXIT_CODE_8A=0
BACKUP_ARTIFACT_ID="not-a-uuid" \
BACKUP_MANIFEST_SHA256="$SHA256_1" \
"$DOWNLOAD_SCRIPT" "$DEST_8" > /dev/null 2>&1 || EXIT_CODE_8A=$?
assert_test "8a rejects non-UUID BACKUP_ARTIFACT_ID" '[ "$EXIT_CODE_8A" -ne 0 ]' "expected non-zero"

# 8b: Missing BACKUP_ARTIFACT_ID
EXIT_CODE_8B=0
(unset BACKUP_ARTIFACT_ID; BACKUP_MANIFEST_SHA256="$SHA256_1" "$DOWNLOAD_SCRIPT" "$DEST_8" > /dev/null 2>&1) || EXIT_CODE_8B=$?
assert_test "8b rejects missing BACKUP_ARTIFACT_ID" '[ "$EXIT_CODE_8B" -ne 0 ]' "expected non-zero"

# 8c: Invalid SHA256 format (e.g. 10 chars)
EXIT_CODE_8C=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_1" \
BACKUP_MANIFEST_SHA256="shortsha" \
"$DOWNLOAD_SCRIPT" "$DEST_8" > /dev/null 2>&1 || EXIT_CODE_8C=$?
assert_test "8c rejects invalid SHA256 format" '[ "$EXIT_CODE_8C" -ne 0 ]' "expected non-zero"

# 8d: Missing BACKUP_MANIFEST_SHA256
EXIT_CODE_8D=0
(unset BACKUP_MANIFEST_SHA256; BACKUP_ARTIFACT_ID="$ARTIFACT_ID_1" "$DOWNLOAD_SCRIPT" "$DEST_8" > /dev/null 2>&1) || EXIT_CODE_8D=$?
assert_test "8d rejects missing BACKUP_MANIFEST_SHA256" '[ "$EXIT_CODE_8D" -ne 0 ]' "expected non-zero"

# 8e: Missing destination argument
EXIT_CODE_8E=0
BACKUP_ARTIFACT_ID="$ARTIFACT_ID_1" \
BACKUP_MANIFEST_SHA256="$SHA256_1" \
"$DOWNLOAD_SCRIPT" > /dev/null 2>&1 || EXIT_CODE_8E=$?
assert_test "8e rejects missing destination argument" '[ "$EXIT_CODE_8E" -ne 0 ]' "expected non-zero"

# 8f: Missing ARTIFACT_API_BASE
EXIT_CODE_8F=0
(unset ARTIFACT_API_BASE; BACKUP_ARTIFACT_ID="$ARTIFACT_ID_1" BACKUP_MANIFEST_SHA256="$SHA256_1" "$DOWNLOAD_SCRIPT" "$DEST_8" > /dev/null 2>&1) || EXIT_CODE_8F=$?
assert_test "8f rejects missing ARTIFACT_API_BASE" '[ "$EXIT_CODE_8F" -ne 0 ]' "expected non-zero"

# -------------------------------------------------------------
# Summary
# -------------------------------------------------------------
echo ""
echo "=== Test Summary ==="
echo "Total tests: $TESTS_RUN"
echo "Passed:      $TESTS_PASSED"
echo "Failed:      $TESTS_FAILED"

if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "Test suite FAILED!" >&2
  exit 1
fi

echo "All tests passed successfully!"
exit 0
