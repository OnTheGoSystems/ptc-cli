#!/bin/bash

# Tests for the 429 handling.
#
# create + process + bulk share one bucket of 10 requests per minute, and a run
# spends two of them per file. Every project past five files therefore meets a
# 429 partway through, and before this the CLI reported it as a failed upload
# and moved on: the run ended green-ish, with some files registered, some not,
# and "HTTP 429" as the only clue in the log.
#
# The regressions guarded here: not retrying at all, retrying forever, treating
# a non-429 failure as retryable, and losing the reason text on the {"error"}
# response shape that source_files#create and #process actually use.

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI_UNDER_TEST="$(dirname "$TEST_DIR")/ptc-cli.sh"

# shellcheck disable=SC1090
source "$CLI_UNDER_TEST"   # main() is guarded by a BASH_SOURCE check

set +e

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

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc (got '$haystack', wanted it to contain '$needle')"
    fi
}

# Never actually wait: record what the retry asked for instead. A test that
# sleeps for real would take minutes and would be the first thing anyone skips.
SLEPT=()
sleep() { SLEPT+=("$1"); }

header_file_with() {
    local file
    file=$(mktemp "${TMPDIR:-/tmp}/ptc-test-headers.XXXXXX")
    printf '%s\n' "$@" > "$file"
    printf '%s' "$file"
}

echo "=== rate_limit_delay: backoff when the server sends no Retry-After ==="

assert_eq "attempt 1 waits the base delay"      "$(rate_limit_delay 1)" "15"
assert_eq "attempt 2 doubles it"                "$(rate_limit_delay 2)" "30"
assert_eq "attempt 3 keeps climbing"            "$(rate_limit_delay 3)" "45"
assert_eq "attempt 4 reaches the window length" "$(rate_limit_delay 4)" "60"
assert_eq "attempt 9 is capped at the window"   "$(rate_limit_delay 9)" "60"

echo
echo "=== rate_limit_delay: honouring Retry-After ==="

hf=$(header_file_with 'HTTP/1.1 429 Too Many Requests' 'Retry-After: 7')
assert_eq "a Retry-After header wins over the backoff" "$(rate_limit_delay 3 "$hf")" "7"
rm -f "$hf"

hf=$(header_file_with 'HTTP/1.1 429 Too Many Requests' 'retry-after: 12')
assert_eq "the header name is matched case-insensitively" "$(rate_limit_delay 1 "$hf")" "12"
rm -f "$hf"

# Servers behind a proxy emit CRLF; a stray \r turns the value into a
# non-number and would silently drop us back to the backoff.
crlf=$(mktemp "${TMPDIR:-/tmp}/ptc-crlf.XXXXXX")
printf 'HTTP/1.1 429\r\nRetry-After: 9\r\n' > "$crlf"
assert_eq "CRLF line endings do not break the value" "$(rate_limit_delay 2 "$crlf")" "9"
rm -f "$crlf"

hf=$(header_file_with 'Retry-After: Wed, 21 Oct 2026 07:28:00 GMT')
assert_eq "an HTTP-date Retry-After falls back to the backoff" "$(rate_limit_delay 2 "$hf")" "30"
rm -f "$hf"

hf=$(header_file_with 'Retry-After: 0')
assert_eq "a zero Retry-After falls back to the backoff" "$(rate_limit_delay 1 "$hf")" "15"
rm -f "$hf"

hf=$(header_file_with 'Retry-After: 99999')
assert_eq "an absurd Retry-After is capped, not obeyed" "$(rate_limit_delay 1 "$hf")" "300"
rm -f "$hf"

assert_eq "a missing header file is not an error" "$(rate_limit_delay 2 /nonexistent/headers)" "30"

echo
echo "=== call_with_rate_limit_retry ==="

CALLS=0
succeeds_immediately() { CALLS=$((CALLS + 1)); return 0; }
call_with_rate_limit_retry succeeds_immediately
assert_eq "a request that works is called once" "$CALLS" "1"
assert_eq "and nothing was waited on" "${#SLEPT[@]}" "0"

CALLS=0
SLEPT=()
rate_limited_twice() {
    CALLS=$((CALLS + 1))
    (( CALLS <= 2 )) && return "$PTC_RATE_LIMITED"
    return 0
}
call_with_rate_limit_retry rate_limited_twice
rc=$?
assert_eq "a 429 twice then success exits 0" "$rc" "0"
assert_eq "which took three calls" "$CALLS" "3"
assert_eq "and waited twice" "${#SLEPT[@]}" "2"
assert_eq "with a growing delay" "${SLEPT[0]}-${SLEPT[1]}" "15-30"

CALLS=0
SLEPT=()
always_rate_limited() { CALLS=$((CALLS + 1)); return "$PTC_RATE_LIMITED"; }
call_with_rate_limit_retry always_rate_limited >/dev/null 2>&1
rc=$?
assert_eq "a permanent 429 eventually gives up with 1" "$rc" "1"
assert_eq "after the configured number of retries" "$CALLS" "$((PTC_RATE_LIMIT_MAX_RETRIES + 1))"
assert_eq "never returning the internal signal to the shell" "$([[ $rc -ne $PTC_RATE_LIMITED ]] && echo ok)" "ok"

CALLS=0
SLEPT=()
fails_for_another_reason() { CALLS=$((CALLS + 1)); return 3; }
call_with_rate_limit_retry fails_for_another_reason
rc=$?
assert_eq "a non-429 failure is passed straight through" "$rc" "3"
assert_eq "without retrying it" "$CALLS" "1"
assert_eq "and without waiting" "${#SLEPT[@]}" "0"

SLEPT=()
sees_header_dump() { [[ -n "${PTC_HEADER_DUMP:-}" ]] && return 0; return 3; }
call_with_rate_limit_retry sees_header_dump
assert_eq "the wrapper exposes a header dump to the request" "$?" "0"

echo
echo "=== describe_api_failure: the {\"error\"} shape ==="

assert_contains "a plain {\"error\"} body is reported" \
    "$(describe_api_failure 422 '{"error":"Failed to replace source file"}')" \
    "Failed to replace source file"

assert_contains "so is the {\"success\":false,\"error\"} variant" \
    "$(describe_api_failure 422 '{"success":false,"error":"Failed to create source file"}')" \
    "Failed to create source file"

assert_contains "the rate-limit body says why" \
    "$(describe_api_failure 429 '{"error":"Rate limit exceeded"}')" \
    "Rate limit exceeded"

assert_eq "the envelope shape still reads the same as before" \
    "$(describe_api_failure 422 '{"success":false,"message":"Unprocessable Entity","code":422,"errors":[9001]}')" \
    "HTTP 422: Unprocessable Entity (error codes: [9001])"

assert_contains "both keys present keeps both" \
    "$(describe_api_failure 402 '{"error":"TRIAL_EXPIRED","message":"Your trial has ended"}')" \
    "Your trial has ended"
assert_contains "including the machine-readable one" \
    "$(describe_api_failure 402 '{"error":"TRIAL_EXPIRED","message":"Your trial has ended"}')" \
    "TRIAL_EXPIRED"

assert_eq "an empty body still names the status" \
    "$(describe_api_failure 401 '')" \
    "HTTP 401"

echo
echo "=== make_ptc_api_call / start_processing signal a 429 rather than failing ==="

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ptc-rl.XXXXXX")
printf '{"hello":"world"}' > "$work_dir/en.json"
PTC_API_URL="https://example.invalid/api/v1/"
PTC_API_TOKEN="test-token"
PTC_VERBOSE="false"

ptc_curl() { printf '%s%s' '{"error":"Rate limit exceeded"}' '429'; }
make_ptc_api_call "$work_dir/en.json" "en.json" "{{lang}}.json" "main" "" >/dev/null 2>&1
assert_eq "an upload that hits 429 asks for a retry" "$?" "$PTC_RATE_LIMITED"

start_processing "$work_dir/en.json" "en.json" "main" >/dev/null 2>&1
assert_eq "so does starting processing" "$?" "$PTC_RATE_LIMITED"

ptc_curl() { printf '%s%s' '{"success":false,"error":"File format is invalid"}' '422'; }
make_ptc_api_call "$work_dir/en.json" "en.json" "{{lang}}.json" "main" "" >/dev/null 2>&1
assert_eq "a real rejection is still a plain failure" "$?" "1"

rm -rf "$work_dir"

echo
echo "=========================================="
echo "Total tests: $test_count"
echo -e "Passed: ${GREEN}${passed_count}${NC}"
echo -e "Failed: ${RED}${failed_count}${NC}"
[[ $failed_count -eq 0 ]] && echo -e "${GREEN}All tests passed successfully!${NC}"
exit $(( failed_count > 0 ? 1 : 0 ))
