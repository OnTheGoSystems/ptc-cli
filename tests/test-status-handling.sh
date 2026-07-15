#!/bin/bash

# Tests for translation-status handling and preflight.
#
# These source ptc-cli.sh and stub curl, so they exercise the real parsing and
# polling logic without touching the network. The important property under test
# is that a terminal state stops polling after a single request: regressions
# here are expensive but silent, showing up only as a multi-minute CI stall
# that reports itself as a timeout.

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

# --- curl stub -------------------------------------------------------------
# Counts calls through a file: curl runs inside $( ), so a variable would not
# survive back to the caller.
CALL_COUNT_FILE=""
MOCK_STATUS_CODE="200"
MOCK_STATUS_BODY=""
# When set, these answer the FIRST status call only - used to model a transient
# error that later recovers.
MOCK_STATUS_FIRST_CODE=""
MOCK_STATUS_FIRST_BODY=""
MOCK_BALANCE_CODE="200"
MOCK_BALANCE_BODY=""
MOCK_TRIAL_BALANCE="4200"
MOCK_PREPAID_BALANCE="0"

curl() {
    local header_file="" url=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -D) header_file="$2"; shift 2 ;;
            -X|-H|-w|-o|-F) shift 2 ;;
            -s|-i|-L) shift ;;
            *) url="$1"; shift ;;
        esac
    done

    local call_index=1
    if [[ -n "$CALL_COUNT_FILE" ]]; then
        printf 'x' >> "$CALL_COUNT_FILE"
        call_index=$(wc -c < "$CALL_COUNT_FILE" | tr -d ' ')
    fi

    if [[ -n "$header_file" ]]; then
        {
            printf 'HTTP/1.1 200 OK\r\n'
            printf 'Content-Type: application/json\r\n'
            printf 'X-PTC-TRIAL-BALANCE: %s\r\n' "$MOCK_TRIAL_BALANCE"
            printf 'X-PTC-PREPAID-BALANCE: %s\r\n' "$MOCK_PREPAID_BALANCE"
            printf '\r\n'
        } > "$header_file"
    fi

    case "$url" in
        *balance*)
            printf '%s%s' "$MOCK_BALANCE_BODY" "$MOCK_BALANCE_CODE"
            ;;
        *)
            if [[ -n "$MOCK_STATUS_FIRST_CODE" && "$call_index" -eq 1 ]]; then
                printf '%s%s' "$MOCK_STATUS_FIRST_BODY" "$MOCK_STATUS_FIRST_CODE"
            else
                printf '%s%s' "$MOCK_STATUS_BODY" "$MOCK_STATUS_CODE"
            fi
            ;;
    esac
}

# --- JSON helpers ----------------------------------------------------------
test_json_helpers() {
    echo "--- JSON parsing"
    assert_eq "compact status" \
        "$(json_string_field '{"status":"completed","completeness":100}' status)" "completed"
    # The server emits compact JSON today; pretty output must not break parsing.
    assert_eq "pretty-printed status" \
        "$(json_string_field '{
  "status" : "completed"
}' status)" "completed"
    assert_eq "whitespace around colon" \
        "$(json_string_field '{"status" :  "failed"}' status)" "failed"
    assert_eq "null status is empty" \
        "$(json_string_field '{"status":null}' status)" ""
    # The *string* "null" is a real status the code handles (get_status_char has
    # a "null" arm); it must not be confused with a JSON null.
    assert_eq "string \"null\" survives as text" \
        "$(json_string_field '{"status":"null"}' status)" "null"
    assert_eq "missing key is empty" \
        "$(json_string_field '{"completeness":0}' status)" ""
    assert_eq "escaped quote kept in value" \
        "$(json_string_field '{"msg":"fai\"led"}' msg)" 'fai\"led'
    assert_eq "number field" \
        "$(json_number_field '{"completeness":42.5}' completeness)" "42.5"
    assert_eq "bool field" \
        "$(json_bool_field '{"active":false}' active)" "false"
    # "iso" appears in both source_language and languages[]; the nested reader
    # must not pick up the first one it sees anywhere in the document.
    assert_eq "nested object isolates iso" \
        "$(json_string_field "$(json_object_field '{"source_language":{"id":1,"iso":"en"},"languages":[{"id":2,"iso":"de"}]}' source_language)" iso)" "en"
    # If PTC ever adds a nested member, the locale check must not silently no-op.
    assert_eq "object with one nested level still readable" \
        "$(json_string_field "$(json_object_field '{"source_language":{"id":1,"iso":"en","flag":{"url":"x"}},"languages":[{"iso":"de"}]}' source_language)" iso)" "en"
}

test_terminal_status_classification() {
    echo "--- terminal status classification"
    # These are the terminal entries of the server's STATUS_PRIORITY
    # (failed, out_of_credit, queued, in_progress, completed).
    for s in failed out_of_credit; do
        if is_terminal_failure_status "$s"; then pass "'$s' is terminal"; else fail "'$s' should be terminal"; fi
    done
    for s in completed queued in_progress pending draft ""; do
        if is_terminal_failure_status "$s"; then fail "'$s' should not be terminal"; else pass "'${s:-<empty>}' is not terminal"; fi
    done
}

# Both step-based monitoring loops route through this one classifier; it is the
# single place a new status has to be handled.
# rc: 0 download, 1 give up, 2 keep polling.
test_monitored_status_classifier() {
    echo "--- monitored status classifier"
    local rc out

    classify_monitored_status "completed" "f.json" >/dev/null 2>&1; rc=$?
    assert_eq "completed -> download" "$rc" "0"

    for s in failed out_of_credit; do
        classify_monitored_status "$s" "f.json" >/dev/null 2>&1; rc=$?
        assert_eq "$s -> give up" "$rc" "1"
    done

    for s in queued in_progress pending null status_unknown; do
        classify_monitored_status "$s" "f.json" >/dev/null 2>&1; rc=$?
        assert_eq "$s -> keep polling" "$rc" "2"
    done

    # A source file with no original attached reports "draft" and will never
    # translate. Kept pollable (the attachment may still be landing) but it must
    # be called out rather than passing for progress.
    rc=0; out=$(classify_monitored_status "draft" "f.json" 2>&1) || rc=$?
    if [[ "$rc" == "2" ]] && printf '%s' "$out" | grep -q "No uploaded file behind"; then
        pass "draft -> keep polling, but surfaced"
    else
        fail "draft (rc=$rc): $out"
    fi

    rc=0; out=$(classify_monitored_status "not_found" "f.json" 2>&1) || rc=$?
    if [[ "$rc" == "2" ]] && printf '%s' "$out" | grep -q "Status unavailable"; then
        pass "not_found -> keep polling, but surfaced"
    else
        fail "not_found (rc=$rc): $out"
    fi

    # Healthy progress must stay quiet, or every round prints noise.
    out=$(classify_monitored_status "in_progress" "f.json" 2>&1) || true
    if [[ -z "$out" ]]; then
        pass "in_progress logs nothing"
    else
        fail "in_progress should be silent: $out"
    fi
}

# --- polling ---------------------------------------------------------------
# rc: 0 completed, 1 error, 2 still pending, 3 terminal failure
assert_poll() {
    local desc="$1" body="$2" code="$3" want_rc="$4" want_calls="$5"

    CALL_COUNT_FILE="$(mktemp)"
    MOCK_STATUS_BODY="$body"
    MOCK_STATUS_CODE="$code"
    MOCK_STATUS_FIRST_CODE=""
    MOCK_STATUS_FIRST_BODY=""

    local rc=0
    monitor_translation_status "locales/en.json" "main" 4 0 >/dev/null 2>&1 || rc=$?
    local calls; calls=$(wc -c < "$CALL_COUNT_FILE" | tr -d ' ')
    rm -f "$CALL_COUNT_FILE"
    CALL_COUNT_FILE=""

    if [[ "$rc" == "$want_rc" && "$calls" == "$want_calls" ]]; then
        pass "$desc (rc=$rc, $calls request(s))"
    else
        fail "$desc (rc=$rc want $want_rc; $calls request(s) want $want_calls)"
    fi
}

test_polling_stops_on_terminal_states() {
    echo "--- polling stops on terminal states (max 4 attempts)"
    PTC_API_TOKEN="test-token"
    PTC_API_URL="https://example.invalid/api/v1/"
    PTC_VERBOSE=false

    # Bodies use the real wire format: fields nested under "translation_status"
    # (verified against production, which returns
    # {"translation_status":{"status":"completed","completeness":100.0}}).
    assert_poll "completed stops at once"       '{"translation_status":{"status":"completed","completeness":100.0}}' 200 0 1
    assert_poll "failed stops at once"          '{"translation_status":{"status":"failed","completeness":0}}'        200 3 1
    assert_poll "out_of_credit stops at once"   '{"translation_status":{"status":"out_of_credit","completeness":0}}' 200 3 1
    assert_poll "pretty completed stops at once" '{
  "translation_status" : {
    "status" : "completed",
    "completeness" : 100.0
  }
}'                                                                                                                   200 0 1
    assert_poll "in_progress keeps polling"     '{"translation_status":{"status":"in_progress","completeness":30.0}}' 200 2 4
    assert_poll "queued keeps polling"          '{"translation_status":{"status":"queued","completeness":0}}'         200 2 4
    assert_poll "null status keeps polling"     '{"translation_status":{"status":null,"completeness":100}}'           200 2 4
    # A flat body must still parse, so the client survives a wrapper rename.
    assert_poll "flat body still parses"        '{"status":"completed","completeness":100}'                           200 0 1
}

# The status endpoint can 404 briefly right after processing starts, before the
# translation record exists. That must not end the run: a hard failure here
# skips the download on a run that would otherwise have succeeded.
test_transient_errors_are_tolerated() {
    echo "--- transient status errors"
    PTC_API_TOKEN="test-token"
    PTC_API_URL="https://example.invalid/api/v1/"
    PTC_VERBOSE=false

    CALL_COUNT_FILE="$(mktemp)"
    MOCK_STATUS_FIRST_CODE="404"
    MOCK_STATUS_FIRST_BODY='{"error":"not yet"}'
    MOCK_STATUS_CODE="200"
    MOCK_STATUS_BODY='{"translation_status":{"status":"completed","completeness":100.0}}'

    local rc=0
    monitor_translation_status "locales/en.json" "main" 5 0 >/dev/null 2>&1 || rc=$?
    local calls; calls=$(wc -c < "$CALL_COUNT_FILE" | tr -d ' ')
    rm -f "$CALL_COUNT_FILE"; CALL_COUNT_FILE=""
    MOCK_STATUS_FIRST_CODE=""; MOCK_STATUS_FIRST_BODY=""

    if [[ "$rc" == "0" && "$calls" == "2" ]]; then
        pass "one 404 then completed recovers (rc=0 after $calls calls)"
    else
        fail "transient 404 should recover (rc=$rc want 0; $calls calls want 2)"
    fi

    # ...but a persistently broken endpoint must give up quickly rather than
    # polling to the attempt limit and reporting itself as a timeout.
    assert_poll "persistent 500 gives up after 3 tries" '{"error":"boom"}' 500 1 3
    assert_poll "persistent 404 gives up after 3 tries" '{"error":"nope"}' 404 1 3
}

# Regression guard: check_translation_status gained return code 3, and every
# caller must account for it. A caller that silently ignores 3 drops the file
# from all result lists and the run reports success for it.
test_all_check_status_callers_handle_terminal() {
    echo "--- terminal code reaches every caller"
    PTC_API_TOKEN="test-token"
    PTC_API_URL="https://example.invalid/api/v1/"
    PTC_VERBOSE=false
    PTC_DRY_RUN=false
    MOCK_STATUS_CODE="200"
    MOCK_STATUS_BODY='{"translation_status":{"status":"out_of_credit","completeness":0}}'

    local base="$TEST_DIR/fixtures-terminal"
    mkdir -p "$base"
    echo '{"a":"b"}' > "$base/en.json"

    local out
    out=$(perform_download_action "$base/en.json" 2>&1) || true
    if printf '%s' "$out" | grep -q "Translation failed and will not complete"; then
        pass "perform_download_action reports a terminal file"
    else
        fail "perform_download_action stayed silent on a terminal file: $out"
    fi
    if printf '%s' "$out" | grep -q "Failed to download 1 file"; then
        pass "perform_download_action counts it as failed"
    else
        fail "perform_download_action did not count the terminal file as failed: $out"
    fi

    out=$(perform_status_action "$base/en.json" 2>&1) || true
    if printf '%s' "$out" | grep -q "Translation failed and will not complete"; then
        pass "perform_status_action reports a terminal file"
    else
        fail "perform_status_action stayed silent on a terminal file: $out"
    fi

    rm -rf "$base"
}

# --- preflight -------------------------------------------------------------
test_preflight() {
    echo "--- preflight"
    PTC_API_TOKEN="test-token"
    PTC_API_URL="https://example.invalid/api/v1/"
    PTC_SOURCE_LOCALE="en"
    PTC_VERBOSE=false
    MOCK_STATUS_CODE="200"
    MOCK_STATUS_BODY='{"source_language":{"id":1,"iso":"en","name":"English"},"languages":[{"id":2,"iso":"de","name":"German"}]}'
    MOCK_BALANCE_CODE="200"
    MOCK_BALANCE_BODY='{"plan":"trial","active":true,"trial_wallet":{"words_count":4200},"ate_wallet":{"words_count":0}}'

    local out rc

    out=$(preflight_check 2>&1); rc=$?
    if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "Preflight OK: source=en, plan=trial, balance=4200 trial words"; then
        pass "healthy account reports one OK line"
    else
        fail "healthy account (rc=$rc): $out"
    fi

    # Shape taken from a real production response: an unlimited subscription
    # reports plan=pro, status=unlimited, active=true and 0 in BOTH wallets
    # because it never draws on them. Warning about that zero would cry wolf on
    # every run of a healthy account.
    MOCK_BALANCE_BODY='{"plan":"pro","status":"unlimited","active":true,"seats":99,"trial_wallet":{"words_count":0},"ate_wallet":{"words_count":0}}'
    MOCK_TRIAL_BALANCE="0"; MOCK_PREPAID_BALANCE="0"
    out=$(preflight_check 2>&1); rc=$?
    if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "balance=unlimited" \
        && ! printf '%s' "$out" | grep -q "balance is 0"; then
        pass "unlimited plan reports unlimited, no zero-balance warning"
    else
        fail "unlimited plan (rc=$rc): $out"
    fi
    MOCK_TRIAL_BALANCE="4200"; MOCK_PREPAID_BALANCE="0"
    MOCK_BALANCE_BODY='{"plan":"trial","active":true,"trial_wallet":{"words_count":4200},"ate_wallet":{"words_count":0}}'

    local saved_token="$PTC_API_TOKEN"
    PTC_API_TOKEN=""
    out=$(preflight_check 2>&1); rc=$?
    if [[ $rc -eq 1 ]] && printf '%s' "$out" | grep -q "no API token"; then
        pass "missing token aborts"
    else
        fail "missing token (rc=$rc): $out"
    fi
    PTC_API_TOKEN="$saved_token"

    MOCK_STATUS_CODE="401"; MOCK_STATUS_BODY=""
    out=$(preflight_check 2>&1); rc=$?
    if [[ $rc -eq 1 ]] && printf '%s' "$out" | grep -q "rejected the API token"; then
        pass "rejected token aborts with a specific message"
    else
        fail "rejected token (rc=$rc): $out"
    fi

    # Preflight is a new network call on a path that had none; a transient 5xx
    # must not fail a run that would otherwise have worked.
    MOCK_STATUS_CODE="503"; MOCK_STATUS_BODY='{"error":"upstream"}'
    out=$(preflight_check 2>&1); rc=$?
    if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "could not reach the PTC API"; then
        pass "unreachable API warns but continues"
    else
        fail "unreachable API should not abort (rc=$rc): $out"
    fi

    MOCK_STATUS_CODE="200"
    MOCK_STATUS_BODY='{"source_language":{"id":1,"iso":"de","name":"German"},"languages":[{"id":2,"iso":"fr","name":"French"}]}'
    out=$(preflight_check 2>&1); rc=$?
    if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "Source locale mismatch"; then
        pass "source locale mismatch warns but continues"
    else
        fail "locale mismatch (rc=$rc): $out"
    fi

    MOCK_STATUS_BODY='{"source_language":{"id":1,"iso":"en","name":"English"},"languages":[]}'
    MOCK_BALANCE_BODY='{"plan":"pro","active":false}'
    out=$(preflight_check 2>&1); rc=$?
    if [[ $rc -eq 1 ]] && printf '%s' "$out" | grep -q "not active"; then
        pass "inactive subscription aborts"
    else
        fail "inactive subscription (rc=$rc): $out"
    fi

    # A broken /balance must not invent a wallet or a scary zero-balance warning.
    MOCK_BALANCE_CODE="500"; MOCK_BALANCE_BODY='{"error":"stripe exploded"}'
    out=$(preflight_check 2>&1); rc=$?
    if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "4200 trial / 0 prepaid words" \
        && ! printf '%s' "$out" | grep -q "balance is 0"; then
        pass "unknown plan reports both wallets, no false warning"
    else
        fail "unknown plan (rc=$rc): $out"
    fi
}

main() {
    echo "PTC CLI - status handling tests"
    echo

    test_json_helpers
    test_terminal_status_classification
    test_monitored_status_classifier
    test_polling_stops_on_terminal_states
    test_transient_errors_are_tolerated
    test_all_check_status_callers_handle_terminal
    test_preflight

    echo
    echo "Test results:"
    echo "============="
    echo "Total tests: $test_count"
    echo -e "Passed: ${GREEN}$passed_count${NC}"
    echo -e "Failed: ${RED}$failed_count${NC}"

    if [[ $failed_count -eq 0 ]]; then
        echo -e "${GREEN}All tests passed successfully!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
