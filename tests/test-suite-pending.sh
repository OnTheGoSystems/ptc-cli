#!/bin/bash
# (1.5.0, L21-3) An upload made while the project's suite is still being set up is stored, not translated: PTC answers
# the process request with 200 + `code: suite_setup_pending` and a `message`. The run prints that message and one line
# saying the translation starts by itself once the suite is set up, lists the files held and does NOT poll for them. A
# file PTC did start in the same run is monitored as always (exit 0). GAP-G46 (WPML lab run 9, CI job 4217058: every one
# of 41 files held, nothing delivered, no MR, and the job exited 0 "[SUCCESS] Processing completed successfully"): a run
# where EVERY file was held delivered nothing, so it exits 13 (setup incomplete), prints PTC's reason on its own line,
# never the success line, and reports the stop to PTC (guide delivery-commit, stopped_reason setup_incomplete).
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
refuse_busy_port() {  # a port that already answers would hide a mock that could not bind (a stale run's server passes the probe)
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
hasnt() { if grep -qF -- "$3" "$2"; then fail "$1 (found: $3)"; else pass "$1"; fi; }
count() { grep -cF -- "$2" "$1"; }
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

mkrepo() {  # mkrepo DIR -> a two-file config repo (a and b)
    mkdir -p "$1/config/locales"
    for n in a b; do printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$1/config/locales/$n.en.yml"; done
    {
      echo "source_locale: en"
      echo "files:"
      for n in a b; do printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n"; done
    } > "$1/.ptc-config.yml"
    git -C "$1" init -q
}

polls_for() { grep -c "translation_status .*'file_path': '$2'" "$1"; }

readonly SERVER_MESSAGE="Stored, not translated yet: this project belongs to a suite whose setup is not finished (waiting for wpml-sticky-links to finish setup)."

readonly FULL_MESSAGE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$TEST_DIR/fixtures/suite_setup_pending/process.json")"
readonly SOURCE_SHA="7f14186e61e0$(printf '0%.0s' $(seq 1 28))"

echo "=== config mode, every file held for the suite: the message, the held files, no polling, exit 13 (nothing delivered) ==="
API=""; JOURNAL="$WORK/all.journal"
PTC_MOCK_LOG="$JOURNAL" PTC_MOCK_BODY_DIR="$WORK/bodies" PTC_MOCK_SUITE_PENDING=config/locales/a.en.yml,config/locales/b.en.yml start_mock API 20111 20121 20131
R="$WORK/all"; mkrepo "$R"; mkdir -p "$WORK/bodies"
start=$SECONDS
( cd "$R" && env -u GITHUB_SHA CI_COMMIT_SHA="$SOURCE_SHA" PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 5 --written-manifest "$WORK/all.manifest" ) >"$WORK/all.out" 2>&1
rc=$?; took=$((SECONDS - start))
expect_rc "every file held for the suite -> exit 13 (setup incomplete, nothing delivered)" 13 $rc
grep -qxF "Nothing delivered (setup_incomplete): $FULL_MESSAGE" "$WORK/all.out" \
    && pass "PTC's reason is printed on its own line" || fail "no line 'Nothing delivered (setup_incomplete): <PTC's message>'"
hasnt "never the success line when nothing was delivered" "$WORK/all.out" "Processing completed successfully"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["body"]; sys.exit(0 if d.get("stopped_reason")=="setup_incomplete" and not d.get("commit_sha") and d.get("source_commit_sha")==sys.argv[2] else 1)' "$WORK/bodies/guide_delivery_commits.json" "$SOURCE_SHA" 2>/dev/null \
    && pass "the delivery report carries stopped_reason setup_incomplete, the source commit and no commit" || fail "stopped report body: $(cat "$WORK/bodies/guide_delivery_commits.json" 2>/dev/null || echo none)"
has "the server's message is printed" "$WORK/all.out" "$SERVER_MESSAGE"
# GAP-G46: once in the run's log, once more as the final "Nothing delivered" line - never once per file.
logged=$(grep -F -- "$SERVER_MESSAGE" "$WORK/all.out" | grep -vc '^Nothing delivered (setup_incomplete): ')
[[ $logged -eq 1 ]] && pass "the message is logged once, not once per file" || fail "message logged $logged times"
has "the suite line names the code and that translation starts by itself" "$WORK/all.out" "Suite setup pending (suite_setup_pending): PTC translates the held files by itself once every project of the suite is set up; the next CI run delivers them."
has "the held files are counted" "$WORK/all.out" "Held for the suite (stored, not translated yet): 2"
has "and listed (a)" "$WORK/all.out" "config/locales/a.en.yml"
has "and listed (b)" "$WORK/all.out" "config/locales/b.en.yml"
[[ $(polls_for "$JOURNAL" config/locales/a.en.yml) -eq 0 && $(polls_for "$JOURNAL" config/locales/b.en.yml) -eq 0 ]] \
    && pass "no translation_status poll for a held file" || fail "held files were polled: $(grep -c translation_status "$JOURNAL") polls"
hasnt "no monitoring step for held files" "$WORK/all.out" "Starting translation monitoring"
hasnt "a held file is not reported as failed to start" "$WORK/all.out" "Processing failed to start"
[[ $took -lt 20 ]] && pass "the run did not wait (${took}s)" || fail "the run took ${took}s"
[[ ! -f "$R/config/locales/a.de.yml" ]] && pass "nothing written for a held file" || fail "a.de.yml written"
[[ -f "$WORK/all.manifest" && ! -s "$WORK/all.manifest" ]] && pass "the written manifest exists, empty" || fail "manifest missing or not empty"

echo "=== config mode, one file held and one started: the started one is delivered, exit 0 ==="
JOURNAL2="$WORK/mixed.journal"; API2=""
PTC_MOCK_LOG="$JOURNAL2" PTC_MOCK_SUITE_PENDING=config/locales/a.en.yml start_mock API2 20141 20151 20161
R="$WORK/mixed"; mkrepo "$R"
( cd "$R" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API2" --monitor-interval 1 --monitor-max-attempts 5 ) >"$WORK/mixed.out" 2>&1
expect_rc "one held, one completed -> exit 0" 0 $?
[[ -f "$R/config/locales/b.de.yml" && -f "$R/config/locales/b.fr.yml" ]] && pass "the started file's translations are on disk" || fail "b.de.yml / b.fr.yml missing"
[[ ! -f "$R/config/locales/a.de.yml" ]] && pass "nothing written for the held file" || fail "a.de.yml written"
[[ $(polls_for "$JOURNAL2" config/locales/a.en.yml) -eq 0 ]] && pass "the held file is not polled" || fail "the held file was polled"
[[ $(polls_for "$JOURNAL2" config/locales/b.en.yml) -ge 1 ]] && pass "the started file is polled" || fail "the started file was not polled"
has "the held file is listed" "$WORK/mixed.out" "Held for the suite (stored, not translated yet): 1"

echo "=== pattern mode (no config file): the same answer, exit 0, no polling ==="
R="$WORK/patterns"; mkrepo "$R"; rm -f "$R/.ptc-config.yml"
: > "$JOURNAL"
( cd "$R" && PTC_API_TOKEN=t "$CLI" --source-locale en --patterns 'config/locales/*.en.yml' --api-url "$API" --monitor-interval 1 --monitor-max-attempts 5 ) >"$WORK/patterns.out" 2>&1
expect_rc "pattern mode, every file held -> exit 13" 13 $?
hasnt "pattern mode: never the success line when nothing was delivered" "$WORK/patterns.out" "Processing completed successfully"
has "pattern mode prints the server's message" "$WORK/patterns.out" "$SERVER_MESSAGE"
has "pattern mode prints the suite line" "$WORK/patterns.out" "Suite setup pending (suite_setup_pending)"
[[ $(grep -c translation_status "$JOURNAL") -eq 0 ]] && pass "pattern mode does not poll" || fail "pattern mode polled"

echo "=== help and README name the code ==="
"$CLI" --help >"$WORK/help.out" 2>&1
has "--help mentions suite_setup_pending" "$WORK/help.out" "suite_setup_pending"
has "the CLI reference (docs/cli.md) mentions suite_setup_pending" "$(dirname "$TEST_DIR")/docs/cli.md" "suite_setup_pending"

echo
echo "Passed: $passed  Failed: $failed"
[[ $failed -eq 0 ]]
