#!/bin/bash

# Org row 7352 (CLI-24, AGD-1, api-cli API-38): `ptc auth login` signs the human in through the browser. The CLI mints a
# device request (POST auth/device), prints the approval link and code (and opens the link with xdg-open/open unless
# --no-browser), polls POST auth/device/token every `interval` seconds (a 429 adds 5 s), and on 200 saves
# PTC_API_TOKEN=<token>, mode 600, where the paste form saves it, verifies it with GET auth/check and prints
# "Signed in; token saved to <file>". A TTY with nothing on stdin runs it by default; --device forces it; --paste forces
# the paste form; piped stdin keeps the paste/stdin form. Covered against tests/mock_ptc_api.py (PTC_MOCK_DEVICE knobs):
#   - approved after two pending polls: the file, its mode, its one line; the token in no output; the link opened;
#   - denied and expired: nothing saved, exit non-zero, the reason named;
#   - a 429 slow_down on the first poll is honoured and the flow still completes;
#   - --paste and the plain stdin form run the paste form unchanged (no device door is called).
# Each case runs with a temp HOME. PTC_CLI_UNDER_TEST points it at another copy (the red run).

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_UNDER_TEST="${PTC_CLI_UNDER_TEST:-$(dirname "$TEST_DIR")/ptc-cli.sh}"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"

test_count=0; passed_count=0; failed_count=0
pass() { echo "[PASS] $*"; passed_count=$((passed_count + 1)); test_count=$((test_count + 1)); }
fail() { echo "[FAIL] $*"; failed_count=$((failed_count + 1)); test_count=$((test_count + 1)); }

WORK_DIR=$(mktemp -d)
MOCK_PIDS=()
cleanup() {
    local p i
    for p in ${MOCK_PIDS[@]+"${MOCK_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
    for p in ${MOCK_PIDS[@]+"${MOCK_PIDS[@]}"}; do wait "$p" 2>/dev/null; for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done; done
    rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT

TOKEN="ptcu_device_$RANDOM$RANDOM$RANDOM"

# The browser openers: record the link they were given, open nothing.
mkdir -p "$WORK_DIR/bin"
for opener in xdg-open open; do
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$OPENED"\n' > "$WORK_DIR/bin/$opener"
    chmod +x "$WORK_DIR/bin/$opener"
done

# start_mock CASE PORT [VAR=value ...]: one mock (all scenarios from PORT up), its journal in $WORK_DIR/CASE/mock.log.
# Sets MOCK_PORT. Ports come from a block apart from the other suites' (the mock binds PORT..PORT+5).
start_mock() {
    local case_dir="$WORK_DIR/$1" base="$2" port pid i; shift 2
    mkdir -p "$case_dir"
    for port in "$base" $((base + 10)) $((base + 20)); do
        env PTC_MOCK_PORT="$port" PTC_MOCK_LOG="$case_dir/mock.log" PTC_MOCK_DEVICE_TOKEN="$TOKEN" "$@" \
            python3 "$MOCK" >>"$case_dir/mock.err" 2>&1 &
        pid=$!
        for i in $(seq 1 30); do
            if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
                MOCK_PIDS+=("$pid"); MOCK_PORT=$port; return 0
            fi
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill "$pid" 2>/dev/null
    done
    echo "mock did not come up for $1"; cat "$case_dir/mock.err"; exit 1
}

# login CASE STDIN ARGS...: `ptc auth login ARGS` with STDIN (the literal word NONE: stdin from /dev/null) against the
# case's mock; stdout, stderr and rc under $WORK_DIR/CASE.
login() {
    local case_dir="$WORK_DIR/$1" input="$2"; shift 2
    mkdir -p "$case_dir/home"; : > "$case_dir/opened"
    local src=/dev/null
    [[ "$input" != NONE ]] && { printf '%s\n' "$input" > "$case_dir/stdin"; src="$case_dir/stdin"; }
    env -u PTC_API_TOKEN -u PTC_AGENT_TOKEN -u PTC_ORG_TOKEN -u XDG_CONFIG_HOME -u APPDATA \
        HOME="$case_dir/home" PATH="$WORK_DIR/bin:$PATH" PTC_API_URL="http://127.0.0.1:$MOCK_PORT/api/v1/" \
        OPENED="$case_dir/opened" \
        timeout 60 bash "$CLI_UNDER_TEST" auth login "$@" < "$src" > "$case_dir/out" 2> "$case_dir/err"
    echo $? > "$case_dir/rc"
}

masked() { cat "$WORK_DIR/$1/out" "$WORK_DIR/$1/err" | sed 's/ptcu_[A-Za-z0-9_]*/<token>/g' | tail -"${2:-4}" | tr '\n' ' '; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
rc_of() { cat "$WORK_DIR/$1/rc"; }
cred() { printf '%s' "$WORK_DIR/$1/home/.config/ptc/credentials"; }
journal_has() { grep -qE -- "$2" "$WORK_DIR/$1/mock.log" 2>/dev/null; }
polls_of() { grep -c 'POST /auth/device/token' "$WORK_DIR/$1/mock.log" 2>/dev/null; }
no_token_in_output() { ! grep -qF -- "$TOKEN" "$WORK_DIR/$1/out" "$WORK_DIR/$1/err"; }

# --- 1. approved after two pending polls (--device: the tests have no terminal)
start_mock approved 18640 PTC_MOCK_DEVICE=approve PTC_MOCK_DEVICE_PENDING=2
login approved NONE --device
if [[ "$(rc_of approved)" == 0 ]]; then pass "device login exits 0 once the browser approves"
else fail "device login exits 0 once the browser approves (rc $(rc_of approved); output: $(masked approved))"; fi
if [[ -f "$(cred approved)" && "$(cat "$(cred approved)")" == "PTC_API_TOKEN=$TOKEN" ]]; then pass "device login writes PTC_API_TOKEN=<token> to ~/.config/ptc/credentials"
else fail "device login writes PTC_API_TOKEN=<token> to ~/.config/ptc/credentials (file: $( [[ -f "$(cred approved)" ]] && echo present || echo absent))"; fi
if [[ "$(mode_of "$(cred approved)")" == 600 ]]; then pass "the credentials file is mode 600"
else fail "the credentials file is mode 600 (mode: $(mode_of "$(cred approved)"))"; fi
if no_token_in_output approved; then pass "device login never prints the token"
else fail "device login never prints the token"; fi
if grep -qF -- 'ABCD-EFGH' "$WORK_DIR/approved/err" && grep -qF -- "/dashboard/agent-tokens/approve?code=ABCD-EFGH" "$WORK_DIR/approved/err"; then
    pass "device login prints the code and the approval link"
else fail "device login prints the code and the approval link (output: $(masked approved 6))"; fi
if grep -qF -- "Signed in; token saved to $(cred approved)" "$WORK_DIR/approved/out" "$WORK_DIR/approved/err"; then
    pass "device login says 'Signed in; token saved to <file>'"
else fail "device login says 'Signed in; token saved to <file>' (output: $(masked approved))"; fi
if [[ "$(polls_of approved)" == 3 ]]; then pass "device login polls until approved (2 pending, then 200) and stops"
else fail "device login polls until approved (2 pending, then 200) and stops (polls: $(polls_of approved))"; fi
if journal_has approved 'GET +/auth/check .*auth=yes'; then pass "device login verifies the saved token with GET auth/check"
else fail "device login verifies the saved token with GET auth/check"; fi
if grep -qF -- "/dashboard/agent-tokens/approve?code=ABCD-EFGH" "$WORK_DIR/approved/opened"; then pass "device login opens the approval link in the browser"
else fail "device login opens the approval link in the browser (opened: $(cat "$WORK_DIR/approved/opened"))"; fi

# --- 2. --no-browser opens nothing
start_mock nobrowser 18700 PTC_MOCK_DEVICE=approve PTC_MOCK_DEVICE_PENDING=0
login nobrowser NONE --device --no-browser
if [[ "$(rc_of nobrowser)" == 0 && ! -s "$WORK_DIR/nobrowser/opened" ]]; then pass "--no-browser signs in without opening a browser"
else fail "--no-browser signs in without opening a browser (rc $(rc_of nobrowser); opened: $(cat "$WORK_DIR/nobrowser/opened"))"; fi

# --- 3. denied: nothing saved
start_mock denied 18760 PTC_MOCK_DEVICE=deny PTC_MOCK_DEVICE_PENDING=1
login denied NONE --device --no-browser
if [[ "$(rc_of denied)" != 0 && ! -e "$(cred denied)" ]] && grep -qi 'denied' "$WORK_DIR/denied/err"; then
    pass "a request denied in the browser saves nothing, names the denial and exits non-zero"
else fail "a request denied in the browser saves nothing, names the denial and exits non-zero (rc $(rc_of denied); output: $(masked denied))"; fi

# --- 4. expired: nothing saved
start_mock expired 18820 PTC_MOCK_DEVICE=expire PTC_MOCK_DEVICE_PENDING=1
login expired NONE --device --no-browser
if [[ "$(rc_of expired)" != 0 && ! -e "$(cred expired)" ]] && grep -qi 'expired' "$WORK_DIR/expired/err"; then
    pass "an expired code saves nothing, says it expired and exits non-zero"
else fail "an expired code saves nothing, says it expired and exits non-zero (rc $(rc_of expired); output: $(masked expired))"; fi

# --- 5. slow_down: a 429 adds 5 s and the flow completes
start_mock slow 18880 PTC_MOCK_DEVICE=approve PTC_MOCK_DEVICE_PENDING=0 PTC_MOCK_DEVICE_SLOW_DOWN=1
started=$SECONDS
login slow NONE --device --no-browser
if [[ "$(rc_of slow)" == 0 && -f "$(cred slow)" && $((SECONDS - started)) -ge 5 ]]; then pass "a 429 slow_down adds 5 s to the interval and the login still completes"
else fail "a 429 slow_down adds 5 s to the interval and the login still completes (rc $(rc_of slow); $((SECONDS - started)) s; output: $(masked slow))"; fi

# --- 6. --paste: the paste form, unchanged (one line on stdin), no device door called
start_mock paste 18940 PTC_MOCK_DEVICE=approve
login paste "ptcu_pasted_$RANDOM" --paste
if [[ "$(rc_of paste)" == 0 && "$(cat "$(cred paste)" 2>/dev/null)" == PTC_API_TOKEN=ptcu_pasted_* ]] && ! journal_has paste 'auth/device'; then
    pass "--paste saves the pasted token and never calls the device doors"
else fail "--paste saves the pasted token and never calls the device doors (rc $(rc_of paste); output: $(masked paste))"; fi

# --- 7. piped stdin, no flag: today's stdin form, unchanged
start_mock stdin 19000 PTC_MOCK_DEVICE=approve
login stdin "ptcu_piped_$RANDOM"
if [[ "$(rc_of stdin)" == 0 && "$(cat "$(cred stdin)" 2>/dev/null)" == PTC_API_TOKEN=ptcu_piped_* ]] && ! journal_has stdin 'auth/device'; then
    pass "piped stdin keeps the stdin form: the token saved, no device door called"
else fail "piped stdin keeps the stdin form: the token saved, no device door called (rc $(rc_of stdin); output: $(masked stdin))"; fi
if [[ "$(mode_of "$(cred stdin)")" == 600 ]]; then pass "the stdin form's file is mode 600"
else fail "the stdin form's file is mode 600 (mode: $(mode_of "$(cred stdin)"))"; fi

# --- 8. a token PTC refuses at auth/check is not saved (the verify step still runs on the device path)
start_mock refused 19060 PTC_MOCK_DEVICE=approve PTC_MOCK_DEVICE_PENDING=0 PTC_MOCK_DEVICE_TOKEN=ptcu_refused
login refused NONE --device --no-browser
if [[ "$(rc_of refused)" != 0 && ! -e "$(cred refused)" ]] && ! grep -qF ptcu_refused "$WORK_DIR/refused/out" "$WORK_DIR/refused/err"; then
    pass "a token PTC refuses at auth/check is not saved, never printed, exit non-zero"
else fail "a token PTC refuses at auth/check is not saved, never printed, exit non-zero (rc $(rc_of refused); output: $(masked refused))"; fi

# --- 9. help names the browser form and both switches
env -u PTC_API_TOKEN HOME="$WORK_DIR" bash "$CLI_UNDER_TEST" auth --help > "$WORK_DIR/help" 2>&1
if grep -qF -- '--paste' "$WORK_DIR/help" && grep -qF -- '--no-browser' "$WORK_DIR/help" && grep -qi 'browser' "$WORK_DIR/help"; then
    pass "auth --help names the browser sign-in, --paste and --no-browser"
else fail "auth --help names the browser sign-in, --paste and --no-browser ($(tr '\n' ' ' < "$WORK_DIR/help"))"; fi

echo
echo "Tests: $test_count, passed: $passed_count, failed: $failed_count"
[[ $failed_count -eq 0 ]]
