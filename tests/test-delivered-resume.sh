#!/bin/bash
# R3 (org #6940; specs/api-cli/SPEC.md API-16, docs/api/api/source_files.md "delivered digest"): a resumed run (the same
# per-run resume key: the CI pipeline / run id) downloads only what the dead run did not receive. The server's status
# answer says a file is unchanged since its delivered sha and was received by this run key; the CLI skips that file,
# counts it as skipped (never failed) and downloads the rest. A new run key downloads everything again.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
PID=""
cleanup() { [[ -n "$PID" ]] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT

API=""
for port in 19643 19653 19663; do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && continue
    PTC_MOCK_PORT="$port" PTC_MOCK_DELIVERED=1 PTC_MOCK_DOWNLOAD_FAIL_ONCE=config/locales/b.en.yml,config/locales/c.en.yml PTC_MOCK_LOG="$WORK/mock.journal" \
        python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
    PID=$!
    for _ in $(seq 1 30); do
        if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null; then
            API="http://127.0.0.1:$port/api/v1/"; break 2
        fi
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.3
    done
    kill "$PID" 2>/dev/null; PID=""
done
[[ -n "$API" ]] || { echo "mock did not come up"; exit 1; }

R="$WORK/repo"; mkdir -p "$R/config/locales"
printf 'en:\n  a: "Hello a"\n' > "$R/config/locales/a.en.yml"
printf 'en:\n  b: "Hello b"\n' > "$R/config/locales/b.en.yml"
printf 'source_locale: en\nfiles:\n  - file: config/locales/a.en.yml\n    output: config/locales/a.{{lang}}.yml\n  - file: config/locales/b.en.yml\n    output: config/locales/b.{{lang}}.yml\n' > "$R/.ptc-config.yml"
git -C "$R" init -q

run() { ( cd "$R" && env -u GITHUB_RUN_ID CI_PIPELINE_ID="$1" PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 5 ) >"$WORK/run-$2.out" 2>&1; }
# RR-2: run_m also writes the run's --written-manifest ($WORK/manifest-<label>).
run_m() { ( cd "$R" && env -u GITHUB_RUN_ID CI_PIPELINE_ID="$1" PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" --monitor-interval 1 --monitor-max-attempts 5 --written-manifest "$WORK/manifest-$2" ) >"$WORK/run-$2.out" 2>&1; }
manifest_has() { tr '\0' '\n' < "$WORK/manifest-$1" | grep -qxF "$2"; }
zips() { grep -cF -- "-> zip" "$WORK/mock.journal" | tr -d ' '; }
zips_for() { grep -F -- "-> zip" "$WORK/mock.journal" | grep -cF "for $1 "; }

echo "=== run 1 (pipeline 77) dies on b: a is received, b is not ==="
run 77 1; rc1=$?
[[ $rc1 -ne 0 ]] && pass "run 1 fails on b (exit $rc1)" || fail "run 1 exited 0 although b's download failed"
[[ "$(zips_for config/locales/a.en.yml)" == 1 ]] && pass "run 1 downloaded a once" || fail "run 1 downloads of a: $(zips_for config/locales/a.en.yml)"
grep -qE "GET  /source_files/translation_status .*'run_key': '77'" "$WORK/mock.journal" && pass "the status call carries the run key" || fail "no run_key on the status call"
grep -qE "GET  /source_files/download_translations .*'run_key': '77'" "$WORK/mock.journal" && pass "the download call carries the run key" || fail "no run_key on the download call"

echo "=== run 2 resumes pipeline 77: a is skipped (unchanged, received in this run), b is downloaded ==="
before=$(zips)
run_m 77 2; rc2=$?
[[ $rc2 -eq 0 ]] && pass "the resumed run exits 0" || fail "the resumed run exited $rc2"
after=$(zips)
[[ "$(zips_for config/locales/a.en.yml)" == 1 ]] && pass "a was not fetched again" || fail "a was fetched again: $(zips_for config/locales/a.en.yml) zips"
[[ "$(zips_for config/locales/b.en.yml)" == 1 ]] && pass "b was fetched by the resumed run" || fail "b zips: $(zips_for config/locales/b.en.yml)"
[[ $((after - before)) -eq 1 ]] && pass "the resumed run fetched exactly one archive" || fail "the resumed run fetched $((after - before)) archives"
grep -qE "Skipped 1 file\(s\) already received unchanged in this run" "$WORK/run-2.out" && pass "the summary counts a as skipped" || fail "no skipped count in the summary"
grep -qF "config/locales/a.en.yml" "$WORK/run-2.out" && pass "the skipped file is named" || fail "the skipped file is not named"
if grep -qiE "failed to download|✗ config/locales/a.en.yml" "$WORK/run-2.out"; then fail "the skipped file was reported failed"; else pass "the skipped file is not a failure"; fi
[[ -f "$R/config/locales/a.de.yml" && -f "$R/config/locales/b.de.yml" ]] && pass "both files' translations are on disk" || fail "translations missing on disk"
manifest_has 2 config/locales/a.de.yml && manifest_has 2 config/locales/a.fr.yml && pass "RR-2: the skipped file's outputs are in the written manifest" || fail "RR-2: the skipped file's outputs are missing from the written manifest"

echo "=== run 3 is a new run (pipeline 78): it downloads both ==="
before=$(zips)
run 78 3; rc3=$?
after=$(zips)
[[ $rc3 -eq 0 && $((after - before)) -eq 2 ]] && pass "a new run key downloads every file again" || fail "run 3 exit $rc3, archives $((after - before))"

# RR-2 (CI-16, API-16; Eran 24 Oct): a GitLab Retry / GitHub "Re-run failed jobs" keeps the run key but starts from a
# FRESH checkout: the files the first job delivered are not on disk. A file is skipped only when its outputs are on disk
# with the sha this run wrote; otherwise it is downloaded again, so the job ends with every delivered file, all in the
# written manifest (the merge request grows, never shrinks to the re-run's files). A new file c, whose first download
# fails, keeps run 4 from ending successfully, so its run state (the outputs and their shas) is there for run 5.
outs=(config/locales/a.de.yml config/locales/a.fr.yml config/locales/b.de.yml config/locales/b.fr.yml)
printf 'en:\n  c: "Hello c"\n' > "$R/config/locales/c.en.yml"
printf '  - file: config/locales/c.en.yml\n    output: config/locales/c.{{lang}}.yml\n' >> "$R/.ptc-config.yml"

echo "=== run 4 retries pipeline 78 in a fresh checkout: nothing on disk, no run state; a and b written again ==="
rm -rf "${R:?}/.git"
for o in "${outs[@]}"; do rm -f "${R:?}/$o"; done
git -C "$R" init -q
before=$(zips)
run_m 78 4; rc4=$?
after=$(zips)
[[ $rc4 -ne 0 ]] && pass "run 4 fails on the new file c only (exit $rc4)" || fail "run 4 exited 0 although c's download failed"
missing=""; for o in "${outs[@]}"; do [[ -f "$R/$o" ]] || missing="$missing $o"; done
[[ -z "$missing" ]] && pass "every delivered file is on disk after the retry" || fail "missing on disk after the retry:$missing"
missing=""; for o in "${outs[@]}"; do manifest_has 4 "$o" || missing="$missing $o"; done
[[ -z "$missing" ]] && pass "the written manifest lists every delivered file" || fail "missing from the manifest:$missing"
[[ $((after - before)) -eq 2 ]] && pass "the retry fetched a and b again" || fail "the retry fetched $((after - before)) archives"

echo "=== run 5 resumes pipeline 78 in the same workspace with a.de deleted and b.fr edited: a, b and c fetched ==="
rm -f "${R:?}/config/locales/a.de.yml"
printf 'fr:\n  b: "edited"\n' > "$R/config/locales/b.fr.yml"
before=$(zips)
run_m 78 5; rc5=$?
after=$(zips)
[[ $rc5 -eq 0 && $((after - before)) -eq 3 ]] && pass "a missing or changed output means a download" || fail "run 5 exit $rc5, archives $((after - before))"
[[ -f "$R/config/locales/a.de.yml" ]] && pass "a.de is back on disk" || fail "a.de still missing"
grep -qF "edited" "$R/config/locales/b.fr.yml" && fail "b.fr keeps the edited bytes" || pass "b.fr has the delivered bytes again"

echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
