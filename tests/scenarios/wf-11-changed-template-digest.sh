#!/bin/bash
# covers: WF-11
# status: fixed
# source: tasks/translation-guide/briefs/WF-RCA.md "Second part" (sitepress: a run report of 2.85 MB, every changed .pot in full)
# title: a changed source template rides the run report as its digest; a changed code file rides with its bytes up to 1 MB
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"

T="$WORK/tree"; mkdir -p "$T/languages" "$T/src"
cat > "$T/.ptc-config.yml" <<'YML'
source_locale: en
files:
  - file: languages/shop.pot
    output: languages/shop-{{lang}}.po
guide:
  project_id: 42
YML
pot() { # $1 = the comment every entry carries; ~450 KB of entries
    python3 - "$1" > "$T/languages/shop.pot" <<'PY'
import sys
print('msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n')
for i in range(4500):
    print(f'#. {sys.argv[1]} {i}\n#: src/shop.php:{i}\nmsgid "Shop string number {i} with some words in it"\nmsgstr ""\n')
PY
}
pot 'translators: first'
printf '<?php\necho __("Shop string number 1 with some words in it", "shop");\n' > "$T/src/shop.php"
git -C "$T" init -q && git -C "$T" add -A && git -C "$T" -c user.email=t@example.com -c user.name=t commit -qm init
git -C "$T" update-ref refs/remotes/origin/main HEAD # the default branch the commit is diffed against
pot 'translators: second'
python3 -c "import sys; open(sys.argv[1], 'a').write('// ' + 'x' * 2000 + '\n')" "$T/src/shop.php"
git -C "$T" -c user.email=t@example.com -c user.name=t commit -qam 'change the template and the code'
size=$(wc -c < "$T/languages/shop.pot")
[[ $size -gt 400000 ]] && pass "the changed template is $size bytes (over the 200 KB sample cap)" || fail "fixture template only $size bytes"

start_mock M 19893
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API_M" -d "$T" >"$WORK/ar.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "the run is reported (exit 0)" || fail "action-run exit $rc: $(tail -5 "$WORK/ar.out")"
body() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print($1)" "$WORK/bodies-M/guide_action_runs.json" 2>/dev/null; }
want=$(sha256sum "$T/languages/shop.pot" | cut -d' ' -f1)
[[ "$(body "d['files_sha'].get('languages/shop.pot')")" == "$want" ]] && pass "the changed template's sha256 is reported" \
    || fail "files_sha[languages/shop.pot]: '$(body "d['files_sha'].get('languages/shop.pot')")'"
[[ "$(body "'languages/shop.pot' in d['files_sample']")" == "False" ]] && pass "the changed template's bytes are not sent (PTC reads its stored upload by sha)" \
    || fail "files_sample carries the changed template ($(body "len(d['files_sample'].get('languages/shop.pot', ''))") bytes)"
want=$(sha256sum "$T/src/shop.php" | cut -d' ' -f1)
[[ "$(body "d['files_sha'].get('src/shop.php')")" == "$want" ]] && pass "the changed code file's sha256 is reported" \
    || fail "files_sha[src/shop.php]: '$(body "d['files_sha'].get('src/shop.php')")'"
[[ "$(body "d['files_sample'].get('src/shop.php') == open('$T/src/shop.php').read()")" == "True" ]] && pass "the changed code file rides with its bytes" \
    || fail "files_sample[src/shop.php]: $(body "repr(d['files_sample'].get('src/shop.php'))" | cut -c1-80)"
bytes=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$WORK/bodies-M/guide_action_runs.json")
[[ $bytes -lt 200000 ]] && pass "the run report is $bytes bytes" || fail "the run report is $bytes bytes"

finish
