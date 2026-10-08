#!/bin/bash
# S2-R2 item 4 (Eran 2026-10-01, decision 5, F13; specs/ci-integrations): a limit reached during CI. The preflight knows
# the balance and (from the config) the census; when the local estimate is over the balance it says so, the files that
# fit are translated in census order, what completed is delivered, and the pull request body names the limit and the
# files left out.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="${PTC_TEST_CLI:-$(dirname "$TEST_DIR")/ptc-cli.sh}"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
refuse_busy_port() {  # a port that already answers would hide a mock that could not bind (a stale run's server passes the probe)
    local i  # up to ~5 s for a listener in its last moments (the previous suite's mock shutting down) to go quiet
    for i in $(seq 1 20); do
        python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), 0.4).close()" 2>/dev/null || return 0
        sleep 0.25
    done
    echo "port $1 already in use: a stale mock_ptc_api.py? (pgrep -af mock_ptc_api.py)" >&2; exit 1
}
stop_mocks() {  # kill the suite's mocks AND wait until they are gone, so the next suite finds their ports free
    local p i; for p in "$@"; do kill "$p" 2>/dev/null; done
    for p in "$@"; do wait "$p" 2>/dev/null; for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done; done
}
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); MOCK_PID=""
cleanup() { [[ -n "$MOCK_PID" ]] && stop_mocks "$MOCK_PID"; rm -rf "$WORK"; }
trap cleanup EXIT

port=19511
refuse_busy_port "$port"
PTC_MOCK_PREPAID_BALANCE=10 PTC_MOCK_PORT=$port PTC_MOCK_LOG="$WORK/journal" python3 "$MOCK" >"$WORK/mock.log" 2>&1 & MOCK_PID=$!
for i in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && kill -0 "$MOCK_PID" 2>/dev/null && break; sleep 0.3; done
kill -0 "$MOCK_PID" 2>/dev/null || { echo "the mock died; its output was:" >&2; sed 's/^/    /' "$WORK/mock.log" >&2; exit 1; }

R="$WORK/repo"; mkdir -p "$R/locales"
printf '{"a": "Open the file", "b": "Save"}\n' > "$R/locales/a-en.json"                      # 4 words x 2 languages = 8
printf '{"c": "Share it with your whole team"}\n' > "$R/locales/b-en.json"                  # 6 words x 2 languages = 12
printf 'source_locale: en\nlanguages: [de, fr]\nfiles:\n  - file: locales/a-en.json\n    output: locales/a-{{lang}}.json\n  - file: locales/b-en.json\n    output: locales/b-{{lang}}.json\n' > "$R/.ptc-config.yml"
git -C "$R" init -q
( cd "$R" && GITHUB_OUTPUT="$WORK/gh_out" PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "http://127.0.0.1:$port/api/v1/" \
    --monitor-interval 1 --monitor-max-attempts 10 ) >"$WORK/out" 2>&1; rc=$?

[[ $rc -eq 0 ]] && pass "the run exits 0 (what fits is translated and delivered)" || fail "rc=$rc: $(tail -5 "$WORK/out")"
grep -q "Preflight: The census is 20 words (2 files x 2 languages); the balance covers 10: 10 words short" "$WORK/out" \
    && pass "the preflight names the census shortfall" || fail "preflight: $(grep -i 'preflight' "$WORK/out")"
grep -qE "upload locales/a-en.json" "$WORK/journal" && pass "the file that fits is uploaded" || fail "a not uploaded: $(grep upload "$WORK/journal")"
grep -qE "upload locales/b-en.json" "$WORK/journal" && fail "the file over the balance was uploaded" || pass "the file over the balance is left out"
[[ -f "$R/locales/a-de.json" && -f "$R/locales/a-fr.json" ]] && pass "what completed is delivered" || fail "not delivered: $(find "$R/locales" -type f | sort)"
grep -q "limit-note<<" "$WORK/gh_out" 2>/dev/null && grep -q "left out: locales/b-en.json" "$WORK/gh_out" \
    && pass "the pull request body note names the limit and the files left out" || fail "gh output: $(cat "$WORK/gh_out" 2>/dev/null)"

echo
echo "Total: $((passed + failed))  Passed: $passed  Failed: $failed"
[[ $failed -eq 0 ]]
