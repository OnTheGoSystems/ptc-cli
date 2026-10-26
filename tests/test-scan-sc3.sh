#!/bin/bash
# SC-3 (WPML lab run 17, wpml-string-translation scope_cleanup gt_1658 / source_upload gt_1665): `null.pot`, a build
# artefact committed to the repository yet listed in its own .gitignore, was in the census, so PTC proposed regenerating
# it and source_upload demanded it. A tracked file that the repository's .gitignore ignores is not a source file: the
# census lists neither it nor an untracked ignored file. Same run (sitepress, CN-1-REPORT.md:50): PHP source under
# `classes/*/log/` was never scanned because `log` and `tmp` were skipped at any depth; they are runtime directories only
# at the repository root, a nested `log/` or `tmp/` is source. The exclusion is a census rule only: a committed
# translation file that .gitignore matches is a delivered output, and the delivery digest (delivered_files_sha) still
# lists it, as the ls-tree digest at HEAD does.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=${KEEP_WORK:-$(mktemp -d)}; [[ -z "${KEEP_WORK:-}" ]] && trap 'rm -rf "$WORK"' EXIT
SCAN="$WORK/scan.json"
check() {  # check "desc" "python expression over s (the census JSON text), p (the paths using msgids of dom.pot)"
    local desc="$1" expr="$2"
    if python3 -c "import json,sys; s=open(sys.argv[1]).read(); d=json.loads(s); us=d['usages'].get('dom/languages/dom.pot', {}); p=sorted({x['path'] for v in us.values() for x in v}); sys.exit(0 if ($expr) else 1)" "$SCAN" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc: usage paths=$(python3 -c "import json,sys; us=json.load(open(sys.argv[1]))['usages'].get('dom/languages/dom.pot', {}); print(sorted({x['path'] for v in us.values() for x in v}))" "$SCAN" 2>&1)"
    fi
}

R="$WORK/repo"
mkdir -p "$R/dom/languages" "$R/dom/inc" "$R/dom/gen" "$R/dom/classes/x/log" "$R/dom/classes/x/tmp" "$R/log" "$R/tmp"
cat > "$R/dom/languages/dom.pot" <<'PO'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid "Plain source"
msgstr ""

msgid "Ignored tracked"
msgstr ""

msgid "Ignored untracked"
msgstr ""

msgid "Nested log"
msgstr ""

msgid "Nested tmp"
msgstr ""

msgid "Root log"
msgstr ""

msgid "Root tmp"
msgstr ""
PO
cp "$R/dom/languages/dom.pot" "$R/dom/null.pot"
printf 'msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n' > "$R/dom/languages/dom-de_DE.po"
php_call() { printf '<?php\necho __( %s, %s );\n' "'$1'" "'dom'" > "$R/$2"; }
php_call "Plain source" dom/inc/a.php
php_call "Ignored tracked" dom/gen/tracked.php
php_call "Ignored untracked" dom/gen/untracked.php
php_call "Nested log" dom/classes/x/log/Logger.php
php_call "Nested tmp" dom/classes/x/tmp/Temp.php
php_call "Root log" log/x.php
php_call "Root tmp" tmp/x.php
G=(git -C "$R" -c user.email=t@example.com -c user.name=t)
"${G[@]}" init -q
"${G[@]}" add -A
"${G[@]}" commit -qm init
"${G[@]}" rm -q --cached dom/gen/untracked.php
printf 'null.pot\ngen/\nlanguages/*.po\n' > "$R/dom/.gitignore"
"${G[@]}" add dom/.gitignore

"$CLI" scan --json -d "$R" > "$SCAN" 2>/dev/null
check "the census is produced" "'dom/inc/a.php' in p"
check "a tracked template the repository's .gitignore ignores is not listed (null.pot)" "'dom/null.pot' not in s"
check "a tracked source file the repository's .gitignore ignores is not listed" "'dom/gen/tracked.php' not in s"
check "the same file untracked and ignored is not listed (unchanged)" "'dom/gen/untracked.php' not in s"
check "a tracked file no .gitignore rule matches is listed (unchanged)" "'dom/languages/dom.pot' in s and 'dom/inc/a.php' in p"
check "a tracked .php under a nested log/ directory is source" "'dom/classes/x/log/Logger.php' in p"
check "a tracked .php under a nested tmp/ directory is source" "'dom/classes/x/tmp/Temp.php' in p"
check "a .php under the root log/ directory is runtime, not listed (unchanged)" "'log/x.php' not in p"
check "a .php under the root tmp/ directory is runtime, not listed (unchanged)" "'tmp/x.php' not in p"
check "a committed translation file that .gitignore matches is not in the census" "'dom/languages/dom-de_DE.po' not in s"
# delivered_files_sha, called straight from the CLI's own Python helper (its body, without the closing dispatch line).
delivered=$(python3 - "$CLI" "$R" <<'PY' 2>&1
import sys
src = open(sys.argv[1]).read()
body = src.split("<<'PTC_PY_EOF'\n", 1)[1].split("\nPTC_PY_EOF\n", 1)[0]
body = body.replace("sys.exit(main(sys.argv[1:]))", "")
ns = {"__name__": "ptc_helper"}
exec(compile(body, "ptc_helper", "exec"), ns)
cfg = {"files": [{"file": "dom/languages/dom.pot", "output": "dom/languages/dom-{{lang}}.po"}]}
print(sorted(ns["delivered_files_sha"](sys.argv[2], cfg)))
PY
)
if [[ "$delivered" == "['dom/languages/dom-de_DE.po']" ]]; then
    pass "the same committed translation file stays in delivered_files_sha (the delivery digest is not the census)"
else
    fail "the same committed translation file stays in delivered_files_sha: got $delivered"
fi

echo; echo "sc3 scan suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
