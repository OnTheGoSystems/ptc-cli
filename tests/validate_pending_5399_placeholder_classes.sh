#!/bin/bash
# PENDING fix row #5399 (reg-1229, reg-1230). NOT run by the suite: CI runs tests/test-*.sh only
# (.gitlab-ci/component-tests.yml), and this file is deliberately named outside that glob.
#
# `ptc validate` (the post-delivery placeholder pass) must tell four classes apart:
#   1. a literal percent sign ("100% satisfied", "%{x}% complete") is text, not a printf
#      placeholder ("% s", "% c") - reg-1229;
#   2. a CLDR exact-count "one" form written as a word ("Eine Datei", Hebrew "one item") is a
#      correct translation in a language whose "one" means exactly 1 - reg-1230;
#   3. a real dropped %{x} still FAILs;
#   4. a real added %{x} still FAILs.
# Staging's ptc-cli.sh has no `validate` command yet, so every case here fails on staging. The
# validator and its fix live on feature/agent-guide-spike (2361b8037); row #5399 brings them to
# staging. When it lands: rename this file to tests/test-validate-placeholder-classes.sh so the
# suite runs it. Point PTC_CLI at another build to run it against that build.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="${PTC_CLI:-$(dirname "$TEST_DIR")/ptc-cli.sh}"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

J="$WORK/repo"; mkdir -p "$J/locales" "$J/config/locales"
cat > "$J/.ptc-config.yml" <<'YML'
source_locale: en
files:
  - file: locales/en.json
    output: locales/{{lang}}.json
  - file: config/locales/en.yml
    output: config/locales/{{lang}}.yml
YML
cat > "$J/locales/en.json" <<'JSON'
{"pct": "If you're not 100% satisfied, we refund.", "pct_after": "%{completeness}% complete",
 "files_one": "%{count} file ready.", "files_other": "%{count} files ready.",
 "dropped": "%{activeCount} resource files", "added": "Translate now"}
JSON
cat > "$J/locales/de.json" <<'JSON'
{"pct": "Wenn Sie nicht zu 100 % zufrieden sind, erstatten wir.", "pct_after": "%{completeness}% abgeschlossen",
 "files_one": "Eine Datei bereit.", "files_other": "%{count} Dateien bereit.",
 "dropped": "Ressourcendateien", "added": "%{count} jetzt übersetzen"}
JSON
printf 'en:\n  items:\n    one: "%%{count} item"\n    other: "%%{count} items"\n' > "$J/config/locales/en.yml"
printf 'he:\n  items:\n    one: "פריט אחד"\n    other: "%%{count} פריטים"\n' > "$J/config/locales/he.yml"
git -C "$J" init -q

"$CLI" validate -d "$J" --json >"$WORK/out.json" 2>"$WORK/err.txt"
echo "ptc validate exit code: $? (CLI: $CLI)"

# c(check, file_suffix) -> sorted keys with a finding of that check (FAIL or WARN) in that file.
vc() {
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); f=d['findings']; c=lambda n, fl=None: sorted((x['key'] or '') for x in f if x['check'] == n and (fl is None or x['file'].endswith(fl))); sys.exit(0 if ($2) else 1)" "$WORK/out.json" 2>/dev/null; then
    pass "$1"
  else
    fail "$1 #5399"
  fi
}

vc "literal percent: '100% satisfied' -> '100 % zufrieden' is not a placeholder" "'pct' not in c('placeholders', 'de.json')"
vc "literal percent: '%{x}% complete' is not '% c'" "'pct_after' not in c('placeholders', 'de.json')"
vc "spelled-out one: de _one form 'Eine Datei' without %{count} passes" "'files_one' not in c('placeholders', 'de.json')"
vc "spelled-out one: he YAML one: form without %{count} passes" "'items.one' not in c('placeholders', 'he.yml')"
vc "real dropped %{activeCount} still FAILs" "'dropped' in c('placeholders', 'de.json')"
vc "real added %{count} (not in the source) still FAILs" "'added' in c('placeholders', 'de.json')"

echo; echo "validate placeholder-classes (pending #5399): $passed passed, $failed failed"
[[ $failed -eq 0 ]]
