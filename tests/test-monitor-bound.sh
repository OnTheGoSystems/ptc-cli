#!/bin/bash
# S2-R3B F-2 (CI-16; Eran 2026-10-04 "explicit options"): a run that stops at its monitor bound (wall clock from the first
# upload, or the attempts cap) with files still translating writes every completed file, lists the files still translating
# with their state, prints the three options with the exact commands, and exits 7 (not a generic 1).
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
has() { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing: $3)"; fi; }
hasre() { if grep -qE -- "$3" "$2"; then pass "$1"; else fail "$1 (no match: $3)"; fi; }
WORK=$(mktemp -d)
PIDS=()
suite_cleanup() { stop_mocks "${PIDS[@]}"; rm -rf "$WORK"; }
trap suite_cleanup EXIT

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

mkrepo() {  # mkrepo DIR -> a two-file config repo (a completes, b is the one the mock keeps translating)
    mkdir -p "$1/config/locales"
    for n in a b; do printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$1/config/locales/$n.en.yml"; done
    {
      echo "source_locale: en"
      echo "guide:"
      echo "  project_id: 42"
      echo "files:"
      for n in a b; do printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n"; done
    } > "$1/.ptc-config.yml"
    git -C "$1" init -q
}

API=""; PTC_MOCK_STILL_TRANSLATING=config/locales/b.en.yml PTC_MOCK_BODY_DIR="$WORK/bodies" start_mock API 19611 19621 19631
mkdir -p "$WORK/bodies"

echo "=== wall-clock bound: the run stops, says what is still translating, prints the three options, exits 7 ==="
R="$WORK/clock"; mkrepo "$R"
start=$SECONDS
( cd "$R" && PTC_MONITOR_MAX_SECONDS=3 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 100 ) >"$WORK/clock.out" 2>&1
rc=$?; took=$((SECONDS - start))
expect_rc "files still translating at the bound -> exit 7" 7 $rc
[[ $took -lt 20 ]] && pass "the bound stopped the run (${took}s, not the 100-attempt budget)" || fail "the run took ${took}s"
[[ -f "$R/config/locales/a.de.yml" && -f "$R/config/locales/a.fr.yml" ]] && pass "the completed file's translations are on disk" || fail "a.de.yml / a.fr.yml missing"
[[ ! -f "$R/config/locales/b.de.yml" ]] && pass "nothing was written for the file still translating" || fail "b.de.yml written"
has "the summary names the file still translating with its state" "$WORK/clock.out" "config/locales/b.en.yml (in_progress)"
has "the summary says the bound was reached" "$WORK/clock.out" "Still translating in PTC: 1"

echo "=== nothing written inside the bound: the manifest still exists, empty (the job's git add reads it) ==="
R="$WORK/clock-empty"; mkdir -p "$R/config/locales"
printf 'en:\n  b: "Hello b"\n' > "$R/config/locales/b.en.yml"
printf 'source_locale: en\nguide:\n  project_id: 42\nfiles:\n  - file: config/locales/b.en.yml\n    output: config/locales/b.{{lang}}.yml\n' > "$R/.ptc-config.yml"
git -C "$R" init -q
( cd "$R" && PTC_MONITOR_MAX_SECONDS=3 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 100 --written-manifest "$WORK/clock-empty.manifest" ) >"$WORK/clock-empty.out" 2>&1
expect_rc "the only file still translating at the bound -> exit 7" 7 $?
[[ -f "$WORK/clock-empty.manifest" ]] && pass "the written manifest exists when nothing was written" || fail "no manifest file: the job's git add --pathspec-from-file fails on it"
[[ -f "$WORK/clock-empty.manifest" && ! -s "$WORK/clock-empty.manifest" ]] && pass "and it is empty" || fail "manifest not empty"
has "option (a): retry the CI job once PTC finishes" "$WORK/clock.out" "Retry this CI job"
hasre "option (b): the exact status command (with the run's file tag)" "$WORK/clock.out" "ptc-cli.sh --config-file .ptc-config.yml( --file-tag-name [^ ]+)? --action status"
has "option (b): the project page" "$WORK/clock.out" "http://127.0.0.1:19611/dashboard/projects/42"
hasre "option (c): the exact download command" "$WORK/clock.out" "ptc-cli.sh --config-file .ptc-config.yml( --file-tag-name [^ ]+)? --action download"
has "option (c): commit what it downloads" "$WORK/clock.out" "commit"
has "the final line names the exit" "$WORK/clock.out" "still running in PTC"

echo "=== attempts cap: the second bound ends the same way ==="
A="$WORK/attempts"; mkrepo "$A"
( cd "$A" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 2 ) >"$WORK/attempts.out" 2>&1
expect_rc "attempts cap with a file still translating -> exit 7" 7 $?
has "attempts cap: the options are printed" "$WORK/attempts.out" "--action download"

echo "=== pattern mode: the commands are spelled in pattern form ==="
P="$WORK/patterns"; mkrepo "$P"; rm -f "$P/.ptc-config.yml"
( cd "$P" && PTC_MONITOR_MAX_SECONDS=3 PTC_API_TOKEN=t "$CLI" --source-locale en --patterns 'config/locales/*.en.yml' --api-url "$API" --monitor-interval 1 ) >"$WORK/patterns.out" 2>&1
expect_rc "pattern mode at the bound -> exit 7" 7 $?
hasre "pattern mode: status command in pattern form" "$WORK/patterns.out" "--source-locale en --patterns 'config/locales/\*\.en\.yml'( --file-tag-name [^ ]+)? --action status"

echo "=== a run that finishes inside the bound is unchanged ==="
OK=""; start_mock OK 19641 19651 19661
F="$WORK/fine"; mkrepo "$F"
( cd "$F" && PTC_MONITOR_MAX_SECONDS=30 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$OK" --monitor-interval 1 ) >"$WORK/fine.out" 2>&1
expect_rc "everything completes -> exit 0" 0 $?
grep -q "Still translating" "$WORK/fine.out" && fail "a complete run printed the bound summary" || pass "a complete run prints no bound summary"

echo "=== S2-R19-1: PTC answered in-progress until the bound -> the still-translating report, never 'Could not reach PTC' ==="
grep -q "Could not reach PTC" "$WORK/clock.out" && fail "an in-progress file was reported unreachable" || pass "an in-progress file is not reported unreachable"
has "the in-progress case still says nothing failed" "$WORK/clock.out" "PTC is still translating; nothing failed"

echo "=== S2-R19-1: every status poll 404s (a tunnel, not PTC) until the bound -> 'Could not reach PTC since T', exit 5 ==="
UN=""; PTC_MOCK_STATUS_404=config/locales/b.en.yml start_mock UN 19671 19681 19691
U="$WORK/unreach"; mkrepo "$U"
( cd "$U" && PTC_MONITOR_MAX_SECONDS=3 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$UN" --monitor-interval 1 --monitor-max-attempts 100 ) >"$WORK/unreach.out" 2>&1
expect_rc "a file PTC could not be asked about at the bound -> exit 5 (the 'Could not reach PTC' code), not 7" 5 $?
[[ -f "$U/config/locales/a.de.yml" ]] && pass "the completed file's translations are on disk" || fail "a.de.yml missing"
hasre "the summary names the unreachable file, since when and the HTTP code" "$WORK/unreach.out" "Could not reach PTC.*since [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z.*HTTP 404"
has "the summary lists the file" "$WORK/unreach.out" "config/locales/b.en.yml"
has "its state is called unknown" "$WORK/unreach.out" "state is unknown"
has "the remedy names the API URL and the network" "$WORK/unreach.out" "check the API URL"
has "the last line does not call the unreachable file rejected" "$WORK/unreach.out" "rejected by PTC or could not reach it"
grep -q "Still translating in PTC" "$WORK/unreach.out" && fail "an unreachable file was reported still translating" || pass "no 'Still translating in PTC' line"
grep -q "nothing failed" "$WORK/unreach.out" && fail "the unreachable case says 'nothing failed'" || pass "no 'nothing failed' line"
grep -q "Retry this CI job once PTC finishes" "$WORK/unreach.out" && fail "the retry-once-PTC-finishes option printed for an unreachable PTC" || pass "no 'retry once PTC finishes' option"

echo "=== S2-R19-1: one file in progress, one unreachable at the bound -> both groups, exit 7 ==="
MX=""; PTC_MOCK_STILL_TRANSLATING=config/locales/a.en.yml PTC_MOCK_STATUS_404=config/locales/b.en.yml start_mock MX 19701 19711 19721
M="$WORK/mixed"; mkrepo "$M"
( cd "$M" && PTC_MONITOR_MAX_SECONDS=3 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$MX" --monitor-interval 1 --monitor-max-attempts 100 ) >"$WORK/mixed.out" 2>&1
expect_rc "in-progress + unreachable at the bound -> exit 7 (PTC confirmed a file still translating)" 7 $?
has "the in-progress group" "$WORK/mixed.out" "Still translating in PTC: 1"
has "the in-progress file with its state" "$WORK/mixed.out" "config/locales/a.en.yml (in_progress)"
hasre "the unreachable group" "$WORK/mixed.out" "Could not reach PTC.*HTTP 404"
grep -qE "⏱ config/locales/b.en.yml" "$WORK/mixed.out" && fail "the unreachable file listed as still translating" || pass "the unreachable file is not listed as still translating"
grep -q "nothing failed" "$WORK/mixed.out" && fail "the mixed case says 'nothing failed'" || pass "the mixed case does not say 'nothing failed'"

echo "=== S2-R19-1: one failed poll, then good answers -> unchanged ==="
TR=""; PTC_MOCK_STILL_TRANSLATING=config/locales/b.en.yml PTC_MOCK_STATUS_404_ONCE=config/locales/a.en.yml,config/locales/b.en.yml start_mock TR 19731 19741 19751
T="$WORK/transient"; mkrepo "$T"
( cd "$T" && PTC_MONITOR_MAX_SECONDS=4 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$TR" --monitor-interval 1 --monitor-max-attempts 100 ) >"$WORK/transient.out" 2>&1
expect_rc "a transient 404 then in-progress at the bound -> exit 7 as before" 7 $?
has "the transient file is reported still translating" "$WORK/transient.out" "config/locales/b.en.yml (in_progress)"
[[ -f "$T/config/locales/a.de.yml" ]] && pass "the file that 404d once then completed is written" || fail "a.de.yml missing"
grep -q "Could not reach PTC" "$WORK/transient.out" && fail "a recovered poll was reported unreachable" || pass "no 'Could not reach PTC' after a recovered poll"
has "the transient poll is still announced" "$WORK/transient.out" "Status unavailable for config/locales/a.en.yml (not_found); will retry"

echo "=== the knobs: config key, flag, environment ==="
# shellcheck disable=SC1090
source "$CLI" >/dev/null 2>&1; set +e   # the CLI turns errexit on; the checks below read variables
trap suite_cleanup EXIT   # sourcing the CLI installed ITS `trap cleanup EXIT` and its own `cleanup`: re-arm the suite's, so the mocks die
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
PTC_MONITOR_MAX_MINUTES=45; PTC_MONITOR_MAX_MINUTES_SET=false
printf 'source_locale: en\nmonitor_max_minutes: 90\nfiles:\n  - file: locales/en.json\n    output: locales/{{lang}}.json\n' > "$WORK/k1.yml"
parse_config_file "$WORK/k1.yml" >/dev/null 2>&1
assert_eq "monitor_max_minutes: 90 in the config is read" "$PTC_MONITOR_MAX_MINUTES" "90"
PTC_MONITOR_MAX_MINUTES=20; PTC_MONITOR_MAX_MINUTES_SET=true   # what --monitor-max-minutes 20 / PTC_MONITOR_MAX_MINUTES=20 leaves
parse_config_file "$WORK/k1.yml" >/dev/null 2>&1
assert_eq "a flag or the environment wins over the config" "$PTC_MONITOR_MAX_MINUTES" "20"
PTC_MONITOR_MAX_MINUTES=45; PTC_MONITOR_MAX_MINUTES_SET=false
printf 'source_locale: en\nmonitor_max_minutes: soon\nfiles:\n  - file: locales/en.json\n    output: locales/{{lang}}.json\n' > "$WORK/k2.yml"
out=$(parse_config_file "$WORK/k2.yml" 2>&1)
assert_eq "an invalid value is ignored" "$PTC_MONITOR_MAX_MINUTES" "45"
[[ "$out" == *"monitor_max_minutes: soon"* ]] && pass "an invalid value is warned about" || fail "no warning for an invalid monitor_max_minutes"

echo "=== guide delivery-commit --stopped-reason: the stop reaches PTC, with or without a commit ==="
D="$WORK/dc"; mkrepo "$D"; git -C "$D" -c user.email=t@t -c user.name=t add -A >/dev/null; git -C "$D" -c user.email=t@t -c user.name=t commit -qm init
sha=$(git -C "$D" rev-parse HEAD)
rm -f "$WORK/bodies/guide_delivery_commits.json"
( cd "$D" && env -u GITHUB_SHA -u CI_COMMIT_SHA PTC_API_TOKEN=t "$CLI" guide delivery-commit --stopped-reason monitor_bound --source-commit "$sha" --config-file .ptc-config.yml --api-url "$API" ) >"$WORK/dc1.out" 2>&1
expect_rc "delivery-commit --stopped-reason without --commit -> exit 0" 0 $?
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["body"]; sys.exit(0 if d.get("stopped_reason")=="monitor_bound" and not d.get("commit_sha") and d.get("source_commit_sha")==sys.argv[2] else 1)' "$WORK/bodies/guide_delivery_commits.json" "$sha" \
  && pass "the report carries stopped_reason, the source commit and no commit_sha" || fail "stopped report body: $(cat "$WORK/bodies/guide_delivery_commits.json" 2>/dev/null)"
has "the CLI says the stop was reported" "$WORK/dc1.out" "still translating"
( cd "$D" && env -u GITHUB_SHA -u CI_COMMIT_SHA PTC_API_TOKEN=t "$CLI" guide delivery-commit --stopped-reason monitor_bound --commit "$sha" --branch ptc/translations --source-commit "$sha" --config-file .ptc-config.yml --api-url "$API" ) >"$WORK/dc2.out" 2>&1
expect_rc "delivery-commit --stopped-reason with --commit -> exit 0" 0 $?
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["body"]; sys.exit(0 if d.get("stopped_reason")=="monitor_bound" and d.get("commit_sha")==sys.argv[2] else 1)' "$WORK/bodies/guide_delivery_commits.json" "$sha" \
  && pass "with a commit the report carries both" || fail "stopped+commit report body: $(cat "$WORK/bodies/guide_delivery_commits.json" 2>/dev/null)"
( cd "$D" && PTC_API_TOKEN=t "$CLI" guide delivery-commit --stopped-reason because --source-commit "$sha" --api-url "$API" ) >/dev/null 2>&1
expect_rc "an unknown stopped reason is refused" 1 $?

echo
echo "Passed: $passed  Failed: $failed"
[[ $failed -eq 0 ]]
