#!/bin/bash
# S2-R2 item 2 (decision 5; specs/agent-guide AGD-3): `ptc estimate` is a LOCAL calculation. Words are counted with
# PTC's rule (Operations::Utils::CalculateWords) over the whole configured census, x target languages x the per-word
# credit rate. The rate and the balance are the only remote inputs (one GET balance, or --rate/--balance).
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
refuse_busy_port() {  # a port that already answers would hide a mock that could not bind (a stale run's server passes the probe)
    local i  # up to ~5 s for a listener in its last moments (the previous suite's mock shutting down) to go quiet
    for i in $(seq 1 20); do
        python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), 0.4).close()" 2>/dev/null || return 0
        sleep 0.25
    done
    echo "port $1 already in use: a stale mock_ptc_api.py? (pgrep -af mock_ptc_api.py)" >&2; exit 1
}
stop_mocks() {  # kill the suite's mocks AND wait until they are gone, so the next suite finds their ports free
    local p i; for p in "$@"; do kill "$p" 2>/dev/null; done
    for p in "$@"; do wait "$p" 2>/dev/null; for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done; done
}
readonly CASES="$(dirname "$(dirname "$TEST_DIR")")/backend/spec/fixtures/files/word_count_cases.json"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); MOCK_PID=""
cleanup() { [[ -n "$MOCK_PID" ]] && stop_mocks "$MOCK_PID"; rm -rf "$WORK"; }
trap cleanup EXIT
field() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {}, {'d': d}))" "$1" "$2"; }

echo "=== the shared word-count fixture (the backend spec of CalculateWords runs the same file) ==="
out=$("$CLI" estimate --check-cases "$CASES" 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "every shared case counts as PTC counts it ($out)" || fail "rc=$rc: $out"

R="$WORK/repo"; mkdir -p "$R/locales"
printf '{"a": "Hello world", "b": "日本語", "c": "Save&nbsp;changes now"}\n' > "$R/locales/en.json"
printf 'msgid ""\nmsgstr ""\n\nmsgid "Save changes"\nmsgstr ""\n' > "$R/locales/en.po"
printf 'source_locale: en\nlanguages: [de, fr]\nfiles:\n  - file: locales/en.json\n    output: locales/{{lang}}.json\n  - file: locales/en.po\n    output: locales/{{lang}}.po\n' > "$R/.ptc-config.yml"

echo "=== S2-R5 F19: whole files of the shared fixture count as PTC's quote parses them (arrays, identifiers, non-strings) ==="
F="$WORK/files"; mkdir -p "$F"
python3 - "$CASES" "$F" <<'PYEOF'
import json, os, sys
for c in json.load(open(sys.argv[1]))["file_cases"]:
    os.makedirs(os.path.dirname(os.path.join(sys.argv[2], c["path"])), exist_ok=True)
    open(os.path.join(sys.argv[2], c["path"]), "w", encoding="utf-8").write(c["content"])
PYEOF
want=$(field "$CASES" "[(c['path'], c['words']) for c in d['file_cases']]")
{ printf 'source_locale: en\nlanguages: [de]\nfiles:\n'
  field "$CASES" "'\\n'.join('  - file: %s\\n    output: %s' % (c['path'], c['path'].replace('en.', '{{lang}}.')) for c in d['file_cases'])"
} > "$F/.ptc-config.yml"
"$CLI" estimate --json --offline -d "$F" --rate 1 --balance 0 > "$WORK/fc.json" 2>"$WORK/fc.err"
got=$(field "$WORK/fc.json" "[(f['path'], f['words']) for f in d['files']]" 2>&1)
[[ "$got" == "$want" ]] && pass "file cases count as PTC counts them: $got" || fail "file cases: want $want, got $got ($(cat "$WORK/fc.err"))"
# F27 (S2-R8): the built-in YAML reader (no PyYAML: the CI image's python) counts the same files the same way.
mkdir -p "$WORK/no-pyyaml"; echo 'raise ImportError("PyYAML hidden by the test")' > "$WORK/no-pyyaml/yaml.py"
PYTHONPATH="$WORK/no-pyyaml" "$CLI" estimate --json --offline -d "$F" --rate 1 --balance 0 > "$WORK/fc-nopy.json" 2>"$WORK/fc-nopy.err"
got=$(field "$WORK/fc-nopy.json" "[(f['path'], f['words']) for f in d['files']]" 2>&1)
[[ "$got" == "$want" ]] && pass "file cases count the same without PyYAML: $got" || fail "file cases without PyYAML: want $want, got $got ($(cat "$WORK/fc-nopy.err"))"

echo "=== offline: --rate and --balance given, nothing remote ==="
"$CLI" estimate --json -d "$R" --rate 4 --balance 30 > "$WORK/e.json" 2>"$WORK/e.err"; rc=$?
[[ $rc -eq 0 ]] && pass "estimate exits 0" || fail "rc=$rc: $(cat "$WORK/e.err")"
[[ "$(field "$WORK/e.json" "[(f['path'], f['words']) for f in d['files']]" 2>&1)" == "[('locales/en.json', 8), ('locales/en.po', 2)]" ]] \
    && pass "per-file words by PTC's rule (CJK per character, &nbsp; a space)" || fail "files: $(field "$WORK/e.json" "d['files']" 2>&1)"
[[ "$(field "$WORK/e.json" "(d['words_per_language'], d['words_total'], d['credits_per_language'], d['credits_total'])" 2>&1)" == "(10, 20, {'de': 40, 'fr': 40}, 80)" ]] \
    && pass "x 2 languages x rate 4: 20 words, 40 credits per language, 80 total" || fail "totals: $(cat "$WORK/e.json")"
[[ "$(field "$WORK/e.json" "(d['balance_words'], d['shortfall_words'])" 2>&1)" == "(30, 0)" ]] && pass "a balance of 30 words covers 20" || fail "balance: $(cat "$WORK/e.json")"
"$CLI" estimate --json -d "$R" --rate 4 --balance 16 > "$WORK/e2.json" 2>/dev/null
[[ "$(field "$WORK/e2.json" "d['shortfall_words']" 2>&1)" == "4" ]] && pass "a balance of 16 words is 4 short" || fail "shortfall: $(cat "$WORK/e2.json")"
txt=$("$CLI" estimate -d "$R" --rate 4 --balance 16 2>&1)
grep -q "Total: 20 words, 80 credits" <<<"$txt" && grep -q "short by 4 words" <<<"$txt" && pass "text output names the total and the shortfall" || fail "text: $txt"

echo "=== S2-R28-2: --exclude and --languages quote the scope a 'fewer files / languages' answer names ==="
"$CLI" estimate --json -d "$R" --rate 4 --balance 30 --exclude locales/en.po --languages de > "$WORK/x.json" 2>"$WORK/x.err"; rc=$?
[[ $rc -eq 0 && "$(field "$WORK/x.json" "([f['path'] for f in d['files']], d['words_total'], d['credits_total'])" 2>&1)" == "(['locales/en.json'], 8, 32)" ]] \
    && pass "the excluded file is left out and one language is quoted: 8 words, 32 credits" || fail "rc=$rc scope: $(cat "$WORK/x.json" "$WORK/x.err")"
"$CLI" estimate --json -d "$R" --rate 4 --balance 30 --exclude locales/en.po --exclude locales/en.json > "$WORK/x2.json" 2>/dev/null
[[ "$(field "$WORK/x2.json" "(d['files'], d['words_total'])" 2>&1)" == "([], 0)" ]] && pass "--exclude repeats" || fail "repeat: $(cat "$WORK/x2.json")"

echo "=== SF-14: before commit_config (no .ptc-config.yml) the command the guide hands out names the languages ==="
N="$WORK/nocfg"; mkdir -p "$N/locales"; cp "$R/locales/en.json" "$R/locales/en.po" "$N/locales/"
"$CLI" estimate --json -d "$N" --rate 4 --balance 0 > /dev/null 2>"$WORK/n.err"; rc=$?
[[ $rc -eq 1 ]] && grep -q -- "--languages" "$WORK/n.err" && pass "no config and no --languages: exit 1 naming --languages" || fail "rc=$rc: $(cat "$WORK/n.err")"
# The estimate task's text (Guide::Tasks::Estimate#local_estimate_text): `ptc estimate --json --rate R --balance B --languages <session languages>`.
"$CLI" estimate --json -d "$N" --rate 4 --balance 0 --languages de,es > "$WORK/n.json" 2>"$WORK/n.err"; rc=$?
[[ $rc -eq 0 && "$(field "$WORK/n.json" "(sorted(f['path'] for f in d['files']), d['words_total'], sorted(d['credits_per_language']))" 2>&1)" == "(['locales/en.json', 'locales/en.po'], 20, ['de', 'es'])" ]] \
    && pass "the handed-out command quotes the scanned census in the session languages: 20 words over de, es" || fail "rc=$rc: $(cat "$WORK/n.json" "$WORK/n.err")"

echo "=== remote inputs: one GET balance for the rate and the balance ==="
port=19411
refuse_busy_port "$port"
PTC_MOCK_PORT=$port PTC_MOCK_LOG="$WORK/journal" python3 "$MOCK" >"$WORK/mock.log" 2>&1 & MOCK_PID=$!
for i in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && kill -0 "$MOCK_PID" 2>/dev/null && break; sleep 0.3; done
kill -0 "$MOCK_PID" 2>/dev/null || { echo "the mock died; its output was:" >&2; sed 's/^/    /' "$WORK/mock.log" >&2; exit 1; }
PTC_API_TOKEN=t "$CLI" estimate --json -d "$R" --api-url "http://127.0.0.1:$port/api/v1/" > "$WORK/e3.json" 2>"$WORK/e3.err"; rc=$?
[[ $rc -eq 0 ]] && pass "remote estimate exits 0" || fail "rc=$rc: $(cat "$WORK/e3.err")"
[[ "$(field "$WORK/e3.json" "(d['word_cost'], d['balance_words'], d['credits_total'])" 2>&1)" == "(4, 62000, 80)" ]] \
    && pass "rate and balance read from PTC (trial + prepaid words)" || fail "remote: $(cat "$WORK/e3.json")"
[[ "$(grep -cE 'GET +/balance' "$WORK/journal")" == "1" ]] && pass "exactly one remote call" || fail "journal: $(cat "$WORK/journal")"

echo "=== S2-R3 item 3: every configured file is counted (decision 5) - other formats via PTC's dry-run estimate ==="
# The local readers cover PO/POT, YAML and JSON; .strings and PHP here go to POST source_files/estimate (its own
# rate-limit bucket, ci18-7252), one call per file, and are added to the total. --offline keeps the local-only quote.
R2="$WORK/repo2"; mkdir -p "$R2/locales" "$R2/ios" "$R2/php"
cp "$R/locales/en.json" "$R2/locales/en.json"
printf '"save" = "Save the document";\n"open" = "Open a file now";\n' > "$R2/ios/en.strings"
printf '<?php\nreturn ["hello" => "Hello there friend"];\n' > "$R2/php/en.php"
printf 'source_locale: en\nlanguages: [de, fr]\nfiles:\n  - file: locales/en.json\n    output: locales/{{lang}}.json\n  - file: ios/en.strings\n    output: ios/{{lang}}.strings\n  - file: php/en.php\n    output: php/{{lang}}.php\n' > "$R2/.ptc-config.yml"
: > "$WORK/journal"
PTC_API_TOKEN=t "$CLI" estimate --json -d "$R2" --rate 4 --balance 1000 --api-url "http://127.0.0.1:$port/api/v1/" > "$WORK/e4.json" 2>"$WORK/e4.err"; rc=$?
[[ $rc -eq 0 ]] && pass "estimate with other formats exits 0" || fail "rc=$rc: $(cat "$WORK/e4.err")"
[[ "$(field "$WORK/e4.json" "(sorted((f['path'], f['words']) for f in d['files']), d['unquoted'])" 2>&1)" == "([('ios/en.strings', 7), ('locales/en.json', 8), ('php/en.php', 7)], [])" ]] \
    && pass "the .strings and PHP files are counted by PTC's estimate; nothing is left uncounted" || fail "files: $(cat "$WORK/e4.json")"
[[ "$(field "$WORK/e4.json" "(d['words_per_language'], d['words_total'], d['credits_total'])" 2>&1)" == "(22, 44, 176)" ]] \
    && pass "the total covers every file: 22 words x 2 languages, 176 credits" || fail "totals: $(cat "$WORK/e4.json")"
[[ "$(grep -cE 'POST +/source_files/estimate' "$WORK/journal")" == "2" ]] && ! grep -q 'estimate file_path=locales/en.json' "$WORK/journal" \
    && pass "one dry-run estimate call per uncounted file, none for the locally counted JSON" || fail "journal: $(cat "$WORK/journal")"
txt=$(PTC_API_TOKEN=t "$CLI" estimate -d "$R2" --rate 4 --balance 1000 --api-url "http://127.0.0.1:$port/api/v1/" 2>&1)
! grep -q "not counted" <<<"$txt" && grep -q "Total: 44 words" <<<"$txt" && pass "text output: no 'not counted', the complete total" || fail "text: $txt"
: > "$WORK/journal"
txt=$(PTC_API_TOKEN=t "$CLI" estimate --offline -d "$R2" --rate 4 --balance 1000 --api-url "http://127.0.0.1:$port/api/v1/" 2>&1)
grep -q "ios/en.strings: not counted" <<<"$txt" && grep -q "php/en.php: not counted" <<<"$txt" && grep -q "Total: 16 words" <<<"$txt" \
    && ! grep -qE 'POST +/source_files/estimate' "$WORK/journal" && pass "--offline: local-only quote, the uncounted files listed, no remote call" || fail "offline: $txt / $(cat "$WORK/journal")"

echo "=== mock validity: the mock's estimate answer has the shape PTC's own request spec pins ==="
SPEC="$(dirname "$(dirname "$TEST_DIR")")/backend/spec/requests/api/v1/source_files_estimate_spec.rb"
curl -s -X POST -H "Authorization: Bearer t" -F "file=@$R2/ios/en.strings" -F "file_path=ios/en.strings" "http://127.0.0.1:$port/api/v1/source_files/estimate" > "$WORK/mock-estimate.json"
out=$(python3 - "$SPEC" "$WORK/mock-estimate.json" <<'PY'
import json, re, sys
spec, body = open(sys.argv[1]).read(), json.load(open(sys.argv[2]))
need = set()
for chain, rest in re.findall(r"expect\(body((?:\[:\w+\])*)\)(.*)", spec):
    keys = re.findall(r"\[:(\w+)\]", chain)
    need.add(tuple(keys))
    m = re.search(r"\.to include\(([^)]*)\)", rest)
    if m:
        need.update(tuple(keys + [k]) for k in re.findall(r":(\w+)", m.group(1)))
missing = []
for path in sorted(need):
    node = body
    for k in path:
        if not isinstance(node, dict) or k not in node:
            missing.append(".".join(path)); break
        node = node[k]
print("checked %d key paths from the spec; missing: %s" % (len(need), ", ".join(missing) or "none"))
sys.exit(1 if missing or len(need) < 8 else 0)
PY
); rc=$?
[[ $rc -eq 0 ]] && pass "mock estimate response matches the backend spec ($out)" || fail "mock drifted from the backend spec: $out"

echo
echo "Total: $((passed + failed))  Passed: $passed  Failed: $failed"
[[ $failed -eq 0 ]]
