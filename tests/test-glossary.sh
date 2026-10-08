#!/bin/bash
# `ptc glossary fmt|validate` over PTC's glossary CSV import shape.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
expect_rc() { [[ "$3" == "$2" ]] && pass "$1" || fail "$1 (rc $3, want $2)"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/g.csv" <<'CSV'
en,de,ru,el
Dashboard,Übersicht,Панель,Πίνακας
WordPress,WordPress,WordPress,WordPress
Invoice,Rechnung,Счёт,Τιμολόγιο
invoice,Faktura,Счёт,Τιμολόγιο
Settings,Einstellungen,Settings RU,Ρυθμίσεις
Post,Beitrag,Запись,Запись
Draft,Entwurf,Черновик,Πρόχειρο
Draft,Entwurf,Черновик,Πρόχειρο
CSV
"$CLI" glossary validate "$WORK/g.csv" --json >"$WORK/out.json" 2>/dev/null; expect_rc "FAIL findings -> exit 2" 2 $?
gc() { if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); f=d['findings']; c=lambda n: [(x['row'], x['level']) for x in f if x['check'] == n]; sys.exit(0 if ($2) else 1)" "$WORK/out.json" 2>/dev/null; then pass "$1"; else fail "$1: $(head -c 400 "$WORK/out.json")"; fi; }
gc "reads header + terms" "d['rows'] == 8 and d['languages'] == ['en', 'de', 'ru', 'el'] and d['source'] == 'en'"
gc "case variants rendered differently are a case contradiction (S2-G2, ruling c), not a self-contradiction" "c('self_contradiction') == [] and c('case_variant') == [] and c('case_contradiction') == [(5, 'FAIL')] and 'de' in [x for x in f if x['check'] == 'case_contradiction'][0]['detail']"
gc "the local run says it is a pre-check" "d['validator'] == 'local-precheck'"
gc "exact duplicate row = WARN" "c('duplicate') == [(9, 'WARN')]"
gc "wrong script: Cyrillic in the Greek column = FAIL; Latin in the Russian column = WARN; kept brand names pass" "sorted(c('wrong_script')) == [(6, 'WARN'), (7, 'FAIL')]"
gc "no structure findings on a well-formed file" "c('structure') == []"
printf 'en,de\nInvoice,Rechnung\ninvoice,rechnung\n' > "$WORK/cv.csv"
"$CLI" glossary validate "$WORK/cv.csv" --json >"$WORK/out.json" 2>/dev/null; expect_rc "case variants rendered alike -> exit 0" 0 $?
gc "case variants rendered alike stay distinct terms (TMG-15): WARN" "c('case_variant') == [(3, 'WARN')] and c('case_contradiction') == []"
printf 'en,de\nInvoice,Rechnung\nInvoice,Faktura\n' > "$WORK/sc.csv"
"$CLI" glossary validate "$WORK/sc.csv" --json >"$WORK/out.json" 2>/dev/null; expect_rc "self-contradiction -> exit 2" 2 $?
gc "self-contradiction: the exact same term, different de translation" "c('self_contradiction') == [(3, 'FAIL')] and 'de' in [x for x in f if x['check'] == 'self_contradiction'][0]['detail']"
"$CLI" glossary validate "$WORK/sc.csv" --remote --json >/dev/null 2>&1; expect_rc "--remote without a project id or token -> exit 1" 1 $?
printf 'en,xx-bogus,de,de\nHello,a,Hallo\n,b,c,d\n' > "$WORK/bad.csv"
"$CLI" glossary validate "$WORK/bad.csv" --json >"$WORK/out.json" 2>/dev/null; expect_rc "broken structure -> exit 2" 2 $?
gc "structure: bad code, repeated column, short row, missing source term" "len(c('structure')) == 4"
printf 'de,en\nHallo,Hello\n' > "$WORK/src.csv"
"$CLI" glossary validate "$WORK/src.csv" --source fr --json >"$WORK/out.json" 2>/dev/null; expect_rc "--source column missing -> exit 2" 2 $?
gc "names the missing source column" "any(\"'fr'\" in x['detail'] for x in f)"
"$CLI" glossary validate "$WORK/src.csv" --source en >/dev/null 2>&1; expect_rc "--source picks a non-first column -> exit 0" 0 $?
printf '\xef\xbb\xbfen , de\n  Hello   world ,Hallo  Welt\n\n,\nBye,\n' > "$WORK/f.csv"
"$CLI" glossary fmt "$WORK/f.csv" >"$WORK/fmt.out" 2>/dev/null; expect_rc "fmt -> exit 0" 0 $?
[[ "$(cat "$WORK/fmt.out")" == $'en,de\nHello world,Hallo Welt\nBye,' ]] && pass "fmt: BOM dropped, cells trimmed and collapsed, blank rows dropped" || fail "fmt: $(od -c "$WORK/fmt.out" | head -5)"
"$CLI" glossary fmt "$WORK/f.csv" --write >/dev/null 2>&1 && cmp -s "$WORK/f.csv" "$WORK/fmt.out" && pass "fmt --write rewrites the file in place" || fail "fmt --write"
"$CLI" glossary validate "$WORK/nope.csv" >/dev/null 2>&1; expect_rc "missing file -> exit 1" 1 $?
"$CLI" glossary >/dev/null 2>&1; expect_rc "no subcommand -> exit 1" 1 $?
echo; echo "glossary suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
