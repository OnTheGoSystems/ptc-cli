#!/bin/bash
# covers: LR2-F7
# status: fixed
# source: WPML lab run 2, .ptc/gt_255-cmd.txt + action-run-gt_255*.out + submit-gt_255*.out ("the run be136a30509b carries no copy and no stored upload of menu/wpml-admin-lang-switcher.class.php")
# title: `ptc guide action-run --file` paths are relative to the run directory (-d), the base the task's paths use; a missing one stops the run, never dropped in silence
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
start_mock AR 19871
# A suite repository: the product lives in its own directory; the source-fix task names product-relative paths.
R="$WORK/repo"; P="$R/sitepress"; mkdir -p "$P/locale" "$P/menu" "$P/classes"; git -C "$R" init -q
printf 'msgid ""\nmsgstr ""\n\nmsgid "Save"\nmsgstr ""\n' > "$P/locale/sitepress.pot"
printf "<?php\necho __( 'Save', 'sitepress' );\n" > "$P/menu/lang-switcher.php"
printf "<?php\necho sprintf( _n( '%%d job', '%%d jobs', \$n, 'sitepress' ), \$n );\n" > "$P/classes/report.php"
cat > "$P/.ptc-config.yml" <<'YML'
source_locale: en
files:
  - file: locale/sitepress.pot
    output: locale/sitepress-{{lang}}.po
guide:
  project_id: 42
YML
git -C "$R" add -A; git -C "$R" -c user.email=t@t -c user.name=t commit -qm base
printf "<?php\necho esc_html__( 'Save', 'sitepress' );\n" > "$P/menu/lang-switcher.php"   # the applied source fix
body() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print($1)" "$WORK/bodies-AR/guide_action_runs.json" 2>/dev/null; }

echo "=== run from the repository root with -d <product> and the task's product-relative --file paths ==="
( cd "$R" && "${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API_AR" -d sitepress \
    --file menu/lang-switcher.php --file classes/report.php ) >"$WORK/ar1.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "the run is reported (exit 0)" || fail "exit $rc: $(cat "$WORK/ar1.out")"
for f in menu/lang-switcher.php classes/report.php; do
    want=$(sha256sum "$P/$f" | cut -d' ' -f1)
    [[ "$(body "d['files_sha'].get('sitepress/$f')")" == "$want" ]] && pass "files_sha[sitepress/$f] carries the edited bytes' sha256" || fail "files_sha: $(body "sorted(d['files_sha'])")"
    [[ "$(body "d['files_sample'].get('sitepress/$f') is not None")" == "True" ]] && pass "the run carries a copy of sitepress/$f" || fail "files_sample keys: $(body "sorted(d['files_sample'])")"
done

echo "=== a --file that does not exist under the run directory stops the run with the reason ==="
rm -f "$WORK/bodies-AR/guide_action_runs.json"
( cd "$R" && "${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API_AR" \
    --file menu/lang-switcher.php ) >"$WORK/ar2.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && pass "exit $rc (non-zero) when a --file is missing" || fail "a missing --file exited 0: $(cat "$WORK/ar2.out")"
grep -q "menu/lang-switcher.php" "$WORK/ar2.out" && grep -q "relative to the run directory" "$WORK/ar2.out" \
    && pass "the error names the path and the base it is read from" || fail "error text: $(cat "$WORK/ar2.out")"
[[ ! -f "$WORK/bodies-AR/guide_action_runs.json" ]] && pass "nothing is reported to PTC" || fail "a run was posted without the named file"
finish
