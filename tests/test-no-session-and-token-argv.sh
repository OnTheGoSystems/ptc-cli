#!/bin/bash
# Org rows #7224 and #7225 (Eran, 27 Oct 2026). (a) With no session anywhere the guide door names every source it checked,
# one line each with its result (the config file, the session cache, PTC's lookup by the repository URL), then the one
# command that opens a session. (b) No CLI request puts the API token on a process argument list: a curl on PATH records
# its own argument list (ps -o args, what every user of the machine sees) and a sampler reads `ps -eo args` while the
# requests run; neither may hold the token, while the fake server still receives it as the bearer.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
has() { grep -qF -- "$3" "$2" && pass "$1" || fail "$1: no '$3' in: $(tail -6 "$2")"; }
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
MOCK_PID=""; PORT=""; SAMPLER=""
cleanup() {
    [[ -n "$SAMPLER" ]] && kill "$SAMPLER" 2>/dev/null
    [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }
    rm -rf "${WORK:?}"
}
trap cleanup EXIT
for port in 19541 19543 19545; do
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
repo() {  # repo DIR [ORIGIN]
    local d="$1"
    mkdir -p "$d/config/locales"; printf 'en:\n  hello: "Hello"\n' > "$d/config/locales/en.yml"
    git -C "$d" init -q -b main && git -C "$d" config user.email t@example.com && git -C "$d" config user.name t
    [[ -n "${2:-}" ]] && git -C "$d" remote add origin "$2"
    git -C "$d" add -A && git -C "$d" commit -qm init
}

echo "=== #7224: no config, no cache, no remote: every source is named ==="
R="$WORK/three-empty"; repo "$R"
(cd "$R" && "${BASE[@]}" PTC_API_TOKEN=tok "$CLI" guide next --api-url "$API") > "$WORK/e1.out" 2>&1; rc=$?
[[ $rc -eq 1 ]] && pass "exit 1" || fail "exit $rc"
has "the header" "$WORK/e1.out" "No guide session."
has "the config file line" "$WORK/e1.out" "Checked config file $R/.ptc-config.yml: absent"
has "the session cache line" "$WORK/e1.out" "Checked session cache $R/.ptc/session.json: absent"
has "the lookup line" "$WORK/e1.out" "Checked PTC lookup by repo URL: not attempted (no git remote origin to look up)"
has "the one command" "$WORK/e1.out" "Start a session: ptc-cli.sh guide start --project-id ID"

echo "=== #7224: a cache without a session, a config without guide.session_id ==="
R="$WORK/cache-only"; repo "$R"
mkdir -p "$R/.ptc"; echo '*' > "$R/.ptc/.gitignore"; printf '{"project_id": "77"}\n' > "$R/.ptc/session.json"
printf 'source_locale: en\nfiles:\n  - file: config/locales/en.yml\n    output: config/locales/{{lang}}.yml\n' > "$R/.ptc-config.yml"
(cd "$R" && "${BASE[@]}" PTC_API_TOKEN=tok "$CLI" guide next --api-url "$API") > "$WORK/e2.out" 2>&1; rc=$?
[[ $rc -eq 1 ]] && pass "exit 1" || fail "exit $rc"
has "the config file is present without a session" "$WORK/e2.out" "Checked config file $R/.ptc-config.yml: present, no guide.session_id"
has "the cache is present without a session" "$WORK/e2.out" "Checked session cache $R/.ptc/session.json: present, no session_id"
has "the lookup line" "$WORK/e2.out" "Checked PTC lookup by repo URL: not attempted (no git remote origin to look up)"
has "the one command" "$WORK/e2.out" "Start a session: ptc-cli.sh guide start --project-id ID"

echo "=== #7224: a remote PTC has no open session for ==="
R="$WORK/remote"; repo "$R" https://example.test/unknown.git
(cd "$R" && "${BASE[@]}" PTC_API_TOKEN=tok "$CLI" guide next --api-url "$API") > "$WORK/e3.out" 2>&1
has "the lookup was attempted and found none" "$WORK/e3.out" "Checked PTC lookup by repo URL: attempted: no open session for this repository (HTTP 404)"

echo "=== #7225: the token never appears on a process argument list ==="
SECRET="ptcu_argvprobe7225secret"
SHIM="$WORK/shim"; mkdir -p "$SHIM"
REAL_CURL=$(command -v curl)
# The shim is what runs as `curl`: it records its own argument list as every user of the machine reads it
# (/proc/<pid>/cmdline; `ps -o args= -p` where there is no /proc - busybox ps, the alpine CI image, has no -p), then
# becomes curl.
printf '#!/bin/bash\nif [[ -r /proc/$$/cmdline ]]; then tr "\\0" " " < /proc/$$/cmdline; echo; else ps -o args= -p $$; fi >> "%s"\nexec "%s" "$@"\n' \
    "$WORK/argv.log" "$REAL_CURL" > "$SHIM/curl"
chmod +x "$SHIM/curl"
: > "$WORK/argv.log"; : > "$WORK/ps.log"
( while :; do ps -eo args >> "$WORK/ps.log" 2>/dev/null; sleep 0.02; done ) & SAMPLER=$!
R="$WORK/argv"; repo "$R" https://example.test/r.git
(cd "$R" && "${BASE[@]}" PATH="$SHIM:$PATH" PTC_API_TOKEN="$SECRET" "$CLI" guide start --project-id 7 --repo-url https://example.test/r.git --branch main --api-url "$API" -d "$R") > "$WORK/a1.out" 2>&1
(cd "$R" && "${BASE[@]}" PATH="$SHIM:$PATH" PTC_API_TOKEN="$SECRET" "$CLI" guide next --session-id 10 --api-url "$API" -d "$R") > "$WORK/a2.out" 2>&1
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null; SAMPLER=""
n=$(grep -c . "$WORK/argv.log")
[[ $n -ge 2 ]] && pass "the requests ran through curl ($n curl processes recorded)" || fail "curl processes recorded: $n"
# Never print the token itself: a hit is reported masked.
if grep -q "$SECRET" "$WORK/argv.log"; then
    fail "a curl argument list holds the token: $(grep -o "Authorization: [A-Za-z]* $SECRET" "$WORK/argv.log" | head -1 | sed 's/ptcu_.*/ptcu_****/')"
else
    pass "no curl argument list holds the token"
fi
grep -q "$SECRET" "$WORK/ps.log" && fail "a ps -eo args sample holds the token (ptcu_****)" \
    || pass "no ps -eo args sample holds the token ($(grep -c . "$WORK/ps.log") lines sampled)"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['headers'].get('Authorization') == 'Bearer ' + sys.argv[2] else 1)" \
    "$BODIES/guide_next.json" "$SECRET" 2>/dev/null && pass "the fake server still receives the token as the bearer" \
    || fail "the fake server did not receive the bearer"

echo
echo "passed: $passed, failed: $failed"
[[ $failed -eq 0 ]]
