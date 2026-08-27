#!/usr/bin/env bash
# Runs the GitLab recipe this CLI prints, instead of grepping it.
#
# The recipe is copied verbatim into a user's .gitlab-ci.yml, so what matters is
# whether it works, not whether it contains particular words. Three defects
# lived in it while text assertions passed:
#
#   1. It did not translate anything. A GitLab runner checks out a DETACHED
#      HEAD; `git branch --show-current` there succeeds and prints an empty
#      string, so the fallbacks in get_current_branch are never reached and
#      validate_args rejects the empty file tag - before a single API call.
#   2. It curled ptc-cli.sh into the project root and then ran `git add -A`,
#      so the merge request carried the CLI itself, plus whatever the caller's
#      job had already dirtied.
#   3. Because that download is always a new file, `git diff --cached --quiet`
#      never short-circuited: every run force-updated the merge request even
#      when no translation had changed.
#
# The real CLI runs here, against a mock PTC API on localhost. Only two things
# are shimmed: `curl`, so the recipe installs the working copy rather than
# downloading a release, and `git push`, because there is nowhere to push.
set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI_UNDER_TEST="$TEST_DIR/../ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
test_count=0; passed_count=0; failed_count=0
pass() { echo -e "${GREEN}[PASS]${NC} $*"; passed_count=$((passed_count + 1)); test_count=$((test_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; failed_count=$((failed_count + 1)); test_count=$((test_count + 1)); }

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$desc"; else fail "$desc (got '$got', want '$want')"; fi
}

# --- the mock ---------------------------------------------------------------
# A plain python process, no docker: the CLI only needs an --api-url.
MOCK_PID=""
MOCK_PORT=""

start_mock() {
    local port
    for port in 18787 18797 18807 18817; do
        PTC_MOCK_PORT="$port" PTC_MOCK_LOCALES=de,fr PTC_MOCK_PENDING=0 \
            python3 "$MOCK" >/dev/null 2>&1 &
        local pid=$!
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            if python3 -c "import socket,sys; s=socket.create_connection(('127.0.0.1', $port), 0.4); s.close()" 2>/dev/null; then
                MOCK_PID="$pid"; MOCK_PORT="$port"; return 0
            fi
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.4
        done
        kill "$pid" 2>/dev/null
    done
    return 1
}

stop_mock() { [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; return 0; }
trap stop_mock EXIT

# --- fixture ----------------------------------------------------------------
# A repository the way a GitLab runner leaves it: detached HEAD, and a working
# directory an earlier job step has already dirtied.
make_fixture() {
    local dir
    # -P: on macOS TMPDIR lives under /var, a symlink to /private/var, and the
    # CLI compares the git root against paths found by `find`. A mismatched
    # prefix there makes it fall back to absolute paths, which is a real defect
    # but not the one this suite is about.
    dir="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ptc-recipe-XXXXXX")" && pwd -P)"
    mkdir -p "$dir/locales"
    printf '{"hello":"world"}\n' > "$dir/locales/en.json"
    # api_url in the config, because the recipe does not print --api-url and
    # PTC_API_URL is assigned unconditionally in the CLI, so the environment
    # cannot redirect it. Without this the recipe reaches the real PTC and the
    # suite fails with a 401 that looks like a bug in the recipe.
    cat > "$dir/.ptc-config.yml" <<CFG
source_locale: en
api_url: http://127.0.0.1:$MOCK_PORT/api/v1/
files:
  - file: locales/en.json
    output: locales/{{lang}}.json
CFG
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email probe@local
    git -C "$dir" config user.name probe
    git -C "$dir" add -A
    git -C "$dir" commit -qm baseline
    # Exactly what a runner does, and the reason defect 1 existed.
    git -C "$dir" checkout -q "$(git -C "$dir" rev-parse HEAD)"
    printf '%s' "$dir"
}

# Shims: curl installs the working copy instead of downloading a release, and
# git push records its arguments instead of pushing.
make_shims() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/curl" <<SHIM
#!/usr/bin/env bash
# The recipe's only curl is the CLI download. Everything the CLI itself does
# goes through the real curl, found by absolute path.
out=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && out="\$a"
  prev="\$a"
done
case "\$out" in
  *ptc-cli.sh) cp "$CLI_UNDER_TEST" "\$out"; chmod +x "\$out"; exit 0 ;;
esac
exec $(command -v curl) "\$@"
SHIM
    cat > "$bin/git" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then
  printf '%s\n' "\$*" > "\$PTC_TEST_PUSH_LOG"
  exit 0
fi
exec $(command -v git) "\$@"
SHIM
    chmod +x "$bin/curl" "$bin/git"
}

# Extracts the shell of the printed GitLab job, in order.
recipe_script() {
    bash -c "source '$CLI_UNDER_TEST' >/dev/null 2>&1; render_ci_gitlab" | awk '
        /^  script:/ { s = 1; next }
        s && /^  [a-z_]+:/ { s = 0 }
        s {
            line = $0
            if (line ~ /^    - \|$/) next
            sub(/^    - /, "", line)
            sub(/^      /, "", line)
            print line
        }'
}

# Runs the recipe in the fixture and prints nothing; the caller inspects the repo.
run_recipe() {
    local dir="$1" bin="$dir/../bin.$$"
    make_shims "$bin"
    export PTC_TEST_PUSH_LOG="$dir/../push.args.$$"
    rm -f "$PTC_TEST_PUSH_LOG"
    # Written outside the repository: a script inside it is another file the
    # recipe could sweep into the merge request, which would mask the defect.
    local script="$dir/../recipe.$$.sh"
    # `set -e` because GitLab aborts a job at the first failing script line -
    # without it a CLI that translated nothing still reaches the git block and
    # the recipe looks like it succeeded.
    { echo 'set -e'; recipe_script; } > "$script"
    ( cd "$dir" && PATH="$bin:$PATH" \
        PTC_API_TOKEN=mock-token-abcdef \
        CI_DEFAULT_BRANCH=main \
        CI_COMMIT_REF_NAME=main \
        CI_SERVER_HOST=gitlab.example \
        CI_PROJECT_PATH=group/project \
        CI_JOB_TOKEN=job-token \
        bash "$script" >"$dir/../recipe.log.$$" 2>&1 )
    local rc=$?
    # A failing recipe is the interesting case; print why rather than leaving
    # the reader with an exit code.
    if [ "$rc" -ne 0 ] || [ -n "${PTC_TEST_TRACE:-}" ]; then
        echo "--- recipe output (exit $rc) ---" >&2
        tail -15 "$dir/../recipe.log.$$" >&2
        echo "--- end ---" >&2
    fi
    rm -f "$dir/../recipe.log.$$" "$script"
    echo $rc
}

committed_files() {
    git -C "$1" show --stat --format="" HEAD 2>/dev/null | \
        sed -n 's/^ \([^|]*\)|.*/\1/p' | sed 's/ *$//' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# --- 1. the recipe actually translates on a detached HEAD -------------------
test_recipe_translates() {
    echo -e "${YELLOW}[TEST]${NC} the printed recipe translates on a detached HEAD"
    local dir rc
    dir="$(make_fixture)"
    rc="$(run_recipe "$dir")"
    assert_eq "the recipe exits 0 on a runner's detached HEAD" "$rc" "0"
    assert_eq "the translations reached disk" \
        "$(ls "$dir/locales" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')" \
        "de.json en.json fr.json"
    rm -rf "$dir"
}

# --- 2. the merge request carries translations and nothing else -------------
test_recipe_commits_only_translations() {
    echo -e "${YELLOW}[TEST]${NC} the merge request carries only what the run wrote"
    local dir
    dir="$(make_fixture)"
    # What an earlier step in the caller's job leaves behind.
    mkdir -p "$dir/dist"
    printf 'BUILD\n' > "$dir/dist/bundle.js"
    printf '{"touched":true}\n' > "$dir/package-lock.json"
    run_recipe "$dir" >/dev/null

    assert_eq "only the translations are committed" \
        "$(committed_files "$dir")" "locales/de.json locales/fr.json"
    rm -rf "$dir"
}

# --- 3. the CLI the recipe downloads does not end up in the repository ------
test_cli_not_left_behind() {
    echo -e "${YELLOW}[TEST]${NC} the downloaded CLI stays out of the repository"
    local dir
    dir="$(make_fixture)"
    run_recipe "$dir" >/dev/null

    if printf '%s' "$(committed_files "$dir")" | grep -q 'ptc-cli.sh'; then
        fail "the downloaded CLI was committed into the merge request"
    else
        pass "the downloaded CLI was not committed"
    fi
    if [ -e "$dir/ptc-cli.sh" ]; then
        fail "the downloaded CLI was left in the working tree"
    else
        pass "the downloaded CLI was not left in the working tree"
    fi
    rm -rf "$dir"
}

# --- 4. a run that writes nothing pushes nothing ----------------------------
test_no_translations_no_push() {
    echo -e "${YELLOW}[TEST]${NC} a run that writes nothing opens no merge request"
    local dir
    dir="$(make_fixture)"
    # Already translated: the mock returns the same content, so nothing changes.
    run_recipe "$dir" >/dev/null
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -qm "translations already in" >/dev/null 2>&1
    rm -f "$PTC_TEST_PUSH_LOG"
    run_recipe "$dir" >/dev/null

    if [ -f "$PTC_TEST_PUSH_LOG" ]; then
        fail "a second identical run still pushed (merge request churn)"
    else
        pass "a second identical run pushed nothing"
    fi
    rm -rf "$dir"
}

# --- 5. the push is a merge request against the default branch --------------
test_push_shape() {
    echo -e "${YELLOW}[TEST]${NC} the push asks GitLab for a merge request"
    local dir args
    dir="$(make_fixture)"
    run_recipe "$dir" >/dev/null
    args="$(cat "$PTC_TEST_PUSH_LOG" 2>/dev/null || echo '')"

    if printf '%s' "$args" | grep -q 'merge_request.create'; then
        pass "the push creates a merge request"
    else
        fail "the push does not create a merge request (args: $args)"
    fi
    if printf '%s' "$args" | grep -q 'merge_request.target=main'; then
        pass "the merge request targets the default branch"
    else
        fail "the merge request does not target the default branch (args: $args)"
    fi
    rm -rf "$dir"
}

main() {
    echo "=== printed GitLab recipe, executed ==="
    for tool in python3 curl unzip git; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            if [ -n "${PTC_REQUIRE_E2E:-}" ]; then
                fail "$tool is required for this suite"
                echo "Total: $test_count  Passed: $passed_count  Failed: $failed_count"
                return 1
            fi
            echo "skipped: $tool is not installed"
            return 0
        fi
    done

    if ! start_mock; then
        if [ -n "${PTC_REQUIRE_E2E:-}" ]; then
            fail "the mock PTC API did not start"
            return 1
        fi
        echo "skipped: could not start the mock PTC API"
        return 0
    fi
    echo "mock PTC API on 127.0.0.1:$MOCK_PORT"

    test_recipe_translates
    test_recipe_commits_only_translations
    test_cli_not_left_behind
    test_no_translations_no_push
    test_push_shape

    echo
    echo "Total: $test_count  Passed: $passed_count  Failed: $failed_count"
    [ "$failed_count" -eq 0 ]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
