#!/bin/bash
# L15 (Eran 2026-10-08; AGD-2 "Wizard handover") against the mock: a project begun in the PTC wizard is handed to the agent
# by its id. `ptc guide --help` carries the one handover line (the same text as the agent token page and the guide_next
# description); `ptc guide start --project-id ID` in a plain directory opens the guide on THAT project (POST guide/sessions
# with its project_id), never POST /projects, and records the project in .ptc/session.json.
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

PORT=19795
python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && { echo "port $PORT busy"; exit 1; }
PTC_MOCK_PORT=$PORT PTC_MOCK_BODY_DIR="$BODIES" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
API="http://127.0.0.1:$PORT/api/v1/"
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN)
body() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print($1)" "$BODIES/$2.json" 2>/dev/null; }

LINE='A project begun in the PTC wizard continues with your agent by its id: `ptc guide start --project-id ID` (MCP: guide_next with project_id); PTC serves that project, never a second one.'

echo "=== the handover line in ptc guide --help ==="
"$CLI" guide --help >"$WORK/help.out" 2>&1
grep -qF -- "$LINE" "$WORK/help.out" && pass "guide --help carries the handover line" || fail "help: $(head -5 "$WORK/help.out")"

echo "=== start --project-id opens the guide on that project ==="
P="$WORK/plain"; mkdir -p "$P"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide start --project-id 4242 --api-url "$API" -d "$P" >"$WORK/start.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "start --project-id: exit 0" || fail "start exit $rc: $(cat "$WORK/start.out")"
[[ "$(body "d.get('project_id')" guide_sessions)" == "4242" ]] && pass "POST guide/sessions carries project_id 4242" || fail "sessions body: $(body "d" guide_sessions)"
[[ ! -f "$BODIES/projects.json" ]] && pass "no POST /projects: no project is created" || fail "projects called: $(body "d" projects)"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["project_id"])' "$P/.ptc/session.json" 2>/dev/null)" == "4242" ]] \
    && pass "session.json names project 4242" || fail "session.json: $(cat "$P/.ptc/session.json" 2>/dev/null)"

echo "=== cli and action copies ==="
cmp -s "$CLI" "$(dirname "$(dirname "$TEST_DIR")")/action/ptc-cli.sh" && pass "cli/ptc-cli.sh and action/ptc-cli.sh are byte-identical" || fail "the two copies differ"

echo ""
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
