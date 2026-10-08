#!/bin/bash
# `ptc lint source`: deterministic FAIL/WARN checks over the source strings.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
expect_rc() { [[ "$3" == "$2" ]] && pass "$1" || fail "$1 (rc $3, want $2)"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
R="$WORK/repo"; mkdir -p "$R/config/locales" "$R/languages"
cat > "$R/config/locales/en.yml" <<'YML'
en:
  a: "Pick a color"
  b: "Your favourite colour"
  c: "Don't stop"
  d: "Don’t go"
  e: "Loading..."
  f: "Saving…"
  g: "<b>Bold start"
  h: "Read the <a href='%{url}'>guide</a>"
  i: "Tom &amp; Jerry"
  j: " trailing fragment "
  k: "Two  spaces"
  l: "See https://example.com/docs for more"
  m: "Open the Translation Memory to review strings"
  n: "Connect WooCommerce to your store now"
YML
git -C "$R" init -q
"$CLI" lint source -d "$R" --json >"$WORK/out.json" 2>/dev/null; expect_rc "a FAIL finding -> exit 2" 2 $?
lc() { if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); f=d['findings']; c=lambda n: [x for x in f if x['check'] == n]; sys.exit(0 if ($2) else 1)" "$WORK/out.json" 2>/dev/null; then pass "$1"; else fail "$1"; fi; }
lc "reads the source file found by scan" "d['files'] == ['config/locales/en.yml'] and d['strings'] == 14"
lc "spelling variants mixed (color/colour, favorite/favourite -> only color pair present)" "len(c('spelling_variant_mix')) == 1 and \"'color'\" in c('spelling_variant_mix')[0]['detail'] and c('spelling_variant_mix')[0]['level'] == 'WARN'"
lc "straight vs curly apostrophes mixed" "len(c('quote_class_mix')) == 1"
lc "'...' vs '…' mixed" "len(c('ellipsis_mix')) == 1"
lc "unbalanced tag = leftover markup FAIL" "[x['key'] for x in c('leftover_markup')] == ['en.g'] and c('leftover_markup')[0]['level'] == 'FAIL'"
lc "balanced inline HTML = WARN" "[x['key'] for x in c('inline_markup')] == ['en.h']"
lc "HTML entity in plain text" "[x['key'] for x in c('html_entity')] == ['en.i']"
lc "edge whitespace + double space" "[x['key'] for x in c('edge_whitespace')] == ['en.j'] and [x['key'] for x in c('double_space')] == ['en.k']"
lc "URL inside a string" "[x['key'] for x in c('url_in_string')] == ['en.l']"
lc "feature/product names inside sentences" "sorted(x['key'] for x in c('feature_name_in_sentence')) == ['en.m', 'en.n'] and 'Translation Memory' in c('feature_name_in_sentence')[0]['detail'] + c('feature_name_in_sentence')[1]['detail']"
lc "fail/warn counters" "d['fail'] == 1 and d['warn'] == len(f) - 1"
"$CLI" lint source -d "$R" >"$WORK/out" 2>&1
grep -q "^FAIL leftover_markup: config/locales/en.yml \[en.g\]" "$WORK/out" && grep -q "14 strings in 1 file(s): 1 FAIL" "$WORK/out" && pass "text output lists findings and totals" || fail "text: $(tail -3 "$WORK/out")"
printf 'en:\n  ok: "All good"\n' > "$WORK/clean.yml"; mkdir -p "$R/x"; cp "$WORK/clean.yml" "$R/x/clean.yml"
"$CLI" lint source -d "$R" --file x/clean.yml >/dev/null 2>&1; expect_rc "clean file -> exit 0" 0 $?
# template regeneration diff
printf 'msgid ""\nmsgstr ""\n\nmsgid "Kept"\nmsgstr ""\n\nmsgid "Dropped by the build"\nmsgstr ""\n' > "$R/languages/p.pot"
cp "$R/languages/p.pot" "$WORK/pot.orig"
"$CLI" lint source -d "$R" --file x/clean.yml --template languages/p.pot --template-cmd "printf 'msgid \"\"\nmsgstr \"\"\n\nmsgid \"Kept\"\nmsgstr \"\"\n' > languages/p.pot" --json >"$WORK/out.json" 2>/dev/null; expect_rc "regeneration loses entries -> exit 2" 2 $?
lc "template: FAIL names the loss and the counts" "c('template_regeneration')[0]['level'] == 'FAIL' and d['template']['committed'] == 2 and d['template']['regenerated'] == 1 and d['template']['lost'] == ['Dropped by the build']"
cmp -s "$R/languages/p.pot" "$WORK/pot.orig" && pass "the committed template is restored after the check" || fail "template not restored"
"$CLI" lint source -d "$R" --file x/clean.yml --template languages/p.pot --template-cmd "true" --json >"$WORK/out.json" 2>/dev/null; expect_rc "regeneration identical -> exit 0" 0 $?
"$CLI" lint source -d "$R" --file x/clean.yml --template languages/p.pot --template-cmd "exit 3" --json >"$WORK/out.json" 2>/dev/null; expect_rc "template command fails -> exit 2" 2 $?
"$CLI" lint source -d "$R" --template languages/p.pot >/dev/null 2>&1; expect_rc "--template without --template-cmd -> exit 1" 1 $?
"$CLI" lint bogus >/dev/null 2>&1; expect_rc "unknown lint target -> exit 1" 1 $?
echo; echo "lint suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
