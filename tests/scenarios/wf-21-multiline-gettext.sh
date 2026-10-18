#!/bin/bash
# covers: WF-21
# status: fixed
# source: tasks/translation-guide/review/wpml-manual/RUN-LOG.md stop 34 (wpml-st-translations-file-scan-ui-block.php:62,76,88,108 flagged)
# title: the readiness audit does not flag the msgid of a multi-line `_x(` / `__(` call as a hardcoded string
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
R="$WORK/plugin"; mkdir -p "$R"
cat > "$R/plugin.php" <<'PHP'
<?php
/**
 * Plugin Name: Scenario
 * Text Domain: my-domain
 */
load_plugin_textdomain( 'my-domain', false, 'languages' );
function block() {
	$a = _x(
		'Scan the <strong>translation files</strong> of your theme and plugins',
		'scan block',
		'my-domain'
	);
	$b = __(
		'Strings from the <a href="#">MO files</a> are imported automatically',
		'my-domain'
	);
	return $a . $b;
}
?>
<p>Plain hardcoded paragraph text here</p>
PHP
(cd "$R" && "$CLI" audit strings --json) >"$WORK/audit.json" 2>"$WORK/audit.err"
python3 - "$WORK/audit.json" > "$WORK/hard.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
fs = d.get("findings") if isinstance(d, dict) else d
for f in fs or []:
    if f.get("class") == "hardcoded_string":
        print(f.get("line"), f.get("text"))
PY
[[ $? -eq 0 ]] || fail "audit output unreadable: $(head -c 300 "$WORK/audit.json") $(head -c 300 "$WORK/audit.err")"
! grep -qE '^(9|14) ' "$WORK/hard.txt" && pass "the msgids of multi-line gettext calls are not hardcoded" || fail "flagged inside gettext calls: $(grep -E '^(9|14) ' "$WORK/hard.txt")"
grep -q '^20 ' "$WORK/hard.txt" && pass "a real hardcoded paragraph is still flagged" || fail "the plain <p> text is not flagged: $(cat "$WORK/hard.txt")"
finish
