#!/bin/bash
# covers: CLI-8, CI-7, POL-4
# status: fixed
# source: WPML lab run 2, GitLab project 5972 jobs 4166443 / 4166499 (sitepress.pot: 462 of 1,853 strings translated); GAP-F15-R (Eran 2026-10-15)
# title: a file PTC served with strings it did not translate is written and listed delivered (✓); the run exits 0 - failed strings notify PTC internally, never the run
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"

# Eran 2026-10-15: "one failed string shouldn't early exit the entire file, it should finish all strings. Then, failed
# strings shouldn't error the delivery - only notify us internally so we can investigate." (CI-7: a failed file is
# delivered, exit 0.)
R="$WORK/repo"; mkdir -p "$R/config/locales"
{ echo "source_locale: en"; echo "files:"; } > "$R/.ptc-config.yml"
for n in a b c d; do
    printf 'en:\n  %s: "Hello %s"\n' "$n" "$n" > "$R/config/locales/$n.en.yml"
    printf '  - file: config/locales/%s.en.yml\n    output: config/locales/%s.{{lang}}.yml\n' "$n" "$n" >> "$R/.ptc-config.yml"
done
git -C "$R" init -q
# b: failed with the counts (3 of 10); c: completed while 2 strings were never translated; d: failed, a server without counts.
start_mock M 19983 PTC_MOCK_FAILED_STRINGS=config/locales/b.en.yml PTC_MOCK_PARTIAL_COMPLETED=config/locales/c.en.yml \
    PTC_MOCK_FAILED_BARE=config/locales/d.en.yml
man="$WORK/written"
(cd "$R" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API_M" --monitor-interval 1 --written-manifest "$man") >"$WORK/run.out" 2>&1
rc=$?
out="$WORK/run.out"

[[ $rc -eq 0 ]] && pass "a run whose files carry failed strings exits 0 (the delivery is complete)" || fail "exit $rc: $(tail -6 "$out")"
for n in a b c d; do
    grep -q "✓ config/locales/$n.en.yml" "$out" && pass "$n is listed delivered (✓)" || fail "$n not listed ✓: $(grep -A8 'FINAL RESULTS' "$out")"
done
grep -q 'Completed files: 4$' "$out" && pass "every file counts as completed" || fail "completed count: $(grep 'Completed files' "$out")"
grep -q 'Step-based processing completed successfully' "$out" && pass "the run ends successfully" || fail "last line: $(tail -2 "$out")"
grep -qiE 'partly translated|run partial|translation failed|failed files|run incomplete' "$out" \
    && fail "the run names PTC-internal failures to the user: $(grep -iE 'partly translated|run partial|translation failed|failed files|run incomplete' "$out")" \
    || pass "no partial/failure line: the failure is PTC's to investigate (POL-4)"
# Written all: the rest of a file with failed strings is real work (CI-7: one failed string never blocks the rest).
for n in a b c d; do
    grep -q "config/locales/$n.de.yml" "$man" 2>/dev/null && pass "$n is written (in the manifest)" || fail "$n not in the manifest: $(cat "$man" 2>/dev/null)"
done
# The CI job's exit-5 line names only rejected and unreachable files (CI-16).
recipe=$(render_gitlab_recipe)  # never `producer | grep -q` under pipefail: an early grep exit is a SIGPIPE (141) red
grep -qF "PTC rejected some files or could not be reached for them (see 'Rejected by PTC' / 'Could not reach PTC' above)" <<<"$recipe" \
    && pass "the GitLab job's exit-5 line names rejected / unreachable files only" || fail "recipe exit-5 line: $(grep 'ptc_rc" -eq 5' <<<"$recipe")"
finish
