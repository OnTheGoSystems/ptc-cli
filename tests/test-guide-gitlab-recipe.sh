#!/usr/bin/env bash
# The agent guide (PTC server) hands the GitLab recipe this CLI prints to an MCP agent that never runs the CLI
# (backend/app/services/guide/gitlab_ci_recipe.yml.tmpl, served by Guide::Tasks::CommitConfig). The two must not
# drift: the server's template is render_ci_gitlab's output byte for byte, with the CLI version as the placeholder
# __PTC_CLI_VERSION__ (the server fills in its recommended CLI version).
# Regenerate after changing render_ci_gitlab:  bash tests/test-guide-gitlab-recipe.sh --write
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$TEST_DIR/../ptc-cli.sh"
readonly TEMPLATE="$TEST_DIR/../../backend/app/services/guide/gitlab_ci_recipe.yml.tmpl"

render() {
    # shellcheck disable=SC1090
    source <(sed -n '/^render_ci_gitlab() {$/,/^}$/p' "$CLI")
    VERSION='__PTC_CLI_VERSION__' render_ci_gitlab
}

# S2-R3 item 2 (CI-16): the job hands the preflight's limit note to the merge request description - the job sets
# PTC_LIMIT_NOTE_FILE (the CLI run writes it, `guide mr-description` reads it) and clears it before the run.
recipe="$(render)"
grep -qE '^    PTC_LIMIT_NOTE_FILE: /tmp/ptc-limit-note$' <<<"$recipe" && grep -q 'rm -f /tmp/ptc-written /tmp/ptc-limit-note' <<<"$recipe" \
  && echo "[PASS] the recipe sets PTC_LIMIT_NOTE_FILE for the run and the merge request description, cleared first" \
  || { echo "[FAIL] the recipe does not pass the limit note to the merge request description"; exit 1; }

# S2-R19-3 (CI-16, CLI-7): exit 5 covers files PTC rejected AND files PTC could not be reached for; the job says both.
EXIT5_LINE='    - if [ "$ptc_rc" -eq 5 ]; then echo "PTC rejected some files or could not be reached for them (see '"'"'Rejected by PTC'"'"' / '"'"'Could not reach PTC'"'"' above); the rest was delivered."; exit 5; fi'
grep -qxF -- "$EXIT5_LINE" <<<"$recipe" \
  && echo "[PASS] the recipe's exit-5 line names both rejected and unreachable files" \
  || { echo "[FAIL] the recipe's exit-5 line does not name files PTC could not be reached for"; exit 1; }

if [[ "${1:-}" == "--write" ]]; then render > "$TEMPLATE"; echo "wrote $TEMPLATE"; exit 0; fi

if [[ ! -f "$TEMPLATE" ]]; then echo "[FAIL] the server template $TEMPLATE is missing"; exit 1; fi
if diff -u "$TEMPLATE" <(render); then
    echo "[PASS] the guide's GitLab recipe template is render_ci_gitlab byte for byte"
else
    echo "[FAIL] the guide's GitLab recipe template drifted from render_ci_gitlab (regenerate with --write)"; exit 1
fi
