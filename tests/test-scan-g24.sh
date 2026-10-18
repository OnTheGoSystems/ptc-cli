#!/bin/bash
# GAP-G24 (the manual WPML preparation, wpml-core MR !939): sitepress.pot regenerated without the page-builder add-ons
# silently lost 235-343 strings. The census `usages` list only the calls whose msgid some template holds, so a string
# missing from EVERY template was invisible to PTC's freshness check (GAP-G21). `ptc scan --json` adds `usages_unmatched`:
# {text_domain => {calls: [{msgid, msgctxt, path, line, text}], total, truncated}} for every gettext call whose
# (msgctxt, msgid) is in no census template of its text domain; a call with no or a variable domain goes under "";
# dynamic literals (concatenation, interpolation, a variable context) are never listed; at most 500 calls per domain.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=${KEEP_WORK:-$(mktemp -d)}; [[ -z "${KEEP_WORK:-}" ]] && trap 'rm -rf "$WORK"' EXIT
SCAN="$WORK/scan.json"
check() {  # check FILE "desc" "python expression over d (and u = d['usages_unmatched']) that must be True"
    local file="$1" desc="$2" expr="$3"
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); u=d.get('usages_unmatched'); sys.exit(0 if ($expr) else 1)" "$file" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc: $(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('usages_unmatched'))[:300])" "$file" 2>&1)"
    fi
}

R="$WORK/repo"; mkdir -p "$R/dom/languages" "$R/dom/inc" "$R/big/languages"
cat > "$R/dom/languages/dom.pot" <<'PO'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid "Kept string"
msgstr ""

msgctxt "noun"
msgid "Post"
msgstr ""
PO
cat > "$R/dom/inc/a.php" <<'PHP'
<?php
echo __( 'Lost string', 'dom' );
echo __( 'Kept string', 'dom' );
echo __( 'Hello ' . $name, 'dom' );
echo __( "Hi $name", 'dom' );
echo _x( 'Post', 'noun', 'dom' );
echo _x( 'Post', 'verb', 'dom' );
echo _x( 'Page', $ctx, 'dom' );
echo __( 'Kept string' );
echo __( 'No domain lost' );
echo __( 'Variable domain lost', $domain );
PHP
cat > "$R/big/languages/big.pot" <<'PO'
msgid ""
msgstr ""

msgid "Held"
msgstr ""
PO
python3 -c "
import sys
with open(sys.argv[1], 'w') as fh:
    fh.write('<?php\n')
    for i in range(501):
        fh.write(\"echo __( 'Lost %d', 'big' );\n\" % i)
" "$R/big/many.php"
git -C "$R" init -q

"$CLI" scan --json -d "$R" > "$SCAN" 2>/dev/null
check "$SCAN" "the census carries usages_unmatched" "isinstance(u, dict)"
check "$SCAN" "a call whose string is in no template of its domain is listed under the domain, with msgctxt, path, line and text" \
    "u['dom']['calls'][0] == {'msgid': 'Lost string', 'msgctxt': None, 'path': 'dom/inc/a.php', 'line': 2, 'text': \"echo __( 'Lost string', 'dom' );\"}"
check "$SCAN" "a msgid the template holds under another context is unmatched for that context only (Post/verb, not Post/noun)" \
    "[(c['msgid'], c['msgctxt']) for c in u['dom']['calls']] == [('Lost string', None), ('Post', 'verb')]"
check "$SCAN" "a string the template holds is never listed (Kept string)" \
    "not [c for k in u for c in u[k]['calls'] if c['msgid'] == 'Kept string']"
check "$SCAN" "dynamic literals (concatenation, interpolation, a variable context) are never listed" \
    "not [c for k in u for c in u[k]['calls'] if c['msgid'] in ('Hello ', 'Hi \$name', 'Page')]"
check "$SCAN" "calls with no or a variable text domain go under \"\" (unattributable)" \
    "[c['msgid'] for c in u['']['calls']] == ['No domain lost', 'Variable domain lost'] and u['']['total'] == 2 and u['']['truncated'] is False"
check "$SCAN" "an untruncated domain carries its total and truncated false" \
    "u['dom']['total'] == 2 and u['dom']['truncated'] is False"
check "$SCAN" "at most 500 calls per domain, with truncated true and the total count" \
    "len(u['big']['calls']) == 500 and u['big']['truncated'] is True and u['big']['total'] == 501"
check "$SCAN" "the census usages are unchanged (template-keyed: Kept string and Post only)" \
    "sorted(d['usages']['dom/languages/dom.pot']) == ['Kept string', 'Post']"

echo; echo "g24 scan suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
