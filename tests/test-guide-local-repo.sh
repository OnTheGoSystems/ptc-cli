#!/bin/bash
# Org row 7186 (AGD-2 "Local session", CLI-26): `ptc guide start` on a checkout with no git remote starts a local
# session (local: 1 + the workspace fingerprint, no repository URL, one line saying so) and never needs a URL; a
# --repo-url that is not one of the checkout's remotes is refused (exit 2) naming the remotes found, or "no remotes";
# the ssh and https spellings of one remote are the same repository.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
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
expect_rc() { local desc="$1" want="$2" got="$3"; [[ "$got" == "$want" ]] && pass "$desc" || fail "$desc (rc $got, want $want)"; }
jcheck() {  # jcheck desc file expr
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($3) else 1)" "$2" 2>/dev/null; then pass "$1"; else fail "$1: $(cat "$2" 2>/dev/null)"; fi
}

WORK=$(mktemp -d)
BODIES="$WORK/bodies"; mkdir -p "$BODIES"
MOCK_PID=""; PORT=""
cleanup() { [[ -n "$MOCK_PID" ]] && stop_mocks "$MOCK_PID"; rm -rf "${WORK:?}"; }
trap cleanup EXIT
for port in 18927 18937 18947 18957; do
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
NOCI=(env -u CI -u GITLAB_CI -u GITHUB_ACTIONS -u CI_COMMIT_SHA -u GITHUB_SHA)
start() { local dir="$1"; shift; "${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide start "$@" --branch main --api-url "$API" -d "$dir"; }
tree() {  # tree DIR: a working tree with one source file
    mkdir -p "$1/config/locales"; printf 'en:\n  hello: "Hello"\n' > "$1/config/locales/en.yml"
}
clear_bodies() { find "${BODIES:?}" -mindepth 1 -name '*.json' -delete; }
clear_cache() { find "${1:?}" -maxdepth 1 -name .ptc -exec rm -r {} +; }

echo "=== a directory with no git at all: a local session ==="
L="$WORK/no-git"; tree "$L"
clear_bodies
start "$L" >"$WORK/out" 2>&1; expect_rc "no git, no --repo-url -> exit 0" 0 $?
grep -qx "no git remote: local project, delivery by ptc sync" "$WORK/out" && pass "prints the one local-project line" || fail "local line: $(cat "$WORK/out")"
# Org row 7319 clause 2 (AGD-3 row 19): a local project delivers by the API alone, so no CI-secret step is served.
grep -q "Created PTC project" "$WORK/out" && ! grep -q "CI secret" "$WORK/out" && pass "a local project is not told to add a CI secret" || fail "CI secret on a local project: $(cat "$WORK/out")"
jcheck "POST /projects: local 1, the 64-hex fingerprint, no repo_url" "$BODIES/projects.json" \
    "d['body']['local'] == 1 and len(d['body']['fingerprint']) == 64 and d['body']['repo_url'] == ''"
jcheck "POST guide/sessions: local 1 and the same fingerprint" "$BODIES/guide_sessions.json" \
    "d['body']['local'] == 1 and d['body']['fingerprint'] == json.load(open('$BODIES/projects.json'))['body']['fingerprint']"

echo "=== a git checkout with no remote: a local session ==="
N="$WORK/no-remote"; tree "$N"; git -C "$N" init -q
clear_bodies
start "$N" >"$WORK/out" 2>&1; expect_rc "git, no remote, no --repo-url -> exit 0" 0 $?
grep -q "no git remote: local project" "$WORK/out" && pass "git without a remote: the local-project line" || fail "local line (git): $(cat "$WORK/out")"
! grep -q "CI secret" "$WORK/out" && pass "git without a remote: no CI-secret step" || fail "CI secret on a local git checkout: $(cat "$WORK/out")"
jcheck "git without a remote: POST guide/sessions is local" "$BODIES/guide_sessions.json" "d['body']['local'] == 1 and d['body']['repo_url'] == ''"

echo "=== --repo-url that is not a remote: refused, nothing sent ==="
clear_bodies
start "$N" --repo-url https://github.com/someone/plugin.git >"$WORK/out" 2>&1; expect_rc "no remote + --repo-url -> exit 2" 2 $?
grep -qF -- "--repo-url https://github.com/someone/plugin.git is not a remote of this checkout (no remotes); pass one of them, or omit --repo-url for a local checkout" "$WORK/out" \
    && pass "refusal says: no remotes" || fail "no-remotes refusal: $(cat "$WORK/out")"
[[ ! -e "$BODIES/projects.json" && ! -e "$BODIES/guide_sessions.json" ]] && pass "a refused URL never reaches PTC" || fail "a request was sent"

R="$WORK/remotes"; tree "$R"; git -C "$R" init -q
git -C "$R" remote add origin https://example.test/acme/app.git
git -C "$R" remote add upstream git@example.test:other/app.git
clear_bodies
start "$R" --repo-url https://github.com/someone/plugin.git >"$WORK/out" 2>&1; expect_rc "mismatched --repo-url -> exit 2" 2 $?
grep -qF "(remotes: origin=https://example.test/acme/app.git, upstream=git@example.test:other/app.git)" "$WORK/out" \
    && pass "refusal names every remote" || fail "remotes refusal: $(cat "$WORK/out")"
[[ ! -e "$BODIES/projects.json" ]] && pass "mismatched URL: no project created" || fail "mismatched URL created a project"

echo "=== the same remote in another spelling is accepted ==="
clear_bodies
start "$R" --repo-url git@EXAMPLE.test:acme/app >"$WORK/out" 2>&1; expect_rc "ssh spelling of the https origin -> exit 0" 0 $?
jcheck "the given spelling is sent, not local" "$BODIES/guide_sessions.json" "d['body']['repo_url'] == 'git@EXAMPLE.test:acme/app' and 'local' not in d['body']"
clear_bodies; clear_cache "$R"
start "$R" --repo-url https://example.test/other/app/ >"$WORK/out" 2>&1; expect_rc "https spelling of the ssh upstream (trailing /) -> exit 0" 0 $?
clear_bodies; clear_cache "$R"
start "$R" --repo-url ssh://git@example.test/acme/app.git >"$WORK/out" 2>&1; expect_rc "ssh:// spelling of the https origin -> exit 0" 0 $?

echo "=== origin present, no --repo-url: unchanged ==="
clear_bodies; clear_cache "$R"
start "$R" >"$WORK/out" 2>&1; expect_rc "origin, no --repo-url -> exit 0" 0 $?
jcheck "origin is the repo_url, no local flag" "$BODIES/projects.json" "d['body']['repo_url'] == 'https://example.test/acme/app.git' and 'local' not in d['body']"
! grep -q "no git remote" "$WORK/out" && pass "no local-project line with a remote" || fail "local line printed with a remote"

echo
echo "guide local repo: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
