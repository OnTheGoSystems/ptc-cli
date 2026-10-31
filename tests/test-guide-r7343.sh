#!/bin/bash
# Org row #7343 (Codex staging walk LIVE-TB, 29 Oct 2026): MCP guide_next opened the session server-side, so the checkout
# had no .ptc/session.json, no guide: block and no git remote (a local project: no repo-URL lookup). `guide next` then
# answered "No guide session" although the agent could name the project. A guide door given --project-id (or
# PTC_PROJECT_ID) with no session in any local source rejoins that project's session through PTC (POST guide/sessions,
# the `guide start --project-id` rejoin: PTC answers the project's existing session) and goes on; with no project named
# it still prints the #7224 no-session message.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
has() { grep -qF -- "$3" "$2" && pass "$1" || fail "$1: no '$3' in: $(tail -6 "$2")"; }
lacks() { grep -qF -- "$3" "$2" && fail "$1: '$3' in: $(tail -6 "$2")" || pass "$1"; }
refuse_busy_port() {
    local i
    for i in $(seq 1 20); do
        python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), 0.4).close()" 2>/dev/null || return 0
        sleep 0.25
    done
    echo "port $1 already in use: a stale mock_ptc_api.py? (pgrep -af mock_ptc_api.py)" >&2; exit 1
}

WORK=$(mktemp -d)
BODIES="$WORK/bodies"; mkdir -p "$BODIES"
MOCK_PID=""; PORT=""
cleanup() {
    [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }
    rm -rf "${WORK:?}"
}
trap cleanup EXIT
for port in 19731 19733 19735; do
    refuse_busy_port "$port"
    PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$BODIES" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
    pid=$!
    for i in $(seq 1 30); do
        if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
            MOCK_PID=$pid; PORT=$port; break 2
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.4
    done
    kill "$pid" 2>/dev/null
done
[[ -n "$PORT" ]] || { echo "mock did not come up"; cat "$WORK/mock.log"; exit 1; }
API="http://127.0.0.1:$PORT/api/v1/"
BASE=(env -u CI -u GITLAB_CI -u GITHUB_ACTIONS -u CI_COMMIT_SHA -u GITHUB_SHA -u PTC_PROJECT_ID -u PTC_GUIDE_PROJECT_ID
      -u PTC_GUIDE_SESSION_ID -u PTC_API_TOKEN -u PTC_AGENT_TOKEN -u PTC_ORG_TOKEN -u PTC_VERBOSE XDG_CONFIG_HOME="$WORK/xdg")

repo() {  # repo DIR: a local checkout, no remote (the walk's disable-comments copy)
    local d="$1"
    mkdir -p "$d/config/locales"; printf 'en:\n  hello: "Hello"\n' > "$d/config/locales/en.yml"
    git -C "$d" init -q -b main && git -C "$d" config user.email t@example.com && git -C "$d" config user.name t
    git -C "$d" add -A && git -C "$d" commit -qm init
}

echo "=== #7343: session opened over MCP, no local source, guide next --project-id rejoins it ==="
R="$WORK/mcp-local"; repo "$R"
(cd "$R" && "${BASE[@]}" PTC_API_TOKEN=tok "$CLI" guide next --project-id 3680 --api-url "$API") > "$WORK/n1.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "exit 0" || fail "exit $rc: $(tail -6 "$WORK/n1.out")"
lacks "no 'No guide session'" "$WORK/n1.out" "No guide session"
has "the task PTC hands out" "$WORK/n1.out" "gt_1"
python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; sys.exit(0 if str(d.get('project_id')) == '3680' else 1)" \
    "$BODIES/guide_sessions.json" 2>/dev/null && pass "the rejoin names project 3680 (POST guide/sessions)" \
    || fail "no POST guide/sessions for project 3680"
grep -q "gs_mock" "$R/.ptc/session.json" 2>/dev/null && pass "the cache learns the rejoined session" \
    || fail "the cache does not hold the rejoined session: $(cat "$R/.ptc/session.json" 2>/dev/null)"

echo "=== #7343: the same through PTC_PROJECT_ID ==="
R="$WORK/mcp-local-env"; repo "$R"; rm -f "${BODIES:?}/guide_sessions.json"
(cd "$R" && "${BASE[@]}" PTC_API_TOKEN=tok PTC_PROJECT_ID=3680 "$CLI" guide next --api-url "$API") > "$WORK/n2.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "exit 0" || fail "exit $rc: $(tail -6 "$WORK/n2.out")"
lacks "no 'No guide session'" "$WORK/n2.out" "No guide session"

echo "=== #7343: no project named anywhere: still the #7224 message, no POST ==="
R="$WORK/nothing"; repo "$R"; rm -f "${BODIES:?}/guide_sessions.json"
(cd "$R" && "${BASE[@]}" PTC_API_TOKEN=tok "$CLI" guide next --api-url "$API") > "$WORK/n3.out" 2>&1; rc=$?
[[ $rc -eq 1 ]] && pass "exit 1" || fail "exit $rc"
has "the header" "$WORK/n3.out" "No guide session."
[[ ! -f "$BODIES/guide_sessions.json" ]] && pass "no session opened without a named project" || fail "a POST guide/sessions ran"

echo
echo "passed: $passed, failed: $failed"
[[ $failed -eq 0 ]]
