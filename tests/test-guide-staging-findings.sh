#!/bin/bash
# L8 (staging findings, POL-116) against the mock:
#  SF-18 `ptc guide start` for a token acting in several organizations: PTC's "which organization" answer is printed as a
#        list with the --organization-id remedy (no traceback); --organization-id rides in POST /projects.
#  SF-22 without git, `ptc guide action-run` carries the files a guide task named (and each --file) with their sha256 and
#        content, and the workspace fingerprint covers them: an edit to a named code file gives a new run key.
#  SF-23 `ptc guide action-run` prints the run_key.
#  SF-24 an ask_human whose options are objects is rendered as a readable list, never as Python dicts.
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

PORT=19787
python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && { echo "port $PORT busy"; exit 1; }
PTC_MOCK_PORT=$PORT PTC_MOCK_BODY_DIR="$BODIES" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
API="http://127.0.0.1:$PORT/api/v1/"
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN)
body() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print($1)" "$BODIES/$2.json" 2>/dev/null; }

echo "=== SF-18: guide start, token acting in several organizations ==="
P="$WORK/plain"; mkdir -p "$P"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide start --repo-url https://example.test/multi-org.git --branch main --api-url "$API" -d "$P" >"$WORK/start.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && pass "no organization named -> non-zero exit" || fail "start exit $rc"
grep -q "Traceback\|KeyError" "$WORK/start.out" && fail "a Python traceback: $(cat "$WORK/start.out")" || pass "no Python traceback"
grep -q "1021  Acme Trial" "$WORK/start.out" && grep -q "1023  Acme Paid" "$WORK/start.out" \
    && pass "the organizations are listed one per line (id, name)" || fail "organization list: $(cat "$WORK/start.out")"
grep -q -- "--organization-id ID" "$WORK/start.out" && grep -qi "ask the human which one" "$WORK/start.out" \
    && pass "the remedy names --organization-id and asking the human" || fail "remedy: $(cat "$WORK/start.out")"
[[ ! -f "$BODIES/guide_sessions.json" ]] && pass "no session is opened without a project" || fail "a session was opened"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide start --organization-id 1023 --repo-url https://example.test/multi-org.git --branch main --api-url "$API" -d "$P" >"$WORK/start2.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "--organization-id -> the project is created and the session opened (exit 0)" || fail "start --organization-id exit $rc: $(cat "$WORK/start2.out")"
[[ "$(body "d.get('organization_id')" projects)" == "1023" ]] && pass "POST /projects carries organization_id" || fail "projects body: $(body "d" projects)"
grep -q "Created PTC project 42" "$WORK/start2.out" && pass "the created project is named" || fail "start2: $(cat "$WORK/start2.out")"
"$CLI" guide --help 2>&1 | grep -q -- "--organization-id" && pass "guide --help names --organization-id" || fail "help lacks --organization-id"

echo "=== SF-24: ask_human options that are objects ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_named --api-url "$API" -d "$P" >"$WORK/next.out" 2>&1
grep -q "{'id'" "$WORK/next.out" && fail "options rendered as Python dicts: $(cat "$WORK/next.out")" || pass "no Python dict in the options"
grep -q -- "- \`ci\`: Add CI (not available: no git host)" "$WORK/next.out" && grep -q -- "- \`api\`: Deliver over the API" "$WORK/next.out" \
    && pass "each option is one readable line (id, label, why not available)" || fail "options: $(cat "$WORK/next.out")"

echo "=== SF-22 + SF-23: action-run without git carries the files the task named ==="
T="$WORK/tree"; mkdir -p "$T/config/locales" "$T/app" "$T/.ptc"
printf 'en:\n  hello: "Hello"\n' > "$T/config/locales/en.yml"
printf 'const a = 1;\nconst n = count + " files";\n' > "$T/app/files_import.js"
printf 'export const t = 1;\n' > "$T/app/trace.js"
printf 'never named\n' > "$T/app/other.js"
cat > "$T/.ptc-config.yml" <<'YML'
source_locale: en
files:
  - file: config/locales/en.yml
    output: config/locales/{{lang}}.yml
guide:
  project_id: 42
YML
# The task reaches the agent through the CLI: guide next records the paths it names in .ptc/session.json.
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_named --api-url "$API" -d "$T" >/dev/null 2>&1
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" >"$WORK/ar1.out" 2>"$WORK/ar1.err"
rc=$?
[[ $rc -eq 0 ]] && pass "the run is reported (exit 0)" || fail "action-run exit $rc: $(cat "$WORK/ar1.out" "$WORK/ar1.err")"
fp1=$(body "d.get('workspace_fingerprint')" guide_action_runs)
grep -qx "run_key: fp:$fp1" "$WORK/ar1.out" && pass "SF-23: stdout prints run_key: fp:<fingerprint>" || fail "SF-23 run_key line: $(cat "$WORK/ar1.out")"
for f in app/files_import.js app/trace.js; do
    want=$(sha256sum "$T/$f" | cut -d' ' -f1)
    [[ "$(body "d['files_sha'].get('$f')" guide_action_runs)" == "$want" ]] && pass "files_sha[$f] = sha256sum of the bytes on disk" || fail "files_sha[$f]: $(body "sorted(d['files_sha'])" guide_action_runs)"
    [[ "$(body "d['files_sample'].get('$f') == open('$T/$f').read()" guide_action_runs)" == "True" ]] && pass "files_sample carries the copy of $f" || fail "no copy of $f"
done
[[ "$(body "'app/other.js' in d['files_sha'] or 'app/other.js' in d['files_sample']" guide_action_runs)" == "False" ]] && pass "a file no task named is not sent" || fail "app/other.js was sent"
"$CLI" scan --json -d "$T" -c "$T/.ptc-config.yml" > "$WORK/scan.json" 2>/dev/null
fps=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['repo']['workspace_fingerprint'])" "$WORK/scan.json")
[[ "$fp1" =~ ^[0-9a-f]{64}$ && "$fp1" != "$fps" ]] && pass "the fingerprint covers the named files (differs from ptc scan's resources-only value)" || fail "fingerprint $fp1 vs scan $fps"
printf 'const a = 1;\nconst n = t("%%d files", count);\n' > "$T/app/files_import.js"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" >"$WORK/ar2.out" 2>/dev/null
fp2=$(body "d.get('workspace_fingerprint')" guide_action_runs)
[[ "$fp2" =~ ^[0-9a-f]{64}$ && "$fp2" != "$fp1" ]] && pass "an edit to a named code file -> a new fingerprint (a new run key)" || fail "fingerprint unchanged after the edit: $fp1 / $fp2"
want=$(sha256sum "$T/app/files_import.js" | cut -d' ' -f1)
[[ "$(body "d['files_sha'].get('app/files_import.js')" guide_action_runs)" == "$want" ]] && pass "the edited file's new digest is reported" || fail "edited digest"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" >/dev/null 2>&1
[[ "$(body "d.get('workspace_fingerprint')" guide_action_runs)" == "$fp2" ]] && pass "same tree twice -> same fingerprint" || fail "fingerprint not stable"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --file app/other.js --file ../escape.js --api-url "$API" -d "$T" >/dev/null 2>&1
[[ "$(body "'app/other.js' in d['files_sample'] and '../escape.js' not in d['files_sha']" guide_action_runs)" == "True" ]] \
    && pass "--file adds a file; a path leaving the tree is ignored" || fail "--file: $(body "sorted(d['files_sha'])" guide_action_runs)"

echo "=== with git: a committed named file keeps the commit's digest ==="
G="$WORK/git"; cp -r "$T" "$G"; git -C "$G" init -q && git -C "$G" add -A && git -C "$G" -c user.email=t@example.com -c user.name=t commit -qm init
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$G" >"$WORK/ar3.out" 2>/dev/null
head=$(git -C "$G" rev-parse HEAD)
[[ "$(body "d.get('commit_sha')" guide_action_runs)" == "$head" ]] && grep -qx "run_key: $head" "$WORK/ar3.out" \
    && pass "with git the run key is the commit sha, printed" || fail "git run_key: $(cat "$WORK/ar3.out")"

echo ""
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
