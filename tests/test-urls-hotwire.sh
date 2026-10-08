#!/bin/bash
# SF-5 (ptc-mcp's agent walk on staging, 2026-10-07; docs/corpus/specs/cli-client/SPEC.md): every PTC page URL the CLI
# prints is the Hotwire route. The monitor-bound summary's "project page" hint (option (b)) prints
# <host>/dashboard/projects/<id> (the Hotwire project tab, backend/config/routes.rb `hotwire_dashboard_project_tab`), never
# the legacy SPA hash route <host>/#/dashboard/projects/<id>; test-monitor-bound.sh asserts the same URL.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
MOCK_PID=""
suite_cleanup() { [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap suite_cleanup EXIT

echo "=== the CLI source prints no SPA hash route ==="
if grep -n '/#/' "$CLI" >"$WORK/hash-routes.txt"; then
    fail "ptc-cli.sh prints a /#/ route: $(tr '\n' ' ' <"$WORK/hash-routes.txt")"
else
    pass "no /#/ route in ptc-cli.sh"
fi

echo "=== the monitor-bound summary names the Hotwire project page ==="
API=""
for port in 19811 19821 19831; do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && continue
    PTC_MOCK_PORT="$port" PTC_MOCK_STILL_TRANSLATING=config/locales/b.en.yml PTC_MOCK_BODY_DIR="$WORK/bodies" \
        python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
    MOCK_PID=$!
    for _ in $(seq 1 30); do
        if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null; then
            API="http://127.0.0.1:$port/api/v1/"; break 2
        fi
        kill -0 "$MOCK_PID" 2>/dev/null || break
        sleep 0.3
    done
    kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""
done
[[ -n "$API" ]] || { echo "mock did not come up"; exit 1; }
mkdir -p "$WORK/bodies"

R="$WORK/repo"; mkdir -p "$R/config/locales"
for n in a b; do printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$R/config/locales/$n.en.yml"; done
{
  echo "source_locale: en"
  echo "guide:"
  echo "  project_id: 42"
  echo "files:"
  for n in a b; do printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n"; done
} > "$R/.ptc-config.yml"
git -C "$R" init -q
( cd "$R" && PTC_MONITOR_MAX_SECONDS=3 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 100 ) >"$WORK/out" 2>&1
host="${API%%/api/*}"
if grep -qF "the project page: ${host}/dashboard/projects/42" "$WORK/out"; then pass "project page is ${host}/dashboard/projects/42"; else fail "project page hint is not the Hotwire route"; fi
if grep -qF '/#/' "$WORK/out"; then fail "the run printed a /#/ URL: $(grep -F '/#/' "$WORK/out" | head -3 | tr '\n' ' ')"; else pass "the run printed no /#/ URL"; fi

echo
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
