#!/bin/bash
# L13 (staging LW, 2026-10-08) against the mock:
#  SF-36 the done message PTC sends (on the API channel it names `ptc sync`) is printed on `guide next` and after the
#        submit/skip that closed the last task, never replaced by a fixed sentence.
#  SF-37 `ptc guide start` in a directory whose config names a session rejoins it: POST /projects carries the config's
#        session_id/project_id, no organization question, no new project; session.json follows the config, and a
#        --project-id naming another project is refused. A stale session.json never wins over the config.
#  SF-38 where the human answers follows `answer_via`: the chat alone, or the chat and the guide page.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); BODIES="$WORK/bodies"; mkdir -p "$BODIES"
MOCK_PID=""
cleanup() { [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "${WORK:?}"; }
trap cleanup EXIT

PORT=19793
python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && { echo "port $PORT busy"; exit 1; }
PTC_MOCK_PORT=$PORT PTC_MOCK_BODY_DIR="$BODIES" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
API="http://127.0.0.1:$PORT/api/v1/"
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN)
body() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print($1)" "$BODIES/$2.json" 2>/dev/null; }
clear_bodies() { find "${BODIES:?}" -name '*.json' -delete; }

echo "=== SF-36: the done message is printed ==="
P="$WORK/plain"; mkdir -p "$P"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_done_api --api-url "$API" -d "$P" >"$WORK/done.out" 2>&1
grep -q 'run `ptc sync` in the project directory' "$WORK/done.out" && pass "guide next prints PTC's done message" || fail "next done: $(cat "$WORK/done.out")"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide skip gt_last --reason "answered early" --session-id gs_x --api-url "$API" -d "$P" >"$WORK/skip.out" 2>&1
grep -q 'run `ptc sync` in the project directory' "$WORK/skip.out" && pass "the skip that closed setup prints the done message" || fail "skip: $(cat "$WORK/skip.out")"

echo "=== SF-38: where the human answers ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_chat_only --api-url "$API" -d "$P" >"$WORK/chat.out" 2>&1
grep -q "answers here in the chat (relay their reply)" "$WORK/chat.out" && ! grep -q "guide page" "$WORK/chat.out" \
    && pass "answer_via [chat]: the chat alone, no guide page" || fail "chat only: $(cat "$WORK/chat.out")"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_page_too --api-url "$API" -d "$P" >"$WORK/page.out" 2>&1
grep -q "or on the guide page in PTC" "$WORK/page.out" && pass "answer_via [chat, app]: the guide page too" || fail "page: $(cat "$WORK/page.out")"

echo "=== SF-37: start rejoins the config's session ==="
R="$WORK/rejoin"; mkdir -p "$R/.ptc"
cat > "$R/.ptc-config.yml" <<'YML'
source_locale: en
languages: [de, es]
files:
  - file: en.yml
    output: '{{lang}}.yml'
guide:
  session_id: 9
  project_id: 3526
YML
clear_bodies
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide start --repo-url https://example.test/multi-org.git --branch main --api-url "$API" -d "$R" >"$WORK/rejoin.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "no --organization-id, token in several organizations: exit 0" || fail "start exit $rc: $(cat "$WORK/rejoin.out")"
[[ "$(body "d.get('session_id')" projects)" == "9" && "$(body "d.get('project_id')" projects)" == "3526" ]] \
    && pass "POST /projects carries the config's session_id and project_id" || fail "projects body: $(body "d" projects)"
grep -q "Rejoined PTC project 3526" "$WORK/rejoin.out" && ! grep -q "Created PTC project\|which organization" "$WORK/rejoin.out" \
    && pass "rejoined: no new project, no organization question" || fail "rejoin: $(cat "$WORK/rejoin.out")"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["project_id"])' "$R/.ptc/session.json")" == "3526" ]] \
    && pass "session.json names the config's project" || fail "session.json: $(cat "$R/.ptc/session.json")"
clear_bodies
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide start --project-id 3527 --api-url "$API" -d "$R" >"$WORK/split.out" 2>&1
rc=$?
[[ $rc -ne 0 && ! -f "$BODIES/guide_sessions.json" ]] && grep -q "names PTC project 3526" "$WORK/split.out" \
    && pass "--project-id naming another project is refused before any session is opened" || fail "split rc=$rc: $(cat "$WORK/split.out")"
printf '{"session_id": 10, "project_id": "3527"}' > "$R/.ptc/session.json"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --api-url "$API" -d "$R" >"$WORK/stale.out" 2>&1
grep -q "Task gt_s9 " "$WORK/stale.out" && pass "a stale session.json (another project) never wins: guide next follows the config's session 9" \
    || fail "stale: $(cat "$WORK/stale.out")"

echo ""
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
