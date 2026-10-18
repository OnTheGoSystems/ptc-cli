#!/bin/bash
# `ptc describe apply`: PTC-authored descriptions into the slot PTC's parsers read
# (gettext `#.` -> Formats::Concerns::PoObject#comments; Chrome-i18n JSON `description`
# -> Parsers::JsonFileParser context). Other formats are skipped with a reason.
# Default for gettext (1.2.1): a `translators:` source comment at the call site; `#.` only with --into-template.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
expect_rc() { [[ "$3" == "$2" ]] && pass "$1" || fail "$1 (rc $3, want $2)"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Tree comparison without .git that works with BusyBox too (CI runs python:3.12-alpine, whose diff has no -x):
# prints the differing paths, exit 0 when the trees are equal.
tree_diff() {
    python3 - "$1" "$2" <<'PY'
import filecmp, os, sys
def walk(root):
    out = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x != ".git"]
        for f in files:
            out[os.path.relpath(os.path.join(d, f), root)] = os.path.join(d, f)
    return out
a, b = walk(sys.argv[1]), walk(sys.argv[2])
bad = sorted(set(a) ^ set(b)) + sorted(k for k in set(a) & set(b) if not filecmp.cmp(a[k], b[k], shallow=False))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}
R="$WORK/repo"; mkdir -p "$R/languages" "$R/_locales/en" "$R/config/locales" "$R/src/locales/en"
cat > "$R/languages/p.pot" <<'POT'
msgid ""
msgstr ""

# Translators: keep short
#: src/a.php:3
msgid "Save"
msgstr ""

#: src/a.php:9
msgctxt "verb"
msgid "Post"
msgstr ""

#. existing note
#: src/b.php:1
msgid "Hello %s"
msgstr ""
POT
printf '{\n  "save": {\n    "message": "Save"\n  }\n}\n' > "$R/_locales/en/messages.json"
printf 'en:\n  save: Save\n' > "$R/config/locales/en.yml"
printf '{"save": "Save"}\n' > "$R/src/locales/en/common.json"
cat > "$WORK/d.json" <<'JSON'
{"descriptions": [
 {"file": "languages/p.pot", "key": "Save", "description": "Button that saves the settings form"},
 {"file": "languages/p.pot", "key": "Post", "context": "verb", "description": "Action: publish the post"},
 {"file": "languages/p.pot", "key": "Hello %s", "description": "%s is the user's first name"},
 {"file": "_locales/en/messages.json", "key": "save", "description": "Toolbar save button"}
]}
JSON
cp -R "$R" "$WORK/orig"
"$CLI" describe apply --into-template --file "$WORK/d.json" -d "$R" --dry-run >"$WORK/out" 2>&1; expect_rc "dry run -> exit 0" 0 $?
diff -r "$R" "$WORK/orig" >/dev/null && pass "dry run writes nothing" || fail "dry run changed files"
grep -q "4 description(s) would write" "$WORK/out" && pass "dry run reports what it would write" || fail "dry run text: $(cat "$WORK/out")"
"$CLI" describe apply --into-template --file "$WORK/d.json" -d "$R" >"$WORK/out" 2>&1; expect_rc "apply -> exit 0" 0 $?
python3 - "$R/languages/p.pot" <<'PY' && pass "gettext: #. lines land in their entry, after existing comments, before #:" || fail "pot content: $(cat "$R/languages/p.pot")"
import sys
t = open(sys.argv[1]).read()
assert "# Translators: keep short\n#. Button that saves the settings form\n#: src/a.php:3\nmsgid \"Save\"" in t, t
assert "#. Action: publish the post\n#: src/a.php:9\nmsgctxt \"verb\"" in t, t
assert "#. existing note\n#. %s is the user's first name\n#: src/b.php:1" in t, t
PY
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d == {'save': {'message': 'Save', 'description': 'Toolbar save button'}} else 1)" "$R/_locales/en/messages.json" && pass "Chrome-i18n JSON: description sibling written" || fail "chrome json: $(cat "$R/_locales/en/messages.json")"
cp -R "$R" "$WORK/after1"
"$CLI" describe apply --into-template --file "$WORK/d.json" -d "$R" --json >"$WORK/out.json" 2>/dev/null; expect_rc "re-apply -> exit 0" 0 $?
diff -r "$R" "$WORK/after1" >/dev/null && pass "re-apply is idempotent (no duplicate lines)" || fail "re-apply changed files"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d['unchanged']) == 4 and d['applied'] == [] else 1)" "$WORK/out.json" && pass "--json reports unchanged entries" || fail "json: $(cat "$WORK/out.json")"
cat > "$WORK/d2.json" <<'JSON'
[{"file": "config/locales/en.yml", "key": "save", "description": "x"},
 {"file": "src/locales/en/common.json", "key": "save", "description": "x"},
 {"file": "languages/p.pot", "key": "Missing", "description": "x"},
 {"file": "../outside.po", "key": "a", "description": "x"},
 {"file": "languages/p.pot", "key": "Save"}]
JSON
"$CLI" describe apply --into-template --file "$WORK/d2.json" -d "$R" --json >"$WORK/out.json" 2>/dev/null; expect_rc "skips -> exit 2" 2 $?
python3 - "$WORK/out.json" <<'PY' && pass "skips carry reasons: YAML / flat JSON (no slot), unknown msgid, outside path, incomplete item" || fail "skips: $(cat "$WORK/out.json")"
import json, sys
d = json.load(open(sys.argv[1]))
r = [x["reason"] for x in d["skipped"]]
assert len(r) == 5 and d["applied"] == [], d
assert any("no description slot" in x for x in r) and any("Chrome-i18n" in x for x in r)
assert "msgid not found in the catalogue" in r and "path is outside the repository" in r and "needs file, key and description" in r
PY
diff -r "$R" "$WORK/after1" >/dev/null && pass "skipped items change no file" || fail "skips changed files"
echo '{"x": 1}' > "$WORK/bad.json"
"$CLI" describe apply --file "$WORK/bad.json" -d "$R" >/dev/null 2>&1; expect_rc "input without descriptions -> exit 1" 1 $?
"$CLI" describe apply -d "$R" >/dev/null 2>&1; expect_rc "no --file -> exit 1" 1 $?
echo '{}' > "$R/.prettierrc"
printf '{\n  "open": {\n    "message": "Open"\n  }\n}\n' > "$R/_locales/en/messages.json"
echo '[{"file": "_locales/en/messages.json", "key": "open", "description": "Menu item"}]' > "$WORK/d3.json"
"$CLI" describe apply --file "$WORK/d3.json" -d "$R" >"$WORK/out" 2>&1
grep -q "prettier may reformat _locales/en/messages.json" "$WORK/out" && pass "warns when prettier would reformat the edited file" || fail "prettier warning: $(cat "$WORK/out")"
echo "_locales/" > "$R/.prettierignore"
printf '{\n  "open": {\n    "message": "Open"\n  }\n}\n' > "$R/_locales/en/messages.json"
"$CLI" describe apply --file "$WORK/d3.json" -d "$R" >"$WORK/out" 2>&1
grep -q "prettier" "$WORK/out" && fail "warned although .prettierignore covers the file" || pass "no warning when .prettierignore covers the file"
echo "=== gettext default: translators: comments at the call site ==="
G="$WORK/g"; mkdir -p "$G/languages" "$G/src" "$G/templates"
printf 'msgid ""\nmsgstr ""\n\n#: src/a.php:3\nmsgid "Save"\nmsgstr ""\n\n#: src/a.php:5\nmsgid "Hello %%s"\nmsgstr ""\n\n#: templates/t.php:2\nmsgid "Delete"\nmsgstr ""\n\nmsgid "Its"\nmsgstr ""\n' > "$G/languages/p.pot"
cat > "$G/src/a.php" <<'PHP'
<?php
function x() {
    echo __( 'Save', 'p' );
    // plain comment
    printf( esc_html__( 'Hello %s', 'p' ), $name );
}
PHP
printf '<div>\n  <p><?php esc_html_e( "Delete", "p" ); ?></p>\n</div>\n' > "$G/templates/t.php"
printf 'const s = __( "It\\x27s", "p" );\n' > "$G/src/b.js"
cp "$G/languages/p.pot" "$WORK/g.pot.orig"
cat > "$WORK/g.json" <<'JSON'
{"descriptions": [
 {"file": "languages/p.pot", "key": "Save", "description": "Button that saves the form", "usage": {"path": "src/a.php", "line": 3}},
 {"file": "languages/p.pot", "key": "Hello %s", "description": "%s: the user's first name */ injected", "usage": {"path": "src/a.php", "line": 4}},
 {"file": "languages/p.pot", "key": "Delete", "description": "Row action", "usage": {"path": "templates/t.php", "line": 2}},
 {"file": "languages/p.pot", "key": "Its", "description": "x", "usage": {"path": "src/b.js", "line": 1}},
 {"file": "languages/p.pot", "key": "Gone", "description": "y"}
]}
JSON
git -C "$G" init -q
"$CLI" describe apply --file "$WORK/g.json" -d "$G" --json >"$WORK/g.out" 2>/dev/null; expect_rc "source comments with skips -> exit 2" 2 $?
cmp -s "$G/languages/p.pot" "$WORK/g.pot.orig" && pass "the template itself is not edited (regeneration carries the comments)" || fail "pot was edited"
python3 - "$G" <<'PY' && pass "translators: comments sit directly above the call (same indent; */ neutralised), a template line gets <?php /* */ ?> on the line above" || fail "source: $(cat "$G/src/a.php" "$G/templates/t.php")"
import sys
a = open(sys.argv[1] + "/src/a.php").read()
assert "    /* translators: Button that saves the form */\n    echo __( 'Save', 'p' );" in a, a
assert "    // plain comment\n    /* translators: %s: the user's first name * / injected */\n    printf( esc_html__( 'Hello %s'" in a, a
t = open(sys.argv[1] + "/templates/t.php").read()
# S2-R2 F8: a template line's note is a PHP comment in its own tag on the line above (never visible text)
assert '<div>\n  <?php /* translators: Row action */ ?>\n  <p><?php esc_html_e( "Delete", "p" ); ?></p>' in t, t
PY
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); r={x['key']: x['reason'] for x in d['skipped']}; sys.exit(0 if len(d['applied']) == 3 and 'does not contain the msgid' in r['Its'] and 'no usage' in r['Gone'] else 1)" "$WORK/g.out" && pass "skips: usage line without the msgid, no usage at all" || fail "skips: $(cat "$WORK/g.out")"
cp -R "$G" "$WORK/g1"
"$CLI" describe apply --file "$WORK/g.json" -d "$G" >/dev/null 2>&1
if changed=$(tree_diff "$G" "$WORK/g1"); then pass "re-apply is idempotent (block and inline comments)"; else fail "re-apply changed: $changed"; fi
sed -i 's/Button that saves the form/Saves the settings form/' "$WORK/g.json"
"$CLI" describe apply --file "$WORK/g.json" -d "$G" >/dev/null 2>&1
# WF-8: an existing /* translators: */ note is never replaced (a hand-written one looks exactly like PTC's): kept, skipped.
grep -c "translators:" "$G/src/a.php" | grep -qx 2 && grep -q "/\* translators: Button that saves the form \*/" "$G/src/a.php" && ! grep -q "Saves the settings form" "$G/src/a.php" && pass "a changed description never replaces an existing translators: line" || fail "update: $(cat "$G/src/a.php")"
# usage from the scan's usage map when the item has none
printf 'msgid ""\nmsgstr ""\n\nmsgid "Only via scan"\nmsgstr ""\n' > "$G/languages/q.pot"
printf '<?php\necho __( "Only via scan", "p" );\n' > "$G/src/c.php"
git -C "$G" add -A >/dev/null 2>&1
echo '[{"file": "languages/q.pot", "key": "Only via scan", "description": "Found by the scan"}]' > "$WORK/q.json"
"$CLI" describe apply --file "$WORK/q.json" -d "$G" >/dev/null 2>&1; expect_rc "usage looked up in the scan -> exit 0" 0 $?
grep -q "^/\* translators: Found by the scan \*/$" "$G/src/c.php" && pass "comment written at the scan's usage line" || fail "scan usage: $(cat "$G/src/c.php")"

echo "=== S2-R2 F8: PHP notes are PHP comments on the line above, never visible text; existing notes stay ==="
H="$WORK/h"; mkdir -p "$H/languages" "$H/templates" "$H/src"
printf 'msgid ""\nmsgstr ""\n\nmsgid "Title"\nmsgstr ""\n\nmsgid "Save"\nmsgstr ""\n\nmsgid "Cancel"\nmsgstr ""\n\nmsgid "Hello"\nmsgstr ""\n' > "$H/languages/h.pot"
cat > "$H/templates/page.php" <<'PHP'
<div class="wrap">
  <h1><?= esc_html__( 'Title', 'h' ) ?></h1>
  <p><button><?php esc_html_e( 'Save', 'h' ); ?></button> <button><?php esc_html_e( 'Cancel', 'h' ); ?></button></p>
</div>
PHP
cat > "$H/src/x.php" <<'PHP'
<?php
// translators: the greeting a developer wrote
echo __( 'Hello', 'h' );
PHP
cat > "$WORK/h.json" <<'JSON'
{"descriptions": [
 {"file": "languages/h.pot", "key": "Title", "description": "Page heading", "usage": {"path": "templates/page.php", "line": 2}},
 {"file": "languages/h.pot", "key": "Save", "description": "Button that saves", "usage": {"path": "templates/page.php", "line": 3}},
 {"file": "languages/h.pot", "key": "Cancel", "description": "Button that cancels", "usage": {"path": "templates/page.php", "line": 3}},
 {"file": "languages/h.pot", "key": "Hello", "description": "Greeting on the dashboard", "usage": {"path": "src/x.php", "line": 3}}
]}
JSON
git -C "$H" init -q
"$CLI" describe apply --file "$WORK/h.json" -d "$H" --json >"$WORK/h.out" 2>/dev/null
python3 - "$H" "$WORK/h.out" <<'PY' && pass "PHP template notes: <?php /* */ ?> on the line above, shared line combined, developer note kept" || fail "F8: $(cat "$H/templates/page.php" "$H/src/x.php" "$WORK/h.out")"
import json, re, sys
page = open(sys.argv[1] + "/templates/page.php").read()
lines = page.split("\n")
# never visible text: every line outside <?php ... ?> carries no translators note
for l in lines:
    outside = re.sub(r"<\?(php|=).*?\?>", "", l)
    assert "translators" not in outside, ("visible note", l)
assert lines[1] == "  <?php /* translators: Page heading */ ?>", lines
assert lines[2] == "  <h1><?= esc_html__( 'Title', 'h' ) ?></h1>", lines
assert lines[3] == "  <?php /* translators: \"Save\": Button that saves; \"Cancel\": Button that cancels */ ?>", lines
x = open(sys.argv[1] + "/src/x.php").read()
assert "// translators: the greeting a developer wrote" in x, x
assert "/* translators: Greeting on the dashboard */\n// translators: the greeting a developer wrote\necho __( 'Hello'" in x, x
d = json.load(open(sys.argv[2]))
assert not d["skipped"], d["skipped"]
PY


echo "=== GAP-G5: a note is never written inside a literal; it sits where the extractor reads it ==="
# WPML lab run 4: the usage line of a string concatenated into a multi-line single-quoted PHP string got its note on the
# line above, i.e. inside the literal (shown as text on the String Translation page). JS notes above a `? __(` / `: __(`
# continuation or above a JSX element line were not extracted (or became JSX text). The note goes on its own line above
# the call's line when that line starts in code (PHP) or starts with the call (JS); otherwise directly before the call.
K="$WORK/k"; mkdir -p "$K/languages" "$K/src"
printf 'msgid ""\nmsgstr ""\n' > "$K/languages/k.pot"
cat > "$K/src/st.php" <<'PHP'
<?php
class X {
	function notice() {
		echo '<div class="info-wrap">
				<p>' . __( 'Scan the selected components', 'd' ) . '</p>
				<form><button type="button">' . __( 'Select affected components', 'd' ) . '</button></form>
			</div>';
		$long = __(
			'A sentence on its own line',
			'd'
		);
		$doc = <<<TXT
Call __( 'Ghost', 'd' ) to translate.
TXT;
	}
}
PHP
cat > "$K/src/jobs.js" <<'JS'
export const loading = page => page === 'queue'
  ? __( 'Loading queue', 'd' )
  : __( 'Loading jobs', 'd' )
const heading = ( a ) => {
  if ( a ) return __( 'Connected', 'd' )
  const n = _n(
    'One item',
    '%d items',
    a,
    'd'
  )
  return n
}
const Row = () => (
  <td>
    <a className='edit' aria-label={__('Edit pair', 'd')}>x</a>
  </td>
)
JS
cat > "$WORK/k.json" <<'JSON'
{"descriptions": [
 {"file": "languages/k.pot", "key": "Scan the selected components", "description": "Notice text", "usage": {"path": "src/st.php", "line": 5}},
 {"file": "languages/k.pot", "key": "Select affected components", "description": "Notice button", "usage": {"path": "src/st.php", "line": 6}},
 {"file": "languages/k.pot", "key": "A sentence on its own line", "description": "Long sentence", "usage": {"path": "src/st.php", "line": 9}},
 {"file": "languages/k.pot", "key": "Ghost", "description": "Not a call", "usage": {"path": "src/st.php", "line": 13}},
 {"file": "languages/k.pot", "key": "Loading queue", "description": "Status Q", "usage": {"path": "src/jobs.js", "line": 2}},
 {"file": "languages/k.pot", "key": "Loading jobs", "description": "Status J", "usage": {"path": "src/jobs.js", "line": 3}},
 {"file": "languages/k.pot", "key": "Connected", "description": "Heading C", "usage": {"path": "src/jobs.js", "line": 5}},
 {"file": "languages/k.pot", "key": "One item", "description": "Count O", "usage": {"path": "src/jobs.js", "line": 7}},
 {"file": "languages/k.pot", "key": "Edit pair", "description": "Tooltip E", "usage": {"path": "src/jobs.js", "line": 16}}
]}
JSON
git -C "$K" init -q
"$CLI" describe apply --file "$WORK/k.json" -d "$K" --json >"$WORK/k.out" 2>/dev/null; expect_rc "a call that is no call (inside a heredoc) is skipped -> exit 2" 2 $?
python3 - "$K" "$WORK/k.out" <<'PY' && pass "PHP: a call inside a multi-line string's concatenation gets its note before the call, never inside the literal; a heredoc mention is skipped with the reason" || fail "G5 PHP: $(cat "$K/src/st.php" "$WORK/k.out")"
import json, sys
p = open(sys.argv[1] + "/src/st.php").read().split("\n")
assert p[4] == "\t\t\t\t<p>' . /* translators: Notice text */ __( 'Scan the selected components', 'd' ) . '</p>", p[3:7]
assert p[5] == "\t\t\t\t<form><button type=\"button\">' . /* translators: Notice button */ __( 'Select affected components', 'd' ) . '</button></form>", p[3:7]
assert p[3] == "\t\techo '<div class=\"info-wrap\">", p[3:7]
assert p[7] == "\t\t/* translators: Long sentence */" and p[8] == "\t\t$long = __(", p[7:10]
assert "Call __( 'Ghost', 'd' ) to translate." == p[13] and "Not a call" not in "\n".join(p), p[11:15]
d = json.load(open(sys.argv[2]))
r = {x["key"]: x["reason"] for x in d["skipped"]}
assert list(r) == ["Ghost"] and "no gettext call" in r["Ghost"], r
PY
python3 - "$K" <<'PY' && pass "JS: notes before a ?/: continuation call, after return, before a multi-line call and inside a JSX attribute sit right before the call" || fail "G5 JS: $(cat "$K/src/jobs.js")"
import sys
j = open(sys.argv[1] + "/src/jobs.js").read().split("\n")
assert j[1] == "  ? /* translators: Status Q */ __( 'Loading queue', 'd' )", j[:3]
assert j[2] == "  : /* translators: Status J */ __( 'Loading jobs', 'd' )", j[:3]
assert j[4] == "  if ( a ) return /* translators: Heading C */ __( 'Connected', 'd' )", j[3:7]
assert j[5] == "  const n = /* translators: Count O */ _n(" and j[6] == "    'One item',", j[3:8]
assert j[15] == "    <a className='edit' aria-label={/* translators: Tooltip E */ __('Edit pair', 'd')}>x</a>", j[13:17]
assert len(j) == 19, len(j)
PY
cp -R "$K" "$WORK/k1"
"$CLI" describe apply --file "$WORK/k.json" -d "$K" >/dev/null 2>&1
if changed=$(tree_diff "$K" "$WORK/k1"); then pass "re-apply of inline notes is idempotent"; else fail "re-apply changed: $changed"; fi
echo; echo "describe suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
