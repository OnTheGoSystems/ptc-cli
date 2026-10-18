#!/bin/bash
# GAP-G11 (WPML lab run 6): wpml-cms-nav and wpml-sticky-links ship an English SOURCE catalogue named .po
# (locale/orig/<domain>.po: header Language en, every msgstr empty) and per-language .mo siblings, no .pot. The scan
# listed no resource set for them, so PTC set up 3 products instead of 5 and nobody said why. Such a .po is the source
# (format po, like a .pot) when no .pot claims its directory or domain; a .po with translations keeps today's behaviour.
# The census also counts every gettext call per text domain (runtime.gettext_domains) so PTC can name a domain no
# catalogue covers.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=${KEEP_WORK:-$(mktemp -d)}; [[ -z "${KEEP_WORK:-}" ]] && trap 'rm -rf "$WORK"' EXIT
SCAN="$WORK/scan.json"; AUDIT="$WORK/audit.json"
check() {  # check FILE "desc" "python expression over d that must be True"
    local file="$1" desc="$2" expr="$3"
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($expr) else 1)" "$file" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc: $(head -c 200 "$file" | tr "\n" " ")"
    fi
}

R="$WORK/repo"; mkdir -p "$R/x/locale/orig" "$R/x/menu" "$R/y/locale/orig"
printf '<?php\n/*\n * Plugin Name: X\n * Text Domain: x\n */\necho __( '"'"'a'"'"', '"'"'x'"'"' );\n' > "$R/x/x.php"
printf '<?php\n_e( '"'"'b'"'"', '"'"'x'"'"' ); echo esc_html__( "c", "x" );\necho _n( "one", "many", $n, "x" );\n' > "$R/x/menu/nav.php"
cat > "$R/x/locale/orig/x.po" <<'PO'
msgid ""
msgstr ""
"Project-Id-Version: X\n"
"POT-Creation-Date: \n"
"Language: en\n"
"Content-Type: text/plain; charset=UTF-8\n"

#: x.php:6
msgid "a"
msgstr ""

msgid "b"
msgstr ""

msgid "c"
msgstr ""

msgid "one"
msgid_plural "many"
msgstr[0] ""
msgstr[1] ""
PO
printf 'compiled' > "$R/x/locale/x-de_DE.mo"
# y: the same layout, but the .po holds German translations: not a template, today's behaviour (no resource set).
printf '<?php\n/*\n * Plugin Name: Y\n */\necho __( "a", "y" );\n' > "$R/y/y.php"
printf 'msgid ""\nmsgstr ""\n"Language: de_DE\\n"\n\nmsgid "a"\nmsgstr "A-de"\n' > "$R/y/locale/orig/y.po"
git -C "$R" init -q

"$CLI" scan --json -d "$R" > "$SCAN" 2>/dev/null
check "$SCAN" "a .po that is a template in all but name (Language en, every msgstr empty, no .pot) is the source of a po resource set" \
    "[s for s in d['resource_sets'] if s['format'] == 'po' and [f['path'] for f in s['source_files']] == ['x/locale/orig/x.po'] and s['source_files'][0]['count'] == 4]"
check "$SCAN" "its .mo sibling one level up gives the languages (x-de_DE.mo -> de_DE, pattern x/locale/x-{{lang}}.mo)" \
    "[s for s in d['resource_sets'] if s['source_pattern'] == 'x/locale/x-{{lang}}.mo' and s['existing_languages'] == ['de_DE']]"
check "$SCAN" "x is a product now (its resource set and plugin main file)" \
    "'x' in [p['dir'] for p in d['products']]"
check "$SCAN" "a .po with translations stays what it was (no resource set for y)" \
    "not [s for s in d['resource_sets'] if any(f['path'].startswith('y/') for f in s['source_files'])]"
check "$SCAN" "runtime.gettext_domains counts gettext calls per text domain (x: 4 calls in 2 files; y: 1 in 1)" \
    "sorted((g['domain'], g['calls'], g['files']) for g in d['runtime']['gettext_domains']) == [('x', 4, 2), ('y', 1, 1)]"

"$CLI" audit strings --json --runtime -d "$R" > "$AUDIT" 2>/dev/null
check "$AUDIT" "the runtime audit takes the source .po as the domain's catalogue (no textdomain_catalogue_name for x)" \
    "d.get('runtime') is not None and not [f for f in d['runtime']['findings'] if f['class'] == 'textdomain_catalogue_name' and \"'x'\" in f['detail']]"

echo; echo "g11 scan suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
