#!/bin/bash
# covers: LR2-F12
# status: fixed
# source: WPML lab run 2, .ptc/upload-sources.out (FileNotFoundError: .../sitepress-multilingual-cms/sitepress-multilingual-cms/locale/..., then "Uploaded 37 source file(s)" and exit 0)
# title: `ptc guide upload-sources -d <product>` records what it uploaded under the repository-root path (no doubled product dir), and a failure to record it is a non-zero exit
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
start_mock UPS 19872
R="$WORK/repo"; P="$R/wpml-cms-nav"; mkdir -p "$P/locale/pot"; git -C "$R" init -q
printf '{"save": "Save"}\n' > "$P/locale/pot/en.json"
cat > "$P/.ptc-config.yml" <<'YML'
source_locale: en
files:
  - file: locale/pot/en.json
    output: locale/pot/{{lang}}.json
guide:
  project_id: 42
YML
git -C "$R" add -A; git -C "$R" -c user.email=t@t -c user.name=t commit -qm base
ledger="$P/.ptc/uploads.tsv"

echo "=== a product directory of a repository: the upload is recorded, nothing doubled ==="
( cd "$R" && "${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide upload-sources --session-id gs_ups --api-url "$API_UPS" -d wpml-cms-nav ) >"$WORK/u1.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "upload-sources exits 0" || fail "exit $rc: $(cat "$WORK/u1.out")"
grep -q "Traceback\|wpml-cms-nav/wpml-cms-nav" "$WORK/u1.out" && fail "a traceback / doubled path: $(cat "$WORK/u1.out")" || pass "no traceback, no doubled product directory"
want=$(sha256sum "$P/locale/pot/en.json" | cut -d' ' -f1)
grep -qxF "wpml-cms-nav/locale/pot/en.json	$want" "$ledger" && pass "the ledger records the repository-root path at its sha256" || fail "ledger: $(cat "$ledger" 2>/dev/null)"
( cd "$R" && "${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide upload-sources --session-id gs_ups --api-url "$API_UPS" -d wpml-cms-nav ) >"$WORK/u2.out" 2>&1
grep -qF "Uploaded 0 source file(s), 0 bytes, to PTC (nothing translated); 1 already held at the same sha256." "$WORK/u2.out" \
    && pass "a rerun sends nothing: the file is held at the same sha256" || fail "rerun: $(cat "$WORK/u2.out")"

echo "=== recording the upload fails: the run says so and exits non-zero ==="
printf '{"save": "Save!"}\n' > "$P/locale/pot/en.json"
# The ledger path is a directory: unwritable for every user, root included (the suite runs this as root in a container,
# where a read-only mode bit does not stop a write).
rm -f "${ledger:?}"; mkdir "${ledger:?}"
( cd "$R" && "${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide upload-sources --session-id gs_ups --api-url "$API_UPS" -d wpml-cms-nav ) >"$WORK/u3.out" 2>&1
rc=$?
rmdir "${ledger:?}"
[[ $rc -ne 0 ]] && pass "exit $rc (non-zero) when the ledger cannot be written" || fail "exit 0 after a failed ledger write: $(cat "$WORK/u3.out")"
grep -q "Could not record the uploaded files" "$WORK/u3.out" && pass "the error says what failed" || fail "no error line: $(cat "$WORK/u3.out")"
finish
