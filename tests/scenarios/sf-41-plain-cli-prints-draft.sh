#!/bin/bash
# covers: SF-41
# status: fixed
# source: L14 staging LW2 (2026-10-08); cli/tests/test-guide-l14.sh SF-41
# title: the plain (non --json) CLI prints PTC's generated description draft in full
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
start_mock M 19885
P="$WORK/plain"; mkdir -p "$P"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide next --session-id gs_draft --api-url "$API_M" -d "$P" >"$WORK/next.out" 2>&1
grep -qF "AI translation platform by OnTheGoSystems for developers who ship software in many languages." "$WORK/next.out" \
    && grep -qF "Readers: product managers and engineers." "$WORK/next.out" \
    && pass "guide next prints the draft, every line" || fail "no draft: $(cat "$WORK/next.out")"
finish
