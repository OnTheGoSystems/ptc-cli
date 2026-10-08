#!/bin/bash
# L3-1 (POL-116, AGD-4): `ptc guide action-run` carries the content proof of the working tree: workspace_fingerprint (from
# `ptc scan`), files_sha = the sha256 of the config file AND of every census source file (the bytes on disk at run time),
# ignored_outputs, and provenance_request: agent_local when it does not run in CI. Without git no commit_sha is sent (the
# door keys the run by the fingerprint, Guide::RunKey). In CI the identity-token path is unchanged. Runs against the mock.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
readonly MINT="$(dirname "$TEST_DIR")/tools/mint-lab-ci-token.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); BODIES="$WORK/bodies"; mkdir -p "$BODIES"
MOCK_PID=""
cleanup() { [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT

PORT=19761
python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && { echo "port $PORT busy"; exit 1; }
PTC_MOCK_PORT=$PORT PTC_MOCK_BODY_DIR="$BODIES" PTC_MOCK_LAB_SECRET=lab-secret python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
API="http://127.0.0.1:$PORT/api/v1/"

# Every CI marker the CLI reads, cleared: the run happens on "the agent's machine".
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN)
body() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print($1)" "$BODIES/guide_action_runs.json" 2>/dev/null; }

T="$WORK/tree"; mkdir -p "$T/config/locales" "$T/src/locales/en"
printf 'en:\n  hello: "Grüße"\n  bye: "Tschüss ✓"\n' > "$T/config/locales/en.yml"
printf '{"save": "Save", "title": "Café"}\n' > "$T/src/locales/en/common.json"
cat > "$T/.ptc-config.yml" <<'YML'
source_locale: en
files:
  - file: config/locales/en.yml
    output: config/locales/{{lang}}.yml
  - file: src/locales/en/common.json
    output: src/locales/{{lang}}/common.json
guide:
  project_id: 42
YML

echo "=== without git, outside CI ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" --out "$WORK/resp.json" >"$WORK/ar.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "the run is reported (exit 0)" || fail "action-run exit $rc: $(cat "$WORK/ar.out")"
"$CLI" scan --json -d "$T" -c "$T/.ptc-config.yml" > "$WORK/scan.json" 2>/dev/null
fp=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['repo']['workspace_fingerprint'])" "$WORK/scan.json")
[[ "$fp" =~ ^[0-9a-f]{64}$ && "$(body "d.get('workspace_fingerprint')")" == "$fp" ]] && pass "workspace_fingerprint is ptc scan's" || fail "fingerprint: body '$(body "d.get('workspace_fingerprint')")' scan '$fp'"
[[ "$(body "'commit_sha' in d")" == "False" ]] && pass "no commit_sha is sent without git" || fail "commit_sha sent: '$(body "d.get('commit_sha')")'"
[[ "$(body "d.get('provenance_request')")" == "agent_local" ]] && pass "provenance_request is agent_local outside CI" || fail "provenance_request: '$(body "d.get('provenance_request')")'"
[[ "$(body "d.get('ci_id_token')")" == "None" ]] && pass "no identity token outside CI" || fail "ci_id_token: $(body "d.get('ci_id_token')")"
[[ "$(body "d.get('ignored_outputs')")" == "[]" ]] && pass "ignored_outputs (ptc config validate --json) rides along" || fail "ignored_outputs: $(body "d.get('ignored_outputs')")"
for f in .ptc-config.yml config/locales/en.yml src/locales/en/common.json; do
    want=$(sha256sum "$T/$f" | cut -d' ' -f1)
    [[ "$(body "d['files_sha'].get('$f')")" == "$want" ]] && pass "files_sha[$f] = sha256sum of the bytes on disk" || fail "files_sha[$f]: '$(body "d['files_sha'].get('$f')")' want $want"
done
[[ "$(body "len(d['files_sha'])")" == "3" ]] && pass "files_sha holds the config and the census sources, nothing else" || fail "files_sha keys: $(body "sorted(d['files_sha'])")"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('run_id') else 1)" "$WORK/resp.json" 2>/dev/null \
    && pass "--out keeps PTC's answer (run_id)" || fail "--out: $(cat "$WORK/resp.json" 2>/dev/null)"

printf '{"save": "Save!", "title": "Café"}\n' > "$T/src/locales/en/common.json"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" >/dev/null 2>&1
want=$(sha256sum "$T/src/locales/en/common.json" | cut -d' ' -f1)
[[ "$(body "d['files_sha'].get('src/locales/en/common.json')")" == "$want" && "$(body "d.get('workspace_fingerprint')")" != "$fp" ]] \
    && pass "an edited source: its new digest and a new fingerprint are reported" || fail "edited source not re-digested"

echo "=== with git, outside CI ==="
git -C "$T" init -q && git -C "$T" add -A && git -C "$T" -c user.email=t@example.com -c user.name=t commit -qm init
head=$(git -C "$T" rev-parse HEAD)
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" >/dev/null 2>&1
[[ "$(body "d.get('commit_sha')")" == "$head" ]] && pass "the commit sha is sent when git has one" || fail "commit_sha with git: '$(body "d.get('commit_sha')")'"
[[ "$(body "d.get('provenance_request')")" == "agent_local" && "$(body "d.get('workspace_fingerprint')")" =~ ^[0-9a-f]{64}$ ]] \
    && pass "still agent_local, with the fingerprint" || fail "git run: $(body "d.get('provenance_request'), d.get('workspace_fingerprint')")"

echo "=== in CI (identity token): the identity path is unchanged ==="
lab=$(GUIDE_LAB_CI_SECRET=lab-secret python3 "$MINT" --repository lab/app --sha "$head" --ref refs/heads/main)
"${NOCI[@]}" CI_COMMIT_SHA="$head" PTC_ID_TOKEN="$lab" PTC_API_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" >"$WORK/ci.out" 2>&1
[[ "$(body "d.get('ci_id_token')")" == "$lab" ]] && pass "CI: the identity token is posted as ci_id_token" || fail "CI ci_id_token"
[[ "$(body "'provenance_request' in d")" == "False" ]] && pass "CI: no provenance_request" || fail "CI provenance_request: $(body "d.get('provenance_request')")"
grep -q "provenance: ci_verified" "$WORK/ci.out" && pass "CI: the signed token -> ci_verified" || fail "CI provenance: $(cat "$WORK/ci.out")"
"${NOCI[@]}" GITLAB_CI=true CI_COMMIT_SHA="$head" PTC_API_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" >"$WORK/ci2.out" 2>&1
[[ "$(body "'provenance_request' in d")" == "False" ]] && grep -q "No CI identity token" "$WORK/ci2.out" \
    && pass "CI without an identity token: no agent_local request, the identity warning as before" || fail "CI without token: $(body "d.get('provenance_request')") / $(cat "$WORK/ci2.out")"

echo ""
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
