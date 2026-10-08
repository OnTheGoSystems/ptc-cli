#!/bin/bash
# L3-2 (POL-116, API-33): `ptc sync` is the CI job run locally: (1) guide action-run, (2) guide check as the job runs it,
# (3) the full translate workflow writing the configured outputs, (4) guide delivery-commit with NO branch and no commit:
# the workspace fingerprint and the sha256 of exactly the files this run wrote. Exit codes and final lines are the job's
# (0 delivered, 5 rejected/unreachable, 6 parked, 7 still translating); --json prints {run_id, uploaded, delivered,
# parked, rejected, delivery_commit}; --dry-run reports the run and the plan and moves no bytes. Runs against the mock.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {  # start_mock NAME PORT [ENV=VALUE...] -> API_<NAME>, BODIES_<NAME>, JOURNAL_<NAME>
    local name="$1" port="$2" i; shift 2
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && { echo "port $port busy"; exit 1; }
    mkdir -p "$WORK/bodies-$name"
    env "$@" PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$WORK/bodies-$name" PTC_MOCK_LOG="$WORK/journal-$name" python3 "$MOCK" >>"$WORK/mock-$name.log" 2>&1 &
    PIDS+=("$!")
    for i in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
    printf -v "API_$name" 'http://127.0.0.1:%s/api/v1/' "$port"
}

NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_API_TOKEN)

make_tree() {  # make_tree DIR [git] -> two configured sources, guide project 42
    local t="$1"; mkdir -p "$t/locales" "$t/admin"
    printf '{"greeting": "Hello", "farewell": "Goodbye"}\n' > "$t/locales/en.json"
    printf '{"save": "Save"}\n' > "$t/admin/en.json"
    cat > "$t/.ptc-config.yml" <<'YML'
source_locale: en
monitor_interval: 1
files:
  - file: locales/en.json
    output: locales/{{lang}}.json
  - file: admin/en.json
    output: admin/{{lang}}.json
guide:
  project_id: 42
  session_id: gs_pass
YML
    if [[ "${2:-}" == git ]]; then
        git -C "$t" init -q -b main && git -C "$t" add -A && git -C "$t" -c user.email=t@t -c user.name=t commit -qm init
    fi
}
dc() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print($2)" "$1/guide_delivery_commits.json" 2>/dev/null; }

start_mock OK 19851
start_mock REJ 19861 PTC_MOCK_REJECT_PROCESS=admin/en.json
start_mock PARK 19871 PTC_MOCK_OUT_OF_CREDIT=admin/en.json
start_mock DRY 19881

echo "=== happy path: exit 0, the branch-less delivery report lists exactly the written files ==="
T="$WORK/ok"; make_tree "$T" git
head=$(git -C "$T" rev-parse HEAD)
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_OK" -d "$T" --json >"$WORK/ok.json" 2>"$WORK/ok.err"; rc=$?
[[ $rc -eq 0 ]] && pass "sync -> exit 0" || fail "sync exit $rc: $(tail -5 "$WORK/ok.err")"
order=$(grep -oE "POST /guide/action_runs|POST /guide/check|POST /source_files |PUT  /source_files/process|GET  /source_files/download_translations|POST /guide/delivery_commits" "$WORK/journal-OK" | awk '!seen[$0]++' | tr '\n' '|')
[[ "$order" == "POST /guide/action_runs|POST /guide/check|POST /source_files |PUT  /source_files/process|GET  /source_files/download_translations|POST /guide/delivery_commits|" ]] \
    && pass "the job's order: action-run, check, upload, process, download, delivery-commit" || fail "order: $order"
B="$WORK/bodies-OK"
[[ "$(dc "$B" "d.get('branch')")" == "None" && "$(dc "$B" "d.get('commit_sha')")" == "None" ]] && pass "the delivery report names no branch and no commit" || fail "branch/commit: $(dc "$B" "d.get('branch'), d.get('commit_sha')")"
"$CLI" scan --json -d "$T" -c "$T/.ptc-config.yml" > "$WORK/scan.json" 2>/dev/null
fp=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['repo']['workspace_fingerprint'])" "$WORK/scan.json")
[[ "$(dc "$B" "d.get('workspace_fingerprint')")" == "$fp" ]] && pass "the delivery report carries the workspace fingerprint" || fail "fingerprint: $(dc "$B" "d.get('workspace_fingerprint')") vs $fp"
want=$(cd "$T" && for f in admin/de.json admin/fr.json locales/de.json locales/fr.json; do printf '%s=%s;' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"; done)
got=$(dc "$B" "''.join('%s=%s;' % kv for kv in sorted(d['delivered_files_sha'].items()))")
[[ -n "$got" && "$got" == "$want" ]] && pass "delivered_files_sha = sha256sum of exactly the four written files" || fail "delivered_files_sha: '$got' want '$want'"
[[ "$(dc "$B" "d.get('source_commit_sha')")" == "$head" && "$(dc "$B" "d.get('provenance_request')")" == "agent_local" ]] \
    && pass "agent-local report with the source commit git has" || fail "source/provenance: $(dc "$B" "d.get('source_commit_sha'), d.get('provenance_request')")"
python3 - "$WORK/ok.json" <<'PY' && pass "--json: {run_id, uploaded, delivered, parked, rejected, delivery_commit} = 1, 2, 4, 0, 0, the report's answer" || fail "--json: $(cat "$WORK/ok.json")"
import json, sys
d = json.load(open(sys.argv[1]))
assert sorted(d) == ["delivered", "delivery_commit", "parked", "rejected", "run_id", "uploaded"], sorted(d)
assert (d["run_id"], d["uploaded"], d["delivered"], d["parked"], d["rejected"]) == (1, 2, 4, 0, 0), d
assert d["delivery_commit"]["reported"] == 4, d["delivery_commit"]
PY
grep -q "Reported the 4 files this run wrote to PTC" "$WORK/ok.err" && pass "the delivery report is acknowledged in the log" || fail "log: $(grep -i report "$WORK/ok.err")"

echo "=== a rejected file -> exit 5, the job's final line; the rest is delivered and reported ==="
T="$WORK/rej"; make_tree "$T" git
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_REJ" -d "$T" >"$WORK/rej.out" 2>"$WORK/rej.err"; rc=$?
[[ $rc -eq 5 ]] && pass "sync -> exit 5" || fail "rejected exit $rc"
grep -q "PTC rejected some files or could not be reached for them (see 'Rejected by PTC' / 'Could not reach PTC' above); the rest was delivered." "$WORK/rej.out" \
    && pass "the job's exit-5 line" || fail "exit-5 line: $(tail -3 "$WORK/rej.out")"
[[ "$(dc "$WORK/bodies-REJ" "sorted(d['delivered_files_sha'])")" == "['locales/de.json', 'locales/fr.json']" ]] && pass "only the written files are reported" || fail "rej report: $(dc "$WORK/bodies-REJ" "sorted(d['delivered_files_sha'])")"

echo "=== a parked file (out of credit) -> exit 6, the job's final line ==="
T="$WORK/park"; make_tree "$T"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_PARK" -d "$T" --json >"$WORK/park.json" 2>"$WORK/park.err"; rc=$?
[[ $rc -eq 6 ]] && pass "sync -> exit 6" || fail "parked exit $rc: $(tail -5 "$WORK/park.err")"
grep -q "Some files wait in PTC - parked for an over-limit approval, or paused out-of-credit (see the lists above); the rest was delivered. Approve in PTC or top up the credit, then re-run." "$WORK/park.err" \
    && pass "the job's exit-6 line (stderr under --json)" || fail "exit-6 line: $(tail -3 "$WORK/park.err")"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert (d['parked'], d['delivered']) == (1, 2), d" "$WORK/park.json" 2>/dev/null \
    && pass "--json counts the parked file" || fail "park json: $(cat "$WORK/park.json")"
[[ "$(dc "$WORK/bodies-PARK" "'commit_sha' in d and d['commit_sha'] is None and d.get('workspace_fingerprint') is not None")" == "True" ]] \
    && pass "without git: the report is keyed by the fingerprint alone" || fail "no-git report: $(dc "$WORK/bodies-PARK" "d")"

echo "=== --dry-run reports the run and the plan, moves no bytes ==="
T="$WORK/dry"; make_tree "$T" git
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_DRY" -d "$T" --dry-run --json >"$WORK/dry.json" 2>"$WORK/dry.err"; rc=$?
[[ $rc -eq 0 ]] && pass "dry run -> exit 0" || fail "dry exit $rc: $(tail -5 "$WORK/dry.err")"
grep -q "POST /guide/action_runs" "$WORK/journal-DRY" && pass "the run is reported" || fail "no action run in the dry run"
if grep -qE "POST /source_files |source_files/process|download_translations|delivery_commits" "$WORK/journal-DRY"; then fail "the dry run moved bytes: $(grep -E 'source_files|delivery' "$WORK/journal-DRY")"; else pass "no upload, process, download or delivery report"; fi
[[ -z "$(find "$T" -name 'de.json' -o -name 'fr.json')" ]] && pass "no output file written" || fail "dry run wrote files"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['dry_run'] is True and d['planned'] == 2 and d['uploaded'] == 0 and d['delivery_commit'] is None, d" "$WORK/dry.json" 2>/dev/null \
    && pass "--json: dry_run, the plan (2 files), nothing uploaded" || fail "dry json: $(cat "$WORK/dry.json")"

echo "=== L4 (POL-116): without git the check names the run by its key fp:<workspace fingerprint> ==="
start_mock NOGIT 19891
T="$WORK/nogit"; make_tree "$T"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_NOGIT" -d "$T" --json >"$WORK/nogit.json" 2>"$WORK/nogit.err"
fp=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['body'].get('workspace_fingerprint',''))" "$WORK/bodies-NOGIT/guide_action_runs.json" 2>/dev/null)
key=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print(d.get('run_key','') if 'commit_sha' not in d else 'commit:'+d['commit_sha'])" "$WORK/bodies-NOGIT/guide_check.json" 2>/dev/null)
[[ -n "$fp" && "$key" == "fp:$fp" ]] && pass "guide check sent run_key fp:<the run's fingerprint>, no commit_sha" || fail "check key '$key' (fingerprint '$fp')"
grep -q "no_session" "$WORK/nogit.err" && fail "the check still refused no_session without git" || pass "no no_session refusal without git"

echo "=== SF-22 (L8): a file a guide task named rides in the sync's run; check and report use the run's own key ==="
T="$WORK/named"; make_tree "$T"; mkdir -p "$T/.ptc" "$T/app"; printf 'const n = t("%%d files", count);\n' > "$T/app/x.js"
printf '{"session_id": 5, "project_id": 42, "named_files": ["app/x.js"]}' > "$T/.ptc/session.json"
rm -f "$WORK/bodies-NOGIT/guide_action_runs.json" "$WORK/bodies-NOGIT/guide_check.json" "$WORK/bodies-NOGIT/guide_delivery_commits.json"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API_NOGIT" -d "$T" --json >"$WORK/named.json" 2>"$WORK/named.err"
fp=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['body'].get('workspace_fingerprint',''))" "$WORK/bodies-NOGIT/guide_action_runs.json" 2>/dev/null)
copy=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['body']['files_sample'].get('app/x.js') is not None)" "$WORK/bodies-NOGIT/guide_action_runs.json" 2>/dev/null)
key=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['body'].get('run_key',''))" "$WORK/bodies-NOGIT/guide_check.json" 2>/dev/null)
"$CLI" scan --json -d "$T" > "$WORK/named-scan.json" 2>/dev/null
sfp=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['repo']['workspace_fingerprint'])" "$WORK/named-scan.json" 2>/dev/null)
[[ "$copy" == "True" && -n "$fp" && "$fp" != "$sfp" ]] && pass "the sync's run carries app/x.js and a fingerprint covering it" || fail "named run: copy=$copy fp=$fp scan=$sfp"
[[ "$key" == "fp:$fp" && "$(dc "$WORK/bodies-NOGIT" "d.get('workspace_fingerprint')")" == "$fp" ]] && pass "guide check and the delivery report use the run's fingerprint" \
    || fail "check key '$key', report fp '$(dc "$WORK/bodies-NOGIT" "d.get('workspace_fingerprint')")', run fp '$fp'"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WORK/named.json" 2>/dev/null && pass "sync --json stdout stays one JSON document" || fail "sync --json stdout: $(head -3 "$WORK/named.json")"

echo ""
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
