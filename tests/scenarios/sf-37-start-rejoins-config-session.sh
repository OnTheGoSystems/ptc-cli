#!/bin/bash
# covers: SF-37
# status: fixed
# source: L13 staging LW (2026-10-08); cli/tests/test-guide-l13.sh SF-37
# title: a second `guide start` in a no-git directory rejoins the config's session instead of opening a new project
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
start_mock M 19883
R="$WORK/rejoin"; mkdir -p "$R/.ptc"
printf 'source_locale: en\nlanguages: [de, es]\nfiles:\n  - file: en.yml\n    output: %s\nguide:\n  session_id: 9\n  project_id: 3526\n' "'{{lang}}.yml'" > "$R/.ptc-config.yml"
"${NOCI[@]}" PTC_ORG_TOKEN=org-token "$CLI" guide start --repo-url https://example.test/multi-org.git --branch main --api-url "$API_M" -d "$R" >"$WORK/rejoin.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "start exits 0" || fail "start exit $rc: $(cat "$WORK/rejoin.out")"
body=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['body']; print(d.get('session_id'), d.get('project_id'))" "$WORK/bodies-M/projects.json" 2>/dev/null)
[[ "$body" == "9 3526" ]] && pass "POST /projects carries the config's session and project" || fail "projects body: $body"
grep -q "Rejoined PTC project 3526" "$WORK/rejoin.out" && ! grep -q "Created PTC project" "$WORK/rejoin.out" \
    && pass "rejoined, no new project" || fail "rejoin: $(cat "$WORK/rejoin.out")"
finish
