#!/bin/bash
# covers: SF-49
# status: fixed
# source: production GitLab job 401, 2026-10-09; cli/tests/test-guide-gitlab-recipe.sh SF-49
# title: the generated GitLab job uses PTC_API_TOKEN before a stale legacy PTC_ORG_TOKEN
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
recipe="$(render_gitlab_recipe)"
line=$(grep -m1 -F '/tmp/ptc-cli.sh guide check' <<<"$recipe" | sed 's/^ *- //')
[[ -n "$line" ]] || { fail "no guide check line in the recipe"; finish; exit 1; }
stub="$WORK/ptc-cli.sh"; printf '#!/bin/sh\necho "token=$PTC_ORG_TOKEN"\n' > "$stub"; chmod +x "$stub"
line2="${line//\/tmp\/ptc-cli.sh/$stub}"; line2="${line2//\/tmp\/ptc-check.json/$WORK/check.json}"
(cd "$WORK" && PTC_API_TOKEN=agent-token PTC_ORG_TOKEN=stale-legacy sh -c "$line2")
grep -qx "token=agent-token" "$WORK/check.json" && pass "both set: the job's CLI call gets PTC_API_TOKEN" || fail "token used: $(cat "$WORK/check.json")"
(cd "$WORK" && env -u PTC_API_TOKEN PTC_ORG_TOKEN=legacy-only sh -c "$line2")
grep -qx "token=legacy-only" "$WORK/check.json" && pass "legacy only: PTC_ORG_TOKEN still works" || fail "legacy: $(cat "$WORK/check.json")"
finish
