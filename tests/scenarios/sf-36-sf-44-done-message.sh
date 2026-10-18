#!/bin/bash
# covers: SF-36 SF-44
# status: fixed
# source: L13/L14 staging LW (2026-10-08); cli/tests/test-guide-l13.sh SF-36, commit 787690902 (SF-44)
# title: the CLI prints PTC's own done message (`ptc sync` on the API channel), never a CI pull-request check line
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
start_mock M 19881
P="$WORK/plain"; mkdir -p "$P"   # no git: the API channel
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_done_api --api-url "$API_M" -d "$P" >"$WORK/next.out" 2>&1
grep -q 'run `ptc sync` in the project directory' "$WORK/next.out" && pass "SF-36: guide next prints PTC's done message" || fail "SF-36 next: $(cat "$WORK/next.out")"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide skip gt_last --reason "answered early" --session-id gs_x --api-url "$API_M" -d "$P" >"$WORK/skip.out" 2>&1
grep -q 'run `ptc sync` in the project directory' "$WORK/skip.out" && pass "SF-36: the skip that closed setup prints the done message" || fail "SF-36 skip: $(cat "$WORK/skip.out")"
# SF-44: on the API channel (no git) nothing printed speaks of a CI run's pull-request / merge-request check.
! grep -qiE 'pull request|merge request|PR check|CI run' "$WORK/next.out" "$WORK/skip.out" \
    && pass "SF-44: no CI pull-request check wording on the API channel" || fail "SF-44: $(grep -iE 'pull request|merge request|PR check|CI run' "$WORK/next.out" "$WORK/skip.out")"
finish
