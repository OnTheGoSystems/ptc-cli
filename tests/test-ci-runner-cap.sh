#!/bin/bash
# GAP-CI-2 (CI-16; WPML lab run 2, jobs 4165306 and 4165711 on GitLab project 5972): the sitepress job ran on a shared
# runner whose maximum_timeout is 3,600 s; GitLab killed it at 1 h both times ("execution took longer than 1h0m0s
# seconds"), the job's `timeout: 3h` and the project's raised build_timeout notwithstanding, and nothing was delivered.
# F13: under a runner cap GitLab exports the EFFECTIVE limit as CI_JOB_TIMEOUT (min of the job/project timeout and the
# runner's maximum, Ci::Builds::TimeoutCalculator; the runner kills at that same value), so the CLI's cap holds; inside
# GitLab CI it never falls back to "no cap" (no CI_JOB_TIMEOUT: GitLab's 60-minute default or the stated limit; an
# unreadable CI_JOB_STARTED_AT: the CLI's own start).
# F14: the "1/1954 ... 141/1954" counter was the status-check budget, not strings; the files read U (unknown) because the
# CLI did not know PTC's `reviewing` state. The monitor counts from PTC's stored state (files done) and names the state.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="${PTC_TEST_CLI:-$(dirname "$TEST_DIR")/ptc-cli.sh}"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
refuse_busy_port() {
    local i
    for i in $(seq 1 20); do
        python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), 0.4).close()" 2>/dev/null || return 0
        sleep 0.25
    done
    echo "port $1 already in use: a stale mock_ptc_api.py? (pgrep -af mock_ptc_api.py)" >&2; exit 1
}
stop_mocks() {
    local p i; for p in "$@"; do kill "$p" 2>/dev/null; done
    for p in "$@"; do wait "$p" 2>/dev/null; for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done; done
}
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
expect_rc() { if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1 (rc $3, want $2)"; fi; }
has() { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing: $3)"; fi; }
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

mkrepo() {  # mkrepo DIR -> a two-file config repo (a completes, b is the one PTC is still on)
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
iso_ago() { python3 -c 'import sys, datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S.123Z"))' "$1"; }
manifest_has() { grep -qxF -- "$2" <<<"$(tr '\0' '\n' < "$1")"; }  # no early-exit grep in a pipeline (SIGPIPE under pipefail)

API=""; PTC_MOCK_STILL_TRANSLATING=config/locales/b.en.yml start_mock API 19911 19941
API2=""; start_mock API2 19921 19951   # the same project once PTC finished b
APIR=""; PTC_MOCK_REVIEWING=config/locales/b.en.yml start_mock APIR 19931 19961

echo "=== F13: a job on a runner whose maximum_timeout is 3,600 s delivers a partial result before the kill ==="
# What GitLab exports there: CI_JOB_TIMEOUT=3600 (the runner's maximum wins over the job's 3 h). The job started
# 2,995 s ago (setup, the guide's steps, uploads), the handout's bound is 162 minutes, the reserve the default 600 s:
# the run must stop ~5 s from now and deliver, not wait out its 162 minutes.
R="$WORK/run1"; mkrepo "$R"; M1="$WORK/run1.manifest"
start=$SECONDS
( cd "$R" && GITLAB_CI=true CI_JOB_TIMEOUT=3600 CI_JOB_STARTED_AT="$(iso_ago 2995)" CI_PROJECT_ID=5972 PTC_MONITOR_MAX_MINUTES=162 \
    PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 60 --written-manifest "$M1" ) >"$WORK/run1.out" 2>&1
rc=$?; took=$((SECONDS - start))
expect_rc "the runner's limit ends the run at its bound -> exit 7 (delivered, not killed)" 7 $rc
[[ $took -lt 30 ]] && pass "stopped inside the job's remaining time less the reserve (${took}s)" || fail "the run took ${took}s: GitLab would have killed it"
[[ -f "$R/config/locales/a.de.yml" ]] && pass "the finished file is written" || fail "a.de.yml missing"
[[ -f "$M1" ]] && manifest_has "$M1" "config/locales/a.de.yml" && pass "the job's merge-request step stages it (written manifest)" || fail "a.de.yml not in the written manifest"
has "the warning names the 60-minute limit" "$WORK/run1.out" "This CI job may run 60 minutes (its timeout"
has "the warning names the runner's maximum and the way past it" "$WORK/run1.out" "give the job a runner with a higher maximum"
has "the warning says the next run builds on this one" "$WORK/run1.out" "the next run delivers what finished without translating it again"

echo "=== F14: the next run builds on the first: it writes what PTC finished since, on top of the first delivery ==="
R2="$WORK/run2"; cp -a "$R" "$R2"; M2="$WORK/run2.manifest"
( cd "$R2" && GITLAB_CI=true CI_JOB_TIMEOUT=3600 CI_JOB_STARTED_AT="$(iso_ago 60)" PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API2" --monitor-interval 1 --written-manifest "$M2" ) >"$WORK/run2.out" 2>&1
expect_rc "PTC finished b: the second run completes -> exit 0" 0 $?
[[ -f "$R2/config/locales/b.de.yml" && -f "$R2/config/locales/a.de.yml" ]] && pass "both files are on disk after the second run" || fail "b.de.yml / a.de.yml missing"
manifest_has "$M2" "config/locales/b.de.yml" && pass "the second delivery stages b on top of a" || fail "b.de.yml not in the second manifest"

echo "=== F13: inside GitLab CI the cap never falls back to none ==="
R="$WORK/bad-start"; mkrepo "$R"
start=$SECONDS
( cd "$R" && GITLAB_CI=true CI_JOB_TIMEOUT=605 CI_JOB_STARTED_AT="yesterday-ish" PTC_CI_DELIVERY_RESERVE_SECONDS=602 \
    PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 60 ) >"$WORK/bad-start.out" 2>&1
rc=$?; took=$((SECONDS - start))
expect_rc "an unreadable CI_JOB_STARTED_AT still caps the bound -> exit 7" 7 $rc
[[ $took -lt 30 ]] && pass "capped from the CLI's own start (${took}s)" || fail "no cap: the run took ${took}s"
has "it says the start could not be read" "$WORK/bad-start.out" "could not be read: the time this job used is counted from the CLI's start"

R="$WORK/no-timeout"; mkrepo "$R"
start=$SECONDS
( cd "$R" && env -u CI_JOB_TIMEOUT GITLAB_CI=true CI_JOB_STARTED_AT="$(iso_ago 0)" PTC_CI_JOB_TIMEOUT_SECONDS=605 PTC_CI_DELIVERY_RESERVE_SECONDS=602 \
    PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 60 ) >"$WORK/no-timeout.out" 2>&1
rc=$?; took=$((SECONDS - start))
expect_rc "a runner without CI_JOB_TIMEOUT: the stated limit caps the bound -> exit 7" 7 $rc
[[ $took -lt 30 ]] && pass "capped at the stated limit (${took}s)" || fail "no cap: the run took ${took}s"
has "the warning names the stated limit" "$WORK/no-timeout.out" "the limit PTC_CI_JOB_TIMEOUT_SECONDS states"

# Neither CI_JOB_TIMEOUT nor a stated limit: GitLab's 60-minute default (checked on the function: a real run would wait 50 min).
out=$(env -u CI_JOB_TIMEOUT -u PTC_CI_JOB_TIMEOUT_SECONDS GITLAB_CI=true CI_JOB_STARTED_AT="$(iso_ago 120)" bash -c '
    source "$1" >/dev/null 2>&1; set +e; cap_monitor_to_ci_job 9720 2>&1; echo "CAPPED=$PTC_MONITOR_CI_CAPPED"' _ "$CLI")
capped=$(sed -n 's/^CAPPED=//p' <<<"$out")
[[ "$capped" =~ ^[0-9]+$ ]] && (( capped >= 2870 && capped <= 2880 )) && pass "no CI_JOB_TIMEOUT: GitLab's 60-minute default less the reserve and the 2 minutes used (${capped}s)" \
    || fail "no CI_JOB_TIMEOUT: capped '${capped}', want ~2880"
[[ "$out" == *"GitLab's 60-minute default"* ]] && pass "and it says so, naming PTC_CI_JOB_TIMEOUT_SECONDS" || fail "no default warning: $out"
out=$(env -u CI_JOB_TIMEOUT -u GITLAB_CI bash -c 'source "$1" >/dev/null 2>&1; set +e; cap_monitor_to_ci_job 600; echo "CAPPED=$PTC_MONITOR_CI_CAPPED"' _ "$CLI")
[[ "$out" == *"CAPPED="* && -z "$(sed -n 's/^CAPPED=//p' <<<"$out")" ]] && pass "outside GitLab CI the bound is untouched" || fail "outside CI: $out"

echo "=== F14: a file PTC translated and its review holds is named so, and the count is files done, not checks ==="
R="$WORK/reviewing"; mkrepo "$R"
( cd "$R" && PTC_MONITOR_MAX_SECONDS=3 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$APIR" --monitor-interval 1 --monitor-max-attempts 100 ) >"$WORK/reviewing.out" 2>&1
expect_rc "held by the review at the bound -> exit 7" 7 $?
has "the state is named, not 'reviewing' nor unknown" "$WORK/reviewing.out" "config/locales/b.en.yml (translated in PTC; its review holds the delivery until it finishes)"
sed 's/\x1b\[[0-9;]*[mK]//g' "$WORK/reviewing.out" > "$WORK/reviewing.plain"
grep -q "V 1 of 2 file(s) done in PTC (status check" "$WORK/reviewing.plain" && pass "the monitor line: V for reviewing, files done of files sent" \
    || fail "monitor line: $(grep -o '[A-Z.]* [0-9]*[ /][^ ]*.\{0,40\}' "$WORK/reviewing.plain" | tail -1)"
grep -qE "[A-Z.]+ [0-9]+/[0-9]+$" "$WORK/reviewing.plain" && fail "a bare check/budget counter is still printed" || pass "no bare check/budget counter"
has "option (a) says the next run translates nothing again" "$WORK/reviewing.out" "the next run translates none of it again"

echo
echo "Passed: $passed  Failed: $failed"
[[ $failed -eq 0 ]]
