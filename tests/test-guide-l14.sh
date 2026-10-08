#!/bin/bash
# L14 (staging LW2, 2026-10-08) against the mock:
#  SF-41 the plain CLI prints every PTC text a human must see: an ask's default (PTC's generated description draft, a
#        default language list) in full, on `guide next`, `guide submit` and `guide wait`, for ask_human and also_ask_human.
#  SF-43 `ptc sync` stops at the first 402 of a run: one process call, the refusal printed once, no doomed calls for the
#        remaining files, the exit code unchanged.
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

start_mock MAIN 19961
start_mock REFUSE 19971 PTC_MOCK_REFUSE_PROCESS=1
P="$WORK/plain"; mkdir -p "$P"
LINE1="AI translation platform by OnTheGoSystems for developers who ship software in many languages."
LINE2="Readers: product managers and engineers."

check_draft() {  # check_draft WHAT FILE
    grep -qF "$LINE1" "$2" && grep -qF "$LINE2" "$2" && pass "$1 prints PTC's draft (ask_human.default) in full" \
        || fail "$1: no draft: $(cat "$2")"
    grep -qE "default.*de, es" "$2" && pass "$1 prints the also-ask's default" || fail "$1: no also-ask default: $(cat "$2")"
}

echo "=== SF-41: an ask's default is printed ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_draft --api-url "$API_MAIN" -d "$P" >"$WORK/next.out" 2>&1
check_draft "guide next" "$WORK/next.out"
printf '{"source":"readme"}\n' > "$WORK/ev.json"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide submit gt_desc --session-id gs_x --file "$WORK/ev.json" --api-url "$API_MAIN" -d "$P" >"$WORK/submit.out" 2>&1
check_draft "guide submit" "$WORK/submit.out"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide wait gt_desc --session-id gs_x --timeout 5 --api-url "$API_MAIN" -d "$P" >"$WORK/wait.out" 2>&1
check_draft "guide wait" "$WORK/wait.out"

echo "=== SF-43: sync stops at the first 402 ==="
T="$WORK/tree"; mkdir -p "$T/locales" "$T/admin" "$T/shop"
for f in locales admin shop; do printf '{"greeting": "Hello %s"}\n' "$f" > "$T/$f/en.json"; done
cat > "$T/.ptc-config.yml" <<'YML'
source_locale: en
monitor_interval: 1
files:
  - file: locales/en.json
    output: locales/{{lang}}.json
  - file: admin/en.json
    output: admin/{{lang}}.json
  - file: shop/en.json
    output: shop/{{lang}}.json
guide:
  project_id: 42
  session_id: gs_pass
YML
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_REFUSE" -d "$T" >"$WORK/refused.out" 2>&1; rc=$?
[[ $rc -eq 1 ]] && pass "a refused sync keeps its exit code (1)" || fail "refused sync exit $rc"
calls=$(grep -c "     process " "$WORK/mock-REFUSE.log")
[[ $calls -eq 1 ]] && pass "one process call: the sync stopped at the first 402" || fail "$calls process calls after the first 402"
n402=$(grep -c "HTTP 402: Nothing was translated" "$WORK/refused.out")
[[ $n402 -eq 1 ]] && pass "the refusal is printed once" || fail "the refusal is printed $n402 times"
grep -qF "PTC refused this push (HTTP 402); the other 2 file(s) were not sent" "$WORK/refused.out" \
    && pass "the sync says it stopped and how many files it did not send" || fail "no stop line: $(grep -i "402\|refus" "$WORK/refused.out" | head -5)"

echo
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
