#!/bin/bash
# covers: WF-11
# status: fixed
# source: tasks/translation-guide/review/wpml-manual/RUN-LOG.md stop 21 (HTTP 422 {"error":"payload too large"} shown as "the guide may be off")
# title: `ptc guide action-run` prints PTC's error text for a refused report, not a guess
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
start_mock M 19891 PTC_MOCK_ACTION_RUN_422="payload too large"
R="$WORK/repo"; mkdir -p "$R"; git -C "$R" init -q
printf 'en:\n  a: "Hello"\n' > "$R/en.yml"
printf 'source_locale: en\nfiles:\n  - file: en.yml\n    output: %s\nguide:\n  project_id: 42\n  session_id: 9\n' "'{{lang}}.yml'" > "$R/.ptc-config.yml"
(cd "$R" && "${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --config-file .ptc-config.yml --api-url "$API_M") >"$WORK/out" 2>&1
grep -q 'action_runs' "$WORK/mock-M.log" && pass "the report reached PTC" || fail "no action_runs call: $(cat "$WORK/out")"
grep -qF "payload too large" "$WORK/out" && pass "PTC's error text is printed" || fail "PTC's error text hidden: $(grep -i 'action_runs' "$WORK/out")"
! grep -qF "the guide may be off" "$WORK/out" && pass "no guess about the guide being off" || fail "still guesses: $(grep -F 'may be off' "$WORK/out")"
finish
