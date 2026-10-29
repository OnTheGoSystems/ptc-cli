#!/bin/bash
# Org row 7188 (production live test, 27 Oct 2026; CLI-27): every door that takes --project-id falls back to the config's
# guide.project_id, then the local cache (.ptc/session.json) the last successful call wrote, then PTC's open session for
# the checkout's origin, and names its source in verbose mode; the flag still wins. The guide doors that take
# --session-id fall back to the cached session; with no token the door says so (never "No guide session"). The install
# line the backend renders puts the script at .ptc/bin/ptc-cli.sh, which runs from the repository root and stays ignored.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
readonly CONFIG_RB="$(dirname "$(dirname "$TEST_DIR")")/backend/app/services/guide/config.rb"
refuse_busy_port() {
    local i
    for i in $(seq 1 20); do
        python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), 0.4).close()" 2>/dev/null || return 0
        sleep 0.25
    done
    echo "port $1 already in use: a stale mock_ptc_api.py? (pgrep -af mock_ptc_api.py)" >&2; exit 1
}
stop_mocks() {
    local p i; for p in "$@"; do kill "$p" 2>/dev/null; done
    for p in "$@"; do wait "$p" 2>/dev/null; for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done; done
}
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
jcheck() {  # jcheck desc file expr
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($3) else 1)" "$2" 2>/dev/null; then pass "$1"; else fail "$1: $(head -c 400 "$2" 2>/dev/null)"; fi
}
has() {  # has desc file text
    grep -qF -- "$3" "$2" && pass "$1" || fail "$1: no '$3' in: $(tail -4 "$2")"
}
hasnt() {
    grep -qF -- "$3" "$2" && fail "$1: '$3' in: $(tail -4 "$2")" || pass "$1"
}

WORK=$(mktemp -d)
BODIES="$WORK/bodies"; mkdir -p "$BODIES"
MOCK_PID=""; PORT=""
cleanup() { [[ -n "$MOCK_PID" ]] && stop_mocks "$MOCK_PID"; rm -rf "${WORK:?}"; }
trap cleanup EXIT
for port in 19471 19473 19475 19477; do
    refuse_busy_port "$port"
    PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$BODIES" PTC_MOCK_LOG="$WORK/journal.log" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
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
# The agent's own machine: an organization agent token, no CI markers, no project in the environment.
AGENT=(env -u CI -u GITLAB_CI -u GITHUB_ACTIONS -u CI_COMMIT_SHA -u GITHUB_SHA -u PTC_PROJECT_ID -u PTC_GUIDE_PROJECT_ID
       -u PTC_GUIDE_SESSION_ID -u PTC_API_TOKEN -u PTC_AGENT_TOKEN -u PTC_VERBOSE XDG_CONFIG_HOME="$WORK/xdg" PTC_ORG_TOKEN=org-token)
NOTOKEN=(env -u CI -u GITLAB_CI -u GITHUB_ACTIONS -u CI_COMMIT_SHA -u GITHUB_SHA -u PTC_PROJECT_ID -u PTC_GUIDE_PROJECT_ID
         -u PTC_GUIDE_SESSION_ID -u PTC_API_TOKEN -u PTC_AGENT_TOKEN -u PTC_ORG_TOKEN -u PTC_VERBOSE XDG_CONFIG_HOME="$WORK/xdg")
clear_bodies() { find "${BODIES:?}" -mindepth 1 -name '*.json' -delete; : > "$WORK/journal.log"; }
repo() {  # repo DIR ORIGIN: a git checkout with one source file
    local d="$1"
    mkdir -p "$d/config/locales"; printf 'en:\n  hello: "Hello"\n' > "$d/config/locales/en.yml"
    git -C "$d" init -q -b main && git -C "$d" config user.email t@example.com && git -C "$d" config user.name t
    [[ -n "${2:-}" ]] && git -C "$d" remote add origin "$2"
    git -C "$d" add -A && git -C "$d" commit -qm init
}
config() {  # config DIR [PROJECT_ID]
    { printf 'source_locale: en\nfiles:\n  - file: config/locales/en.yml\n    output: config/locales/{{lang}}.yml\n'
      [[ -n "${2:-}" ]] && printf 'guide:\n  project_id: %s\n' "$2"; } > "$1/.ptc-config.yml"
}
cache() {  # cache DIR SESSION PROJECT
    mkdir -p "$1/.ptc"; echo '*' > "$1/.ptc/.gitignore"
    printf '{"session_id": "%s", "project_id": "%s"}\n' "$2" "$3" > "$1/.ptc/session.json"
}
run_pid() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['body'].get('project_id'))" "$BODIES/guide_action_runs.json" 2>/dev/null; }
ar() {  # ar DIR OUT ARGS...: `ptc guide action-run` from the repository root, verbose (PTC_VERBOSE=true)
    local d="$1" out="$2"; shift 2
    (cd "$d" && "${AGENT[@]}" PTC_VERBOSE=true "$CLI" guide action-run --api-url "$API" "$@") > "$out" 2>&1
}

echo "=== action-run: the project only in the config ==="
R="$WORK/cfg-only"; repo "$R" https://example.test/fallbacks.git; config "$R" 3565
clear_bodies; ar "$R" "$WORK/a1.out"; rc=$?
[[ $rc -eq 0 ]] && pass "reported (exit 0)" || fail "action-run exit $rc: $(tail -3 "$WORK/a1.out")"
[[ "$(run_pid)" == 3565 ]] && pass "the report carries project 3565" || fail "report project_id: $(run_pid)"
has "verbose names the config" "$WORK/a1.out" "project 3565 from config"
(cd "$R" && "${AGENT[@]}" "$CLI" -v guide action-run --api-url "$API") > "$WORK/a1v.out" 2>&1
has "\`ptc -v guide action-run\` is verbose too" "$WORK/a1v.out" "project 3565 from config"
(cd "$R" && "${AGENT[@]}" "$CLI" guide action-run -v --api-url "$API") > "$WORK/a1w.out" 2>&1
has "\`ptc guide action-run -v\` is verbose too" "$WORK/a1w.out" "project 3565 from config"

echo "=== action-run: the project only in the local cache ==="
R="$WORK/cache-only"; repo "$R" https://example.test/fallbacks.git; cache "$R" gs_c 77
clear_bodies; ar "$R" "$WORK/a2.out"; rc=$?
[[ $rc -eq 0 ]] && pass "reported (exit 0)" || fail "action-run exit $rc: $(tail -3 "$WORK/a2.out")"
[[ "$(run_pid)" == 77 ]] && pass "the report carries project 77" || fail "report project_id: $(run_pid)"
has "verbose names the cache" "$WORK/a2.out" "project 77 from cache"

echo "=== action-run: config and cache and the flag: the flag wins ==="
R="$WORK/all-three"; repo "$R" https://example.test/fallbacks.git; config "$R" 3565; cache "$R" gs_c 77
clear_bodies; ar "$R" "$WORK/a3.out" --project-id 999; rc=$?
[[ $rc -eq 0 ]] && pass "reported (exit 0)" || fail "action-run exit $rc: $(tail -3 "$WORK/a3.out")"
[[ "$(run_pid)" == 999 ]] && pass "the report carries the flag's project 999" || fail "report project_id: $(run_pid)"
has "verbose names the flag" "$WORK/a3.out" "project 999 from flag"
clear_bodies; ar "$R" "$WORK/a3b.out"
[[ "$(run_pid)" == 3565 ]] && pass "without the flag the config outranks the cache (L13)" || fail "report project_id: $(run_pid)"

echo "=== action-run: no config, no cache, the session opened over MCP (the live test's defect 1): PTC names it ==="
R="$WORK/mcp-opened"; repo "$R" https://example.test/known.git
clear_bodies; ar "$R" "$WORK/a4.out"; rc=$?
[[ $rc -eq 0 ]] && pass "reported (exit 0), no HTTP 400" || fail "action-run exit $rc: $(tail -3 "$WORK/a4.out")"
[[ "$(run_pid)" == 77 ]] && pass "the report carries PTC's project 77" || fail "report project_id: $(run_pid)"
has "verbose names PTC" "$WORK/a4.out" "project 77 from ptc"
jcheck "the lookup is cached with both ids" "$R/.ptc/session.json" "d.get('session_id') == 'gs_found' and str(d.get('project_id')) == '77'"

echo "=== glossary validate --remote: the project only in the config (the live test's defect 2) ==="
R="$WORK/glossary"; repo "$R" https://example.test/fallbacks.git; config "$R" 3565
printf 'en,de\nhello,hallo\n' > "$R/g.csv"
clear_bodies
(cd "$R" && "${AGENT[@]}" PTC_API_URL="$API" PTC_VERBOSE=true "$CLI" glossary validate g.csv --remote) > "$WORK/g1.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "validated by PTC (exit 0)" || fail "glossary validate exit $rc: $(tail -3 "$WORK/g1.out")"
hasnt "no 'needs the project id'" "$WORK/g1.out" "needs the project id"
jcheck "the request names project 3565" "$BODIES/guide_glossary_validate.json" "str(d['body'].get('project_id')) == '3565'"
has "verbose names the config" "$WORK/g1.out" "project 3565 from config"
R2="$WORK/glossary-none"; repo "$R2"; printf 'en,de\nhello,hallo\n' > "$R2/g.csv"
(cd "$R2" && "${AGENT[@]}" PTC_API_URL="$API" "$CLI" glossary validate g.csv --remote) > "$WORK/g2.out" 2>&1; rc=$?
[[ $rc -eq 1 ]] && pass "no project anywhere: exit 1" || fail "exit $rc"
has "the error names every source" "$WORK/g2.out" "--project-id N, PTC_PROJECT_ID, guide.project_id in .ptc-config.yml, or a guide session (.ptc/session.json)"

echo "=== guide next: the session only in the cache ==="
R="$WORK/next-cache"; repo "$R" https://example.test/fallbacks.git; cache "$R" 9 77
clear_bodies
(cd "$R" && "${AGENT[@]}" PTC_VERBOSE=true "$CLI" guide next --api-url "$API") > "$WORK/n1.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "guide next (exit 0)" || fail "guide next exit $rc: $(tail -3 "$WORK/n1.out")"
has "the cached session 9 is asked (task gt_s9)" "$WORK/n1.out" "gt_s9"
has "verbose names the cache" "$WORK/n1.out" "session 9 from cache"

echo "=== guide next: a --session-id call is cached; the next call without it asks the same session ==="
R="$WORK/next-learn"; repo "$R" https://example.test/fallbacks.git
(cd "$R" && "${AGENT[@]}" "$CLI" guide next --session-id 10 --project-id 4242 --api-url "$API") > "$WORK/n2.out" 2>&1
jcheck "the cache holds session 10 and project 4242" "$R/.ptc/session.json" "str(d.get('session_id')) == '10' and str(d.get('project_id')) == '4242'"
(cd "$R" && "${AGENT[@]}" "$CLI" guide next --api-url "$API") > "$WORK/n3.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "guide next without --session-id (exit 0)" || fail "exit $rc: $(tail -3 "$WORK/n3.out")"
has "the cached session 10 is asked (task gt_s10)" "$WORK/n3.out" "gt_s10"
clear_bodies
(cd "$R" && "${AGENT[@]}" "$CLI" guide action-run --api-url "$API") > "$WORK/n4.out" 2>&1
[[ "$(run_pid)" == 4242 ]] && pass "action-run then reports to the cached project 4242" || fail "report project_id: $(run_pid)"

echo "=== guide next: no token, no cache, no config (the live test's defect 3) ==="
R="$WORK/no-token"; repo "$R" https://example.test/known.git
(cd "$R" && "${NOTOKEN[@]}" "$CLI" guide next --api-url "$API") > "$WORK/t1.out" 2>&1; rc=$?
[[ $rc -eq 1 ]] && pass "exit 1" || fail "exit $rc"
has "the token error" "$WORK/t1.out" "No API token: PTC_API_TOKEN and PTC_AGENT_TOKEN are not set"
has "the token error names the credentials file" "$WORK/t1.out" "$WORK/xdg/ptc/credentials"
hasnt "never 'No guide session'" "$WORK/t1.out" "No guide session"
R="$WORK/no-session"; repo "$R" https://example.test/unknown.git
(cd "$R" && "${AGENT[@]}" "$CLI" guide next --api-url "$API") > "$WORK/t2.out" 2>&1; rc=$?
[[ $rc -eq 1 ]] && pass "no open session: exit 1" || fail "exit $rc"
has "the lookup's answer is named" "$WORK/t2.out" "No guide session (PTC lookup by repo URL answered HTTP 404)"

echo "=== the stable install path: the backend's install line, from a file:// copy ==="
R="$WORK/install"; repo "$R" https://example.test/fallbacks.git
line=$(python3 - "$CONFIG_RB" "file://$CLI" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
path = re.search(r"CLI_INSTALL_PATH = '([^']+)'", src)
tmpl = re.search(r'CLI_INSTALL_LINE = "([^"]+)"', src)
if not (path and tmpl):
    sys.exit(1)
print(tmpl.group(1).replace("#{CLI_INSTALL_URL}", sys.argv[2]).replace("#{CLI_INSTALL_PATH}", path.group(1)))
PY
)
[[ "$line" == "mkdir -p .ptc/bin && curl -fsSL file://$CLI -o .ptc/bin/ptc-cli.sh && chmod +x .ptc/bin/ptc-cli.sh" ]] \
  && pass "the backend renders the .ptc/bin install line" || fail "install line: '${line}'"
if [[ -n "$line" ]]; then
    (cd "$R" && bash -c "$line") > "$WORK/i1.out" 2>&1 || fail "the install line failed: $(tail -3 "$WORK/i1.out")"
fi
[[ -x "$R/.ptc/bin/ptc-cli.sh" ]] && pass ".ptc/bin/ptc-cli.sh installed, executable" || fail "no executable .ptc/bin/ptc-cli.sh"
(cd "$R" && .ptc/bin/ptc-cli.sh --version) > "$WORK/i2.out" 2>&1 && pass ".ptc/bin/ptc-cli.sh --version runs" || fail "--version: $(cat "$WORK/i2.out")"
(cd "$R" && "${AGENT[@]}" .ptc/bin/ptc-cli.sh guide start --project-id 77 --branch main --api-url "$API") > "$WORK/i3.out" 2>&1 \
  || fail "guide start from .ptc/bin: $(tail -3 "$WORK/i3.out")"
git -C "$R" check-ignore -q .ptc/bin/ptc-cli.sh && pass ".ptc/.gitignore ignores the installed script" || fail "the script is not ignored"
[[ -z "$(git -C "$R" status --porcelain --untracked-files=all -- .ptc)" ]] && pass "nothing under .ptc/ is ever committed" || fail "git status lists .ptc: $(git -C "$R" status --porcelain -- .ptc)"
(cd "$R" && "${AGENT[@]}" .ptc/bin/ptc-cli.sh guide next --api-url "$API") > "$WORK/i4.out" 2>&1 \
  && pass "a later call runs the same .ptc/bin path, no reinstall" || fail "second call: $(tail -3 "$WORK/i4.out")"

echo
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
