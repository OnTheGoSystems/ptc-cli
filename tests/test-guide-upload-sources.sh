#!/bin/bash
# L12 (SF-33; Eran 2026-10-08; specs/agent-guide AGD-1, AGD-4; specs/cli-client) against the mock: on the API channel
# `ptc guide upload-sources TASK_ID` sends the census source files PTC does not hold yet through the doors `ptc sync`
# uses (POST source_files, then PUT source_files/process with translate=false: stored, nothing translated), skips a file PTC holds at the same sha256,
# prints what it uploaded (count, bytes), and submits the task. In CI it uploads nothing (the job uploads).
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; [[ -n "${KEEP:-}" ]] || rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {  # start_mock NAME PORT [ENV=VALUE...] -> API_<NAME>, bodies in $WORK/bodies-NAME, journal $WORK/journal-NAME
    local name="$1" port="$2" i; shift 2
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && { echo "port $port busy"; exit 1; }
    mkdir -p "$WORK/bodies-$name"
    env "$@" PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$WORK/bodies-$name" PTC_MOCK_LOG="$WORK/journal-$name" python3 "$MOCK" >>"$WORK/mock-$name.log" 2>&1 &
    PIDS+=("$!")
    for i in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
    printf -v "API_$name" 'http://127.0.0.1:%s/api/v1/' "$port"
}
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_API_TOKEN)

make_tree() {  # make_tree DIR -> two configured sources (no git: the API channel's folder), guide project 42
    local t="$1"; mkdir -p "$t/locales" "$t/admin"
    printf '{"greeting": "Hello", "farewell": "Goodbye"}\n' > "$t/locales/en.json"
    printf '{"save": "Save"}\n' > "$t/admin/en.json"
    cat > "$t/.ptc-config.yml" <<'YML'
source_locale: en
files:
  - file: locales/en.json
    output: locales/{{lang}}.json
  - file: admin/en.json
    output: admin/{{lang}}.json
guide:
  project_id: 42
YML
}
uploads() { grep -c "     upload " "$1" 2>/dev/null || true; }

T="$WORK/api"; make_tree "$T"
held_sha=$(sha256sum "$T/admin/en.json" | cut -d' ' -f1)
en_bytes=$(wc -c < "$T/locales/en.json" | tr -d ' ')
start_mock UP 19961 PTC_MOCK_HELD_SHA="$held_sha"

echo "=== no git, API channel: the files PTC lacks are uploaded (no translation), the held one is skipped, the task submitted ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide upload-sources gt_up --session-id gs_upload --api-url "$API_UP" -d "$T" >"$WORK/up.out" 2>"$WORK/up.err"
rc=$?
[[ $rc -eq 0 ]] && pass "upload-sources exits 0" || fail "upload-sources exit $rc: $(cat "$WORK/up.out" "$WORK/up.err")"
grep -q "     upload locales/en.json -> output locales/{{lang}}.json" "$WORK/journal-UP" && pass "locales/en.json is uploaded through POST source_files with its output pattern" || fail "no upload of locales/en.json: $(cat "$WORK/journal-UP")"
grep -q "upload admin/en.json" "$WORK/journal-UP" && fail "admin/en.json (held at the same sha256) was uploaded again" || pass "admin/en.json, held at the same sha256, is not uploaded again"
grep -q "     process locales/en.json translate=false" "$WORK/journal-UP" && pass "its bytes are stored through the process door with translate=false" || fail "no store-only process: $(cat "$WORK/journal-UP")"
grep -q "translate=default\|translate=true" "$WORK/journal-UP" && fail "upload-sources asked PTC to translate" || pass "nothing is translated: every process call says translate=false"
grep -q "process admin/en.json" "$WORK/journal-UP" && fail "admin/en.json was stored again" || pass "admin/en.json is not stored again either"
grep -qF "Uploaded 1 source file(s), $en_bytes bytes, to PTC (nothing translated); 1 already held at the same sha256." "$WORK/up.out" \
    && pass "prints what it uploaded (count, bytes) and what PTC already held" || fail "summary: $(cat "$WORK/up.out")"
grep -qF "locales/en.json ($en_bytes bytes)" "$WORK/up.out" && pass "names each uploaded file with its bytes" || fail "per-file line: $(cat "$WORK/up.out")"
python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; sys.exit(0 if d['task_id']=='gt_up' and d['evidence']=={'uploaded':1,'bytes':int(sys.argv[2])} else 1)" "$WORK/bodies-UP/guide_submit.json" "$en_bytes" \
    && pass "submits the task with {uploaded, bytes}" || fail "submit body: $(cat "$WORK/bodies-UP/guide_submit.json" 2>/dev/null)"
grep -q "accepted" "$WORK/up.out" && pass "prints PTC's verdict" || fail "no verdict printed: $(cat "$WORK/up.out")"

echo "=== rerun without a task id (any point of setup): only the files whose sha256 changed, nothing submitted ==="
before=$(uploads "$WORK/journal-UP"); submits=$(grep -c "guide/submit" "$WORK/journal-UP")
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide upload-sources --session-id gs_upload --api-url "$API_UP" -d "$T" >"$WORK/re0.out" 2>&1
rc=$?
[[ $rc -eq 0 && "$(uploads "$WORK/journal-UP")" == "$before" ]] && pass "a rerun with nothing changed uploads nothing and exits 0" || fail "unchanged rerun: rc=$rc $(cat "$WORK/re0.out")"
grep -qF "Uploaded 0 source file(s), 0 bytes, to PTC (nothing translated); 2 already held at the same sha256." "$WORK/re0.out" && pass "says both files are held" || fail "unchanged summary: $(cat "$WORK/re0.out")"
printf '{"greeting": "Hello there", "farewell": "Goodbye"}\n' > "$T/locales/en.json"   # a source fix edits the file
new_bytes=$(wc -c < "$T/locales/en.json" | tr -d ' ')
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide upload-sources --session-id gs_upload --api-url "$API_UP" -d "$T" >"$WORK/re1.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "the rerun after an edit exits 0" || fail "edit rerun rc=$rc: $(cat "$WORK/re1.out")"
[[ $(( $(uploads "$WORK/journal-UP") - before )) -eq 1 ]] && pass "the rerun uploads exactly one file" || fail "edit rerun uploads: $(cat "$WORK/journal-UP")"
[[ $(grep -c "     process locales/en.json translate=false" "$WORK/journal-UP") -eq 2 ]] && pass "the edited file is stored again with translate=false" || fail "no second store-only process"
grep -q "upload admin/en.json\|process admin/en.json" "$WORK/journal-UP" && fail "the unchanged admin/en.json was sent on the rerun" || pass "the unchanged file is not sent"
grep -q "translate=default\|translate=true" "$WORK/journal-UP" && fail "a rerun asked PTC to translate" || pass "the rerun translates nothing"
grep -qF "Uploaded 1 source file(s), $new_bytes bytes, to PTC (nothing translated); 1 already held at the same sha256." "$WORK/re1.out" && pass "the rerun prints what it uploaded" || fail "rerun summary: $(cat "$WORK/re1.out")"
[[ "$(grep -c "guide/submit" "$WORK/journal-UP")" == "$submits" ]] && pass "a rerun submits no task" || fail "a rerun submitted a task"

echo "=== in CI: nothing uploaded, nothing submitted (the job uploads) ==="
T2="$WORK/ci"; make_tree "$T2"
start_mock CI 19971
"${NOCI[@]}" GITLAB_CI=true PTC_ORG_TOKEN=org-token "$CLI" guide upload-sources gt_up --session-id gs_upload --api-url "$API_CI" -d "$T2" >"$WORK/ci.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "upload-sources in CI exits 0" || fail "CI exit $rc: $(cat "$WORK/ci.out")"
[[ "$(uploads "$WORK/journal-CI")" == "0" ]] && pass "in CI no source file is uploaded" || fail "CI uploaded: $(cat "$WORK/journal-CI")"
[[ -f "$WORK/bodies-CI/guide_submit.json" ]] && fail "in CI the task was submitted" || pass "in CI nothing is submitted"
grep -qF "In CI the job uploads the source files; nothing uploaded here." "$WORK/ci.out" && pass "says why in CI" || fail "CI text: $(cat "$WORK/ci.out")"

echo "=== a task that is not the current one: refused with the remedy, nothing uploaded ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide upload-sources gt_other --session-id gs_upload --api-url "$API_UP" -d "$T" >"$WORK/other.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q "does not list gt_other as the current task" "$WORK/other.out" && pass "a task that is not current is refused" || fail "other: rc=$rc $(cat "$WORK/other.out")"

cmp -s "$CLI" "$(dirname "$(dirname "$TEST_DIR")")/action/ptc-cli.sh" && pass "cli/ptc-cli.sh and action/ptc-cli.sh are byte-identical" || fail "cli and action copies differ"

echo
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
