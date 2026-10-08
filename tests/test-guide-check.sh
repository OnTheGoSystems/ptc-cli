#!/bin/bash
# `ptc guide check` (ptc-cli 1.3.0, G8 continuous gate) against the mock PTC API (tests/mock_ptc_api.py
# guide/check route): exit 0 pass / 1 fail / 2 cannot evaluate, and a code + message on every refusal (POL-31).
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
PROJ="$WORK/proj"; mkdir -p "$PROJ"
SHA=dddddddddddddddddddddddddddddddddddddddd
c() { PTC_ORG_TOKEN="${TOKEN-org-token}" "$CLI" guide check --commit "$SHA" --api-url "${URL:-$API}" -d "$PROJ" "$@"; }

echo "=== guide check ==="
c --session-id gs_pass >"$WORK/out" 2>&1; expect_rc "pass -> exit 0" 0 $?
grep -q "guide check: pass" "$WORK/out" && pass "pass is printed" || fail "pass output: $(cat "$WORK/out")"
jcheck "check body = {session_id, commit_sha}" "$BODIES/guide_check.json" "d['body'] == {'session_id': 'gs_pass', 'commit_sha': '$SHA'}"

c --session-id gs_fail >"$WORK/out" 2>&1; expect_rc "fail -> exit 1" 1 $?
grep -q "\[under_specified_string\] app/views/users/edit.html.erb:7" "$WORK/out" && pass "fail lists each reason with its code and file:line" || fail "fail output: $(cat "$WORK/out")"

c --session-id gs_fail --json >"$WORK/out.json" 2>/dev/null; expect_rc "fail --json -> exit 1" 1 $?
jcheck "--json prints PTC's verdict unchanged" "$WORK/out.json" "d['verdict'] == 'fail' and d['reasons'][0]['key'] == 'users.save'"

c --session-id gs_norun >"$WORK/out" 2>&1; expect_rc "no run for the commit -> exit 2" 2 $?
grep -q "cannot evaluate (run_missing)" "$WORK/out" && pass "run_missing refusal prints PTC's code and message" || fail "run_missing output: $(cat "$WORK/out")"

c --session-id gs_nope --json >"$WORK/out.json" 2>/dev/null; expect_rc "unknown session -> exit 2" 2 $?
jcheck "--json refusal carries error.code + error.message" "$WORK/out.json" "d['error']['code'] == 'no_session' and d['error']['message']"

URL="http://127.0.0.1:1/api/v1/" c --session-id gs_pass --json >"$WORK/out.json" 2>/dev/null; expect_rc "PTC unreachable -> exit 2" 2 $?
jcheck "unreachable refusal has a code" "$WORK/out.json" "d['error']['code'] == 'ptc_unreachable'"

TOKEN="" c --session-id gs_pass >"$WORK/out" 2>&1; expect_rc "no token -> exit 2" 2 $?
grep -q "cannot evaluate (no_token)" "$WORK/out" && pass "no_token refusal is named" || fail "no_token output: $(cat "$WORK/out")"

(cd "$PROJ" && PTC_ORG_TOKEN=org-token "$CLI" guide check --api-url "$API" -d "$PROJ" --json >"$WORK/out.json" 2>/dev/null); expect_rc "no session and no git repo -> exit 2" 2 $?
jcheck "no session refusal is named" "$WORK/out.json" "d['error']['code'] == 'no_session'"

# P3D-4 (lab p3d, suite repo B): check ignored the product's guide.session_id and resolved the suite root by origin.
SUITE="$WORK/suite"; mkdir -p "$SUITE/acfml"
printf 'source_locale: en\nguide:\n  project_id: 1236\n  session_id: gs_prod   # the product session\n' > "$SUITE/acfml/.ptc-config.yml"
PTC_ORG_TOKEN=org-token "$CLI" guide check --commit "$SHA" --api-url "$API" -d "$SUITE/acfml" --json >"$WORK/out.json" 2>/dev/null; expect_rc "product dir -> its guide.session_id is checked" 0 $?
jcheck "check body names the product session from .ptc-config.yml" "$BODIES/guide_check.json" "d['body']['session_id'] == 'gs_prod'"
cp "$SUITE/acfml/.ptc-config.yml" "$WORK/other.yml"
PTC_ORG_TOKEN=org-token "$CLI" guide check --commit "$SHA" --api-url "$API" -d "$PROJ" -c "$WORK/other.yml" --json >/dev/null 2>&1; expect_rc "-c config -> its guide.session_id" 0 $?
jcheck "-c names the session" "$BODIES/guide_check.json" "d['body']['session_id'] == 'gs_prod'"
PTC_ORG_TOKEN=org-token "$CLI" guide check --commit "$SHA" --api-url "$API" -d "$SUITE/acfml" --session-id gs_fail >/dev/null 2>&1; expect_rc "--session-id outranks the config" 1 $?

cmp -s "$CLI" "$(dirname "$(dirname "$TEST_DIR")")/action/ptc-cli.sh" && pass "action/ptc-cli.sh is byte-identical to cli/ptc-cli.sh" || fail "action/ptc-cli.sh differs from cli/ptc-cli.sh"
grep -q "guide check --json --api-url" "$(dirname "$(dirname "$TEST_DIR")")/action/action.yml" && pass "the action exposes the guide check step" || fail "action.yml has no guide check step"

# action.yml order (P4 R2, check-first): the check runs BEFORE the translate call, never exits the Translate step, and
# its failure is reported in its own last step after the pull request and the findings comment.
python3 - "$(dirname "$(dirname "$TEST_DIR")")/action/action.yml" <<'PY' && pass "action: check before translate, failure in its own later step" || fail "action.yml check order"
import sys
s = open(sys.argv[1]).read()
translate = s.index('"$CLI" "${args[@]}" || cli_rc=$?')
check = s.index('"$CLI" "${check_args[@]}" > "$CHECK_JSON" || check_rc=$?')
fail_step = s.index('- name: Fail on the agent-guide check')
pr_step = s.index('- name: Create/update translation pull request')
comment_step = s.index('- name: Comment the agent-guide findings')
block = s[check:s.index('PY_CHECK', check)]
sys.exit(0 if check < translate < pr_step < comment_step < fail_step and 'exit' not in block else 1)
PY

# action.yml (P3-FIX7, AGD-12, POL-40): a failed translation (rc other than 0 / 5 / 6) still runs the check report-only, the
# Translate step keeps the translation's exit code, and the last step reports both the translate failure and the verdict.
python3 - "$(dirname "$(dirname "$TEST_DIR")")/action/action.yml" <<'PY' && pass "action: check runs report-only after a failed translation; last step reports both" || fail "action.yml translate-failure reporting"
import sys
s = open(sys.argv[1]).read()
check = s.index('"$CLI" "${check_args[@]}" > "$CHECK_JSON" || check_rc=$?')
stop = s.index('if [ "$cli_rc" -ne 0 ] && [ "$cli_rc" -ne 5 ] && [ "$cli_rc" -ne 6 ] && [ "$cli_rc" -ne 7 ]; then')
step = s[s.index('- name: Fail on the agent-guide check'):s.index('- name: Fail on files PTC rejected')]
cond = step[step.index('if:'):step.index('\n', step.index('if:'))]
ok = check < stop and "steps.ptc.outcome == 'failure'" in cond and '!cancelled()' in cond
ok = ok and 'PTC translate step failed' in step and 'PTC agent-guide check:' in step and 'exit "${CHECK_RC:-2}"' in step
sys.exit(0 if ok else 1)
PY

# The same order, executed: a failing check (rc 1) then a failing translate (rc 1) -> the check never stops the
# translation, the Translate block exits 1 after writing guide-check=fail; the last step prints both and exits with the
# check's rc under guide-check-fail.
python3 - "$(dirname "$(dirname "$TEST_DIR")")/action/action.yml" "$WORK" <<'PY' && pass "action: executed order - check rc 1 reported, then translate rc 1, last step exits 1" || fail "action.yml executed order"
import os, subprocess, sys
s, tmp = open(sys.argv[1]).read(), sys.argv[2]
start = s.index('        # P4 (R2, check-first)')
end = s.index('        # The pull request must carry translation output')
body = "\n".join(l[8:] for l in s[start:end].splitlines())
fake = os.path.join(tmp, 'fake-cli.sh')
open(fake, 'w').write('#!/bin/bash\n[ "$1" = guide ] && { echo check >> "$LOG"; exit 1; }\necho translate >> "$LOG"; exit 1\n')
os.chmod(fake, 0o755)
out, log = os.path.join(tmp, 'gh_out'), os.path.join(tmp, 'calls')
for f in (out, log):
    open(f, 'w').close()
env = dict(os.environ, CLI=fake, GITHUB_OUTPUT=out, LOG=log, INPUT_GUIDE_CHECK='true', INPUT_API_URL='http://x', CONFIG='')
script = 'args=( --api-url x )\n' + body
rc = subprocess.run(['bash', '-c', script], env=env).returncode
outputs = open(out).read()
calls = open(log).read().split()
if not (rc == 1 and calls == ['check', 'translate'] and 'guide-check=fail' in outputs and 'guide-check-rc=1' in outputs):
    print('translate block:', rc, calls, outputs); sys.exit(1)
step = s[s.index('- name: Fail on the agent-guide check'):s.index('- name: Fail on files PTC rejected')]
run = "\n".join(l[8:] for l in step[step.index('run: |') + 7:].splitlines())
env = dict(os.environ, VERDICT='fail', CHECK_RC='1', CLI_EXIT='1', TRANSLATE='failure', FAIL_ON_CHECK='true')
res = subprocess.run(['bash', '-c', run], env=env, capture_output=True, text=True)
ok = res.returncode == 1 and 'PTC translate step failed (exit 1)' in res.stdout and 'PTC agent-guide check: fail (rc 1' in res.stdout
env.update(VERDICT='pass', CHECK_RC='0', FAIL_ON_CHECK='false')
res2 = subprocess.run(['bash', '-c', run], env=env, capture_output=True, text=True)
ok = ok and res2.returncode == 1 and 'check: pass (rc 0)' in res2.stdout and 'translate step failed' in res2.stdout
print(res.stdout, res2.stdout) if not ok else None
sys.exit(0 if ok else 1)
PY

echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
