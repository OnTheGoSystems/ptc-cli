#!/bin/bash

# Tests for config/examples/* — the files we tell people to copy.
#
# ci18-7398: three of the five examples were written as KEY=VALUE and every one
# of them died with "Missing 'files:' section", while a fourth taught the
# deprecated api_token: key. Nothing caught it because no test ever fed an
# example to the parser. This does: each example is run through a real --dry-run
# against a scratch project built from the paths it declares.

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$TEST_DIR")"
readonly CLI="$PROJECT_DIR/ptc-cli.sh"
readonly EXAMPLES_DIR="$PROJECT_DIR/config/examples"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

test_count=0
passed_count=0
failed_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; passed_count=$((passed_count + 1)); test_count=$((test_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; failed_count=$((failed_count + 1)); test_count=$((test_count + 1)); }

# Builds a scratch project holding every source file the config declares, then
# runs the CLI against it. Source paths are the `- file:` entries; `output:` is
# what PTC would write, so those are deliberately not created.
run_example() {
    local config="$1"
    local name workdir line src
    name="$(basename "$config")"

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' RETURN

    while IFS= read -r line; do
        src="${line#*file:}"
        src="$(echo "$src" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$src" ]] && continue
        mkdir -p "$workdir/$(dirname "$src")"
        printf '{"key":"value"}\n' > "$workdir/$src"
    done < <(grep -E '^\s*-\s+file:' "$config")

    PTC_API_TOKEN='' "$CLI" --config-file "$config" --project-dir "$workdir" --dry-run 2>&1
}

assert_parses() {
    local config="$1" name output
    name="$(basename "$config")"
    output="$(run_example "$config")"

    if echo "$output" | grep -q "Missing 'files:' section"; then
        fail "$name is parsed as a config (got: Missing 'files:' section)"
        return
    fi
    if echo "$output" | grep -q 'File not found'; then
        fail "$name declares source paths the parser then cannot find"
        echo "$output" | grep 'File not found' | sed 's/^/        /'
        return
    fi
    if ! echo "$output" | grep -q 'Processing files from config'; then
        fail "$name never reached file processing"
        echo "$output" | tail -3 | sed 's/^/        /'
        return
    fi
    pass "$name parses and reaches file processing"
}

# `{lang}` is not a placeholder the CLI knows — substitute_pattern only expands
# `{{lang}}`. A single-brace example silently translates into a literal path.
assert_placeholder() {
    local config="$1" name
    name="$(basename "$config")"
    if grep -E '(^|[^{])\{lang\}([^}]|$)' "$config" >/dev/null 2>&1; then
        fail "$name uses {lang}; only {{lang}} is substituted"
    else
        pass "$name uses the {{lang}} placeholder"
    fi
}

# A token in a committed file is the thing the deprecation exists to prevent.
assert_no_token_key() {
    local config="$1" name
    name="$(basename "$config")"
    if grep -qE '^\s*api_token:' "$config"; then
        fail "$name teaches the deprecated api_token: key"
    else
        pass "$name keeps the token out of the file"
    fi
}

main() {
    echo "Config examples — every file we tell people to copy"
    echo "==================================================="

    local found=0 config
    for config in "$EXAMPLES_DIR"/*.yml "$EXAMPLES_DIR"/*.yml.example; do
        [[ -e "$config" ]] || continue
        found=$((found + 1))
        assert_parses "$config"
        assert_placeholder "$config"
        assert_no_token_key "$config"
    done

    if [[ $found -eq 0 ]]; then
        fail "no examples found in $EXAMPLES_DIR"
    fi

    echo
    echo "Total: $test_count  Passed: $passed_count  Failed: $failed_count"
    [[ $failed_count -eq 0 ]] || return 1
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
