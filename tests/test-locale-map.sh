#!/bin/bash
# WF-5 (Eran 2026-10-10, specs/cli-client): `.ptc-config.yml` `locale_map: {he: he_IL}` names the locale a PTC language's
# files use. `ptc config validate` accepts it and expands {{lang}} with it; every upload carries it (locale_map[<code>]),
# so PTC names the delivered files with it; a config without the field sends nothing new. Runs against the mock.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
PID=""
cleanup() { [[ -n "$PID" ]] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT
PORT=19951
mkdir -p "$WORK/bodies"
PTC_MOCK_PORT=$PORT PTC_MOCK_BODY_DIR="$WORK/bodies" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
PID=$!
for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
API="http://127.0.0.1:$PORT/api/v1/"
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_API_TOKEN)

T="$WORK/wp"; mkdir -p "$T/languages"
printf 'msgid ""\nmsgstr ""\n\nmsgid "Hello"\nmsgstr ""\n' > "$T/languages/sitepress.pot"
cat > "$T/.ptc-config.yml" <<'YML'
source_locale: en
languages: [he, de]
locale_map: {he: he_IL, de: de_DE}
monitor_interval: 1
files:
  - file: languages/sitepress.pot
    output: languages/sitepress-{{lang}}.po
    additional_translation_files:
      - type: mo
        path: languages/sitepress-{{lang}}.mo
YML
git -C "$T" init -q -b main && git -C "$T" add -A && git -C "$T" -c user.email=t@t -c user.name=t commit -qm init

echo "=== config validate: locale_map accepted, {{lang}} expands to the file locale ==="
"$CLI" config validate --json -d "$T" > "$WORK/v.json" 2>/dev/null; rc=$?
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['valid'] and d['files'][0]['outputs'] == {'he': 'languages/sitepress-he_IL.po', 'de': 'languages/sitepress-de_DE.po'} and d['config']['locale_map'] == {'he': 'he_IL', 'de': 'de_DE'} else 1)" "$WORK/v.json" \
  && pass "valid; outputs he -> sitepress-he_IL.po, de -> sitepress-de_DE.po" || fail "validate rc=$rc $(head -c 600 "$WORK/v.json")"
sed -i 's/^locale_map: .*/locale_map: {zz9: he_IL, de: "de DE"}/' "$T/.ptc-config.yml"
out=$("$CLI" config validate -d "$T" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "locale_map: 'zz9' is not a known language code" <<<"$out" && grep -q "locale_map: 'de' maps to 'de DE', not a locale token" <<<"$out" \
  && pass "a malformed locale_map entry -> not valid, named" || fail "malformed map: rc=$rc $out"
sed -i 's/^locale_map: .*/locale_map: {he: he_IL, de: de_DE}/' "$T/.ptc-config.yml"

echo "=== ptc sync: every upload carries the map ==="
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API" -d "$T" >"$WORK/sync.out" 2>&1
python3 - "$WORK/bodies/uploads.raw" <<'PY' && pass "the upload carries locale_map[he]=he_IL and locale_map[de]=de_DE" || fail "upload body: $(head -c 800 "$WORK/bodies/uploads.raw" 2>/dev/null) / $(tail -5 "$WORK/sync.out")"
import json, re, sys
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace").split("\n--END-OF-UPLOAD--\n")[0]
form = dict(re.findall(r'name="(locale_map\[\w+\])"\r\n\r\n([^\r]*)\r\n', raw))
try:
    body = json.loads(raw)
except ValueError:
    body = {}
sys.exit(0 if form == {"locale_map[he]": "he_IL", "locale_map[de]": "de_DE"} or body.get("locale_map") == {"he": "he_IL", "de": "de_DE"} else 1)
PY
rm -f "$WORK/bodies/uploads.raw"
sed -i '/^locale_map:/d' "$T/.ptc-config.yml"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" sync --api-url "$API" -d "$T" >"$WORK/sync2.out" 2>&1
[[ -s "$WORK/bodies/uploads.raw" ]] && ! grep -q "locale_map" "$WORK/bodies/uploads.raw" && pass "no locale_map in the config -> none in the upload" || fail "unmapped upload: $(head -c 400 "$WORK/bodies/uploads.raw" 2>/dev/null)"

echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
