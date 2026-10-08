#!/bin/bash
# `ptc guide start|next|submit|status|skip` against the mock PTC API
# (tests/mock_ptc_api.py guide routes), plus the version headers that every
# API call carries.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
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
readonly CLI_VERSION="$(grep -m1 -oE 'VERSION="[^"]+"' "$CLI" | cut -d'"' -f2)"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
expect_rc() { local desc="$1" want="$2" got="$3"; [[ "$got" == "$want" ]] && pass "$desc" || fail "$desc (rc $got, want $want)"; }
jcheck() {  # jcheck desc file expr
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($3) else 1)" "$2" 2>/dev/null; then pass "$1"; else fail "$1"; fi
}

WORK=$(mktemp -d)
BODIES="$WORK/bodies"; mkdir -p "$BODIES"
MOCK_PID=""; PORT=""
cleanup() { [[ -n "$MOCK_PID" ]] && stop_mocks "$MOCK_PID"; rm -rf "$WORK"; }
trap cleanup EXIT
for port in 18887 18897 18907 18917; do
    refuse_busy_port "$port"
    PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$BODIES" PTC_MOCK_LAB_SECRET=lab-secret python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
    pid=$!
    for i in $(seq 1 30); do
        if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
            MOCK_PID=$pid; PORT=$port; break 2
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.4
    done
    kill "$pid" 2>/dev/null
done
[[ -n "$PORT" ]] || { echo "mock did not come up"; cat "$WORK/mock.log"; exit 1; }
API="http://127.0.0.1:$PORT/api/v1/"
OLD_API="http://127.0.0.1:$((PORT + 5))/api/v1/"
PROJ="$WORK/proj"; mkdir -p "$PROJ"
g() { PTC_ORG_TOKEN="${TOKEN-org-token}" "$CLI" guide "$@" --api-url "$API" -d "$PROJ"; }

echo "=== version headers on every call ==="
hdrs=$(bash -c 'source "$1"; curl() { printf "%s\n" "$@"; }; ptc_curl http://x; PTC_HEADER_DUMP=/dev/null ptc_curl http://x' _ "$CLI")
[[ $(grep -c "^X-PTC-CLI-Version: $CLI_VERSION\$" <<<"$hdrs") == 2 ]] && pass "ptc_curl sends X-PTC-CLI-Version (both branches)" || fail "ptc_curl X-PTC-CLI-Version: $hdrs"
[[ $(grep -c "^User-Agent: ptc-cli/$CLI_VERSION\$" <<<"$hdrs") == 2 ]] && pass "ptc_curl sends User-Agent (both branches)" || fail "ptc_curl User-Agent"
bare=$(grep -nE '(^|[^_[:alnum:]])curl +-' "$CLI" | grep -vE '^\s*[0-9]+:\s*#|log_info|curl -H "User-Agent: \$PTC_USER_AGENT"|curl -fsSL "?(\\?\$\{PTC_CLI_URL:-)?https://raw' || true)
[[ -z "$bare" ]] && pass "no API call bypasses ptc_curl" || fail "bare curl calls: $bare"

echo "=== guide ==="
TOKEN="" g next >/dev/null 2>&1; expect_rc "no PTC_ORG_TOKEN -> exit 1" 1 $?
g next >/dev/null 2>&1; expect_rc "no session -> exit 1" 1 $?
g start --project-id 7 --repo-url https://example.test/r.git --branch main >"$WORK/out" 2>&1; expect_rc "start -> exit 0" 0 $?
jcheck "start caches the session id in .ptc/session.json" "$PROJ/.ptc/session.json" "d['session_id'] == 'gs_mock'"
[[ "$(cat "$PROJ/.ptc/.gitignore" 2>/dev/null)" == "*" ]] && pass "start git-ignores .ptc/ itself" || fail "start did not write .ptc/.gitignore"
jcheck "start body = {project_id, repo_url, branch}" "$BODIES/guide_sessions.json" "d['body'] == {'project_id': 7, 'repo_url': 'https://example.test/r.git', 'branch': 'main'}"
jcheck "guide call sends X-PTC-CLI-Version + User-Agent + org bearer" "$BODIES/guide_sessions.json" "d['headers']['X-PTC-CLI-Version'] == '$CLI_VERSION' and d['headers']['User-Agent'] == 'ptc-cli/$CLI_VERSION' and d['headers']['Authorization'] == 'Bearer org-token'"
rm -rf "$PROJ/.ptc"
g start --repo-url https://example.test/r.git --branch main >"$WORK/out" 2>&1; expect_rc "start without --project-id -> exit 0" 0 $?
jcheck "start without --project-id POSTs /projects {name, repo_url, default_branch}" "$BODIES/projects.json" "d['body']['repo_url'] == 'https://example.test/r.git' and d['body']['default_branch'] == 'main' and d['body']['name']"
grep -q "Created PTC project 42" "$WORK/out" && grep -q "organization agent token" "$WORK/out" && grep -q "https://ptc.test/dashboard/organizations/5/agent-tokens" "$WORK/out" && pass "start prints the project id and the ORG agent-token page (E5)" || fail "start prints the project id and token page: $(cat "$WORK/out")"
if grep -q "no target languages yet" "$WORK/out" && grep -q "PTC dashboard" "$WORK/out" && grep -q "target_languages task" "$WORK/out"; then
    pass "start tells the operator to set the target languages: the dashboard or the guide's target_languages task (T19)"
else fail "start names no target-language step: $(cat "$WORK/out")"; fi
grep -qi "token (shown once" "$WORK/out" && fail "start must never print a project token" || pass "start prints no project token (B1)"
jcheck "session.json keeps the created project id" "$PROJ/.ptc/session.json" "d['project_id'] == '42'"
jcheck "the session is opened for the created project" "$BODIES/guide_sessions.json" "d['body']['project_id'] == 42"
# B4: no .ptc/session.json -> the session is resolved from the origin URL
R2="$WORK/r2"; mkdir -p "$R2"; git -C "$R2" init -q; git -C "$R2" remote add origin https://example.test/known.git
PTC_ORG_TOKEN=org-token "$CLI" guide next --json --api-url "$API" -d "$R2" >"$WORK/r2.json" 2>/dev/null; expect_rc "next without session.json resolves the session from origin -> exit 0" 0 $?
jcheck "the resolved session is cached" "$R2/.ptc/session.json" "d['session_id'] == 'gs_found' and d['project_id'] == '77'"
[[ "$(cat "$R2/.ptc/.gitignore" 2>/dev/null)" == "*" ]] && pass "resolution git-ignores .ptc/" || fail "resolution did not write .ptc/.gitignore"
R3="$WORK/r3"; mkdir -p "$R3"; git -C "$R3" init -q; git -C "$R3" remote add origin https://example.test/unknown.git
PTC_ORG_TOKEN=org-token "$CLI" guide next --api-url "$API" -d "$R3" >/dev/null 2>&1; expect_rc "no session anywhere -> exit 1" 1 $?
# B2: PTC_API_URL from the environment (no --api-url)
PTC_API_URL="$API" PTC_ORG_TOKEN=org-token "$CLI" guide next --json -d "$R2" >/dev/null 2>&1; expect_rc "PTC_API_URL from the environment reaches the mock -> exit 0" 0 $?
# S2-R2 item 6: the config file's api_url is honoured by the guide subcommands too (no --api-url, no PTC_API_URL)
printf 'source_locale: en\napi_url: %s\n' "$API" > "$R2/.ptc-config.yml"
env -u PTC_API_URL PTC_ORG_TOKEN=org-token "$CLI" guide next --json -d "$R2" >/dev/null 2>&1; expect_rc "api_url from .ptc-config.yml reaches the mock -> exit 0" 0 $?
rm -f "$R2/.ptc-config.yml"
g next --json >"$WORK/next.json" 2>/dev/null; expect_rc "next --json -> exit 0" 0 $?
jcheck "next --json prints the task envelope" "$WORK/next.json" "d['task']['id'] == 'gt_1' and d['cli']['min_version'] == '1.1.0'"
out=$(g next 2>/dev/null); case "$out" in *"Task gt_1 [repo_census]"*"ptc scan --json"*) pass "next text shows the task and commands" ;; *) fail "next text: $out" ;; esac
echo '{"schema":1,"resource_sets":[]}' > "$WORK/ev.json"
g submit gt_1 --file "$WORK/ev.json" >"$WORK/out" 2>&1; expect_rc "submit accepted -> exit 0" 0 $?
jcheck "submit body carries session, task and the evidence verbatim" "$BODIES/guide_submit.json" "d['body'] == {'session_id': 'gs_mock', 'task_id': 'gt_1', 'evidence': {'schema': 1, 'resource_sets': []}}"
echo '{"mock_verdict":"rejected"}' | g submit gt_1 >"$WORK/out" 2>&1; expect_rc "submit rejected (stdin) -> exit 2" 2 $?
grep -q "evidence does not match the census" "$WORK/out" && pass "rejected prints the reasons" || fail "rejected reasons: $(cat "$WORK/out")"
echo '{"mock_verdict":"needs_more"}' | g submit gt_1 --json >"$WORK/out" 2>/dev/null; expect_rc "submit needs_more -> exit 3" 3 $?
jcheck "submit --json prints the verdict JSON" "$WORK/out" "d['verdict'] == 'needs_more'"
echo 'not json' | g submit gt_1 >/dev/null 2>&1; expect_rc "invalid evidence JSON -> exit 1" 1 $?
g skip gt_1 --reason "the human said so" >/dev/null 2>&1; expect_rc "skip -> exit 0" 0 $?
jcheck "skip body carries the reason" "$BODIES/guide_skip.json" "d['body'] == {'session_id': 'gs_mock', 'task_id': 'gt_1', 'reason': 'the human said so'}"
out=$(g status 2>/dev/null); rc=$?
expect_rc "status -> exit 0" 0 $rc
case "$out" in *"readiness 0.25"*"gt_1"*) pass "status text lists readiness and tasks" ;; *) fail "status text: $out" ;; esac
g next --session-id gs_done >"$WORK/out" 2>&1; expect_rc "next when done -> exit 0" 0 $?
grep -q "All guide tasks are done" "$WORK/out" && pass "done is reported" || fail "done text: $(cat "$WORK/out")"
PTC_ORG_TOKEN=org-token "$CLI" guide next --api-url "$OLD_API" -d "$PROJ" >"$WORK/out" 2>&1; expect_rc "CLI below cli.min_version -> exit 4" 4 $?
grep -q "requires at least 99.0.0. Upgrade" "$WORK/out" && pass "upgrade instruction printed" || fail "upgrade text: $(cat "$WORK/out")"

echo "=== SF-12: next while PTC waits is not done ==="
W="$WORK/waiting"; mkdir -p "$W/.ptc"; echo '{"session_id": "gs_waiting", "project_id": "7"}' > "$W/.ptc/session.json"
PTC_ORG_TOKEN=org-token "$CLI" guide next --api-url "$API" -d "$W" >"$WORK/out" 2>&1; expect_rc "next answered {task: null, waiting} -> exit 3 (waiting), not 0" 3 $?
grep -q "All guide tasks are done" "$WORK/out" && fail "next printed done while PTC waits: $(cat "$WORK/out")" || pass "next does not say done while PTC waits"
grep -q "PTC is waiting: .*ptc guide action-run --project-id 7" "$WORK/out" && pass "next prints the step PTC waits on" || fail "waiting line: $(cat "$WORK/out")"
PTC_ORG_TOKEN=org-token "$CLI" guide next --json --api-url "$API" -d "$W" >"$WORK/wj.json" 2>/dev/null; expect_rc "next --json while PTC waits -> exit 3" 3 $?
jcheck "next --json prints PTC's waiting answer as it came" "$WORK/wj.json" "d['task'] is None and d['done'] is False and 'action-run' in d['waiting']"
D="$WORK/done"; mkdir -p "$D/.ptc"; echo '{"session_id": "gs_done", "project_id": "7"}' > "$D/.ptc/session.json"
PTC_ORG_TOKEN=org-token "$CLI" guide next --api-url "$API" -d "$D" >"$WORK/out" 2>&1; expect_rc "next on PTC's explicit done -> exit 0" 0 $?
grep -q "All guide tasks are done" "$WORK/out" && pass "done only on PTC's explicit done" || fail "done text: $(cat "$WORK/out")"

echo "=== guide on a multi-product suite ==="
S="$WORK/suite"; mkdir -p "$S/.ptc"; echo '{"session_id": "gs_suite", "project_id": "80"}' > "$S/.ptc/session.json"
PTC_ORG_TOKEN=org-token "$CLI" guide next --api-url "$API" -d "$S" >"$WORK/out" 2>&1; expect_rc "next on a suite -> exit 0" 0 $?
grep -q "Product pb (session gs_pb)" "$WORK/out" && grep -q "Task gt_9 \[commit_config\]" "$WORK/out" && pass "next walks the products and shows the first open product's task" || fail "suite next: $(cat "$WORK/out")"
jcheck "session.json keeps the products in order" "$S/.ptc/session.json" "[p['dir'] for p in d['products']] == ['pa', 'pb'] and d['products'][1]['session_id'] == 'gs_pb' and d['session_id'] == 'gs_suite'"
jcheck "session.json maps the task to its product session" "$S/.ptc/session.json" "d['tasks']['gt_9'] == 'gs_pb'"
PTC_ORG_TOKEN=org-token "$CLI" guide next --json --api-url "$API" -d "$S" >"$WORK/sj.json" 2>/dev/null
jcheck "next --json on a suite prints the product task tagged with its dir" "$WORK/sj.json" "d['task']['id'] == 'gt_9' and d['product_dir'] == 'pb' and d['session_id'] == 'gs_pb'"
echo '{"commit_sha":"x"}' | PTC_ORG_TOKEN=org-token "$CLI" guide submit gt_9 --api-url "$API" -d "$S" >/dev/null 2>&1; expect_rc "submit a product task -> exit 0" 0 $?
jcheck "the product task is submitted to its own session" "$BODIES/guide_submit.json" "d['body']['session_id'] == 'gs_pb' and d['body']['task_id'] == 'gt_9'"

echo "=== guide action-run (ptc-action hook) ==="
cp -R "$TEST_DIR/fixtures/scan-repo/." "$WORK/repo/" 2>/dev/null || { mkdir -p "$WORK/repo"; cp -R "$TEST_DIR/fixtures/scan-repo/." "$WORK/repo/"; }
git -C "$WORK/repo" init -q -b main && git -C "$WORK/repo" -c user.email=t@t -c user.name=t add -A && git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -qm fixture
sha=$(git -C "$WORK/repo" rev-parse HEAD)
# L3-1 (POL-116): files_sha also carries every census source's digest (bytes on disk); NONSRC lists the other keys.
NONSRC="sorted(k for k in d['body']['files_sha'] if k not in [(d['body']['repo_prefix'] + '/' if d['body']['repo_prefix'] else '') + f['path'] for s in d['body']['scan']['resource_sets'] for f in s['source_files']])"
NOID=(env -u GITHUB_ACTIONS -u GITLAB_CI -u GITHUB_SHA -u GITHUB_REF_NAME -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN)
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >"$WORK/ar.out" 2>&1; expect_rc "action-run -> exit 0" 0 $?
jcheck "action_runs body shape" "$BODIES/guide_action_runs.json" "sorted(d['body']) == ['branch', 'ci_id_token', 'commit_sha', 'config', 'delivered_files_sha', 'files_sample', 'files_sha', 'ignored_outputs', 'project_id', 'provenance_request', 'repo_prefix', 'scan', 'workspace_fingerprint'] and d['body']['repo_prefix'] == '' and d['body']['scan']['repo']['prefix'] == '' and d['body']['commit_sha'] == '$sha' and d['body']['branch'] == 'main' and d['body']['project_id'] == 7"
jcheck "action_runs carries the scan and the parsed config" "$BODIES/guide_action_runs.json" "d['body']['scan']['schema'] == 2 and d['body']['scan']['repo']['head_sha'] == '$sha' and d['body']['config']['guide']['session_id'] == 'gs_mock'"
jcheck "files_sample holds the source files' content" "$BODIES/guide_action_runs.json" "sorted(d['body']['files_sample']) == ['config/locales/en.yml', 'languages/plugin.pot', 'src/locales/en/common.json'] and 'Hello, %{name}!' in d['body']['files_sample']['config/locales/en.yml']"
jcheck "no identity token -> ci_id_token null" "$BODIES/guide_action_runs.json" "d['body']['ci_id_token'] is None"
# S2-R3F B1-3 (AGD-4, POL-11): the run carries `ptc config validate --json`'s ignored_outputs, so PTC checks the commit's
# git-ignored outputs from the checkout, not from the agent's claim.
jcheck "action_runs carries ignored_outputs ([] when no output is git-ignored)" "$BODIES/guide_action_runs.json" "d['body']['ignored_outputs'] == []"
mkdir -p "$WORK/repo-ign" && cp -R "$TEST_DIR/fixtures/scan-repo/." "$WORK/repo-ign/" && printf '/config/locales/de.yml\n' > "$WORK/repo-ign/.gitignore"
git -C "$WORK/repo-ign" init -q -b main && git -C "$WORK/repo-ign" -c user.email=t@t -c user.name=t add -A && git -C "$WORK/repo-ign" -c user.email=t@t -c user.name=t commit -qm fixture
rm -f "$BODIES/guide_action_runs.json"
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo-ign" --project-id 7 >"$WORK/ar-ign.out" 2>&1; expect_rc "action-run on a repo whose .gitignore ignores an output -> still exit 0 (never fails the run)" 0 $?
jcheck "action_runs lists the git-ignored output (first target language, as config validate does)" "$BODIES/guide_action_runs.json" "d['body']['ignored_outputs'] == ['config/locales/de.yml']"
rm -f "$BODIES/guide_action_runs.json"
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >/dev/null 2>&1
grep -q "Not in CI" "$WORK/ar.out" && grep -q "provenance: agent_local" "$WORK/ar.out" && pass "outside CI (L3-1): reported as an agent-local run" || fail "agent-local output: $(cat "$WORK/ar.out")"
"${NOID[@]}" GITHUB_ACTIONS=true PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >"$WORK/ar-ci.out" 2>&1
grep -q "No CI identity token" "$WORK/ar-ci.out" && grep -q "provenance: unverified" "$WORK/ar-ci.out" && pass "CI without an identity token: warns and reports unverified provenance" || fail "no-token output: $(cat "$WORK/ar-ci.out")"
cfg_sha=$(git -C "$WORK/repo" cat-file blob HEAD:.ptc-config.yml | sha256sum | cut -d' ' -f1)
jcheck "files_sha = sha256 of the committed .ptc-config.yml, plus the census sources (L3-1)" "$BODIES/guide_action_runs.json" "d['body']['files_sha']['.ptc-config.yml'] == '$cfg_sha' and $NONSRC == ['.ptc-config.yml'] and sorted(d['body']['files_sha']) == sorted(['.ptc-config.yml'] + list(d['body']['files_sample']))"
de_yml=$(git -C "$WORK/repo" cat-file blob HEAD:config/locales/de.yml | sha256sum | cut -d' ' -f1)
jcheck "delivered_files_sha = sha256 of every committed delivered file (config output patterns, never the source)" "$BODIES/guide_action_runs.json" "sorted(d['body']['delivered_files_sha']) == ['config/locales/de.yml', 'config/locales/fr.yml', 'languages/plugin-de_DE.po'] and d['body']['delivered_files_sha']['config/locales/de.yml'] == '$de_yml'"
jcheck "action_runs uses the project token" "$BODIES/guide_action_runs.json" "d['headers']['Authorization'] == 'Bearer project-token' and d['headers']['X-PTC-CLI-Version'] == '$CLI_VERSION'"
echo "=== guide delivery-commit (P4 T14: the translations-branch commit, read from the commit, not the work tree) ==="
git -C "$WORK/repo" checkout -q -b ptc/translations
printf 'de:\n  hello: "Hallo aus PTC"\n' > "$WORK/repo/config/locales/de.yml"
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -qam "chore(i18n): update translations via PTC"
tsha=$(git -C "$WORK/repo" rev-parse HEAD)
tde=$(git -C "$WORK/repo" cat-file blob "$tsha:config/locales/de.yml" | sha256sum | cut -d' ' -f1)
git -C "$WORK/repo" checkout -q main
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide delivery-commit --commit "$tsha" --branch ptc/translations --source-commit "$sha" \
  --api-url "$API" -d "$WORK/repo" --project-id 7 >"$WORK/dc.out" 2>&1; expect_rc "delivery-commit -> exit 0" 0 $?
jcheck "delivery_commits body: the translations commit, its source commit, the project" "$BODIES/guide_delivery_commits.json" "sorted(d['body']) == ['branch', 'ci_id_token', 'commit_sha', 'delivered_files_sha', 'project_id', 'provenance_request', 'source_commit_sha'] and d['body']['provenance_request'] == 'agent_local' and d['body']['commit_sha'] == '$tsha' and d['body']['source_commit_sha'] == '$sha' and d['body']['branch'] == 'ptc/translations' and d['body']['project_id'] == 7"
jcheck "delivered_files_sha is read from the reported commit (main's work tree differs)" "$BODIES/guide_delivery_commits.json" "d['body']['delivered_files_sha']['config/locales/de.yml'] == '$tde' and '$tde' != '$de_yml' and 'config/locales/en.yml' not in d['body']['delivered_files_sha']"
grep -q "Reported the translations-branch commit ${tsha:0:12} to PTC" "$WORK/dc.out" && pass "delivery-commit says what PTC matched" || fail "delivery-commit output: $(cat "$WORK/dc.out")"
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide delivery-commit --api-url "$API" -d "$WORK/repo" >/dev/null 2>&1; expect_rc "delivery-commit without --commit -> exit 1" 1 $?
# S2-R3B C-1: no config and no --project-id used to die silently (errexit on the `&&` assignment) before posting. Now the
# run is posted (a legacy project token needs no project) after a warning; an organization token's refusal names the remedy.
rm -f "$BODIES/guide_action_runs.json"; mkdir -p "$WORK/noconf" && git -C "$WORK/noconf" init -q
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/noconf" >"$WORK/noconf.out" 2>&1; rc=$?
[[ $rc -eq 0 && -f "$BODIES/guide_action_runs.json" ]] && grep -q -- "--project-id" "$WORK/noconf.out" \
  && pass "action-run without a config or --project-id (project token) -> posted, exit 0, warning names --project-id (C-1)" \
  || fail "action-run without a config or --project-id (project token): rc $rc, out: $(cat "$WORK/noconf.out")"
rm -f "$BODIES/guide_action_runs.json"
"${NOID[@]}" PTC_API_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$WORK/noconf" >"$WORK/noconf2.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q "HTTP 400" "$WORK/noconf2.out" && grep -q "guide.project_id" "$WORK/noconf2.out" \
  && pass "action-run without a project (organization token) -> non-zero, the refusal names --project-id / guide.project_id (C-1)" \
  || fail "action-run without a project (organization token): rc $rc, out: $(cat "$WORK/noconf2.out")"

# D13: with a base ref, the body carries the commit's changed paths (repo-root relative)
git -C "$WORK/repo" update-ref refs/remotes/origin/main HEAD
mkdir -p "$WORK/repo/tasks" && echo x > "$WORK/repo/tasks/NOTE.md" && echo "a: 1" > "$WORK/repo/.ptc-extra.yml"
git -C "$WORK/repo" -c user.email=t@t -c user.name=t add -A && git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -qm extra
env -u GITHUB_SHA -u GITHUB_REF_NAME PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >/dev/null 2>&1
jcheck "action_runs carries changed_files against the merge base" "$BODIES/guide_action_runs.json" "d['body']['changed_files'] == ['.ptc-extra.yml', 'tasks/NOTE.md']"
echo "echo changed" >> "$WORK/repo/.ptc-config.yml"   # uncommitted edit: the digest stays the commit's
mkdir -p "$WORK/repo/.github/workflows" "$WORK/repo/pb" && printf 'name: x\n' > "$WORK/repo/.github/workflows/ptc.yml" && printf 'files: []\n' > "$WORK/repo/pb/.ptc-config.yml"
git -C "$WORK/repo" -c user.email=t@t -c user.name=t add .github pb && git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -qm ci
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >/dev/null 2>&1
wf_sha=$(printf 'name: x\n' | sha256sum | cut -d' ' -f1)
jcheck "files_sha: workflow + product config (committed content only) + every path changed since the base (E32)" "$BODIES/guide_action_runs.json" "$NONSRC == ['.github/workflows/ptc.yml', '.ptc-config.yml', '.ptc-extra.yml', 'pb/.ptc-config.yml', 'tasks/NOTE.md'] and d['body']['files_sha']['.github/workflows/ptc.yml'] == '$wf_sha' and d['body']['files_sha']['.ptc-config.yml'] == '$cfg_sha'"
git -C "$WORK/repo" checkout -q -- .ptc-config.yml
# E32 (lab p2r2 s1: ra1 applied in a JS controller never reached PTC's view): with no base ref, the HEAD commit's own
# edits are hashed from the commit, so source_fixes can match the sha256 the agent reports.
git -C "$WORK/repo" update-ref -d refs/remotes/origin/main
mkdir -p "$WORK/repo/app/js" && printf 'const s = `${(n / 1024).toLocaleString()} KB`\n' > "$WORK/repo/app/js/size.js"
git -C "$WORK/repo" -c user.email=t@t -c user.name=t add app && git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -qm js
printf 'uncommitted\n' >> "$WORK/repo/app/js/size.js"
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >/dev/null 2>&1
js_sha=$(git -C "$WORK/repo" cat-file blob HEAD:app/js/size.js | sha256sum | cut -d' ' -f1)
jcheck "files_sha: no base ref -> the HEAD commit's own edited file, committed content (E32)" "$BODIES/guide_action_runs.json" "d['body']['files_sha'].get('app/js/size.js') == '$js_sha' and 'changed_files' not in d['body']"
git -C "$WORK/repo" checkout -q -- app/js/size.js
git -C "$WORK/repo" update-ref refs/remotes/origin/main HEAD~3
sha2=$(git -C "$WORK/repo" rev-parse HEAD)

echo "=== S1 F17: files_sha carries .gitlab/ptc.yml even when the reported commit changed nothing (commit_config checks it by digest) ==="
mkdir -p "$WORK/repo-gl/.gitlab" && cp -R "$TEST_DIR/fixtures/scan-repo/." "$WORK/repo-gl/"
printf 'ptc-translate:\n  script: [true]\n' > "$WORK/repo-gl/.gitlab/ptc.yml"; printf 'include:\n  - local: .gitlab/ptc.yml\n' > "$WORK/repo-gl/.gitlab-ci.yml"
git -C "$WORK/repo-gl" init -q -b main && git -C "$WORK/repo-gl" -c user.email=t@t -c user.name=t add -A && git -C "$WORK/repo-gl" -c user.email=t@t -c user.name=t commit -qm gitlab-job
git -C "$WORK/repo-gl" -c user.email=t@t -c user.name=t commit -q --allow-empty -m retrigger
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo-gl" --project-id 7 >"$WORK/ar-gl.out" 2>&1; expect_rc "action-run on an empty commit after the GitLab job -> exit 0" 0 $?
gl_sha=$(git -C "$WORK/repo-gl" cat-file blob HEAD:.gitlab/ptc.yml | sha256sum | cut -d' ' -f1)
jcheck "files_sha carries .gitlab/ptc.yml, .gitlab-ci.yml and .ptc-config.yml from the commit" "$BODIES/guide_action_runs.json" "d['body']['files_sha'].get('.gitlab/ptc.yml') == '$gl_sha' and '.gitlab-ci.yml' in d['body']['files_sha'] and '.ptc-config.yml' in d['body']['files_sha']"
echo "=== S2-R6 F22: a depth-1 checkout (actions/checkout's default) still reports the commit's own edit ==="
# Lab pay-g2c s28: HEAD of a shallow single-commit clone has no parent, so `git diff-tree HEAD` listed nothing and the
# run's files_sha carried only the config files; source_fixes then found none of the agent's edits.
mkdir -p "$WORK/f22-src" && cp -R "$TEST_DIR/fixtures/scan-repo/." "$WORK/f22-src/"
git -C "$WORK/f22-src" init -q -b main && git -C "$WORK/f22-src" -c user.email=t@t -c user.name=t add -A && git -C "$WORK/f22-src" -c user.email=t@t -c user.name=t commit -qm base
mkdir -p "$WORK/f22-src/src" && printf 'export const label = "Delete comments";\n' > "$WORK/f22-src/src/label.js"
git -C "$WORK/f22-src" -c user.email=t@t -c user.name=t add src && git -C "$WORK/f22-src" -c user.email=t@t -c user.name=t commit -qm "source fix"
git clone -q --depth 1 "file://$WORK/f22-src" "$WORK/f22-shallow" 2>/dev/null
[[ "$(git -C "$WORK/f22-shallow" rev-parse --is-shallow-repository)" == true ]] && pass "F22 fixture: a depth-1 clone" || fail "F22 fixture is not shallow"
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/f22-shallow" --project-id 7 >/dev/null 2>&1
f22_sha=$(printf 'export const label = "Delete comments";\n' | sha256sum | cut -d' ' -f1)
jcheck "files_sha on a depth-1 clone carries the file the commit changed, and not the untouched tree" "$BODIES/guide_action_runs.json" "d['body']['files_sha'].get('src/label.js') == '$f22_sha' and all(k == 'src/label.js' or k.endswith('.ptc-config.yml') or k.startswith('.github/') or k.startswith('.gitlab') for k in $NONSRC)"
echo "=== action-run provenance: CI identity token ==="
MINT="$(dirname "$TEST_DIR")/tools/mint-lab-ci-token.py"
lab=$(GUIDE_LAB_CI_SECRET=lab-secret python3 "$MINT" --repository lab/app --sha "$sha2" --ref refs/heads/main)
python3 - "$lab" "$sha2" <<'PY' && pass "lab token: HS256 with the documented claims" || fail "lab token claims"
import base64, json, sys
h, c, s = sys.argv[1].split(".")
dec = lambda x: json.loads(base64.urlsafe_b64decode(x + "=" * (-len(x) % 4)))
hd, cl = dec(h), dec(c)
assert hd == {"alg": "HS256", "typ": "JWT"}, hd
assert sorted(cl) == ["aud", "exp", "iat", "iss", "jti", "nbf", "project_path", "ref", "repository", "sha", "sub"], sorted(cl)
assert cl["iss"] == "ptc-lab" and cl["aud"] == "ptc" and cl["repository"] == cl["project_path"] == "lab/app"
assert cl["sha"] == sys.argv[2] and cl["ref"] == "refs/heads/main" and cl["sub"] == "repo:lab/app:ref:refs/heads/main"
assert cl["exp"] - cl["iat"] == 600
PY
env -u GUIDE_LAB_CI_SECRET python3 "$MINT" --repository x --sha y >/dev/null 2>&1; expect_rc "mint without the secret -> exit 1" 1 $?
"${NOID[@]}" PTC_CI_ID_TOKEN="$lab" PTC_API_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >"$WORK/ar.out" 2>&1
jcheck "lab: ci_id_token posted verbatim" "$BODIES/guide_action_runs.json" "d['body']['ci_id_token'] == '$lab'"
grep -q "provenance: ci_verified" "$WORK/ar.out" && pass "lab: signed token -> ci_verified" || fail "lab provenance: $(cat "$WORK/ar.out")"
bad=$(GUIDE_LAB_CI_SECRET=wrong python3 "$MINT" --repository lab/app --sha "$sha2")
"${NOID[@]}" PTC_CI_ID_TOKEN="$bad" PTC_API_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >"$WORK/ar.out" 2>&1
grep -q "provenance: unverified" "$WORK/ar.out" && pass "lab: wrong secret -> unverified" || fail "bad-secret provenance: $(cat "$WORK/ar.out")"
"${NOID[@]}" PTC_ID_TOKEN="$lab" PTC_API_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >/dev/null 2>&1
jcheck "GitLab: PTC_ID_TOKEN (id_tokens) is posted as ci_id_token" "$BODIES/guide_action_runs.json" "d['body']['ci_id_token'] == '$lab'"
"${NOID[@]}" ACTIONS_ID_TOKEN_REQUEST_URL="${API%/}/_oidc/token?sha=$sha2" ACTIONS_ID_TOKEN_REQUEST_TOKEN=gh-req-token PTC_API_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >/dev/null 2>&1
jcheck "GitHub: token requested with audience ptc and the request bearer" "$BODIES/_oidc_token.json" "d['headers']['Authorization'] == 'bearer gh-req-token'"
python3 - "$BODIES/guide_action_runs.json" <<'PY' && pass "GitHub: the requested JWT (aud ptc) is posted as ci_id_token" || fail "GitHub ci_id_token"
import base64, json, sys
t = json.load(open(sys.argv[1]))["body"]["ci_id_token"]
c = t.split(".")[1]
assert json.loads(base64.urlsafe_b64decode(c + "=" * (-len(c) % 4)))["aud"] == "ptc"
PY
grep -q 'PTC_CI_ID_TOKEN_VALUE="$id_token" _ptc_py action-body' "$CLI" && pass "the identity token reaches the body builder by env, not argv" || fail "id token passing"

echo "=== E1: a product's action run reports repository-root config paths ==="
M="$WORK/mono"; mkdir -p "$M/pa/languages" "$M/pb/languages" "$M/.github/workflows"
for p in pa pb; do
  echo '{"name": "x/'$p'"}' > "$M/$p/composer.json"
  printf 'msgid ""\nmsgstr ""\n\nmsgid "Hi"\nmsgstr ""\n' > "$M/$p/languages/$p.pot"
  printf 'msgid "Hi"\nmsgstr "Hallo"\n' > "$M/$p/languages/$p-de_DE.po"
  printf 'source_locale: en\nfiles:\n  - file: languages/%s.pot\n    output: languages/%s-{{lang}}.po\nguide:\n  project_id: 8%s\n' "$p" "$p" "${p:1}" > "$M/$p/.ptc-config.yml"
done
printf 'name: ptc\n' > "$M/.github/workflows/ptc.yml"
git -C "$M" init -q -b main && git -C "$M" -c user.email=t@t -c user.name=t add -A && git -C "$M" -c user.email=t@t -c user.name=t commit -qm m
"${NOID[@]}" PTC_API_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$M/pa" --config-file "$M/pa/.ptc-config.yml" >/dev/null 2>&1; expect_rc "product action-run -> exit 0" 0 $?
jcheck "files_sha keys are repository-root paths, whole repository" "$BODIES/guide_action_runs.json" "$NONSRC == ['.github/workflows/ptc.yml', 'pa/.ptc-config.yml', 'pb/.ptc-config.yml']"
po_sha=$(printf 'msgid "Hi"\nmsgstr "Hallo"\n' | sha256sum | cut -d' ' -f1)
jcheck "delivered_files_sha: the product's delivered files only, repository-root keys" "$BODIES/guide_action_runs.json" "d['body']['delivered_files_sha'] == {'pa/languages/pa-de_DE.po': '$po_sha'}"
jcheck "repo_prefix names the product dir; scan paths stay product-relative (engine slice contract)" "$BODIES/guide_action_runs.json" "d['body']['repo_prefix'] == 'pa' and d['body']['scan']['repo']['prefix'] == 'pa' and d['body']['scan']['resource_sets'][0]['source_files'][0]['path'] == 'languages/pa.pot'"

echo "=== E2: X-PTC-Project-Id from guide.project_id on org-token API calls ==="
jcheck "action-run names the project (guide.project_id 8a)" "$BODIES/guide_action_runs.json" "d['headers'].get('X-PTC-Project-Id') == '8a'"
jcheck "guide calls do not carry a product project header" "$BODIES/guide_sessions.json" "'X-PTC-Project-Id' not in d['headers']"
rm -f "$BODIES"/api_*.json
( cd "$M/pa" && env -u PTC_PROJECT_ID PTC_API_TOKEN=org-token "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 ) >"$WORK/tr.out" 2>&1; expect_rc "translate with the org token + config project -> exit 0" 0 $?
python3 - "$BODIES" <<'PY' && pass "every translate-pipeline call (preflight, upload, process, status, download) sends X-PTC-Project-Id" || fail "translate headers: $(ls "$BODIES"; tail -5 "$WORK/tr.out")"
import glob, json, sys
files = glob.glob(sys.argv[1] + "/api_*.json")
routes = {f.split("/api_")[-1] for f in files}
assert {"languages.json", "source_files.json"} <= routes, routes
for f in files:
    assert json.load(open(f))["headers"].get("X-PTC-Project-Id") == "8a", f
PY
rm -f "$BODIES"/api_*.json
( cd "$M/pa" && PTC_PROJECT_ID=99 PTC_API_TOKEN=org-token "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 ) >/dev/null 2>&1
jcheck "PTC_PROJECT_ID overrides guide.project_id" "$BODIES/api_languages.json" "d['headers'].get('X-PTC-Project-Id') == '99'"
rm -f "$BODIES"/api_*.json
( cd "$WORK/repo" && PTC_API_TOKEN=project-token "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 ) >/dev/null 2>&1
jcheck "no guide.project_id -> no header" "$BODIES/api_languages.json" "'X-PTC-Project-Id' not in d['headers']"
printf 'guide:\n  session_id: x\n  project_id: "1281"  # set by PTC\nfiles: []\n' > "$WORK/pid.yml"
[[ "$(bash -c 'source "$1"; ptc_config_project_id "$2"' _ "$CLI" "$WORK/pid.yml")" == "1281" ]] && pass "project_id parsing: quotes and trailing comments" || fail "project_id parsing"

echo "=== E5: a project-token page URL is never shown ==="
rm -rf "$PROJ/.ptc"
PTC_ORG_TOKEN=org-token "$CLI" guide start --repo-url https://example.test/r.git --branch main --api-url "$API" -d "$PROJ" >"$WORK/out" 2>&1
! grep -q "ptc-api-token\|project token page" "$WORK/out" && pass "start never names a project-token page" || fail "E5: $(cat "$WORK/out")"
grep -qi "project token" <<<"$("$CLI" guide --help)" && fail "guide help mentions a project token" || pass "guide help mentions no project token"

echo "=== guide wait ==="
# S2-R7-6: a harness that does not wake on a background command's end runs the wait in the foreground.
GH="$("$CLI" guide --help 2>&1 | tr -s ' \n' ' ')"
grep -q "background command only when your harness wakes you on its end; otherwise run it in the foreground and read its output" <<<"$GH" && pass "guide help: background only when the harness wakes on its end, else foreground" || fail "R7-6 wait help: $GH"
W="$WORK/w"; mkdir -p "$W/.ptc"; echo '{"session_id": "gs_mock", "project_id": "7"}' > "$W/.ptc/session.json"
gw() { PTC_GUIDE_WAIT_CAP=1 PTC_GUIDE_WAIT_RETRY_S=1 PTC_ORG_TOKEN=org-token "$CLI" guide wait "$@" --api-url "$API" -d "$W"; }
gw gt_wait >"$WORK/out" 2>&1; expect_rc "wait: waiting then accepted -> exit 0" 0 $?
grep -q "Still waiting for PTC's verdict on gt_wait" "$WORK/out" && grep -q "Verdict: accepted" "$WORK/out" && grep -q "Task gt_1" "$WORK/out" && pass "wait prints progress, then the verdict and next task like submit" || fail "wait text: $(cat "$WORK/out")"
grep -q "PTC's verdict on task gt_wait:" "$WORK/out" && pass "wait output names the task it waited on (read later from a background run)" || fail "wait task id: $(cat "$WORK/out")"
jcheck "wait body = {session_id, task_id, timeout_s <= cap}" "$BODIES/guide_wait.json" "d['body'] == {'session_id': 'gs_mock', 'task_id': 'gt_wait', 'timeout_s': 1}"
jcheck "wait sends the org bearer + CLI version" "$BODIES/guide_wait.json" "d['headers']['Authorization'] == 'Bearer org-token' and d['headers']['X-PTC-CLI-Version'] == '$CLI_VERSION'"
# S2-R30-2 (SF-16): with no PTC_GUIDE_WAIT_CAP one request asks for at most PTC's cap (25 s), never the gateway's 60 s.
PTC_GUIDE_WAIT_RETRY_S=1 PTC_ORG_TOKEN=org-token "$CLI" guide wait gt_wait --timeout 600 --api-url "$API" -d "$W" >"$WORK/out" 2>&1; expect_rc "wait (default cap): accepted -> exit 0" 0 $?
jcheck "wait clamps timeout_s to the server cap by default (25 s < the gateway's 60 s)" "$BODIES/guide_wait.json" "d['body']['timeout_s'] == 25"
gw gt_rej >"$WORK/out" 2>&1; expect_rc "wait: rejected -> exit 2" 2 $?
grep -q "PTC's verdict on task gt_rej:" "$WORK/out" && pass "wait rejected output names the task" || fail "wait rej task id: $(cat "$WORK/out")"
grep -q "config differs" "$WORK/out" && pass "wait prints the rejection reasons" || fail "wait reasons: $(cat "$WORK/out")"
gw gt_rej --json >"$WORK/out" 2>/dev/null; expect_rc "wait --json rejected -> exit 2" 2 $?
jcheck "wait --json prints the verdict JSON" "$WORK/out" "d['verdict'] == 'rejected'"
start=$SECONDS; gw gt_never --timeout 2s >"$WORK/out" 2>&1; rc=$?; took=$((SECONDS - start))
expect_rc "wait: no verdict before --timeout -> exit 3" 3 $rc
grep -q "Still waiting after 2s" "$WORK/out" && [[ $took -le 6 ]] && pass "wait stops at --timeout (${took}s) and says so" || fail "wait timeout (${took}s): $(cat "$WORK/out")"
gw gt_never --timeout 1 --json >"$WORK/out" 2>/dev/null; expect_rc "wait --json timeout -> exit 3" 3 $?
jcheck "wait --json timeout prints the waiting status" "$WORK/out" "d['status'] == 'waiting'"
gw gt_flaky --timeout 20 >"$WORK/out" 2>&1; expect_rc "wait: a 503 is retried -> exit 0" 0 $?
grep -q "transient failure (HTTP 503)" "$WORK/out" && pass "wait reports the retried transient failure" || fail "flaky: $(cat "$WORK/out")"
gw gt_wait --timeout soon >/dev/null 2>&1; expect_rc "wait: bad --timeout -> exit 1" 1 $?
gw >/dev/null 2>&1; expect_rc "wait without TASK_ID -> exit 1" 1 $?
PTC_ORG_TOKEN=org-token "$CLI" guide wait gt_wait --api-url "$OLD_API" -d "$W" >"$WORK/out" 2>&1; expect_rc "wait: CLI below min_version -> exit 4" 4 $?
[[ "$(_s=$(bash -c 'source "$1"; _guide_seconds 20m; _guide_seconds 1h; _guide_seconds 90s; _guide_seconds 7' _ "$CLI"); echo $_s)" == "1200 3600 90 7" ]] && pass "durations: 20m 1h 90s 7" || fail "durations"

PTC_FILES_SAMPLE_LIMIT=10 PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" >/dev/null 2>&1
jcheck "files_sample respects the byte cap" "$BODIES/guide_action_runs.json" "d['body']['files_sample'] == {}"
# S2-R21-2 (run 11: a source fix in en.yml left out by the cap, so review_followup could not see it): a source file the
# commit changed is sent beyond the cap.
r21_main=$(git -C "$WORK/repo" rev-parse -q --verify refs/remotes/origin/main)
echo "  r21: Fixed typo" >> "$WORK/repo/config/locales/en.yml"
git -C "$WORK/repo" add config/locales/en.yml && git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -qm r21
git -C "$WORK/repo" update-ref refs/remotes/origin/main HEAD~1
PTC_FILES_SAMPLE_LIMIT=10 PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" >/dev/null 2>&1
jcheck "files_sample: a source file the commit changed is sent beyond the byte cap (S2-R21-2)" "$BODIES/guide_action_runs.json" "sorted(d['body']['files_sample']) == ['config/locales/en.yml'] and 'r21: Fixed typo' in d['body']['files_sample']['config/locales/en.yml']"
git -C "$WORK/repo" reset -q --keep HEAD~1
if [[ -n "$r21_main" ]]; then git -C "$WORK/repo" update-ref refs/remotes/origin/main "$r21_main"; else git -C "$WORK/repo" update-ref -d refs/remotes/origin/main; fi

echo "=== T18: every guide verb with --session-id and no session cache (lab p4r: submit crashed 'sid: unbound variable') ==="
N="$WORK/nocache"; mkdir -p "$N"; echo '{"mock_verdict": "accepted"}' > "$WORK/ev.json"
gn() { PTC_GUIDE_WAIT_CAP=1 PTC_GUIDE_WAIT_RETRY_S=1 PTC_ORG_TOKEN=org-token "$CLI" guide "$@" --api-url "$API" -d "$N"; }
gn submit gt_1 --session-id gs_t18 --file "$WORK/ev.json" >"$WORK/out" 2>&1; expect_rc "submit --session-id, no cache -> exit 0" 0 $?
grep -q "unbound variable" "$WORK/out" && fail "submit --session-id: $(cat "$WORK/out")" || pass "submit --session-id never hits an unbound variable"
jcheck "submit --session-id posts that session id" "$BODIES/guide_submit.json" "d['body']['session_id'] == 'gs_t18' and d['body']['task_id'] == 'gt_1'"
gn skip gt_1 --session-id gs_t18 --reason "not this repo" >"$WORK/out" 2>&1; expect_rc "skip --session-id, no cache -> exit 0" 0 $?
grep -q "unbound variable" "$WORK/out" && fail "skip --session-id: $(cat "$WORK/out")" || pass "skip --session-id never hits an unbound variable"
jcheck "skip --session-id posts that session id and the reason" "$BODIES/guide_skip.json" "d['body'] == {'session_id': 'gs_t18', 'task_id': 'gt_1', 'reason': 'not this repo'}"
gn wait gt_wait --session-id gs_t18 >"$WORK/out" 2>&1; expect_rc "wait --session-id, no cache -> exit 0" 0 $?
grep -q "unbound variable" "$WORK/out" && fail "wait --session-id: $(cat "$WORK/out")" || pass "wait --session-id never hits an unbound variable"
jcheck "wait --session-id posts that session id" "$BODIES/guide_wait.json" "d['body']['session_id'] == 'gs_t18'"
for verb in next status; do
    gn "$verb" --session-id gs_t18 >"$WORK/out" 2>&1; expect_rc "$verb --session-id, no cache -> exit 0" 0 $?
    grep -q "unbound variable" "$WORK/out" && fail "$verb --session-id: $(cat "$WORK/out")" || pass "$verb --session-id never hits an unbound variable"
done
gn check --session-id gs_pass --commit dddddddddddddddddddddddddddddddddddddddd >"$WORK/out" 2>&1; expect_rc "check --session-id, no cache -> exit 0" 0 $?
grep -q "unbound variable" "$WORK/out" && fail "check --session-id: $(cat "$WORK/out")" || pass "check --session-id never hits an unbound variable"
for verb in submit skip wait; do
    gn "$verb" gt_1 --reason r --file "$WORK/ev.json" --repo-url https://example.test/unknown.git >"$WORK/out" 2>&1; rc=$?
    grep -q "unbound variable" "$WORK/out" && fail "$verb without a session: $(cat "$WORK/out")" || pass "$verb without any session never hits an unbound variable (rc $rc)"
done

echo "=== P4E-4: guide skip of an accepted task is rejected and exits 2, like submit ==="
gn skip gt_accepted --session-id gs_t18 --reason "late" >"$WORK/out" 2>&1; expect_rc "skip of an accepted task -> exit 2" 2 $?
if grep -q "gt_accepted is already accepted" "$WORK/out"; then pass "skip of an accepted task names why"; else fail "skip of an accepted task: $(cat "$WORK/out")"; fi

echo "=== T22: guide skip without --reason is a usage error and exits non-zero (PROTOCOL exit codes; lab p4v) ==="
gn skip gt_1 --session-id gs_t18 >"$WORK/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && pass "skip without --reason exits non-zero (rc $rc)" || fail "skip without --reason exited 0: $(cat "$WORK/out")"
grep -q "guide skip needs --reason" "$WORK/out" && pass "skip without --reason names the missing --reason" || fail "skip without --reason: $(cat "$WORK/out")"

echo "=== transient retry on guide calls and the two report POSTs (S2-F2 C-2) ==="
calls() { grep -c "POST /guide/$1 " "$WORK/mock.log"; }
retried() {  # retried desc route before want
    local got=$(( $(calls "$2") - $3 ))
    [[ "$got" == "$4" ]] && pass "$1 ($4 requests)" || fail "$1: $got requests, want $4"
}
export PTC_TRANSIENT_BASE_DELAY=0
n0=$(calls submit); echo '{}' | g submit gt_flaky >"$WORK/out" 2>&1; expect_rc "submit: a 503 is retried -> exit 0" 0 $?
retried "submit: 503 then 2xx" submit "$n0" 2
grep -q "retry 1 of 3" "$WORK/out" && pass "submit says it is retrying" || fail "submit retry message: $(cat "$WORK/out")"
n0=$(calls submit); echo '{}' | g submit gt_down >"$WORK/out" 2>&1; expect_rc "submit: a persistent 503 -> exit 1" 1 $?
retried "submit: one request and 3 retries, then it gives up" submit "$n0" 4
grep -q "Could not reach PTC" "$WORK/out" && grep -q "HTTP 503" "$WORK/out" && pass "submit names the last HTTP code when it gives up" || fail "submit give-up message: $(cat "$WORK/out")"
n0=$(calls submit); echo '{}' | g submit gt_429ra >"$WORK/out" 2>&1; expect_rc "submit: a 429 with Retry-After is retried -> exit 0" 0 $?
retried "submit: 429 + Retry-After then 2xx" submit "$n0" 2
n0=$(calls submit); echo '{}' | g submit gt_429 >"$WORK/out" 2>&1; expect_rc "submit: a 429 without Retry-After is final -> exit 1" 1 $?
retried "submit: a 429 without Retry-After is not retried" submit "$n0" 1
grep -q "HTTP 429" "$WORK/out" && pass "submit names the 429" || fail "submit 429 message: $(cat "$WORK/out")"
n0=$(calls action_runs)
"${NOID[@]}" GITHUB_REF_NAME=ptc-flaky-once PTC_API_TOKEN=project-token "$CLI" guide action-run --api-url "$API" -d "$WORK/repo" --project-id 7 >"$WORK/out" 2>&1; expect_rc "action-run: a 503 is retried -> exit 0" 0 $?
retried "action-run: 503 then 201" action_runs "$n0" 2
grep -q "Reported this run to PTC" "$WORK/out" && pass "action-run reports after the retry" || fail "action-run flaky: $(cat "$WORK/out")"
n0=$(calls delivery_commits)
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide delivery-commit --commit "$tsha" --branch ptc/flaky --source-commit "$sha" --api-url "$API" -d "$WORK/repo" --project-id 7 >"$WORK/out" 2>&1; expect_rc "delivery-commit: a 503 is retried -> exit 0" 0 $?
retried "delivery-commit: 503 then 200" delivery_commits "$n0" 2
n0=$(calls delivery_commits)
"${NOID[@]}" PTC_API_TOKEN=project-token "$CLI" guide delivery-commit --commit "$tsha" --branch ptc/down --source-commit "$sha" --api-url "$API" -d "$WORK/repo" --project-id 7 >"$WORK/out" 2>&1; expect_rc "delivery-commit: a persistent 503 -> exit 1" 1 $?
retried "delivery-commit: one request and 3 retries, then it gives up" delivery_commits "$n0" 4
grep -q "Could not reach PTC" "$WORK/out" && grep -q "HTTP 503" "$WORK/out" && pass "delivery-commit names the last HTTP code when it gives up" || fail "delivery-commit give-up message: $(cat "$WORK/out")"
unset PTC_TRANSIENT_BASE_DELAY

echo; echo "guide suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
