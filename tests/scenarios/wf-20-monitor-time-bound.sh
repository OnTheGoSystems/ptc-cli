#!/bin/bash
# covers: WF-20
# status: fixed
# source: tasks/translation-guide/review/wpml-manual/RUN-LOG.md stop 33/35 (string-translation job exit 7 after ~15 min of a promised 45)
# title: the CI monitor is bounded by time at the server's poll interval; the attempts cap is a per-round safety net only
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"

# 1. The unset attempts cap never ends a run before the minutes bound: 5 files, 5 s interval, the 45-minute default.
budget=$(
    # shellcheck disable=SC1090
    source <(sed -n -e '/^log_debug() {$/,/^}$/p' -e '/^start_monitor_clock() {$/,/^}$/p' -e '/^scale_monitor_max_attempts() {$/,/^}$/p' "$CLI")
    PTC_VERBOSE=false; PTC_MONITOR_MAX_SECONDS=""; PTC_MONITOR_MAX_MINUTES=45; PTC_MONITOR_INTERVAL=5
    PTC_MONITOR_MAX_ATTEMPTS=100; PTC_MONITOR_MAX_ATTEMPTS_SET=false
    start_monitor_clock >/dev/null 2>&1; scale_monitor_max_attempts 5 >/dev/null 2>&1
    echo "$PTC_MONITOR_MAX_ATTEMPTS"
)
[[ "$budget" =~ ^[0-9]+$ && $((budget * 5)) -ge $((45 * 60)) ]] \
    && pass "unset attempts cap ($budget rounds x 5 s) outlasts the 45-minute bound" \
    || fail "unset attempts cap is $budget rounds x 5 s = $((budget * 5)) s, short of the 45-minute bound (2700 s)"

# 2. Five files PTC keeps preparing (download 202, retry_after 3): rounds follow the server's interval, not the 1 s
#    monitor interval, and the run stops at its time bound naming it.
FILES=""; R="$WORK/repo"; mkdir -p "$R/config/locales"
{ echo "source_locale: en"; echo "files:"; } > "$R/.ptc-config.yml"
for n in a b c d e; do
    printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$R/config/locales/$n.en.yml"
    printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n" >> "$R/.ptc-config.yml"
    FILES+="config/locales/$n.en.yml,"
done
git -C "$R" init -q
start_mock M 19889 PTC_MOCK_DOWNLOAD_BUILDING="${FILES%,}" PTC_MOCK_RETRY_AFTER=3
start=$SECONDS
(cd "$R" && PTC_MONITOR_MAX_SECONDS=8 PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API_M" --monitor-interval 1) >"$WORK/run.out" 2>&1
rc=$?; took=$((SECONDS - start))
[[ $rc -eq 7 ]] && pass "still preparing at the bound: exit 7" || fail "exit $rc: $(tail -5 "$WORK/run.out")"
polls=$(grep -c 'translation_status.*a\.en\.yml' "$WORK/mock-M.log")
[[ $polls -ge 2 && $polls -le 4 ]] && pass "file a polled $polls times in 8 s: one round per server interval (3 s)" \
    || fail "file a polled $polls times in 8 s: the 3 s server interval was not honoured (1 s monitor interval)"
grep -q "8-second bound" "$WORK/run.out" && pass "the stop names the time bound" || fail "stop line: $(grep -i 'still translating in PTC' "$WORK/run.out")"
# The files PTC reports completed while the download door still prepares them are not labelled "(completed)" in a
# "still translating" list: the line names what holds them.
grep -q '⏱ config/locales/a.en.yml (completed)' "$WORK/run.out" && fail "a held file is labelled (completed): $(grep '⏱' "$WORK/run.out" | head -1)" \
    || pass "a held file is not labelled (completed)"
grep -q '⏱ config/locales/a.en.yml (completed in PTC; the download is still being prepared)' "$WORK/run.out" && pass "the held file's line names the download still being prepared" \
    || fail "held file line: $(grep '⏱' "$WORK/run.out" | head -1)"
# The bound is checked between rounds, so the run ends at the first round boundary past 8 s; a round is ten curl calls
# plus the 3 s server interval. On a loaded CI worker (x4 lane, v1.47 cut run #278) process spawn latency stretched a
# round to ~6 s and the whole run to 20 s while the poll count above stayed inside its 2-4 window: the bound held. The
# regression WF-20 guards against is the attempts budget running the monitor to its 100 rounds (300 s here), so the
# outer clock is a coarse ceiling well under that; the poll count is the precise proof of the bound.
[[ $took -le 45 ]] && pass "stopped at the bound (${took}s, under the 300 s attempts budget)" || fail "the run took ${took}s"
finish
