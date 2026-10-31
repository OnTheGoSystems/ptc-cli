#!/bin/bash
# #7346 (Codex staging walk LIVE-TB run 2, T7; POL-1) against the mock: with every free automatic delivery of the trial
# used and no push window of the project open (X-PTC-TRIAL-API-RUNS-REMAINING: 0, X-PTC-TRIAL-API-RUN-OPEN: false),
# PTC refuses the sync's push (HTTP 402) and delivers nothing. `ptc sync`'s preflight says so in one line and exits
# non-zero BEFORE any upload. An open window (the rest of an admitted push) or a delivery left runs as before.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {  # start_mock NAME PORT [ENV=VALUE...] -> API_<NAME>, the mock's journal in $WORK/journal-NAME.log
    local name="$1" port="$2" i; shift 2
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && { echo "port $port busy"; exit 1; }
    env "$@" PTC_MOCK_PORT="$port" PTC_MOCK_LOG="$WORK/journal-$name.log" python3 "$MOCK" >>"$WORK/mock-$name.log" 2>&1 &
    PIDS+=("$!")
    for i in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
    printf -v "API_$name" 'http://127.0.0.1:%s/api/v1/' "$port"
}
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_API_TOKEN)

start_mock SPENT 20211 PTC_MOCK_TRIAL_RUNS_REMAINING=0 PTC_MOCK_TRIAL_RUN_OPEN=false
start_mock OPEN 20221 PTC_MOCK_TRIAL_RUNS_REMAINING=0 PTC_MOCK_TRIAL_RUN_OPEN=true
start_mock LEFT 20231 PTC_MOCK_TRIAL_RUNS_REMAINING=1

T="$WORK/tree"; mkdir -p "$T/locales"
printf '{"greeting": "Hello"}\n' > "$T/locales/en.json"
cat > "$T/.ptc-config.yml" <<'YML'
source_locale: en
monitor_interval: 1
files:
  - file: locales/en.json
    output: locales/{{lang}}.json
YML

uploads() { grep -cE "^     (upload|process) " "$WORK/journal-$1.log" 2>/dev/null; }

echo "=== the free automatic deliveries are used up and no window is open: the preflight stops ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_SPENT" -d "$T" >"$WORK/spent.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && pass "the sync exits non-zero (rc $rc)" || fail "the sync exited 0: $(tail -5 "$WORK/spent.out")"
n=$(uploads SPENT)
[[ "${n:-0}" -eq 0 ]] && pass "nothing was uploaded: the stop is before any upload" || fail "$n upload/process calls: $(cat "$WORK/journal-SPENT.log")"
lines=$(grep -c "free automatic deliveries are used up" "$WORK/spent.out")
[[ $lines -eq 1 ]] && pass "one line names the used-up allowance" || fail "$lines lines name it: $(cat "$WORK/spent.out")"
grep -F "free automatic deliveries are used up" "$WORK/spent.out" | grep -qi "upgrade" \
    && pass "the line says what can happen (upgrade)" || fail "no upgrade in: $(grep -F "free automatic" "$WORK/spent.out")"
[[ ! -f "$T/locales/de.json" ]] && pass "no translation was written" || fail "a translation was written"

echo "=== at 0 left with this project's push window open: the sync runs (the window admits the rest of the push) ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_OPEN" -d "$T" >"$WORK/open.out" 2>&1; rc=$?
n=$(uploads OPEN)
[[ "${n:-0}" -gt 0 ]] && pass "the open window's sync uploads ($n calls, rc $rc)" || fail "no upload with the window open: $(tail -5 "$WORK/open.out")"
! grep -q "free automatic deliveries are used up" "$WORK/open.out" && pass "and says nothing about the allowance" || fail "allowance line with the window open"

echo "=== a delivery left: the sync runs ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_LEFT" -d "$T" >"$WORK/left.out" 2>&1; rc=$?
n=$(uploads LEFT)
[[ "${n:-0}" -gt 0 ]] && pass "a sync with a delivery left uploads ($n calls, rc $rc)" || fail "no upload with a delivery left: $(tail -5 "$WORK/left.out")"

echo
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
