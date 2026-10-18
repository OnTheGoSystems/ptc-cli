#!/bin/bash
# GAP-F3 (WPML lab, G7 worker run 4; CLI-19): `ptc guide wait` that reaches its --timeout while the task's stored verdict
# is needs_more asks PTC once more and prints that verdict (its reasons capped like the server caps them: 20 + "and N
# more") instead of only "no verdict yet"; the exit code stays 3.
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

start_mock MAIN 19981
P="$WORK/plain"; mkdir -p "$P"
gw() { "${NOCI[@]}" PTC_GUIDE_WAIT_CAP=1 PTC_ORG_TOKEN=org-token "$CLI" guide wait "$@" --session-id gs_x --api-url "$API_MAIN" -d "$P"; }

echo "=== a timed-out wait prints the stored needs_more verdict ==="
gw gt_notproved --timeout 2 >"$WORK/np.out" 2>&1; rc=$?
[[ $rc -eq 3 ]] && pass "a timed-out wait keeps exit 3" || fail "exit $rc"
grep -qF "Still waiting after 2s" "$WORK/np.out" && pass "it says it timed out" || fail "no timeout line: $(cat "$WORK/np.out")"
grep -qF "PTC's stored verdict on task gt_notproved: needs_more" "$WORK/np.out" && pass "it prints the stored verdict" \
    || fail "no stored verdict: $(cat "$WORK/np.out")"
grep -qF "  - src/p01.php was not reported by the CI run for abcdef012345" "$WORK/np.out" \
    && grep -qF "  - src/p20.php was not reported" "$WORK/np.out" && pass "it prints the reasons" || fail "no reasons: $(cat "$WORK/np.out")"
! grep -qF "src/p21.php" "$WORK/np.out" && grep -qF "  - and 3 more reasons (23 in all)" "$WORK/np.out" \
    && pass "the reasons are capped at 20 + 'and N more'" || fail "no cap: $(grep -c '^  - ' "$WORK/np.out") reason lines"
grep -qF "no verdict for gt_notproved" "$WORK/np.out" && fail "still says 'no verdict' beside a stored verdict" || pass "no 'no verdict' line beside a stored verdict"
grep -qF "PTC: Nothing changed yet (CI may still be running)" "$WORK/np.out" && pass "it prints PTC's hint" || fail "no hint: $(cat "$WORK/np.out")"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d["body"]["timeout_s"]==0 else 1)' "$WORK/bodies-MAIN/guide_wait.json" \
    && pass "the last call asks PTC once more without waiting (timeout_s 0)" || fail "last body: $(cat "$WORK/bodies-MAIN/guide_wait.json")"

echo "=== a list PTC already capped is printed whole ==="
gw gt_capped --timeout 1 >"$WORK/cap.out" 2>&1; rc=$?
[[ $rc -eq 3 ]] && pass "exit 3" || fail "exit $rc"
grep -qF "  - and 3 more verified paths (23 in all) are not proved by this run" "$WORK/cap.out" && ! grep -qF "and 1 more reasons" "$WORK/cap.out" \
    && pass "PTC's own 'and N more' line is kept, not re-capped" || fail "re-capped: $(tail -5 "$WORK/cap.out")"

echo "=== no stored verdict: the old line ==="
gw gt_never --timeout 1 >"$WORK/never.out" 2>&1; rc=$?
[[ $rc -eq 3 ]] && grep -qF "PTC has no verdict for gt_never yet" "$WORK/never.out" && ! grep -qF "stored verdict" "$WORK/never.out" \
    && pass "a task with no verdict keeps 'no verdict yet'" || fail "rc $rc: $(cat "$WORK/never.out")"

echo "=== --json: the refreshed answer ==="
gw gt_notproved --timeout 1 --json >"$WORK/np.json" 2>/dev/null; rc=$?
[[ $rc -eq 3 ]] && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d["verdict"]=="needs_more" and len(d["reasons"])==23 else 1)' "$WORK/np.json" \
    && pass "--json prints PTC's stored verdict as it came" || fail "rc $rc: $(head -c 300 "$WORK/np.json")"

echo
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
