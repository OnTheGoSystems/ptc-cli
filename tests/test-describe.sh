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
grep -c "translators:" "$G/src/a.php" | grep -qx 2 && grep -q "/\* translators: Saves the settings form \*/" "$G/src/a.php" && pass "a changed description replaces the old translators: line" || fail "update: $(cat "$G/src/a.php")"
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

echo; echo "describe suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
