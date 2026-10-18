#!/bin/bash
# GAP-G6 (WPML lab run 4, staging 8980e6d9c; CLI-16, POL-116): the suite's GitLab job runs `cd <product>` then
# `ptc guide action-run --config-file .ptc-config.yml` in a checkout with no .ptc/session.json and no project in the
# environment. PTC answered gt_418 with "<path> was not reported by the CI run", and the job log said nothing about which
# project the run asked for its paths, or whether PTC answered. The run resolves its project from the environment,
# --project-id, the config's guide.project_id, then .ptc/session.json, and prints ONE line naming the project, where it
# came from and the served / named path counts; a PTC that gives no list, or no project at all, is a warning in the log.
# Runs against the mock.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); BODIES="$WORK/bodies"; mkdir -p "$BODIES"
MOCK_PID=""
cleanup() { [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {
    [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }
    rm -f "$BODIES"/*; : > "$WORK/mock.log"
    env "$@" PTC_MOCK_PORT=$PORT PTC_MOCK_BODY_DIR="$BODIES" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
    MOCK_PID=$!
    for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
}

PORT=19897
python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && { echo "port $PORT busy"; exit 1; }
API="http://127.0.0.1:$PORT/api/v1/"
body() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print($1)" "$BODIES/guide_action_runs.json" 2>/dev/null; }

# A suite: the product lives in prod/, its config is the hand-out (guide.project_id), and PTC verified two of its files.
T="$WORK/repo"; P="$T/prod"; mkdir -p "$P/locales" "$P/inc"
git -C "$T" init -q -b main && git -C "$T" config user.email t@example.com && git -C "$T" config user.name t
printf '{"hello": "Hello"}\n' > "$P/locales/en.json"
printf '<?php echo __("Hello", "prod");\n' > "$P/inc/a.php"
cat > "$P/.ptc-config.yml" <<'YML'
source_locale: en
files:
  - file: locales/en.json
    output: locales/{{lang}}.json
guide:
  session_id: 35
  project_id: 3565
YML
git -C "$T" add -A && git -C "$T" commit -qm "suite product + config"
want=$(sha256sum "$P/inc/a.php" | cut -d' ' -f1)
# The GitLab job's environment: no session file, no project id, an agent token, no identity token.
CIENV=(env -u PTC_PROJECT_ID -u PTC_GUIDE_PROJECT_ID -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u GITHUB_ACTIONS -u GITHUB_SHA -u GITHUB_REF_NAME
       -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_ACTION_RUN_FILES
       GITLAB_CI=true CI=true CI_COMMIT_SHA="$(git -C "$T" rev-parse HEAD)" CI_COMMIT_REF_NAME=main PTC_API_TOKEN=agent-token)
run() { (cd "$P" && "${CIENV[@]}" "$CLI" guide action-run --api-url "$API" --config-file .ptc-config.yml >"$WORK/$1" 2>&1); }

echo "=== suite GitLab job: no session file, no env; the project comes from the config ==="
start_mock PTC_MOCK_RUN_PATHS=prod/inc/a.php,prod/locales/en.json
run ar1.out; rc=$?
[[ $rc -eq 0 ]] && pass "the run is reported (exit 0)" || fail "action-run exit $rc: $(tail -5 "$WORK/ar1.out")"
grep -q "/guide/run_paths  q={'project_id': '3565'}" "$WORK/mock.log" \
  && pass "the run asked PTC which paths to hash for project 3565" || fail "no GET guide/run_paths?project_id=3565: $(grep run_paths "$WORK/mock.log")"
[[ "$(body "d['files_sha'].get('prod/inc/a.php')")" == "$want" ]] \
  && pass "files_sha carries the served path at its sha256" || fail "files_sha keys: $(body "sorted(d['files_sha'])")"
grep -qF "guide run paths: project 3565 (guide.project_id of .ptc-config.yml), 2 path(s) served by PTC, 2 named in all." "$WORK/ar1.out" \
  && pass "the job log names the project, its source and the served / named counts" || fail "no run-paths line: $(cat "$WORK/ar1.out")"
[[ $(grep -c "guide run paths:" "$WORK/ar1.out") -eq 1 ]] && pass "exactly one run-paths line" || fail "run-paths lines: $(grep -c "guide run paths:" "$WORK/ar1.out")"

echo "=== a config without a guide: block: the project comes from .ptc/session.json ==="
cp "$P/.ptc-config.yml" "$WORK/cfg.keep"
head -4 "$WORK/cfg.keep" > "$P/.ptc-config.yml"
mkdir -p "$P/.ptc" && printf '{"session_id": 9, "project_id": "77"}\n' > "$P/.ptc/session.json"
start_mock PTC_MOCK_RUN_PATHS=prod/inc/a.php
run ar2.out
grep -q "/guide/run_paths  q={'project_id': '77'}" "$WORK/mock.log" \
  && pass "the run asked PTC for project 77's paths (.ptc/session.json)" || fail "no GET guide/run_paths?project_id=77: $(grep run_paths "$WORK/mock.log")"
grep -qF "guide run paths: project 77 (.ptc/session.json), 1 path(s) served by PTC, 1 named in all." "$WORK/ar2.out" \
  && pass "the log line names the session file as the source" || fail "no run-paths line: $(cat "$WORK/ar2.out")"

echo "=== no project anywhere: the log says PTC was not asked ==="
rm -rf "$P/.ptc"
start_mock PTC_MOCK_RUN_PATHS=prod/inc/a.php
run ar3.out
! grep -q "run_paths" "$WORK/mock.log" && pass "no project, no run_paths request" || fail "run_paths asked without a project"
grep -qF "guide run paths: no project named, so PTC was not asked which paths to hash; 0 named in all." "$WORK/ar3.out" \
  && pass "the log says no project was named" || fail "no no-project line: $(cat "$WORK/ar3.out")"
cp "$WORK/cfg.keep" "$P/.ptc-config.yml"

echo "=== PTC cannot list the paths (HTTP 500): a warning, the run still reported ==="
start_mock PTC_MOCK_RUN_PATHS=prod/inc/a.php PTC_MOCK_RUN_PATHS_STATUS=500
run ar4.out; rc=$?
[[ $rc -eq 0 ]] && pass "the run is still reported (exit 0)" || fail "action-run exit $rc: $(tail -5 "$WORK/ar4.out")"
grep -qF "[WARNING]" "$WORK/ar4.out" && grep -qF "guide run paths: project 3565 (guide.project_id of .ptc-config.yml), PTC's path list unavailable (HTTP 500), 0 path(s) served by PTC, 0 named in all." "$WORK/ar4.out" \
  && pass "the job log warns that PTC gave no path list, with its HTTP code" || fail "no unavailable line: $(cat "$WORK/ar4.out")"

echo
echo "passed: $passed, failed: $failed"
[[ $failed -eq 0 ]]
