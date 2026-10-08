#!/bin/bash
# S2-R29-1 (SF-11; specs/api-cli/SPEC.md API-13): the per-file download door builds the archive in the background and
# answers 202 + Retry-After until it is current, even for a file whose translation already reads completed. The CLI keeps
# such a file in its monitoring loop and downloads it on the next poll: the file is written and the run exits 0.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
PID=""
cleanup() { [[ -n "$PID" ]] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT

API=""
for port in 19641 19651 19661; do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && continue
    PTC_MOCK_PORT="$port" PTC_MOCK_DOWNLOAD_BUILDING_ONCE=config/locales/a.en.yml PTC_MOCK_LOG="$WORK/mock.journal" \
        python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
    PID=$!
    for _ in $(seq 1 30); do
        if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null; then
            API="http://127.0.0.1:$port/api/v1/"; break 2
        fi
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.3
    done
    kill "$PID" 2>/dev/null; PID=""
done
[[ -n "$API" ]] || { echo "mock did not come up"; exit 1; }

R="$WORK/repo"; mkdir -p "$R/config/locales"
printf 'en:\n  a: "Hello a"\n' > "$R/config/locales/a.en.yml"
printf 'source_locale: en\nfiles:\n  - file: config/locales/a.en.yml\n    output: config/locales/a.{{lang}}.yml\n' > "$R/.ptc-config.yml"
git -C "$R" init -q

echo "=== a completed file whose archive is still being built: 202 first, then the zip ==="
( cd "$R" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 20 ) >"$WORK/run.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "the run exits 0" || fail "the run exited $rc"
[[ -f "$R/config/locales/a.de.yml" && -f "$R/config/locales/a.fr.yml" ]] && pass "the file's translations are on disk" || fail "a.de.yml / a.fr.yml missing"
grep -qF "202 archive building for config/locales/a.en.yml" "$WORK/mock.journal" && pass "the first download was answered 202" || fail "the mock never answered 202"
grep -qF "still being prepared" "$WORK/run.out" && pass "the CLI says the archive is still being prepared and retries" || fail "no retry message"
if grep -qiE "failed to download" "$WORK/run.out"; then fail "the 202 was reported as a download failure"; else pass "the 202 is not a download failure"; fi

echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
