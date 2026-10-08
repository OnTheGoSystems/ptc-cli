#!/bin/bash
# L11 (SF-31, SF-32; POL-1; specs/agent-guide AGD-4 "Conversion pushes", specs/cli-client) against the mock:
#  every conversion push PTC attaches to a guide answer (the switch-to-CI `suggestion`, the `subscribe` push) is printed in
#  full, text and link, on `guide next`, `guide wait`, `guide submit`, `guide skip` and `sync` (its delivery report); the
#  CLI tells PTC it shows them (X-PTC-Pushes: shown), so PTC counts the suggestion as told only on such an answer; a push
#  refused by the trial's free automatic deliveries (402) is printed with its billing link.
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

start_mock() {  # start_mock NAME PORT [ENV=VALUE...] -> API_<NAME>, bodies in $WORK/bodies-NAME
    local name="$1" port="$2" i; shift 2
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && { echo "port $port busy"; exit 1; }
    mkdir -p "$WORK/bodies-$name"
    env "$@" PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$WORK/bodies-$name" python3 "$MOCK" >>"$WORK/mock-$name.log" 2>&1 &
    PIDS+=("$!")
    for i in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
    printf -v "API_$name" 'http://127.0.0.1:%s/api/v1/' "$port"
}
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_API_TOKEN)
header() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['headers'].get('X-PTC-Pushes', ''))" "$1" 2>/dev/null; }

start_mock PUSH 19941 PTC_MOCK_PUSHES=1
start_mock REFUSE 19951 PTC_MOCK_REFUSE_PROCESS=1
P="$WORK/plain"; mkdir -p "$P"
SUGGESTION="PTC suggests (tell your user once; a suggestion, not a task): Delivered via API. Switch to CI"
SUBSCRIBE="PTC asks your user to subscribe (free_runs): This push was refused: the trial's 2 free automatic deliveries are used up"
BILLING="Billing: https://ptc.test/organizations/5/billing?conversion_source=agent_guide_free_runs"

check_pushes() {  # check_pushes WHAT FILE
    grep -qF "$SUGGESTION" "$2" && pass "$1 prints the switch-to-CI suggestion" || fail "$1: no suggestion: $(cat "$2")"
    grep -qF "$SUBSCRIBE" "$2" && grep -qF "$BILLING" "$2" && pass "$1 prints the subscribe push and its billing link" || fail "$1: no subscribe push: $(cat "$2")"
}

echo "=== guide next / submit / skip / wait print the pushes ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_any --api-url "$API_PUSH" -d "$P" >"$WORK/next.out" 2>&1
check_pushes "guide next" "$WORK/next.out"
[[ "$(header "$WORK/bodies-PUSH/guide_next.json")" == "shown" ]] && pass "guide next tells PTC it shows the pushes (X-PTC-Pushes: shown)" || fail "no X-PTC-Pushes header on guide next"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_done --api-url "$API_PUSH" -d "$P" >"$WORK/done.out" 2>&1
grep -q "All guide tasks are done." "$WORK/done.out" && check_pushes "guide next (all done)" "$WORK/done.out" || fail "done: $(cat "$WORK/done.out")"
printf '{"x":1}\n' > "$WORK/ev.json"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide submit gt_1 --session-id gs_any --file "$WORK/ev.json" --api-url "$API_PUSH" -d "$P" >"$WORK/submit.out" 2>&1
check_pushes "guide submit" "$WORK/submit.out"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide skip gt_1 --session-id gs_any --reason "not needed" --api-url "$API_PUSH" -d "$P" >"$WORK/skip.out" 2>&1
check_pushes "guide skip" "$WORK/skip.out"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide wait gt_ok --session-id gs_any --timeout 5 --api-url "$API_PUSH" -d "$P" >"$WORK/wait.out" 2>&1
check_pushes "guide wait" "$WORK/wait.out"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_any --json --api-url "$API_PUSH" -d "$P" >"$WORK/next.json" 2>/dev/null
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('suggestion') and d['subscribe'].get('url') else 1)" "$WORK/next.json" \
    && pass "guide next --json carries both pushes in its one JSON document" || fail "next --json: $(head -c 400 "$WORK/next.json")"

echo "=== sync: the delivery report's pushes are printed ==="
T="$WORK/tree"; mkdir -p "$T/locales"
printf '{"greeting": "Hello"}\n' > "$T/locales/en.json"
cat > "$T/.ptc-config.yml" <<'YML'
source_locale: en
monitor_interval: 1
files:
  - file: locales/en.json
    output: locales/{{lang}}.json
guide:
  project_id: 42
  session_id: gs_pass
YML
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_PUSH" -d "$T" >"$WORK/sync.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "sync -> exit 0" || fail "sync exit $rc: $(tail -5 "$WORK/sync.out")"
check_pushes "sync" "$WORK/sync.out"
[[ "$(header "$WORK/bodies-PUSH/guide_delivery_commits.json")" == "shown" ]] && pass "the delivery report tells PTC it shows the pushes" || fail "no X-PTC-Pushes on the delivery report"

echo "=== sync refused by the trial cap (402): the refusal and its billing link are printed ==="
T2="$WORK/tree2"; cp -r "$T" "$T2"; rm -f "$T2"/locales/de.json "$T2"/locales/fr.json
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_REFUSE" -d "$T2" >"$WORK/refused.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && pass "a refused sync -> non-zero exit ($rc)" || fail "refused sync exit 0"
grep -q "HTTP 402: Nothing was translated. Your trial's 2 free automatic deliveries are used up. Upgrade to Pro at https://ptc.test/#/dashboard/organizations/5/billing?conversion_source=api_translation_cap" "$WORK/refused.out" \
    && pass "the 402 refusal is printed with the billing link" || fail "refusal: $(grep -i "402\|error" "$WORK/refused.out" | head -5)"

echo
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
