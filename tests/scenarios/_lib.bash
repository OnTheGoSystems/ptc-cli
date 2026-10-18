# Shared by the defect regression scenarios (cli/tests/scenarios/*.sh, run by cli/tests/test-guide-scenarios.sh).
# Sourced, never run: the runner skips files starting with "_". A scenario exits 0 when every check passed.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$(dirname "$TESTS_DIR")/ptc-cli.sh"
MOCK="$TESTS_DIR/mock_ptc_api.py"
TEMPLATE="$TESTS_DIR/../../backend/app/services/guide/gitlab_ci_recipe.yml.tmpl"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
MOCK_PIDS=()
scenario_cleanup() {
    local p i
    for p in "${MOCK_PIDS[@]}"; do kill "$p" 2>/dev/null; done
    for p in "${MOCK_PIDS[@]}"; do wait "$p" 2>/dev/null; for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done; done
    rm -rf "${WORK:?}"
}
trap scenario_cleanup EXIT
# Outside any CI (the CLI reads these to decide the channel and the provenance).
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_API_TOKEN)

port_answers() { python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), 0.4).close()" 2>/dev/null; }

# start_mock NAME PORT [ENV=VALUE...] -> API_<NAME>; journal in $WORK/mock-NAME.log, bodies in $WORK/bodies-NAME.
# A port that already answers is refused (a stale mock would answer in place of ours).
start_mock() {
    local name="$1" port="$2" i pid; shift 2
    port_answers "$port" && { echo "port $port already in use: a stale mock_ptc_api.py? (pgrep -af mock_ptc_api.py)" >&2; exit 1; }
    mkdir -p "$WORK/bodies-$name"
    env "$@" PTC_MOCK_PORT="$port" PTC_MOCK_BODY_DIR="$WORK/bodies-$name" python3 "$MOCK" >>"$WORK/mock-$name.log" 2>&1 &
    pid=$!; MOCK_PIDS+=("$pid")
    for i in $(seq 1 30); do port_answers "$port" && kill -0 "$pid" 2>/dev/null && break; sleep 0.3; done
    kill -0 "$pid" 2>/dev/null || { echo "mock $name did not come up on $port" >&2; exit 1; }
    printf -v "API_$name" 'http://127.0.0.1:%s/api/v1/' "$port"
}

# The GitLab recipe the CLI prints (and the guide serves byte for byte), CLI version left as its placeholder.
render_gitlab_recipe() {
    # shellcheck disable=SC1090
    source <(sed -n '/^render_ci_gitlab() {$/,/^}$/p' "$CLI")
    VERSION='__PTC_CLI_VERSION__' render_ci_gitlab
}

finish() { echo "passed=$passed failed=$failed"; [[ $failed -eq 0 ]]; }
