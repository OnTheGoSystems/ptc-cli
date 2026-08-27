#!/bin/bash

# What the CLI makes of the git context it is run in.
#
# The file tag defaults to the current branch, and CI is exactly where that
# assumption is weakest: a CI checkout normally leaves the tree on a detached
# HEAD, where `git branch --show-current` prints an empty string and exits 0.
# These assert the behaviour as it stands today rather than leaving it to
# whichever checkout style a runner happens to use — including the case that
# stops the run, so a change in that area has to be deliberate.

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

test_count=0
passed_count=0
failed_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; passed_count=$((passed_count + 1)); test_count=$((test_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; failed_count=$((failed_count + 1)); test_count=$((test_count + 1)); }

# A throwaway repository with one translatable file, left on `main`.
make_repo() {
    local dir
    dir="$(mktemp -d)"
    mkdir -p "$dir/locales"
    printf '{"hello":"Hello"}\n' > "$dir/locales/en.json"
    (
        cd "$dir" || exit 1
        git init -q -b main . 2>/dev/null || { git init -q .; git checkout -q -b main 2>/dev/null; }
        git add -A
        git -c user.email=test@example.com -c user.name=test commit -qm init
    )
    echo "$dir"
}

run_cli() {
    local dir="$1"
    shift
    ( cd "$dir" && PTC_API_TOKEN='' "$CLI" -s en -p 'locales/{{lang}}.json' --dry-run "$@" 2>&1 )
}

main() {
    echo "Git context — where the file tag comes from"
    echo "==========================================="

    local repo output
    repo="$(make_repo)"

    # 1. On a branch, the tag is detected and the run proceeds.
    output="$(run_cli "$repo")"
    if echo "$output" | grep -q 'Processing completed successfully'; then
        pass "on a branch: the file tag is auto-detected and the run completes"
    else
        fail "on a branch: the run did not complete"
        echo "$output" | tail -3 | sed 's/^/        /'
    fi

    # 2. Detached HEAD — what every CI checkout looks like by default.
    #
    # This used to stop the run: `git branch --show-current` succeeds and prints
    # an empty string there, so the fallbacks were never reached and the empty
    # tag was rejected before a single API call. Every CI recipe that forgot to
    # pass --file-tag-name therefore translated nothing at all, which is exactly
    # what the printed GitLab recipe did.
    ( cd "$repo" && git checkout -q --detach HEAD )
    output="$(CI_COMMIT_REF_NAME=feature/from-ci run_cli "$repo")"
    if echo "$output" | grep -q 'could not auto-detect git branch'; then
        fail "detached HEAD: the run still stops instead of using the runner's branch"
        echo "$output" | tail -3 | sed 's/^/        /'
    else
        pass "detached HEAD: the runner's branch variable carries the file tag"
    fi

    # ...and with no runner variables either, a default beats stopping.
    # A subshell with the variables unset - `env -u` cannot run a shell
    # function, and would have made this assert pass on empty output.
    output="$( unset CI_COMMIT_REF_NAME GITHUB_REF_NAME BITBUCKET_BRANCH BRANCH_NAME CIRCLE_BRANCH
               run_cli "$repo" )"
    if echo "$output" | grep -q 'could not auto-detect git branch'; then
        fail "detached HEAD with no CI variables: the run stops"
        echo "$output" | tail -3 | sed 's/^/        /'
    else
        pass "detached HEAD with no CI variables: falls back rather than stopping"
    fi

    # 3. ...and an explicit tag is the way through it. This is why the CI
    #    recipes the CLI prints pass one.
    output="$(run_cli "$repo" --file-tag-name my-branch)"
    if echo "$output" | grep -q 'Processing completed successfully'; then
        pass "detached HEAD: an explicit --file-tag-name completes the run"
    else
        fail "detached HEAD: an explicit --file-tag-name should complete the run"
        echo "$output" | tail -3 | sed 's/^/        /'
    fi

    # 4. Outside a repository there IS a default, and the run proceeds.
    #
    # The asymmetry this note used to describe — no repo falls back to "main",
    # a detached HEAD fell back to nothing — is gone: get_current_branch now
    # treats an empty `git branch --show-current` as "no answer", consults the
    # runner's own branch variables, and only then defaults.
    local bare
    bare="$(mktemp -d)"
    mkdir -p "$bare/locales"
    printf '{"hello":"Hello"}\n' > "$bare/locales/en.json"
    output="$(run_cli "$bare")"
    if echo "$output" | grep -q 'Processing completed successfully'; then
        pass "outside a repository: falls back to a default tag and completes"
    else
        fail "outside a repository: expected the default-tag fallback to complete the run"
        echo "$output" | tail -3 | sed 's/^/        /'
    fi

    rm -rf "$repo" "$bare"

    echo
    echo "Total: $test_count  Passed: $passed_count  Failed: $failed_count"
    [ "$failed_count" -eq 0 ] || return 1
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
