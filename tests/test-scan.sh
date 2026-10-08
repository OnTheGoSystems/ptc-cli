#!/bin/bash
# `ptc scan --json` (schema 2 = v1 fields + census v2) and `ptc config validate` against the committed
# fixture repository tests/fixtures/scan-repo (Rails YAML + gettext + i18next
# JSON, with code references). Deterministic, no network.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly REPO="$TEST_DIR/fixtures/scan-repo"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
check() {  # check "desc" "python expression over d (the scan) that must be True"
    local desc="$1" expr="$2"
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($expr) else 1)" "$SCAN" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc"
    fi
}
WORK=${KEEP_WORK:-$(mktemp -d)}; [[ -z "${KEEP_WORK:-}" ]] && trap 'rm -rf "$WORK"' EXIT
SCAN="$WORK/scan.json"

echo "=== ptc scan --json: products of a multi-product repository ==="
M="$WORK/multi"; mkdir -p "$M/pa/languages" "$M/pb/languages" "$M/lib/languages"
echo '{"name": "x/pa"}' > "$M/pa/composer.json"
printf '<?php\n/*\n * Plugin Name: PB\n */\n' > "$M/pb/pb.php"
for d in pa pb lib; do printf 'msgid ""\nmsgstr ""\n\nmsgid "Save"\nmsgstr ""\n' > "$M/$d/languages/$d.pot"; done
git -C "$M" init -q
SCAN_M="$WORK/multi.json"
"$CLI" scan --json -d "$M" > "$SCAN_M" 2>/dev/null
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if [p['dir'] for p in d['products']] == ['pa', 'pb'] else 1)" "$SCAN_M" && pass "products = top-level dirs with resource sets AND a manifest or plugin main file (lib/ has neither)" || fail "products: $(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('products'))" "$SCAN_M")"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p={x['dir']: x for x in d['products']}; sys.exit(0 if all(s.startswith(k + '/') for k in p for s in p[k]['resource_sets']) and p['pa']['resource_sets'] and d['schema'] == 2 and len(d['resource_sets']) == 3 else 1)" "$SCAN_M" && pass "each product lists its own resource sets; the flat list and schema 2 stay" || fail "product resource sets: $(cat "$SCAN_M" | head -c 600)"

echo "=== config validate: shared outputs (D12) ==="
V="$WORK/val"; mkdir -p "$V/pa/l" "$V/pb/l"
printf 'msgid "a"\nmsgstr ""\n' > "$V/pa/l/a.pot"; cp "$V/pa/l/a.pot" "$V/pa/l/b.pot"; cp "$V/pa/l/a.pot" "$V/pb/l/c.pot"
printf 'source_locale: en\nlanguages: [de]\nfiles:\n  - file: l/a.pot\n    output: l/{{lang}}.po\n  - file: l/b.pot\n    output: l/{{lang}}.po\n' > "$V/pa/.ptc-config.yml"
git -C "$V" init -q
out=$("$CLI" config validate -d "$V/pa" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "is also the output of files\[1\]" <<<"$out" && pass "two entries writing one output -> not valid" || fail "same-output entries: rc=$rc $out"
printf 'source_locale: en\nlanguages: [de]\nfiles:\n  - file: l/a.pot\n    output: l/a-{{lang}}.po\n' > "$V/pa/.ptc-config.yml"
printf 'source_locale: en\nlanguages: [de]\nfiles:\n  - file: l/c.pot\n    output: ../pa/l/a-{{lang}}.po\n' > "$V/pb/.ptc-config.yml"
out=$("$CLI" config validate -d "$V/pa" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "is also written by pb/.ptc-config.yml" <<<"$out" && pass "two products writing one output -> not valid" || fail "cross-product clash: rc=$rc $out"
printf 'source_locale: en\nlanguages: [de]\nfiles:\n  - file: l/c.pot\n    output: l/c-{{lang}}.po\n' > "$V/pb/.ptc-config.yml"
"$CLI" config validate -d "$V/pa" >/dev/null 2>&1 && pass "distinct outputs across products -> valid" || fail "distinct outputs: $("$CLI" config validate -d "$V/pa" 2>&1)"

echo "=== config validate: outputs git ignores (E35) ==="
# lab p2r2 s2: sitepress-multilingual-cms/.gitignore:105 `/locale/jed/**/*.po` ignored 20 outputs
# locale/jed/pot/*-{{lang}}.po, so 40 translated files were written and never committed.
mkdir -p "$V/pb/locale/jed/pot"; printf 'msgid "a"\nmsgstr ""\n' > "$V/pb/locale/jed/pot/ui.pot"
printf '/vendor\n/locale/jed/**/*.po\n' > "$V/pb/.gitignore"
printf 'source_locale: en\nlanguages: [de, fr]\nfiles:\n  - file: l/c.pot\n    output: l/c-{{lang}}.po\n  - file: locale/jed/pot/ui.pot\n    output: locale/jed/pot/ui-{{lang}}.po\n' > "$V/pb/.ptc-config.yml"
out=$("$CLI" config validate -d "$V/pb" 2>&1); rc=$?
[[ $rc -eq 2 ]] && grep -q "output 'locale/jed/pot/ui-de.po' is ignored by git (pb/.gitignore:2:/locale/jed/\*\*/\*.po)" <<<"$out" && ! grep -q "l/c-de.po' is ignored" <<<"$out" && pass "an output the .gitignore ignores -> not valid, the rule cited" || fail "ignored output: rc=$rc $out"
"$CLI" config validate --json -d "$V/pb" > "$WORK/ign.json" 2>/dev/null
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['ignored_outputs'] == ['locale/jed/pot/ui-de.po'] and d['valid'] is False else 1)" "$WORK/ign.json" && pass "--json lists ignored_outputs (first target language)" || fail "ignored_outputs json: $(cat "$WORK/ign.json" | head -c 400)"
printf '/vendor\n' > "$V/pb/.gitignore"
"$CLI" config validate --json -d "$V/pb" > "$WORK/ign.json" 2>/dev/null
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['ignored_outputs'] == [] and d['valid'] is True else 1)" "$WORK/ign.json" && pass "no ignored output -> valid, ignored_outputs empty" || fail "not ignored: $(cat "$WORK/ign.json" | head -c 400)"

echo "=== ptc scan --json ==="
if "$CLI" scan --json -d "$REPO" > "$SCAN" 2>"$WORK/err"; then pass "scan exits 0"; else fail "scan exits 0: $(cat "$WORK/err")"; fi
check "schema is 2 and cli_version is the CLI's" "d['schema'] == 2 and d['cli_version'] == '$("$CLI" --version | awk '{print $2}' | tr -d v)'"
check "head_sha is 40 hex" "__import__('re').match(r'^[0-9a-f]{40}$', d['repo']['head_sha'] or '')"
check "frameworks detected" "d['frameworks'] == ['gettext', 'i18next', 'rails-i18n']"
check "none_reason is null when sets exist" "d['none_reason'] is None"
sets='{s["source_pattern"]: s for s in d["resource_sets"]}'
check "Rails YAML set with its languages" "(lambda m: m['config/locales/{{lang}}.yml']['existing_languages'] == ['de', 'fr'] and m['config/locales/{{lang}}.yml']['format'] == 'yaml')($sets)"
check "Rails YAML counts (plural group = 1 entry, block scalar, comments)" "(lambda f: (f['path'], f['lang'], f['count'], f['placeholders'], f['plurals'], f['comments']) == ('config/locales/en.yml', 'en', 5, 3, 1, 2))($sets['config/locales/{{lang}}.yml']['source_files'][0])"
check "gettext set: .pot is the source, .po gives the pattern, .mo siblings count as languages" "(lambda s: s['source_files'][0]['path'] == 'languages/plugin.pot' and s['existing_languages'] == ['de_DE', 'fr_FR'])($sets['languages/plugin-{{lang}}.po'])"
check "gettext counts (header skipped, plural, context, extracted comment)" "(lambda f: (f['count'], f['placeholders'], f['plurals'], f['contexts'], f['comments']) == (4, 2, 1, 1, 1))($sets['languages/plugin-{{lang}}.po']['source_files'][0])"
check "i18next JSON counts (item_one/item_other = 1 plural entry)" "(lambda f: (f['count'], f['plurals'], f['placeholders']) == (3, 1, 3))($sets['src/locales/{{lang}}/common.json']['source_files'][0])"
check "usage: Rails lazy lookup t('.title') resolves to users.index.title" "d['usages']['config/locales/en.yml']['users.index.title'] == [{'path': 'app/views/users/index.html.erb', 'line': 1, 'text': \"<h1><%= t('.title') %></h1>\"}]"
check "usage: I18n.t(\"users.count\")" "d['usages']['config/locales/en.yml']['users.count'] == [{'path': 'app/models/user.rb', 'line': 3, 'text': 'I18n.t(\"users.count\", count: n)'}]"
check "usage: gettext esc_html__/__/_x/_n keyed by msgid" "sorted(d['usages']['languages/plugin.pot']) == ['%d item', 'Hello %s', 'Post', 'Save changes']"
check "usage: i18next t('ns:key') maps to the namespace file" "d['usages']['src/locales/en/common.json']['welcome'] == [{'path': 'src/app.js', 'line': 2, 'text': 'export const hello = (name) => t(\"common:welcome\", { name });'}]"
check "unused keys are absent from the usage map" "'users.title' not in d['usages']['config/locales/en.yml']"
"$CLI" scan --json -d "$REPO" > "$WORK/scan2.json" 2>/dev/null
if cmp -s "$SCAN" "$WORK/scan2.json"; then pass "scan is deterministic (byte-identical rerun)"; else fail "scan is deterministic"; fi
mkdir -p "$WORK/empty" && echo "x" > "$WORK/empty/readme.txt"
SCAN="$WORK/empty.json"; "$CLI" scan --json -d "$WORK/empty" > "$SCAN" 2>/dev/null
check "no resources -> resource_sets [] with none_reason" "d['resource_sets'] == [] and d['none_reason'] and d['frameworks'] == ['unknown']"

echo "=== ptc config validate ==="
out=$("$CLI" config validate -d "$REPO" --json 2>/dev/null); rc=$?
SCAN="$WORK/cfg.json"; printf '%s' "$out" > "$SCAN"
[[ $rc -eq 0 ]] && pass "valid config exits 0" || fail "valid config exits 0 (rc=$rc)"
check "per-language outputs from guide.languages" "d['files'][0]['outputs'] == {'de': 'config/locales/de.yml', 'fr': 'config/locales/fr.yml'}"
check "parsed config carries the guide key" "d['config']['guide'] == {'session_id': 'gs_mock', 'languages': ['de', 'fr']}"
bad="$WORK/bad.yml"
printf 'source_locale: xx\nfiles:\n  - file: nope/en.yml\n    output: nope/en.yml\nguide:\n  languages: [de, zz]\n' > "$bad"
out=$("$CLI" config validate -d "$REPO" -c "$bad" 2>/dev/null); rc=$?
[[ $rc -eq 2 ]] && pass "invalid config exits 2" || fail "invalid config exits 2 (rc=$rc)"
for needle in "source_locale 'xx' is not a known language code" "matches no file" "has no {{lang}} slot" "'zz' is not a known language code" "config is NOT valid"; do
    case "$out" in *"$needle"*) pass "text report: $needle" ;; *) fail "text report: $needle (got: $out)" ;; esac
done

# A5: tasks/, fixtures and .ptcignore paths are never part of the census
X="$WORK/xrepo"; cp -R "$REPO" "$X"
mkdir -p "$X/tasks/t1/config/locales" "$X/spec/fixtures/config/locales" "$X/extra/locales"
cp "$REPO/config/locales/en.yml" "$X/tasks/t1/config/locales/en.yml"
cp "$REPO/config/locales/en.yml" "$X/spec/fixtures/config/locales/en.yml"
printf '{"a": "A"}\n' > "$X/extra/locales/en.json"
printf '# comment\nextra/\n' > "$X/.ptcignore"
( cd "$X" && git init -q && git add -A )
"$CLI" scan --json -d "$X" > "$WORK/x.json" 2>/dev/null
python3 - "$WORK/x.json" <<'PY' && pass "scan excludes tasks/, spec/fixtures/ and .ptcignore paths" || fail "scan excludes tasks/, spec/fixtures/ and .ptcignore paths"
import json, sys
d = json.load(open(sys.argv[1]))
paths = [sf["path"] for s in d["resource_sets"] for sf in s["source_files"]]
assert paths and not [p for p in paths if p.startswith(("tasks/", "spec/", "extra/"))], paths
PY

echo "=== ptc scan --json: census v2 (other sources, partition, existing translations, runtime) ==="
C="$WORK/c2"; mkdir -p "$C/languages" "$C/lang2" "$C/admin/locales/en" "$C/admin/locales/de" "$C/third_party/widget/locales" \
    "$C/app/views/pages" "$C/app/views/user_mailer" "$C/src" "$C/assets"
cat > "$C/myplug.php" <<'PHP'
<?php
/**
 * Plugin Name: My Plug
 * Text Domain: myplug
 * Domain Path: /languages
 */
add_action('init', function () { load_plugin_textdomain('myplug', false, dirname(plugin_basename(__FILE__)) . '/languages'); });
echo esc_html__('Save settings', 'myplug');
PHP
printf 'msgid ""\nmsgstr ""\n\nmsgid "Save settings"\nmsgstr ""\n\nmsgid "Delete"\nmsgstr ""\n' > "$C/languages/myplug.pot"
printf 'msgid ""\nmsgstr ""\n\nmsgid "Save settings"\nmsgstr "Einstellungen speichern"\n\nmsgid "Delete"\nmsgstr ""\n' > "$C/languages/myplug-de_DE.po"
cp "$C/languages/myplug-de_DE.po" "$C/languages/myplug-de.po"; : > "$C/languages/myplug-de_DE.mo"; : > "$C/languages/myplug-de.mo"
printf 'msgid ""\nmsgstr ""\n\nmsgid "Save settings"\nmsgstr "Enregistrer"\n' > "$C/languages/myplug-fr_FR.po"
printf 'msgid ""\nmsgstr ""\n\nmsgid "Old"\nmsgstr ""\n' > "$C/lang2/oldname.pot"
printf 'msgid ""\nmsgstr ""\n\nmsgid "Old"\nmsgstr "Vecchio"\n' > "$C/lang2/oldname-it_IT.po"; : > "$C/lang2/oldname-it_IT.mo"
echo '{"title": "Users"}' > "$C/admin/locales/en/admin.json"; echo '{"title": "Benutzer"}' > "$C/admin/locales/de/admin.json"
echo '{"ok": "OK"}' > "$C/third_party/widget/locales/en.json"
cat > "$C/app/views/pages/home.html.erb" <<'ERB'
<title>My shop online</title>
<h1>Welcome to our store</h1>
<p><%= t('home.intro') %></p>
ERB
echo '<p>Thanks for signing up today</p>' > "$C/app/views/user_mailer/welcome.html.erb"
printf 'const msg = "Please try again later.";\nimport x from "./a/b";\n' > "$C/src/app.js"
printf 'i18next.use(initReactI18next).init({ lng: "en" });\n' > "$C/src/i18n.js"
printf '%%PDF-1.4\n' > "$C/assets/guide.pdf"
git -C "$C" init -q
"$CLI" scan --json -d "$C" > "$WORK/c2.json" 2>/dev/null; rc=$?
[[ $rc == 0 ]] && pass "census v2 scan -> exit 0" || fail "census v2 scan rc $rc"
c2() { if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); o={x['kind']: x for x in d['other_string_sources']}; p={x['source_pattern']: x for x in d['partition']}; e=d['existing_translations']; r=d['runtime']; sys.exit(0 if ($2) else 1)" "$WORK/c2.json" 2>/dev/null; then pass "$1"; else fail "$1"; fi; }
c2 "schema 2 keeps the v1 fields" "d['schema'] == 2 and all(k in d for k in ('repo', 'frameworks', 'resource_sets', 'usages', 'products', 'none_reason'))"
c2 "other sources: hard-coded template text (not t() calls)" "o['templates']['occurrences'] == 2 and [(x['line'], x['text']) for x in o['templates']['samples']] == [(1, 'My shop online'), (2, 'Welcome to our store')]"
c2 "other sources: e-mail templates" "o['emails']['files'] == 1 and o['emails']['samples'][0]['path'] == 'app/views/user_mailer/welcome.html.erb'"
c2 "other sources: SEO meta (<title>)" "o['seo_meta']['occurrences'] == 1 and o['seo_meta']['samples'][0]['line'] == 1"
c2 "other sources: JS sentence literals, import paths ignored" "o['js_literals']['occurrences'] == 1 and o['js_literals']['samples'][0]['text'] == 'Please try again later.'"
c2 "other sources: PDFs" "o['pdf']['files'] == 1"
c2 "partition: admin/ -> staff_only, third_party/ -> vendor, languages/ -> client" "p['admin/locales/{{lang}}/admin.json']['audience'] == 'staff_only' and p['third_party/widget/locales/{{lang}}.json']['audience'] == 'vendor' and p['languages/myplug-{{lang}}.po']['audience'] == 'client' and all(x['rule'] for x in d['partition'])"
c2 "existing translations: languages on disk" "e['languages_on_disk'] == ['de', 'de_DE', 'fr_FR', 'it_IT']"
c2 "existing translations: per-file entry and translated counts (gettext)" "[(f['lang'], f['entries'], f['translated']) for s in e['by_set'] if s['source_pattern'] == 'languages/myplug-{{lang}}.po' for f in s['files']] == [('de', 2, 1), ('de_DE', 2, 1), ('fr_FR', 1, 1)]"
c2 "existing translations: duplicate variants de / de_DE" "e['duplicates'] == [{'source_pattern': 'languages/myplug-{{lang}}.po', 'language': 'de', 'variants': ['de', 'de_DE']}]"
c2 "existing translations: .po without .mo does not load" "{'path': 'languages/myplug-fr_FR.po', 'reason': 'no compiled .mo next to it (WordPress loads the .mo)'} in e['non_loading']"
c2 "existing translations: catalogue named for another text domain does not load" "any(x['path'] == 'lang2/oldname-it_IT.po' and \"domain 'oldname'\" in x['reason'] for x in e['non_loading']) and len(e['non_loading']) == 2"
c2 "runtime: Text Domain + Domain Path headers" "r['text_domains'] == [{'path': 'myplug.php', 'line': 4, 'domain': 'myplug'}] and r['domain_paths'][0]['domain_path'] == '/languages'"
c2 "runtime: load_plugin_textdomain call" "r['load_textdomain'][0]['domain'] == 'myplug' and r['load_textdomain'][0]['kind'] == 'plugin' and r['load_textdomain'][0]['args'].startswith('false, dirname(plugin_basename(__FILE__))') and r['load_textdomain'][0]['args'].endswith('/languages\'')"
c2 "runtime: i18n init config" "[x['path'] for x in r['i18n_init']] == ['src/i18n.js']"
"$CLI" scan --json -d "$REPO" > "$WORK/plain.json" 2>/dev/null
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['other_string_sources'] == [] or all(o['kind'] != 'templates' or o['samples'][0]['path'] != 'config/locales/en.yml' for o in d['other_string_sources']) else 1)" "$WORK/plain.json" && pass "resource files are never counted as other sources" || fail "resource files counted as other sources"

echo "=== ptc scan --json: YAML anchors, aliases and merge keys count the same with and without PyYAML (FMT-29) ==="
# S2-R1: PTC's own config/locales/admin/placeholders.en.yml (`&default` + `<<: *default`) counted 74 strings
# without PyYAML and 213 with it, so a scan from a machine without PyYAML disagreed with CI's.
A="$WORK/anchors"; mkdir -p "$A/config/locales" "$WORK/no-pyyaml"
cat > "$A/config/locales/en.yml" <<'YML'
en:
  base: &base
    save: Save
    cancel: Cancel
    title: &title Hello %{name}
  copy: *title
  edit:
    <<: *base
    cancel: Discard
    extra: Extra
  view:
    <<: [*base]
YML
git -C "$A" init -q
echo 'raise ImportError("PyYAML hidden by the test")' > "$WORK/no-pyyaml/yaml.py"
anchor_counts() {  # -> "count placeholders" of the one source file
    python3 -c "import json,sys; f=json.load(open(sys.argv[1]))['resource_sets'][0]['source_files'][0]; print(f['count'], f['placeholders'])" "$1" 2>/dev/null
}
PYTHONPATH="$WORK/no-pyyaml" "$CLI" scan --json -d "$A" > "$WORK/anchors-fallback.json" 2>/dev/null
fallback=$(anchor_counts "$WORK/anchors-fallback.json")
[[ "$fallback" == "11 4" ]] && pass "built-in reader expands anchors, aliases and merge keys (11 strings, 4 placeholders)" || fail "built-in reader anchors: got '$fallback', want '11 4'"
if python3 -c "import yaml" 2>/dev/null; then
    "$CLI" scan --json -d "$A" > "$WORK/anchors-pyyaml.json" 2>/dev/null
    with=$(anchor_counts "$WORK/anchors-pyyaml.json")
    [[ "$with" == "$fallback" ]] && pass "PyYAML and the built-in reader agree on the anchored file ($with)" || fail "PyYAML '$with' vs built-in '$fallback'"
else
    echo "[SKIP] PyYAML not installed: the PyYAML half of the anchor check runs in the PyYAML pass"
fi

echo "=== F27 (S2-R8): PTC's own backend/config/locales/en.yml scans the same with and without PyYAML ==="
# The built-in reader dropped a key with no value (`service_errors:`, which PyYAML reads as null: one string) and kept
# double-quoted escapes (\" and \n) literally.
M="$WORK/monorepo-en"; mkdir -p "$M/config/locales"
cp "$(dirname "$(dirname "$TEST_DIR")")/backend/config/locales/en.yml" "$M/config/locales/en.yml"; git -C "$M" init -q
PYTHONPATH="$WORK/no-pyyaml" "$CLI" scan --json -d "$M" > "$WORK/en-fallback.json" 2>/dev/null
fallback=$(anchor_counts "$WORK/en-fallback.json")
if python3 -c "import yaml" 2>/dev/null; then
    "$CLI" scan --json -d "$M" > "$WORK/en-pyyaml.json" 2>/dev/null
    with=$(anchor_counts "$WORK/en-pyyaml.json")
    [[ -n "$with" && "$with" == "$fallback" ]] && pass "PyYAML and the built-in reader agree on PTC's en.yml ($with)" || fail "PTC en.yml: PyYAML '$with' vs built-in '$fallback'"
else
    echo "[SKIP] PyYAML not installed: the en.yml comparison runs in the PyYAML pass"
fi

echo; echo "scan suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
