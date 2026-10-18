#!/bin/bash
# covers: WF-8
# status: fixed
# source: tasks/translation-guide/review/wpml-manual/RUN-LOG.md stop 15 (46/90 JS files got the note as a JSX child; a hand-written PHP note replaced; 60/152 notes >= 400 chars with internal paths)
# title: `ptc describe apply` writes a JSX-safe note inside the expression, never replaces an existing translators: note, never writes a note that names a path (LR2-F6: skipped, never cut)
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
R="$WORK/repo"; mkdir -p "$R/languages" "$R/src"; git -C "$R" init -q
printf 'msgid ""\nmsgstr ""\n\n#: src/List.jsx:3\nmsgid "Save"\nmsgstr ""\n\n#: src/a.php:3\nmsgid "Delete"\nmsgstr ""\n' > "$R/languages/p.pot"
printf "export const List = () => (\n  <div>\n    {__('Save', 'p')}\n  </div>\n);\n" > "$R/src/List.jsx"
printf "<?php\n/* translators: hand-written - the verb, not the noun */\necho __( 'Delete', 'p' );\n" > "$R/src/a.php"
long="Button in the filters list (src/components/FiltersList/FiltersList.js renders it inside FiltersPanel) that saves the current filter selection of the translation management dashboard so that the same filters apply the next time the user opens the dashboard on any device they use"
note_ok="Shown in the filters list as a button. Saves the current filter selection for the next visit."
python3 -c 'import json,sys; print(json.dumps([
 {"file": "languages/p.pot", "key": "Save", "description": sys.argv[1], "usage": {"path": "src/List.jsx", "line": 3}},
 {"file": "languages/p.pot", "key": "Delete", "description": "Removes the row", "usage": {"path": "src/a.php", "line": 3}}]))' "$long" > "$WORK/long.json"
"$CLI" describe apply --file "$WORK/long.json" -d "$R" >"$WORK/long.out" 2>&1
grep -q "translators" "$R/src/List.jsx" && fail "a note naming a path was written: $(cat "$R/src/List.jsx")" || pass "LR2-F6: a description naming a path is not written (never cut into a note)"
grep -q "skipped languages/p.pot Save: the description names src/components/FiltersList/FiltersList.js" "$WORK/long.out" && pass "the skip names the path" || fail "skip text: $(cat "$WORK/long.out")"
python3 -c 'import json,sys; print(json.dumps([
 {"file": "languages/p.pot", "key": "Save", "description": sys.argv[1], "usage": {"path": "src/List.jsx", "line": 3}},
 {"file": "languages/p.pot", "key": "Delete", "description": "Removes the row", "usage": {"path": "src/a.php", "line": 3}}]))' "$note_ok" > "$WORK/d.json"
"$CLI" describe apply --file "$WORK/d.json" -d "$R" >"$WORK/out" 2>&1
jsx=$(cat "$R/src/List.jsx")
grep -qE "^\s*/\* translators:" "$R/src/List.jsx" && fail "JSX: the note is a JSX child (visible text): $jsx" || pass "JSX: no note line among the JSX children"
grep -qE "\{ */\* translators: [^*]*\*/ *__\('Save'" "$R/src/List.jsx" && pass "JSX: the note sits inside the expression, before the call" || fail "JSX: no in-expression note: $jsx"
note=$(grep -o "/\* translators: .* \*/" "$R/src/List.jsx" | head -1)
text="${note#/\* translators: }"; text="${text% \*/}"
[[ "$text" == "$note_ok" ]] && pass "the note is PTC's description byte for byte" || fail "note: $note"
grep -qF "/* translators: hand-written - the verb, not the noun */" "$R/src/a.php" && pass "PHP: the existing hand-written note is kept" || fail "PHP note replaced: $(cat "$R/src/a.php")"
! grep -qF "Removes the row" "$R/src/a.php" && pass "PHP: no second note stacked on the hand-written one" || fail "PHP: $(cat "$R/src/a.php")"
finish
