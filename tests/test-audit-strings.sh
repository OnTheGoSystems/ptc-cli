#!/bin/bash
# `ptc audit strings`: the i18n readiness audit (G7) — per-framework rule fixtures with expected findings, the runtime
# loading audit, the size caps and the exit codes.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly FIX="$TEST_DIR/fixtures/audit"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Each framework fixture: the findings (class rule line) must equal expected.txt exactly — no misses, no extras.
for fw in wordpress js rails; do
    cp -R "$FIX/$fw" "$WORK/$fw"; rm -f "$WORK/$fw/expected.txt"
    "$CLI" audit strings -d "$WORK/$fw" --json >"$WORK/$fw.json" 2>/dev/null; rc=$?
    [[ $rc == 0 ]] && pass "$fw: exit 0 with findings" || fail "$fw: rc $rc"
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [print(f['class'], f['rule'], f['line']) for f in d['findings']]" "$WORK/$fw.json" >"$WORK/$fw.got"
    if diff -u "$FIX/$fw/expected.txt" "$WORK/$fw.got" >"$WORK/$fw.diff"; then pass "$fw: findings match expected.txt"; else fail "$fw: $(cat "$WORK/$fw.diff")"; fi
    python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d['schema']==1 and d['framework']==[sys.argv[2]], d['framework']
assert d['truncated'] is False and d['coverage']['files_scanned']>=1
assert sum(d['counts']['by_class'].values())==len(d['findings'])
assert all(set(f)>={'class','file','line','excerpt','rule','fix_hint'} for f in d['findings'])
assert all(f.get('text') for f in d['findings'] if f['class']=='hardcoded_string')
" "$WORK/$fw.json" "$fw" 2>"$WORK/err" && pass "$fw: schema 1 shape, counts, text on hardcoded_string" || fail "$fw: $(tail -2 "$WORK/err")"
done

# Translated lines never flag: the fixture's esc_html_e / t() / date_i18n / l() lines are absent from expected.txt (above).
"$CLI" audit strings -d "$FIX/none" --json >/dev/null 2>&1; rc=$?
[[ $rc == 2 ]] && pass "no recognised framework -> exit 2" || fail "none: rc $rc"

# Runtime loading audit.
R="$WORK/wordpress"
touch -d '2026-01-01 00:00' "$R/languages/shop-de_DE.mo" "$R/languages/shop-de_DE-shop-cart.json"
touch -d '2026-02-01 00:00' "$R/languages/"*.po
touch -d '2026-03-01 00:00' "$R/languages/shop-fr_FR.mo"
"$CLI" audit strings -d "$R" --runtime --json >"$WORK/rt.json" 2>/dev/null
python3 -c "
import json,sys
r=json.load(open(sys.argv[1]))['runtime']
got=sorted((f['class'], f['file'] or '', ) for f in r['findings'])
want=[('script_catalogue_name','shop.php'),('stale_compiled_catalogue','languages/shop-de_DE-shop-cart.json'),
      ('stale_compiled_catalogue','languages/shop-de_DE.mo'),('unreferenced_catalogue','languages/legacy-de_DE.po')]
assert got==want, got
assert 'shop-admin' in [f for f in r['findings'] if f['class']=='script_catalogue_name'][0]['detail']
assert r['text_domains']==['shop'], r['text_domains']
" "$WORK/rt.json" 2>"$WORK/err" && pass "runtime: handle without jed json, stale .mo/.json, unreferenced catalogue" || fail "runtime: $(tail -2 "$WORK/err")"
rm -f "$R/languages/shop.pot" "$R/languages/shop-"*.po
"$CLI" audit strings -d "$R" --runtime --json >"$WORK/rt2.json" 2>/dev/null
python3 -c "import json,sys; r=json.load(open(sys.argv[1]))['runtime']; assert any(f['class']=='textdomain_catalogue_name' and \"'shop'\" in f['detail'] for f in r['findings'])" "$WORK/rt2.json" \
    && pass "runtime: text domain without a .pot/.po of that name" || fail "runtime textdomain"

# Size caps: > 500 findings -> truncated:true, 500 kept; vendor/minified dirs skipped.
B="$WORK/big"; mkdir -p "$B/vendor/lib" "$B/dist"
{ echo '<?php'; echo '// Text Domain: big'; for i in $(seq 1 520); do echo "echo 'Plain text number $i here';"; done; } >"$B/big.php"
cp "$B/big.php" "$B/vendor/lib/x.php"; cp "$B/big.php" "$B/dist/y.php"
printf 'msgid ""\nmsgstr ""\n' >"$B/big.pot"
"$CLI" audit strings -d "$B" --json >"$WORK/big.json" 2>/dev/null
python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d['truncated'] is True and len(d['findings'])==500, (d['truncated'], len(d['findings']))
assert all(f['file']=='big.php' for f in d['findings'])
" "$WORK/big.json" 2>"$WORK/err" && pass "caps: 500 findings + truncated; vendor/dist skipped" || fail "caps: $(tail -2 "$WORK/err")"

"$CLI" audit strings -d "$FIX/js" >"$WORK/txt" 2>&1
grep -q "^frameworks: js; 5 finding(s)" "$WORK/txt" && pass "text output summary" || fail "text: $(tail -2 "$WORK/txt")"
"$CLI" audit >/dev/null 2>&1; [[ $? == 1 ]] && pass "audit without a subcommand -> usage, exit 1" || fail "usage rc"

echo "audit strings: $passed passed, $failed failed"
[[ $failed == 0 ]]
