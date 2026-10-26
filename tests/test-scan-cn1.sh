#!/bin/bash
# CN-1 (WPML lab run 17, sitepress scope_cleanup gt_1588: 11 of 15 `regenerate` proposals were false positives): the census
# `usages` matched a gettext call only when its first string literal sat on the call's own line, so 441 multi-line calls
# (`__(` / `'text',` / `'domain'`), 10 later-line literals and the concatenated spellings left their entries "unused".
# A call is now a use of its first string argument read ahead up to 6 lines past the opening paren (blank lines and
# comments skipped, adjacent literals joined by `.`/`+`, a backtick literal without `${`, `_n_noop`/`_nx_noop` too). A
# call whose first argument is not a literal proves no entry used. `usages_unmatched` stays line-bound (SPEC.md:239).
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=${KEEP_WORK:-$(mktemp -d)}; [[ -z "${KEEP_WORK:-}" ]] && trap 'rm -rf "$WORK"' EXIT
SCAN="$WORK/scan.json"
check() {  # check "desc" "python expression over d, k (the msgids used under dom.pot), us (its usages), u (usages_unmatched)"
    local desc="$1" expr="$2"
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); us=d['usages'].get('dom/languages/dom.pot', {}); k=set(us); u=d.get('usages_unmatched'); sys.exit(0 if ($expr) else 1)" "$SCAN" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc: used=$(python3 -c "import json,sys; print(sorted(json.load(open(sys.argv[1]))['usages'].get('dom/languages/dom.pot', {})))" "$SCAN" 2>&1)"
    fi
}

R="$WORK/repo"; mkdir -p "$R/dom/languages" "$R/dom/inc" "$R/dom/src"
cat > "$R/dom/languages/dom.pot" <<'PO'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid "PHP multi-line"
msgstr ""

msgid "Same line"
msgstr ""

msgid "JSX next line"
msgstr ""

msgid "%d file"
msgid_plural "%d files"
msgstr[0] ""
msgstr[1] ""

msgid "Joined over lines"
msgstr ""

msgid "Plus joined"
msgstr ""

msgid "Backtick text"
msgstr ""

msgid "Noop single"
msgid_plural "Noop plural"
msgstr[0] ""
msgstr[1] ""

msgctxt "menu"
msgid "Noop ctx"
msgid_plural "Noop ctxs"
msgstr[0] ""
msgstr[1] ""

msgid "After comments"
msgstr ""

msgid "Variable first"
msgstr ""

msgid "Hi ${name}"
msgstr ""

msgid "Too far"
msgstr ""

msgid "Hello "
msgstr ""

msgid "Unrelated literal"
msgstr ""

msgid "One two three four"
msgstr ""
PO
cat > "$R/dom/inc/a.php" <<'PHP'
<?php
echo __(
	'PHP multi-line',
	'dom'
);
echo __( 'Same line', 'dom' );
echo _n(
	'%d file',
	'%d files',
	$n,
	'dom'
);
echo esc_html__(
	'Joined ' .
	'over lines',
	'dom'
);
$a = _n_noop( 'Noop single', 'Noop plural', 'dom' );
$b = _nx_noop(
	'Noop ctx', 'Noop ctxs', 'menu', 'dom'
);
echo __(
	$variable,
	'Variable first'
);
echo __( 'Hello ' . $name, 'dom' );
echo __(
	'Lost multi-line',
	'dom'
);
echo __( 'Lost same line', 'dom' );
echo __(






	'Too far',
	'dom'
);
echo __(
	'One '
	.
	'two '
	.
	'three '
	.
	'four',
	'dom'
);
echo __(
	'Unrelated ' . $x . 'literal',
	'dom'
);
PHP
cat > "$R/dom/src/View.tsx" <<'TSX'
export const View = () => (
	<p>
		{__(
			'JSX next line',
			'dom'
		)}
		{_n(
			/* translators: %d: count */
			'%d file',
			'%d files',
			n,
			'dom'
		)}
		{__( 'Plus ' +
			'joined', 'dom' )}
		{__(
			`Backtick text`,
			'dom'
		)}
		{__(
			// eslint-disable-next-line max-len

			'After comments',
			'dom'
		)}
		{__(
			`Hi ${name}`,
			'dom'
		)}
	</p>
);
TSX
git -C "$R" init -q

"$CLI" scan --json -d "$R" > "$SCAN" 2>/dev/null
check "a same-line call stays a use (unchanged)" "'Same line' in k"
check "a PHP call whose msgid sits on the next line is a use" "'PHP multi-line' in k"
check "the use of a multi-line call is reported at the call's own line, with that line's text" \
    "us['PHP multi-line'] == [{'path': 'dom/inc/a.php', 'line': 2, 'text': 'echo __('}]"
check "a JSX call whose msgid sits on the next line is a use" "'JSX next line' in k"
check "an _n call over lines (and past a /* */ translators comment) uses its first literal" \
    "[x['path'] for x in us.get('%d file', [])] == ['dom/inc/a.php', 'dom/src/View.tsx']"
check "PHP literals joined by . over lines form one msgid" "'Joined over lines' in k"
check "JS literals joined by + form one msgid" "'Plus joined' in k"
check "a backtick literal without \${ is a msgid" "'Backtick text' in k"
check "_n_noop and _nx_noop calls are uses" "'Noop single' in k and 'Noop ctx' in k"
check "a line comment and a blank line between the paren and the literal are skipped" "'After comments' in k"
check "a call whose first argument is a variable uses nothing (not even its later literal)" "'Variable first' not in k"
check "a backtick template with \${ is not a literal" "'Hi \${name}' not in k"
check "a literal more than 6 lines below the call line is not read" "'Too far' not in k"
check "literals joined to the first one may run past the 6-line window (WPML RestEnabledRequirement.php)" "'One two three four' in k"
check "a literal glued to a variable keeps today's same-line behaviour only (Hello )" "'Hello ' in k and 'Unrelated literal' not in k"
check "usages_unmatched stays line-bound: the same-line lost call only, never the multi-line one" \
    "[c['msgid'] for c in u['dom']['calls']] == ['Lost same line'] and u['dom']['total'] == 1"

echo; echo "cn1 scan suite: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
