#!/usr/bin/env bash
# P4 T5 (R4; Eran 2026-09-29): `ptc guide mr-description --file CHECK.json` - the GitLab twin of the action's findings
# comment is the translations merge request's description, set by the recipe's push option. The line it prints must be
# ONE line (git refuses a push option with a newline), use `\n` for newlines (GitLab's only unescaping), carry PTC's
# findings when the project setting is on, a fixed neutral text when it is off or PTC gave no answer, and print the
# findings to stderr (the job log) either way. The lab run that proved GitLab's side: lab/runs/p4g/.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
readonly CLI="$TEST_DIR/../ptc-cli.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
# verdict RC PASS_MSG FAIL_MSG
verdict() { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$3"; fi; }
# What GitLab does with the value (MergeRequests::PushOptionsHandlerService#base_params): gsub('\n', "\n"), nothing else.
gitlab_unescape() { python3 -c 'import sys;sys.stdout.write(sys.stdin.read().rstrip("\n").replace("\\n","\n"))'; }

cat > "$WORK/check.json" <<'JSON'
{"verdict":"fail","reasons":[{"code":"under_specified_string","message":"m"}],"notes":[],
 "comment":{"enabled":true,"marker":"<!-- ptc-agent-guide-findings -->",
  "body":"<!-- ptc-agent-guide-findings -->\n### PTC agent guide\n- `under_specified_string` \"Save\" in C:\\new\\file"}}
JSON
desc() { bash "$CLI" guide mr-description --file "$1" 2>"$WORK/err"; }

out="$(desc "$WORK/check.json")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "exit 0"; else fail "exit $rc"; fi
lines="$(printf '%s\n' "$out" | wc -l)"
if [ "$lines" -eq 1 ]; then pass "one line (a push option cannot hold a newline)"; else fail "not one line: $out"; fi
got="$(printf '%s' "$out" | gitlab_unescape)"
case "$got" in
  "<!-- ptc-agent-guide-findings -->"$'\n'"### PTC agent guide"$'\n'*) pass "GitLab reads PTC's findings back as multi-line markdown" ;;
  *) fail "unescaped description: $got" ;;
esac
grep -q 'Set to auto-merge' <<<"$got" && grep -q 'git fetch origin ptc/translations' <<<"$got"; verdict $? "the description adds the auto-merge instruction and the fetch command" "no auto-merge / fetch line: $got"
printf '%s' "$got" | python3 -c 'import sys;sys.exit(0 if "C:\\\u200bnew\\file" in sys.stdin.read() else 1)'; verdict $? "a backslash-n already in the text survives GitLab's unescaping" "backslash-n in the text was not protected: $(printf '%s' "$got" | grep -a 'C:' | od -c | head -3)"
grep -q 'PTC agent-guide findings for this commit' "$WORK/err" && grep -q 'under_specified_string' "$WORK/err"; verdict $? "the findings are in the job log" "no findings on stderr: $(cat "$WORK/err")"

python3 -c "import json,sys; d=json.load(open(sys.argv[1])); d['comment']['enabled']=False; json.dump(d, open(sys.argv[1],'w'))" "$WORK/check.json"
out="$(desc "$WORK/check.json")"
case "$out" in "Translations delivered by PTC."*) pass "project setting off -> the fixed neutral description" ;; *) fail "setting off: $out" ;; esac
! { grep -q 'under_specified_string' <<<"$out"; }; verdict $? "setting off carries no findings" "setting off still carries findings"
grep -q 'under_specified_string' "$WORK/err"; verdict $? "setting off: the findings are still in the job log" "setting off: no findings on stderr"

out="$(desc "$WORK/missing.json")"; rc=$?
[ "$rc" -eq 0 ] && case "$out" in "Translations delivered by PTC."*) true ;; *) false ;; esac; verdict $? "no check answer -> exit 0 and the neutral description" "missing file: rc=$rc out=$out"

python3 - "$WORK/big.json" <<'PY'
import json, sys
body = "<!-- ptc-agent-guide-findings -->\n" + "\n".join("- `under_specified_string` string %d needs a description" % i for i in range(5000))
json.dump({"verdict": "fail", "comment": {"enabled": True, "marker": "x", "body": body}}, open(sys.argv[1], "w"))
PY
out="$(PTC_MR_DESCRIPTION_MAX=4000 bash "$CLI" guide mr-description --file "$WORK/big.json" 2>/dev/null)"
bytes="$(printf '%s' "$out" | wc -c)"
[ "$bytes" -le 4000 ] && grep -q 'cut to fit the merge request' <<<"$out"; verdict $? "a long body is cut to the cap ($bytes bytes) and says so" "cap not applied: $bytes bytes"
out="$(bash "$CLI" guide mr-description --file "$WORK/big.json" 2>/dev/null)"
bytes="$(printf '%s' "$out" | wc -c)"
[ "$bytes" -le 60000 ]; verdict $? "default cap 60000 bytes ($bytes)" "default cap exceeded: $bytes"

# S2-R14 (Eran 2026-10-02): `ptc validate` is gone. A recipe committed before still passes --validate-file: accepted and
# ignored (the description is PTC's findings only, never a validate section).
cat > "$WORK/validate-fail.json" <<'JSON'
{"checked":[{"source":"en.yml","target":"de.yml","lang":"de","entries":1}],"fail":1,"warn":0,
 "findings":[{"level":"FAIL","check":"placeholders","file":"de.yml","lang":"de","key":"users.greeting","detail":"missing %{name}"}]}
JSON
printf '{"verdict":"pass","reasons":[],"comment":{"enabled":true,"body":"### PTC agent guide"}}' > "$WORK/check-on.json"
got="$(bash "$CLI" guide mr-description --file "$WORK/check-on.json" --validate-file "$WORK/validate-fail.json" 2>/dev/null | gitlab_unescape)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '### PTC agent guide' <<<"$got" && ! grep -q -e 'delivery_validate_failed' -e 'ptc validate' <<<"$got"
verdict $? "an older recipe's --validate-file is accepted and ignored" "validate leaked or refused: $got"

# S2-R3 item 2 (decision 5, F13; specs/ci-integrations CI-16): the CI-time limit note the preflight writes to
# PTC_LIMIT_NOTE_FILE is in the merge request description, as the GitHub PR body carries it - with PTC's findings on,
# with the project setting off, and with no check answer at all.
NOTE='**Translation limit reached (PTC balance).** The census is 120 words (2 files x 1 languages); the balance covers 60: 60 words short. The files that fit are translated in census order; left out: locales/b-en.json.'
printf '%s\n' "$NOTE" > "$WORK/limit-note"
got="$(PTC_LIMIT_NOTE_FILE="$WORK/limit-note" bash "$CLI" guide mr-description --file "$WORK/check-on.json" 2>/dev/null | gitlab_unescape)"
grep -qF "$NOTE" <<<"$got" && grep -q '### PTC agent guide' <<<"$got"; verdict $? "the limit note is in the description next to PTC's findings" "no limit note (findings on): $got"
got="$(PTC_LIMIT_NOTE_FILE="$WORK/limit-note" bash "$CLI" guide mr-description --file "$WORK/check.json" 2>/dev/null | gitlab_unescape)"
grep -q 'Translations delivered by PTC.' <<<"$got" && grep -qF "$NOTE" <<<"$got" && ! grep -q 'under_specified_string' <<<"$got"; verdict $? "findings off: the neutral description still carries the limit note" "no limit note (findings off): $got"
got="$(PTC_LIMIT_NOTE_FILE="$WORK/limit-note" bash "$CLI" guide mr-description --file "$WORK/missing.json" 2>/dev/null | gitlab_unescape)"
grep -qF "$NOTE" <<<"$got"; verdict $? "no check answer: the limit note is still there" "no limit note (no check answer): $got"
got="$(PTC_LIMIT_NOTE_FILE="$WORK/no-such-note" bash "$CLI" guide mr-description --file "$WORK/check-on.json" 2>/dev/null | gitlab_unescape)"
! grep -q 'Translation limit reached' <<<"$got"; verdict $? "no note file (limit not reached): nothing added" "a note appeared without a note file: $got"

echo "Total: $((passed + failed))  Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]

