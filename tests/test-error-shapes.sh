#!/bin/bash

# Tests for tolerating both shapes of a rejected API response.
#
# The PTC API reports a rejected request one of two ways depending on the
# server build: HTTP 200 with {"success":false,...,"code":422} in the body
# (older), or a real HTTP 422 carrying the same body (newer). Deployments do not
# all update on the same day, so the CLI must read both identically.
#
# The regressions these guard against are silent rather than loud: a rejected
# `process` reported as "processing started successfully", and a rejected
# `download` saving the JSON error envelope as a .zip and unpacking it. Both
# end as a green CI run that produced no translations.

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI_UNDER_TEST="$(dirname "$TEST_DIR")/ptc-cli.sh"

# shellcheck disable=SC1090
source "$CLI_UNDER_TEST"   # main() is guarded by a BASH_SOURCE check

set +e   # let individual assertions fail without aborting the run

test_count=0
passed_count=0
failed_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; passed_count=$((passed_count + 1)); test_count=$((test_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; failed_count=$((failed_count + 1)); test_count=$((test_count + 1)); }

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$desc"
    else
        fail "$desc (got '$got', want '$want')"
    fi
}

assert_failure() {
    local desc="$1" code="$2" body="$3"
    if response_indicates_failure "$code" "$body"; then
        pass "$desc"
    else
        fail "$desc (expected a failure verdict, got success)"
    fi
}

assert_success() {
    local desc="$1" code="$2" body="$3"
    if response_indicates_failure "$code" "$body"; then
        fail "$desc (expected a success verdict, got failure)"
    else
        pass "$desc"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *) fail "$desc (expected '$needle' in '$haystack')" ;;
    esac
}

readonly REJECTION_BODY='{"success":false,"message":"Unprocessable Entity","code":422,"errors":[1]}'
readonly CREATED_BODY='{"source_file":{"id":18475,"file_path":"locales/en.json"}}'
readonly STATUS_BODY='{"translation_status":{"status":"completed","completeness":100,"terminal":true,"failure_reason":null}}'

echo "=== response_indicates_failure: the older shape (200 + success:false) ==="

assert_failure "200 carrying success:false is a failure" "200" "$REJECTION_BODY"
assert_failure "201 carrying success:false is a failure" "201" "$REJECTION_BODY"

echo
echo "=== response_indicates_failure: the newer shape (real 422) ==="

assert_failure "422 is a failure" "422" "$REJECTION_BODY"
assert_failure "422 with an empty body is a failure" "422" ""

echo
echo "=== response_indicates_failure: genuine successes stay successes ==="

assert_success "201 with a created source_file" "201" "$CREATED_BODY"
assert_success "200 with a translation status" "200" "$STATUS_BODY"
assert_success "200 with an empty body" "200" ""
# The word "success" appearing as a value, or a true flag, must not read as a rejection.
assert_success "200 with success:true" "200" '{"success":true,"id":7}'

echo
echo "=== response_indicates_failure: other non-2xx codes ==="

assert_failure "401 is a failure" "401" ""
assert_failure "404 is a failure" "404" ""
assert_failure "500 is a failure" "500" ""
assert_failure "a non-numeric code is a failure" "000" ""

echo
echo "=== describe_api_failure ==="

description=$(describe_api_failure "422" "$REJECTION_BODY")
assert_contains "carries the status" "$description" "HTTP 422"
assert_contains "carries the message" "$description" "Unprocessable Entity"
assert_contains "carries the numeric error codes" "$description" "[1]"

description=$(describe_api_failure "500" "")
assert_eq "degrades to the bare status with no body" "$description" "HTTP 500"

echo
echo "=== start_processing: a rejected call must not report success ==="

# Stub the pieces start_processing depends on, so the assertion is about the
# verdict rather than about curl.
PTC_API_TOKEN="test-token"
PTC_API_URL="https://example.invalid/api/v1/"
MOCK_PROCESS_CODE="200"
MOCK_PROCESS_BODY="$REJECTION_BODY"

ptc_curl() { printf '%s%s' "$MOCK_PROCESS_BODY" "$MOCK_PROCESS_CODE"; }

probe_file=$(mktemp)
printf '{"a":"b"}\n' > "$probe_file"

output=$(start_processing "$probe_file" "locales/en.json" "main" 2>&1)
rc=$?
assert_eq "rejected 200 returns non-zero" "$rc" "1"
assert_contains "rejected 200 does not claim success" "$output" "Failed to start file processing"

MOCK_PROCESS_CODE="422"
output=$(start_processing "$probe_file" "locales/en.json" "main" 2>&1)
rc=$?
assert_eq "rejected 422 returns non-zero" "$rc" "1"
assert_contains "rejected 422 reports the reason" "$output" "Unprocessable Entity"

MOCK_PROCESS_CODE="200"
MOCK_PROCESS_BODY='{"source_file":{"id":1}}'
output=$(start_processing "$probe_file" "locales/en.json" "main" 2>&1)
rc=$?
assert_eq "an accepted 200 still succeeds" "$rc" "0"
assert_contains "an accepted 200 reports success" "$output" "processing started successfully"

rm -f "$probe_file"

echo
echo "=========================================="
echo "Total:  $test_count"
echo -e "Passed: ${GREEN}${passed_count}${NC}"
echo -e "Failed: ${RED}${failed_count}${NC}"
echo "=========================================="

[[ "$failed_count" -eq 0 ]]
