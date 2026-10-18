#!/bin/bash
# L16 (SF-50; production org 2372, GitHub job 113571080321 with ptc-cli 1.4.0, 2026-10-09): the CI run of an EMPTY commit on
# a shallow checkout reported no hash for the two files a source fix had changed (the diff-tree of an empty commit is empty,
# origin/<default> is absent, and the action has no .ptc/session.json), and PTC called them "differs". `ptc guide action-run`
# now asks PTC which paths to hash (GET guide/run_paths: the paths setup verified and the open source-fix tasks name) and
# hashes exactly those on top of its diff; a server without the door changes nothing. Runs against the mock.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); BODIES="$WORK/bodies"; mkdir -p "$BODIES"
MOCK_PID=""
cleanup() { [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; [[ -n "${KEEP:-}" ]] && cp "$WORK/mock.log" "$KEEP"; rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {
    [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }
    rm -f "$BODIES"/*
    env "$@" PTC_MOCK_PORT=$PORT PTC_MOCK_BODY_DIR="$BODIES" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
    MOCK_PID=$!
    for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
}

PORT=19886
python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && { echo "port $PORT busy"; exit 1; }
API="http://127.0.0.1:$PORT/api/v1/"
body() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print($1)" "$BODIES/guide_action_runs.json" 2>/dev/null; }

# A repository whose source fix (app/js/trace.js) was committed earlier, then an EMPTY commit on top (the production run).
T="$WORK/repo"; mkdir -p "$T/locales" "$T/app/js"
git -C "$T" init -q -b feature/ptc-setup && git -C "$T" config user.email t@example.com && git -C "$T" config user.name t
printf '{"hello": "Hello"}\n' > "$T/locales/en.json"
printf 'const n = value.toLocaleString(locale);\n' > "$T/app/js/trace.js"
cat > "$T/.ptc-config.yml" <<'YML'
source_locale: en
files:
  - file: locales/en.json
    output: locales/{{lang}}.json
guide:
  project_id: 42
YML
git -C "$T" add -A && git -C "$T" commit -qm "source fix + config"
git -C "$T" commit -q --allow-empty -m "empty: re-run CI"
want=$(git -C "$T" cat-file blob HEAD:app/js/trace.js | sha256sum | cut -d' ' -f1)
CIENV=(env -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME
       GITHUB_ACTIONS=true CI=true GITHUB_SHA="$(git -C "$T" rev-parse HEAD)" GITHUB_REF_NAME=feature/ptc-setup PTC_API_TOKEN=agent-token)

echo "=== CI run of an empty commit; PTC names the verified path ==="
start_mock PTC_MOCK_RUN_PATHS=app/js/trace.js
(cd "$T" && "${CIENV[@]}" "$CLI" guide action-run --api-url "$API" --config-file .ptc-config.yml >"$WORK/ar1.out" 2>&1)
rc=$?
[[ $rc -eq 0 ]] && pass "the run is reported (exit 0)" || fail "action-run exit $rc: $(tail -5 "$WORK/ar1.out")"
grep -q "GET  /guide/run_paths" "$WORK/mock.log" 2>/dev/null || grep -q "guide/run_paths" "$WORK/mock.log" \
  && pass "the run asked PTC which paths to hash (GET guide/run_paths)" || fail "no GET guide/run_paths in the mock journal"
[[ "$(body "d['files_sha'].get('app/js/trace.js')")" == "$want" ]] \
  && pass "files_sha carries the path PTC named, at the committed blob's sha256, though the commit's diff is empty" \
  || fail "files_sha[app/js/trace.js]: '$(body "d['files_sha'].get('app/js/trace.js')")' want $want; keys $(body "sorted(d['files_sha'])")"

echo "=== a server without the door: nothing changes ==="
start_mock
(cd "$T" && "${CIENV[@]}" "$CLI" guide action-run --api-url "$API" --config-file .ptc-config.yml >"$WORK/ar2.out" 2>&1)
rc=$?
[[ $rc -eq 0 ]] && pass "the run is still reported when PTC has no run_paths door (exit 0)" || fail "action-run exit $rc: $(tail -5 "$WORK/ar2.out")"
[[ "$(body "'app/js/trace.js' in d['files_sha']")" == "False" ]] \
  && pass "without PTC's list the run hashes only its own diff and census, as before" \
  || fail "files_sha unexpectedly carries app/js/trace.js: $(body "sorted(d['files_sha'])")"

echo
echo "passed: $passed, failed: $failed"
[[ $failed -eq 0 ]]
