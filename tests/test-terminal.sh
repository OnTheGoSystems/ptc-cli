#!/bin/bash
# E18: a signal ends the CLI (128+n; `timeout` works). E20: files PTC refuses (processing 422, draft forever,
# status rejected) are terminal; the other files are still downloaded, and the run exits 5 with a summary.
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
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
expect_rc() { if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1 (rc $3, want $2)"; fi; }
WORK=$(mktemp -d)
PIDS=()
cleanup() { stop_mocks "${PIDS[@]}"; rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {  # start_mock VAR port... (env passed through) -> sets VAR to the API url
    local var="$1" port pid i; shift
    for port in "$@"; do
        refuse_busy_port "$port"
        PTC_MOCK_PORT="$port" python3 "$MOCK" >>"$WORK/mock-$port.log" 2>&1 &
        pid=$!
        for i in $(seq 1 30); do
            if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
                PIDS+=("$pid"); printf -v "$var" 'http://127.0.0.1:%s/api/v1/' "$port"; return 0
            fi
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.3
        done
        kill "$pid" 2>/dev/null
    done
    echo "mock did not come up"; exit 1
}

R="$WORK/repo"; mkdir -p "$R/config/locales"
for n in a b c d; do printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$R/config/locales/$n.en.yml"; done
{
  echo "source_locale: en"
  echo "files:"
  for n in a b c d; do printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n"; done
} > "$R/.ptc-config.yml"
git -C "$R" init -q

API=""; PTC_MOCK_REJECT_PROCESS=config/locales/b.en.yml PTC_MOCK_DRAFT=config/locales/c.en.yml PTC_MOCK_REJECTED=config/locales/d.en.yml start_mock API 19187 19197 19207
SLOW=""; PTC_MOCK_PENDING=100000 start_mock SLOW 19217 19227 19237

echo "=== E20: rejected files are terminal, the rest is delivered ==="
start=$SECONDS
( cd "$R" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 30 ) >"$WORK/e20.out" 2>&1
rc=$?; took=$((SECONDS - start))
expect_rc "only PTC-rejected files missing -> exit 5 (partial)" 5 $rc
[[ $took -le 12 ]] && pass "the run ends on terminal states (${took}s), not at the attempt limit" || fail "run took ${took}s"
[[ $(find "$R/config/locales" -name 'a.*' ! -name a.en.yml | wc -l) -eq 2 ]] && pass "the completed file's translations are written" || fail "a.* not written: $(ls "$R/config/locales")"
if [[ $(find "$R/config/locales" -name '[bcd].*' ! -name '?.en.yml' | wc -l) -eq 0 ]]; then pass "nothing is written for the rejected files"; else fail "rejected files were written"; fi
out=$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/e20.out")
[[ $(grep -c "YAML aliases are not allowed" <<<"$out") == 1 ]] && pass "the processing 422 reason is printed once" || fail "422 reason count: $(grep -c "YAML aliases" <<<"$out")"
[[ $(grep -c "c.en.yml (status: draft); will retry" <<<"$out") == 1 ]] && grep -q "c.en.yml (still draft after 3 checks): rejected" <<<"$out" && pass "draft: one warning, then terminal after 3 checks" || fail "draft lines: $(grep c.en.yml <<<"$out")"
grep -q "PTC rejected config/locales/d.en.yml (status: rejected)" <<<"$out" && pass "status rejected is terminal" || fail "rejected status: $(grep d.en.yml <<<"$out" | head -3)"
summary=$(sed -n '/Rejected by PTC/,$p' <<<"$out")
grep -q "Rejected by PTC.*: 3" <<<"$summary" && grep -q "⊘ config/locales/b.en.yml" <<<"$summary" && grep -q "⊘ config/locales/c.en.yml" <<<"$summary" && grep -q "⊘ config/locales/d.en.yml" <<<"$summary" && pass "the summary lists the rejected files" || fail "summary: $summary"
grep -q "Run partial: 1 completed and written, 3 rejected by PTC" <<<"$out" && pass "partial summary line" || fail "partial line missing"
find "$R/config/locales" -name 'a.*' ! -name a.en.yml -delete
sed -i '/b.en.yml\|c.en.yml\|d.en.yml/d; /b.{{lang}}\|c.{{lang}}\|d.{{lang}}/d' "$R/.ptc-config.yml"
( cd "$R" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 ) >/dev/null 2>&1; expect_rc "no rejected files -> exit 0 (unchanged)" 0 $?

echo "=== S2-R12: a transient 503 on process is retried, and an unreachable file is not called rejected ==="
U="$WORK/unreach"; mkdir -p "$U/config/locales"; git -C "$U" init -q
for n in a b c; do printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$U/config/locales/$n.en.yml"; done
{ echo "source_locale: en"; echo "files:"
  for n in a b c; do printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n"; done; } > "$U/.ptc-config.yml"
UNREACH=""; PTC_MOCK_PROCESS_503_ONCE=config/locales/b.en.yml PTC_MOCK_PROCESS_503=config/locales/c.en.yml start_mock UNREACH 19277 19287 19297
( cd "$U" && PTC_TRANSIENT_BASE_DELAY=0 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$UNREACH" --monitor-interval 1 --monitor-max-attempts 30 ) >"$WORK/unreach.out" 2>&1
rc=$?; out=$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/unreach.out")
expect_rc "a file PTC was never reached for still delivers the rest (exit 5, partial)" 5 $rc
nb=$(find "$U/config/locales" -name 'b.*' ! -name b.en.yml | wc -l); na=$(find "$U/config/locales" -name 'a.*' ! -name a.en.yml | wc -l)
[[ $nb -gt 0 && $nb -eq $na ]] && pass "a 503 that clears on retry completes the file" || fail "b.* not written: $(ls "$U/config/locales")"
grep -q "Rejected by PTC" <<<"$out" && fail "a transient 503 is reported as a PTC rejection: $(grep -A2 'Rejected by PTC' <<<"$out")" || pass "no file is called rejected by PTC"
summary=$(sed -n '/Could not reach PTC/,$p' <<<"$out")
grep -q "⊘ config/locales/c.en.yml\|✗ config/locales/c.en.yml" <<<"$summary" && pass "the summary lists the unreachable file under 'Could not reach PTC'" || fail "summary: $(tail -8 <<<"$out")"
grep -q "ERR_NGROK_3004" <<<"$out" && pass "the proxy's own error code reaches the log" || fail "no ERR_NGROK_3004 in the log"

echo "=== S2-R10 + S2-R15 (D1): a run with files parked for over-limit approval delivers the rest, then ends with the reason ==="
P="$WORK/parked"; mkdir -p "$P/config/locales"; git -C "$P" init -q
for n in a b c; do printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$P/config/locales/$n.en.yml"; done
{ echo "source_locale: en"; echo "files:"
  for n in a b c; do printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n"; done; } > "$P/.ptc-config.yml"
PARKED=""; PTC_MOCK_AWAITING_APPROVAL=config/locales/a.en.yml PTC_MOCK_APPROVAL_EXPIRED=config/locales/b.en.yml start_mock PARKED 19247 19257 19267
start=$SECONDS
( cd "$P" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$PARKED" --monitor-interval 1 --monitor-max-attempts 30 ) >"$WORK/parked.out" 2>&1
rc=$?; took=$((SECONDS - start)); out=$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/parked.out")
expect_rc "files parked for approval, the rest written -> exit 6 (delivered, then the job fails)" 6 $rc
[[ $took -le 12 ]] && pass "the run ends on the approval states (${took}s), not at the attempt limit" || fail "parked run took ${took}s"
[[ $(find "$P/config/locales" -name 'c.*' ! -name c.en.yml | wc -l) -eq 2 ]] && pass "the file that was not parked is downloaded and written" || fail "c.* not written: $(ls "$P/config/locales")"
[[ $(find "$P/config/locales" -name '[ab].*' ! -name '?.en.yml' | wc -l) -eq 0 ]] && pass "nothing is written for the parked files" || fail "parked files were written"
grep -q "config/locales/a.en.yml is waiting for an over-limit approval in PTC" <<<"$out" && pass "awaiting_approval names the wait and the remedy" || fail "awaiting line: $(grep a.en.yml <<<"$out" | head -3)"
grep -q "config/locales/b.en.yml: the over-limit approval expired" <<<"$out" && pass "approval_expired is terminal and named" || fail "expired line: $(grep b.en.yml <<<"$out" | head -3)"
summary=$(sed -n '/Parked for an over-limit approval/,$p' <<<"$out")
grep -q "Parked for an over-limit approval in PTC.*: 2" <<<"$summary" && grep -q "config/locales/a.en.yml (awaiting_approval)" <<<"$summary" && grep -q "config/locales/b.en.yml (approval_expired)" <<<"$summary" && pass "the summary lists the parked files with their state" || fail "summary: $(tail -12 <<<"$out")"
grep -q "Run partial: 1 completed and written, 2 parked for an over-limit approval" <<<"$out" && pass "partial summary line names the parked files" || fail "partial line: $(grep 'Run ' <<<"$out")"
grep -q "the next run picks them up once the approval is given" <<<"$out" && pass "the remedy says the next run picks them up after the approval" || fail "remedy line missing"
grep -q "Failed files" <<<"$out" && fail "parked files are reported as failed" || pass "parked files are not called failed"
# Only parked files (nothing else completed): still exit 6, nothing to deliver.
sed -i '/c.en.yml/d; /c.{{lang}}/d' "$P/.ptc-config.yml"; find "$P/config/locales" -name 'c.*' ! -name c.en.yml -delete
( cd "$P" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$PARKED" --monitor-interval 1 --monitor-max-attempts 30 ) >/dev/null 2>&1
expect_rc "every file parked -> exit 6" 6 $?
echo "=== S2-R28-3 (SF-10; TRN-23/24): out-of-credit files pause, the complete files are delivered, the run is partial ==="
O="$WORK/credit"; mkdir -p "$O/config/locales"; git -C "$O" init -q
for n in a b c; do printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$O/config/locales/$n.en.yml"; done
{ echo "source_locale: en"; echo "files:"
  for n in a b c; do printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n"; done; } > "$O/.ptc-config.yml"
CREDIT=""; PTC_MOCK_OUT_OF_CREDIT=config/locales/a.en.yml,config/locales/b.en.yml start_mock CREDIT 19337 19347 19357
( cd "$O" && PTC_LIMIT_NOTE_FILE="$WORK/credit-note" PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$CREDIT" --monitor-interval 1 --monitor-max-attempts 30 ) >"$WORK/credit.out" 2>&1
rc=$?; out=$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/credit.out")
grep -q "Paused out-of-credit in PTC.*config/locales/a.en.yml, config/locales/b.en.yml" "$WORK/credit-note" 2>/dev/null && grep -q "tops up or upgrades" "$WORK/credit-note" \
    && pass "(l) the delivery merge request's note (PTC_LIMIT_NOTE_FILE) lists the paused files" || fail "(l) note: $(cat "$WORK/credit-note" 2>&1)"
expect_rc "(l) files paused out-of-credit, the rest written -> exit 6 (delivered, then the job fails)" 6 $rc
[[ $(find "$O/config/locales" -name 'c.*' ! -name c.en.yml | wc -l) -eq 2 ]] && pass "(l) the complete file is written" || fail "c.* not written: $(ls "$O/config/locales")"
[[ $(find "$O/config/locales" -name '[ab].*' ! -name '?.en.yml' | wc -l) -eq 0 ]] && pass "(l) nothing is written for the paused files" || fail "paused files were written"
summary=$(sed -n '/Paused out-of-credit in PTC/,$p' <<<"$out")
grep -q "Paused out-of-credit in PTC.*: 2" <<<"$summary" && grep -q "config/locales/a.en.yml (out_of_credit)" <<<"$summary" && grep -q "config/locales/b.en.yml (out_of_credit)" <<<"$summary" \
    && pass "(l) the summary lists the paused files" || fail "summary: $(tail -12 <<<"$out")"
grep -q "Run partial: 1 completed and written, 2 paused out-of-credit in PTC" <<<"$out" && pass "(l) the partial line names the paused files" || fail "partial line: $(grep 'Run ' <<<"$out")"
grep -q "resume when the organization tops up or upgrades" <<<"$out" && pass "(l) the remedy says top-up resumes them" || fail "remedy missing: $(tail -6 <<<"$out")"
grep -q "Failed files" <<<"$out" && fail "(l) paused files are reported as failed" || pass "(l) paused files are not called failed"
# (o) nothing complete: today's failure, exit 1 (the job stops before the push; there is nothing to deliver).
sed -i '/c.en.yml/d; /c.{{lang}}/d' "$O/.ptc-config.yml"; find "$O/config/locales" -name 'c.*' ! -name c.en.yml -delete
( cd "$O" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$CREDIT" --monitor-interval 1 --monitor-max-attempts 30 ) >"$WORK/credit0.out" 2>&1
rc=$?
expect_rc "(o) every file paused out-of-credit, nothing complete -> exit 1" 1 $rc
grep -q "nothing completed" "$WORK/credit0.out" && pass "(o) the failure says nothing completed" || fail "(o): $(tail -5 "$WORK/credit0.out")"
# (m) the generated GitLab job delivers on the partial code before it fails the job.
job=$(source <(sed -n '/^render_ci_gitlab() {$/,/^}$/p' "$CLI"); VERSION=x render_ci_gitlab)
grep -q -- '-ne 6 ]' <<<"$job" && grep -q 'eq 6 ]; then echo "Some files wait in PTC' <<<"$job" && grep -q "paused out-of-credit" <<<"$job" \
    && pass "(m) the GitLab job continues to the delivery on exit 6 and names out-of-credit at the end" || fail "(m) job: $(grep -n 'ptc_rc' <<<"$job" | head -5)"

# The legacy (no config file) path classifies the same way.
L="$WORK/legacy"; mkdir -p "$L/locales"; git -C "$L" init -q
printf 'en:\n  a: "Hello a"\n' > "$L/locales/a.en.yml"; printf 'en:\n  c: "Hello c"\n' > "$L/locales/c.en.yml"
LEG=""; PTC_MOCK_AWAITING_APPROVAL=locales/a.en.yml start_mock LEG 19307 19317 19327
( cd "$L" && PTC_API_TOKEN=t "$CLI" --source-locale en --patterns 'locales/*.en.yml' --api-url "$LEG" --monitor-interval 1 --monitor-max-attempts 30 ) >"$WORK/legacy.out" 2>&1
rc=$?; out=$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/legacy.out")
expect_rc "patterns mode: parked file + completed file -> exit 6" 6 $rc
grep -q "Run partial: 1 completed and written, 1 parked for an over-limit approval" <<<"$out" && pass "patterns mode: partial line" || fail "patterns mode: $(tail -8 <<<"$out")"

echo "=== E18: signals end the run ==="
start=$SECONDS
( cd "$R" && PTC_API_TOKEN=t timeout 2 "$CLI" --config-file .ptc-config.yml --api-url "$SLOW" --monitor-interval 30 --monitor-max-attempts 100 ) >"$WORK/t.out" 2>&1
rc=$?; took=$((SECONDS - start))
# GNU timeout reports 124; BusyBox timeout (the alpine CI image) passes on the child's own status, 143 = TERM.
[[ $rc == 124 || $rc == 143 ]] && pass "timeout 2 stops a monitoring run (rc $rc: 124 GNU / 143 BusyBox)" || fail "timeout 2 rc $rc, want 124 or 143"
[[ $took -le 5 ]] && pass "stopped within ${took}s" || fail "timeout took ${took}s"
( cd "$R" && exec env PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$SLOW" --monitor-interval 30 --monitor-max-attempts 100 ) >"$WORK/k.out" 2>&1 &
pid=$!; sleep 2; start=$SECONDS; kill -TERM "$pid"; wait "$pid"; rc=$?; took=$((SECONDS - start))
expect_rc "SIGTERM to the CLI alone (sleeping in the monitor loop) -> exit 143" 143 $rc
[[ $took -le 2 ]] && pass "it does not finish the 30 s sleep first (${took}s)" || fail "TERM took ${took}s"
( exec env PTC_API_TOKEN=t "$CLI" --config-file "$R/.ptc-config.yml" -d "$R" --api-url "$SLOW" --monitor-interval 30 ) >/dev/null 2>&1 &
pid=$!; sleep 2; kill -HUP "$pid"; wait "$pid"; expect_rc "SIGHUP -> exit 129" 129 $?
W="$WORK/w"; mkdir -p "$W/.ptc"; echo '{"session_id": "gs_mock", "project_id": "7"}' > "$W/.ptc/session.json"
( exec env PTC_GUIDE_WAIT_CAP=1 PTC_ORG_TOKEN=o "$CLI" guide wait gt_never --timeout 60 --api-url "$API" -d "$W" ) >/dev/null 2>&1 &
pid=$!; sleep 2; start=$SECONDS; kill -TERM "$pid"; wait "$pid"; rc=$?; took=$((SECONDS - start))
expect_rc "guide wait: SIGTERM -> exit 143" 143 $rc
[[ $took -le 2 ]] && pass "guide wait stops at once (${took}s)" || fail "guide wait TERM took ${took}s"
start=$SECONDS; PTC_GUIDE_WAIT_CAP=1 PTC_ORG_TOKEN=o timeout 2 "$CLI" guide wait gt_never --timeout 60 --api-url "$API" -d "$W" >/dev/null 2>&1; rc=$?
[[ $rc == 124 || $rc == 143 ]] && pass "guide wait under timeout 2 stops (rc $rc)" || fail "guide wait under timeout 2: rc $rc, want 124 or 143"
grep -q "^trap cleanup EXIT$" "$CLI" && ! grep -q "^trap cleanup EXIT INT TERM" "$CLI" && pass "cleanup is an EXIT trap; signals exit" || fail "trap lines"

echo "=== E20 delivery: CI recipes deliver a partial run, then fail ==="
bash -c 'source "$1" >/dev/null 2>&1; render_ci_gitlab' _ "$CLI" > "$WORK/gl.yml"
# Plain-text checks: the CI image's python has no PyYAML.
python3 - "$WORK/gl.yml" <<'PY' && pass "GitLab recipe: rc captured, only 0/5/6 reach the push, exit 5 / 6 after the push" || fail "gitlab recipe order"
import sys
text = open(sys.argv[1]).read()
job = [l[6:] for l in text.split("\n") if l.startswith("    - ")]
i_run = next(i for i, l in enumerate(job) if "--written-manifest" in l and "|| ptc_rc=$?" in l)
i_gate = next(i for i, l in enumerate(job) if '-ne 5 ] && [ "$ptc_rc" -ne 6 ] && [ "$ptc_rc" -ne 7 ]; then exit "$ptc_rc"' in l)
i_push = text.index("git push")
i_fail = next(i for i, l in enumerate(job) if '"$ptc_rc" -eq 5 ]' in l and "exit 5" in l)
i_park = next(i for i, l in enumerate(job) if '"$ptc_rc" -eq 6 ]' in l and "exit 6" in l and "over-limit approval" in l)
# S2-R3B F-2 (CI-16): exit 7 (still translating at the monitor bound) reaches the push too, reports the stop, and is the last step.
i_stop = next(i for i, l in enumerate(job) if '"$ptc_rc" -eq 7 ]' in l and "exit 7" in l and "still running in PTC" in l)
assert job[i_run - 1] == "ptc_rc=0" and i_run < i_gate < i_fail < i_park < i_stop == len(job) - 1, job
assert text.index('-ne 7 ]; then exit') < i_push < text.index('"$ptc_rc" -eq 5 ]')
assert text.index("git push") < text.index("guide delivery-commit") < text.index('"$ptc_rc" -eq 6 ]')
assert text.index("--stopped-reason monitor_bound") < i_push and text.count("guide delivery-commit") == 2  # with the commit, or alone
PY
python3 - "$(dirname "$(dirname "$TEST_DIR")")/action/action.yml" <<'PY' && pass "action: exit 5 / 6 still stage, open the PR and report the delivery commit, then a last step fails the job" || fail "action.yml delivery steps"
import sys
t = open(sys.argv[1]).read()
ptc = t[t.index("      id: ptc\n"):t.index("    - name: Create/update translation pull request")]
assert '"$CLI" "${args[@]}" || cli_rc=$?' in ptc and 'echo "cli-exit=$cli_rc" >> "$GITHUB_OUTPUT"' in ptc
assert '[ "$cli_rc" -ne 5 ] && [ "$cli_rc" -ne 6 ] && [ "$cli_rc" -ne 7 ]' in ptc and ptc.index("cli_rc=$?") < ptc.index("add-paths")
steps = [l for l in t.split("\n") if l.startswith("    - name: ")]
assert steps[-3:] == ["    - name: Fail on files PTC rejected", "    - name: Fail on files parked for an over-limit approval",
                      "    - name: Fail on files still translating in PTC"], steps
rej = t[t.index("    - name: Fail on files PTC rejected"):t.index("    - name: Fail on files parked")]
assert "if: ${{ steps.ptc.outputs.cli-exit == '5' }}" in rej and "exit 5" in rej
assert "PTC rejected some source files or could not be reached for them (listed under 'Rejected by PTC' / 'Could not reach PTC' in the Translate step)" in rej, rej  # S2-R19-3
park = t[t.index("    - name: Fail on files parked for an over-limit approval"):t.index("    - name: Fail on files still translating")]
assert "if: ${{ steps.ptc.outputs.cli-exit == '6' }}" in park and "exit 6" in park
# S2-R3B F-2 (CI-16): exit 7 is delivered and reported the same way (the report step runs on 7 even without a pull request).
last = t[t.index("    - name: Fail on files still translating in PTC"):]
assert "if: ${{ steps.ptc.outputs.cli-exit == '7' }}" in last and "exit 7" in last and "still running in PTC" in last
report = t[t.index("    - name: Report the translations-branch commit to PTC"):t.index("    - name: Comment the agent-guide findings")]
assert "steps.ptc.outputs.cli-exit == '7'" in report and "--stopped-reason monitor_bound" in report
assert t.index("    - name: Report the translations-branch commit to PTC") < t.index("    - name: Fail on files parked")
PY

echo; echo "terminal suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
