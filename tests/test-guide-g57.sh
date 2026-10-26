#!/bin/bash
# GAP-G57 (WPML lab run 11, session 75, gt_1031): the agent cut PTC's accepted readiness_audit verdict at 8,000 characters,
# could not resubmit, and `guide status` did not repeat the reasons. Every verdict the CLI receives is written in full to
# .ptc/work/s<session>/verdict-<task id>.json before it is printed, the output names that file, and `guide status TASK_ID`
# prints PTC's stored verdict on the task with every reason. A task never answered: no verdict, no file.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
jcheck() {  # jcheck desc file expr
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($3) else 1)" "$2" 2>/dev/null; then pass "$1"; else fail "$1"; fi
}
WORK=$(mktemp -d)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "${WORK:?}"; }
trap cleanup EXIT

port=19957
python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && { echo "port $port busy"; exit 1; }
mkdir -p "$WORK/bodies"
PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$WORK/bodies" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
PIDS+=("$!")
for i in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
API="http://127.0.0.1:$port/api/v1/"
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_API_TOKEN)
P="$WORK/proj"; mkdir -p "$P/.ptc"; echo '{"session_id": "gs_mock", "project_id": "7"}' > "$P/.ptc/session.json"
g() { "${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide "$@" --api-url "$API" -d "$P"; }
FILE="$P/.ptc/work/sgs_mock/verdict-gt_long.json"
REL=".ptc/work/sgs_mock/verdict-gt_long.json"

echo "=== submit answered with a long verdict: written in full before it is printed ==="
echo '{"findings": []}' | g submit gt_long >"$WORK/submit.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "accepted -> exit 0" || fail "exit $rc: $(head -c 400 "$WORK/submit.out")"
[[ -f "$FILE" ]] && pass "the verdict file exists at $REL" || fail "no verdict file: $(find "$P/.ptc" -type f)"
jcheck "the file holds the whole answer: the verdict and all 40 reasons" "$FILE" "d['verdict'] == 'accepted' and d['task_id'] == 'gt_long' and len(d['reasons']) == 40 and sum(len(r) for r in d['reasons']) > 8000"
head -n 1 "$WORK/submit.out" | grep -qF "$REL" && pass "the output names the file on its first line" || fail "first line: $(head -n 1 "$WORK/submit.out")"
echo '{"findings": []}' | g submit gt_long --json >"$WORK/submit.json" 2>"$WORK/submit.err"
jcheck "--json keeps stdout PTC's answer as it came" "$WORK/submit.json" "len(d['reasons']) == 40"
grep -qF "$REL" "$WORK/submit.err" && pass "--json names the file on stderr" || fail "--json stderr: $(cat "$WORK/submit.err")"

echo "=== guide status TASK_ID: PTC's stored verdict, every reason ==="
rm -f "$FILE"
g status gt_long >"$WORK/status.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "status gt_long -> exit 0" || fail "status exit $rc: $(head -c 400 "$WORK/status.out")"
grep -qF "PTC's verdict on task gt_long [readiness_audit]: accepted (task accepted)" "$WORK/status.out" && pass "status prints the stored verdict" || fail "status: $(head -c 600 "$WORK/status.out")"
[[ $(grep -c '^  - finding ' "$WORK/status.out") -eq 40 ]] && pass "status prints all 40 reasons" || fail "reasons printed: $(grep -c '^  - finding ' "$WORK/status.out")"
jcheck "status writes the stored verdict to the same file" "$FILE" "d['verdict'] == 'accepted' and len(d['reasons']) == 40"

echo "=== a task never answered: no verdict, no file ==="
g status gt_pending >"$WORK/pending.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "status gt_pending -> exit 0" || fail "exit $rc"
grep -qF "Task gt_pending [readiness_audit] (pending): no verdict yet" "$WORK/pending.out" && pass "status says there is no verdict yet" || fail "pending: $(cat "$WORK/pending.out")"
[[ ! -e "$P/.ptc/work/sgs_mock/verdict-gt_pending.json" ]] && pass "no file for a task without a verdict" || fail "a file was written for a pending task"
g status >"$WORK/plain.out" 2>&1
grep -q "verdict on task\|in full" "$WORK/plain.out" && fail "status without TASK_ID changed: $(cat "$WORK/plain.out")" || pass "status without TASK_ID is unchanged"

echo
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
