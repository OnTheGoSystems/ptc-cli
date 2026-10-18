#!/bin/bash
# GAP-F5 (F4 follow-up; CLI-20): when PTC answers `guide wait` with no next task because it is still working in the
# background (the grouping, an induction), its `waiting` text is printed as one "PTC: ..." line; `guide status` prints the
# same line, and `guide next` keeps its own "PTC is waiting: ..." line, printed once.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "${WORK:?}"; }
trap cleanup EXIT

start_mock() {  # start_mock NAME PORT [ENV=VALUE...] -> API_<NAME>, the mock's journal in $WORK/mock-NAME.log
    local name="$1" port="$2" i; shift 2
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && { echo "port $port busy"; exit 1; }
    mkdir -p "$WORK/bodies-$name"
    env "$@" PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$WORK/bodies-$name" python3 "$MOCK" >>"$WORK/mock-$name.log" 2>&1 &
    PIDS+=("$!")
    for i in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
    printf -v "API_$name" 'http://127.0.0.1:%s/api/v1/' "$port"
}
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_API_TOKEN)

start_mock MAIN 19991
P="$WORK/plain"; mkdir -p "$P"
LINE="PTC: PTC is grouping the strings of 3 file(s) in the background (running since 14:02Z); the feature inventory is built after it. Run guide next again in a minute"

echo "=== guide wait: PTC's waiting text is one line ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide wait gt_grouping --session-id gs_x --timeout 5 --api-url "$API_MAIN" -d "$P" >"$WORK/wait.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "an accepted verdict keeps exit 0" || fail "exit $rc"
grep -qF "Verdict: accepted" "$WORK/wait.out" && pass "the verdict is printed" || fail "no verdict: $(cat "$WORK/wait.out")"
[[ $(grep -cxF "$LINE" "$WORK/wait.out") -eq 1 ]] && pass "the waiting text is printed once, as a 'PTC: ' line" || fail "waiting line: $(cat "$WORK/wait.out")"

echo "=== guide status: the same line ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide status --session-id gs_grouping --api-url "$API_MAIN" -d "$P" >"$WORK/status.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "status exit 0" || fail "status exit $rc"
[[ $(grep -cxF "$LINE" "$WORK/status.out") -eq 1 ]] && pass "status prints the waiting text once" || fail "status: $(cat "$WORK/status.out")"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide status --session-id gs_other --api-url "$API_MAIN" -d "$P" >"$WORK/status2.out" 2>&1
grep -q "^PTC: " "$WORK/status2.out" && fail "a status without waiting prints a PTC line: $(cat "$WORK/status2.out")" || pass "no waiting, no line"

echo "=== guide next: its own line, not doubled ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_waiting --api-url "$API_MAIN" -d "$P" >"$WORK/next.out" 2>&1
[[ $(grep -c "ptc guide action-run --project-id 7" "$WORK/next.out") -eq 1 ]] && pass "next prints PTC's waiting text once" || fail "next: $(cat "$WORK/next.out")"

echo
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
