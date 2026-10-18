#!/bin/bash
# covers: WF-6
# status: fixed
# source: tasks/translation-guide/review/wpml-manual/RUN-LOG.md stop 10 (validator: 24 ignored WITH the `!` exceptions in place)
# title: `ptc config validate` does not count an output a .gitignore negation (`!pattern`) un-ignores
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
R="$WORK/repo"; mkdir -p "$R/locale/jed/pot"
git -C "$R" init -q
printf '/locale/jed/**/*.po\n!/locale/jed/pot/x-he.po\n' > "$R/.gitignore"
printf 'msgid ""\nmsgstr ""\n\nmsgid "Hello"\nmsgstr ""\n' > "$R/locale/jed/pot/x.pot"
cp "$R/locale/jed/pot/x.pot" "$R/locale/jed/y.pot"
printf 'source_locale: en\nlanguages: [he]\nfiles:\n  - file: locale/jed/pot/x.pot\n    output: locale/jed/pot/x-{{lang}}.po\n  - file: locale/jed/y.pot\n    output: locale/jed/y-{{lang}}.po\n' > "$R/.ptc-config.yml"
[[ -z "$(git -C "$R" check-ignore locale/jed/pot/x-he.po)" ]] && pass "git: the output is not ignored" || fail "fixture: git ignores the output"
(cd "$R" && "$CLI" config validate --json --config-file .ptc-config.yml) >"$WORK/v.json" 2>"$WORK/v.err"
got=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("ignored_outputs") or []))' "$WORK/v.json" 2>/dev/null)
[[ "$got" != *x-he.po* ]] && pass "config validate: the un-ignored output is not counted" || fail "config validate counts the un-ignored output: $got $(head -c 300 "$WORK/v.err")"
[[ "$got" == "locale/jed/y-he.po" ]] && pass "an output the rule still ignores is counted" || fail "ignored outputs: '$got'"
finish
