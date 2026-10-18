#!/bin/bash
# (1.5.0, L21-3) An upload made while the project's suite is still being set up is stored, not translated: PTC answers
# the process request with 200 + `code: suite_setup_pending` and a `message`. The run prints that message and one line
# saying the translation starts by itself once the suite is set up, lists the files held, does NOT poll for them, and
# exits 0 (the next CI run picks the translation up). A file PTC did start in the same run is monitored as always.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
refuse_busy_port() {  # a port that already answers would hide a mock that could not bind (a stale run's server passes the probe)
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
expect_rc() { if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1 (rc $3, want $2)"; fi; }
has() { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing: $3)"; fi; }
hasnt() { if grep -qF -- "$3" "$2"; then fail "$1 (found: $3)"; else pass "$1"; fi; }
count() { grep -cF -- "$2" "$1"; }
WORK=$(mktemp -d)
PIDS=()
suite_cleanup() { stop_mocks "${PIDS[@]}"; rm -rf "$WORK"; }
trap suite_cleanup EXIT

start_mock() {  # start_mock VAR port... (env passed through) -> sets VAR to the API url
    local var="$1" port pid i; shift
    for port in "$@"; do
        refuse_busy_port "$port"
        PTC_MOCK_PORT="$port" python3 "$MOCK" >>"$WORK/mock-$port.log" 2>&1 &
        pid=$!
        for i in $(seq 1 30); do
            if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
                PIDS+=("$pid"); printf -v "$var" 'http://127.0.0.1:%s/api/v1/' "$port"; return 0
            fi
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.3
        done
        kill "$pid" 2>/dev/null
    done
    echo "mock did not come up"; exit 1
}

mkrepo() {  # mkrepo DIR -> a two-file config repo (a and b)
    mkdir -p "$1/config/locales"
    for n in a b; do printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$1/config/locales/$n.en.yml"; done
    {
      echo "source_locale: en"
      echo "files:"
      for n in a b; do printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n"; done
    } > "$1/.ptc-config.yml"
    git -C "$1" init -q
}

polls_for() { grep -c "translation_status .*'file_path': '$2'" "$1"; }

readonly SERVER_MESSAGE="Stored, not translated yet: this project belongs to a suite whose setup is not finished (waiting for wpml-sticky-links to finish setup)."

echo "=== config mode, every file held for the suite: the message, the held files, no polling, exit 0 ==="
API=""; JOURNAL="$WORK/all.journal"
PTC_MOCK_LOG="$JOURNAL" PTC_MOCK_SUITE_PENDING=config/locales/a.en.yml,config/locales/b.en.yml start_mock API 20111 20121 20131
R="$WORK/all"; mkrepo "$R"
start=$SECONDS
( cd "$R" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 5 --written-manifest "$WORK/all.manifest" ) >"$WORK/all.out" 2>&1
rc=$?; took=$((SECONDS - start))
expect_rc "every file held for the suite -> exit 0" 0 $rc
has "the server's message is printed" "$WORK/all.out" "$SERVER_MESSAGE"
[[ $(count "$WORK/all.out" "$SERVER_MESSAGE") -eq 1 ]] && pass "the message is printed once, not once per file" || fail "message printed $(count "$WORK/all.out" "$SERVER_MESSAGE") times"
has "the suite line names the code and that translation starts by itself" "$WORK/all.out" "Suite setup pending (suite_setup_pending): PTC translates the held files by itself once every project of the suite is set up; the next CI run delivers them."
has "the held files are counted" "$WORK/all.out" "Held for the suite (stored, not translated yet): 2"
has "and listed (a)" "$WORK/all.out" "config/locales/a.en.yml"
has "and listed (b)" "$WORK/all.out" "config/locales/b.en.yml"
[[ $(polls_for "$JOURNAL" config/locales/a.en.yml) -eq 0 && $(polls_for "$JOURNAL" config/locales/b.en.yml) -eq 0 ]] \
    && pass "no translation_status poll for a held file" || fail "held files were polled: $(grep -c translation_status "$JOURNAL") polls"
hasnt "no monitoring step for held files" "$WORK/all.out" "Starting translation monitoring"
hasnt "a held file is not reported as failed to start" "$WORK/all.out" "Processing failed to start"
[[ $took -lt 20 ]] && pass "the run did not wait (${took}s)" || fail "the run took ${took}s"
[[ ! -f "$R/config/locales/a.de.yml" ]] && pass "nothing written for a held file" || fail "a.de.yml written"
[[ -f "$WORK/all.manifest" && ! -s "$WORK/all.manifest" ]] && pass "the written manifest exists, empty" || fail "manifest missing or not empty"

echo "=== config mode, one file held and one started: the started one is delivered, exit 0 ==="
JOURNAL2="$WORK/mixed.journal"; API2=""
PTC_MOCK_LOG="$JOURNAL2" PTC_MOCK_SUITE_PENDING=config/locales/a.en.yml start_mock API2 20141 20151 20161
R="$WORK/mixed"; mkrepo "$R"
( cd "$R" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API2" --monitor-interval 1 --monitor-max-attempts 5 ) >"$WORK/mixed.out" 2>&1
expect_rc "one held, one completed -> exit 0" 0 $?
[[ -f "$R/config/locales/b.de.yml" && -f "$R/config/locales/b.fr.yml" ]] && pass "the started file's translations are on disk" || fail "b.de.yml / b.fr.yml missing"
[[ ! -f "$R/config/locales/a.de.yml" ]] && pass "nothing written for the held file" || fail "a.de.yml written"
[[ $(polls_for "$JOURNAL2" config/locales/a.en.yml) -eq 0 ]] && pass "the held file is not polled" || fail "the held file was polled"
[[ $(polls_for "$JOURNAL2" config/locales/b.en.yml) -ge 1 ]] && pass "the started file is polled" || fail "the started file was not polled"
has "the held file is listed" "$WORK/mixed.out" "Held for the suite (stored, not translated yet): 1"

echo "=== pattern mode (no config file): the same answer, exit 0, no polling ==="
R="$WORK/patterns"; mkrepo "$R"; rm -f "$R/.ptc-config.yml"
: > "$JOURNAL"
( cd "$R" && PTC_API_TOKEN=t "$CLI" --source-locale en --patterns 'config/locales/*.en.yml' --api-url "$API" --monitor-interval 1 --monitor-max-attempts 5 ) >"$WORK/patterns.out" 2>&1
expect_rc "pattern mode, every file held -> exit 0" 0 $?
has "pattern mode prints the server's message" "$WORK/patterns.out" "$SERVER_MESSAGE"
has "pattern mode prints the suite line" "$WORK/patterns.out" "Suite setup pending (suite_setup_pending)"
[[ $(grep -c translation_status "$JOURNAL") -eq 0 ]] && pass "pattern mode does not poll" || fail "pattern mode polled"

echo "=== help and README name the code ==="
"$CLI" --help >"$WORK/help.out" 2>&1
has "--help mentions suite_setup_pending" "$WORK/help.out" "suite_setup_pending"
has "README mentions suite_setup_pending" "$(dirname "$TEST_DIR")/README.md" "suite_setup_pending"

echo
echo "Passed: $passed  Failed: $failed"
[[ $failed -eq 0 ]]
