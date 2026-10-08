#!/bin/bash
# A mock launcher must observe its OWN server. With a stale listener on the mock's port, the launched mock
# cannot bind and dies, while the port still answers - so the probe must refuse a busy port loudly before
# starting anything, instead of running the suite against whatever is listening there.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); DUMMY=""
cleanup() { [[ -n "$DUMMY" ]] && kill "$DUMMY" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

port=19511   # test-limit.sh's literal port
# A dummy that accepts and closes, like the stale mock would answer a connect but never our requests.
python3 -c "
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', $port)); s.listen(5)
while True:
    c, _ = s.accept(); c.close()
" & DUMMY=$!
for i in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
kill -0 "$DUMMY" 2>/dev/null || { echo "the dummy listener did not come up on $port" >&2; exit 1; }

timeout 120 bash "$TEST_DIR/test-limit.sh" >"$WORK/out" 2>"$WORK/err"; rc=$?
[[ $rc -ne 0 ]] && pass "a launcher facing a busy port exits non-zero (rc $rc)" || fail "launcher exited 0 against a busy port"
grep -qF "port $port already in use: a stale mock_ptc_api.py?" "$WORK/err" \
    && pass "and says so on stderr, naming the port" || fail "no refusal line on stderr; stderr was: $(head -c 400 "$WORK/err")"
! grep -q '^\[PASS\]' "$WORK/out" && pass "no check ran against the stranger's listener" \
    || fail "checks ran against the busy port: $(grep -c '^\[PASS\]' "$WORK/out") passes"

echo "passed=$passed failed=$failed"; [[ $failed -eq 0 ]]
