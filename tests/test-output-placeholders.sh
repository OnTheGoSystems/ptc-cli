#!/bin/bash
# #7250 (specs/delivery-mr-archive DLV-1, POL-40): the CLI door. `ptc config validate` treats {{lang}}, {{locale}} and
# {{language}} as one language slot and expands each alike; an output with no slot for a config with more than one
# language is refused by name (the sentence names the placeholder); a one-language config keeps its plain path as written
# (ruling D4). No API: validate reads the checkout only.
# #7252: the READER of a configured output, the delivered-file matcher behind the delivery report (delivered_files_sha_at,
# the helper's delivery-body op that `ptc guide delivery-commit` sends), recognises the three spellings as one slot too.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# checkout <dir> <languages> <output>: a repository with one source file and a config naming that output.
checkout() {
    local dir="$WORK/$1"; mkdir -p "$dir/locales"
    printf '{"hello": "Hello"}\n' > "$dir/locales/en.json"
    printf 'source_locale: en\nlanguages: [%s]\nfiles:\n  - file: locales/en.json\n    output: %s\n' "$2" "$3" > "$dir/.ptc-config.yml"
    git -C "$dir" init -q -b main && git -C "$dir" add -A && git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init
    printf '%s' "$dir"
}

# outputs_are <json file> <python dict literal>: valid, and the one entry's outputs are exactly that.
outputs_are() {
    python3 -c "import ast,json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['valid'] and d['files'][0]['outputs'] == ast.literal_eval(sys.argv[2]) else 1)" "$1" "$2"
}

for placeholder in lang locale language; do
    echo "=== {{$placeholder}} expands like {{lang}} ==="
    T=$(checkout "p-$placeholder" "de, fr" "locales/{{$placeholder}}.json")
    "$CLI" config validate --json -d "$T" > "$WORK/$placeholder.json" 2>/dev/null; rc=$?
    outputs_are "$WORK/$placeholder.json" "{'de': 'locales/de.json', 'fr': 'locales/fr.json'}" \
      && pass "{{$placeholder}}: valid; de -> locales/de.json, fr -> locales/fr.json" \
      || fail "{{$placeholder}}: rc=$rc $(head -c 600 "$WORK/$placeholder.json")"
done

echo "=== no language placeholder, two languages: refused by name ==="
T=$(checkout plain-two "de, fr" "locales/translated.json")
out=$("$CLI" config validate -d "$T" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -qF "files[1].output 'locales/translated.json' has no {{lang}} slot: all 2 target languages would be written to that one file and overwrite each other. Put {{lang}} (or {{locale}} or {{language}}) where the language code goes" <<<"$out" \
  && pass "plain path, two languages -> not valid, the sentence names {{lang}}" || fail "plain-two: rc=$rc $out"

echo "=== no language placeholder, one language: the plain path as written ==="
T=$(checkout plain-one "de" "locales/translated.json")
"$CLI" config validate --json -d "$T" > "$WORK/plain-one.json" 2>/dev/null; rc=$?
outputs_are "$WORK/plain-one.json" "{'de': 'locales/translated.json'}" \
  && pass "plain path, one language -> valid, de -> locales/translated.json (kept as written)" \
  || fail "plain-one: rc=$rc $(head -c 600 "$WORK/plain-one.json")"

# #7252: the delivered-file reader. A commit carrying locales/de.json and locales/fr.json for an output written with each
# spelling: the delivery report names both files, as it does for {{lang}}. Driven through the CLI's own python helper.
HELPER="$WORK/helper.py"
awk '/^PTC_PY_EOF$/{f=0} f; /^PTC_PY_HELPER=\$\(cat <<.PTC_PY_EOF.$/{f=1}' "$CLI" > "$HELPER"
for placeholder in lang locale language; do
    echo "=== delivered files read back for {{$placeholder}} like {{lang}} ==="
    T=$(checkout "d-$placeholder" "de, fr" "locales/{{$placeholder}}.json")
    printf '{"hello": "Hallo"}\n' > "$T/locales/de.json"; printf '{"hello": "Bonjour"}\n' > "$T/locales/fr.json"
    git -C "$T" add -A && git -C "$T" -c user.email=t@t -c user.name=t commit -qm delivered
    python3 -c "import json,sys; print(json.dumps({'config': {'source_locale': 'en', 'languages': ['de', 'fr'], 'files': [{'file': 'locales/en.json', 'output': sys.argv[1]}]}}))" \
      "locales/{{$placeholder}}.json" > "$WORK/d-$placeholder.cfg.json"
    got=$(PTC_CLI_VERSION=test python3 - delivery-body "$WORK/d-$placeholder.cfg.json" 42 "$(git -C "$T" rev-parse HEAD)" "" "" "$T" < "$HELPER" 2>"$WORK/d-$placeholder.err" \
      | python3 -c "import json,sys; print(','.join(sorted(json.load(sys.stdin)['delivered_files_sha'])))" 2>>"$WORK/d-$placeholder.err")
    [[ "$got" == "locales/de.json,locales/fr.json" ]] \
      && pass "{{$placeholder}}: the delivery report names locales/de.json and locales/fr.json" \
      || fail "{{$placeholder}}: delivered_files_sha keys '$got' $(head -c 400 "$WORK/d-$placeholder.err")"
done

echo "=== one slot definition in the CLI (#7252 lint) ==="
readers=$(grep -nE 're\.escape\("\{\{lang\}\}"\)|"\{\{lang\}\}" (not )?in ' "$CLI" </dev/null)
defs=$(grep -cE '^LANG_SLOT = re\.compile' "$CLI" </dev/null)
[[ -z "$readers" && "$defs" == 1 ]] && pass "ptc-cli.sh reads the slot only through LANG_SLOT (defined once)" \
  || fail "LANG_SLOT definitions: $defs; literal {{lang}} readers: $readers"

echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
