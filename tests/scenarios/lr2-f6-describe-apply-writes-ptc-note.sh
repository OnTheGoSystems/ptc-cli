#!/bin/bash
# covers: LR2-F6
# status: fixed
# source: WPML lab run 2, ~/lab-staging/scenarios/run-claude-wpml-core-2/.ptc/TASK.md "ptc describe apply garbles comments" (sitepress 114 of 137 notes rewritten, 13 cut with "...."; media 8/12; string-translation 15/36; cms-nav 1/7; sticky-links 2/2, one leaking `wpml_bold_names`)
# title: `ptc describe apply` writes PTC's translator note byte for byte (never cut, never rewritten) and skips, with the reason, a description that names code
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
# A WPML-shaped product: a PHP admin template (inline <?php ?> lines), a PHP class, a JSX component.
R="$WORK/wpml-sticky-links"; mkdir -p "$R/locale/pot" "$R/menu" "$R/classes" "$R/src/js"; git -C "$R" init -q
printf 'msgid ""\nmsgstr ""\n\n#: menu/management.php:3\nmsgid "Sticky links"\nmsgstr ""\n\n#: menu/management.php:4\nmsgid "Scan ALL posts"\nmsgstr ""\n\n#: classes/notice.php:3\nmsgid "%%1$s of %%2$s posts processed"\nmsgstr ""\n\n#: src/js/Panel.js:3\nmsgid "Open"\nmsgstr ""\n\n#: classes/notice.php:4\nmsgid "Remove"\nmsgstr ""\n' > "$R/locale/pot/wpml-sticky-links.pot"
printf '<div class="wrap">\n<h2>Options</h2>\n<h2><?php echo wpml_bold_names( __( '"'"'Sticky links'"'"', '"'"'wpml-sticky-links'"'"' ) ); ?></h2>\n<input type="button" value="<?php echo esc_attr__( '"'"'Scan ALL posts'"'"', '"'"'wpml-sticky-links'"'"' ); ?>" />\n</div>\n' > "$R/menu/management.php"
printf "<?php\nclass Notice {\n\tpublic function text() { return sprintf( __( '%%1\$s of %%2\$s posts processed', 'wpml-sticky-links' ), \$a, \$b ); }\n\tpublic function remove() { return __( 'Remove', 'wpml-sticky-links' ); }\n}\n" > "$R/classes/notice.php"
printf "export const Panel = () => (\n  <div>\n    {__('Open', 'wpml-sticky-links')}\n  </div>\n);\n" > "$R/src/js/Panel.js"
git -C "$R" add -A; git -C "$R" -c user.email=t@t -c user.name=t commit -qm base
# The notes PTC composes now (Guide::TranslatorNote): in the UI's words, within the rule. Run 2's CLI rewrote each of these:
# "Yes/No" and "on/off" were dropped as paths, the note with the placeholder list was cut at 200 with "...".
ok1='Shown in the Sticky Links page (WPML > Sticky Links) as a button. Appears next to: Scan, Yes/No, Replace permalinks with sticky links in all blog posts.'
ok2='Shown in the Sticky Links page, progress line under the scan button as a notice. Placeholders: %1$s = the number of posts already processed; %2$s = the number of posts on the site in all. Keep it within 60 characters. Appears next to: Scan ALL posts.'
ok3='Shown in the Sticky Links panel (on/off switch area) as a button. Appears next to: Close, "Save settings".'
ok4="Shown in the Sticky Links notice as a link. It removes the notice; it's a verb, not the noun."
# Run 2's own stored descriptions for the same strings (desc-25.json): they name a file and a function.
leak1='Shown in Sticky Links setup page (menu/management.php), top-level page heading, passed through wpml_bold_names() as a heading. Appears next to: Options, Apply, Broken Links.'
python3 -c 'import json,sys; a=sys.argv[1:]; print(json.dumps({"descriptions": [
 {"file": "locale/pot/wpml-sticky-links.pot", "key": "Scan ALL posts", "description": a[0], "usage": {"path": "menu/management.php", "line": 4}},
 {"file": "locale/pot/wpml-sticky-links.pot", "key": "%1$s of %2$s posts processed", "description": a[1], "usage": {"path": "classes/notice.php", "line": 3}},
 {"file": "locale/pot/wpml-sticky-links.pot", "key": "Open", "description": a[2], "usage": {"path": "src/js/Panel.js", "line": 3}},
 {"file": "locale/pot/wpml-sticky-links.pot", "key": "Remove", "description": a[3], "usage": {"path": "classes/notice.php", "line": 4}},
 {"file": "locale/pot/wpml-sticky-links.pot", "key": "Sticky links", "description": a[4], "usage": {"path": "menu/management.php", "line": 3}}]}))' \
    "$ok1" "$ok2" "$ok3" "$ok4" "$leak1" > "$WORK/descriptions.json"
"$CLI" describe apply --file "$WORK/descriptions.json" --json -d "$R" >"$WORK/out.json" 2>"$WORK/err"
rc=$?
[[ $rc -eq 2 ]] && pass "describe apply exits 2 (a description was skipped, the CLI's contract)" || fail "exit $rc: $(cat "$WORK/err")"
# Every note the CLI added, as written (the text between `translators: ` and the comment's end).
notes=$(git -C "$R" diff -U0 | sed -n 's/^+.*translators: \(.*\) \*\/.*$/\1/p')
for want in "$ok1" "$ok2" "$ok3" "$ok4"; do
    grep -qxF -- "$want" <<<"$notes" && pass "written byte for byte: ${want:0:60}..." || fail "not written as PTC composed it: ${want:0:60}... | notes added: $notes"
done
[[ $(grep -c . <<<"$notes") -eq 4 ]] && pass "exactly the four valid notes were added" || fail "notes added: $notes"
grep -q 'wpml_bold_names\|management\.php' <<<"$notes" && fail "a code name or file name reached a note: $notes" || pass "no note names code or a file"
python3 - "$WORK/out.json" <<'PY' && pass "the description naming code is skipped with the reason" || fail "skip: $(cat "$WORK/out.json")"
import json, sys
r = json.load(open(sys.argv[1]))
s = [x for x in r["skipped"] if x.get("key") == "Sticky links"]
assert s and "not written" in s[0]["reason"] and "management.php" in s[0]["reason"], r["skipped"]
assert len(r["applied"]) == 4, r["applied"]
PY
grep -n "wpml_bold_names( __( 'Sticky links'" "$R/menu/management.php" | grep -q '^3:' && pass "the heading line has no note above it (line 3 unchanged)" || fail "management.php: $(cat "$R/menu/management.php")"
finish
