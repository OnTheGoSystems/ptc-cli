#!/bin/bash

# Test runner for PTC CLI
# Runs basic functionality tests

set -uo pipefail  # Note: -e is not used to allow tests to fail without stopping execution

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly PTC_CLI="$PROJECT_DIR/ptc-cli.sh"
readonly FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

test_count=0
passed_count=0
failed_count=0

log_test() {
    echo -e "${YELLOW}[TEST]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((passed_count++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((failed_count++))
}

run_test() {
    local test_name="$1"
    shift
    
    ((test_count++))
    log_test "$test_name"
    
    # Run test and capture result without affecting main script execution
    if "$@" 2>/dev/null; then
        log_pass "$test_name"
    else
        log_fail "$test_name"
    fi
    
    # Always return success to continue test execution
    return 0
}

# Creating test files
setup_fixtures() {
    mkdir -p "$FIXTURES_DIR"
    
    # Create test translation files
    echo '{"hello": "Hello"}' > "$FIXTURES_DIR/sample-en.json"
    echo '{"hello": "Hallo"}' > "$FIXTURES_DIR/sample-de.json"
    
    mkdir -p "$FIXTURES_DIR/locales/en" "$FIXTURES_DIR/locales/de"
    echo '{"common": {"yes": "Yes", "no": "No"}}' > "$FIXTURES_DIR/locales/en/common.json"
    echo '{"common": {"yes": "Ja", "no": "Nein"}}' > "$FIXTURES_DIR/locales/de/common.json"
    
    mkdir -p "$FIXTURES_DIR/i18n"
    echo 'app.title=My App' > "$FIXTURES_DIR/i18n/en-app.properties"
    echo 'app.title=Meine Anwendung' > "$FIXTURES_DIR/i18n/de-app.properties"
    
    # Create WordPress-like translation structure
    mkdir -p "$FIXTURES_DIR/languages/plugins/wpsite" "$FIXTURES_DIR/languages/themes/wpsite-theme"
    
    # Plugin translations
    cat > "$FIXTURES_DIR/languages/plugins/wpsite/wpsite-en_US.po" << 'EOF'
msgid "Activity"
msgstr "Activity"
msgid "Groups"
msgstr "Groups"
EOF
    
    cat > "$FIXTURES_DIR/languages/plugins/wpsite/wpsite-de_DE.po" << 'EOF'
msgid "Activity"
msgstr "Aktivität"
msgid "Groups"
msgstr "Gruppen"
EOF
    
    # Theme translations
    cat > "$FIXTURES_DIR/languages/themes/wpsite-theme/en_US.po" << 'EOF'
msgid "Home"
msgstr "Home"
msgid "About"
msgstr "About"
EOF
    
    cat > "$FIXTURES_DIR/languages/themes/wpsite-theme/de_DE.po" << 'EOF'
msgid "Home"
msgstr "Startseite"
msgid "About"
msgstr "Über uns"
EOF
}

# Cleanup test files
cleanup_fixtures() {
    rm -rf "$FIXTURES_DIR"
}

# Test: show help
test_help() {
    "$PTC_CLI" --help >/dev/null 2>&1
}

# Test: show version
test_version() {
    "$PTC_CLI" --version >/dev/null 2>&1
}

# Test: error when no arguments
test_no_args() {
    ! "$PTC_CLI" >/dev/null 2>&1
}

# Test: search files by simple pattern
test_simple_pattern() {
    "$PTC_CLI" -s en -p 'sample-{{lang}}.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: search files by complex pattern
test_complex_pattern() {
    "$PTC_CLI" -s en -p 'locales/{{lang}}/common.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: multiple patterns
test_multiple_patterns() {
    "$PTC_CLI" -s en -p 'sample-{{lang}}.json,locales/{{lang}}/common.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: missing files
test_missing_files() {
    ! "$PTC_CLI" -s en -p '{{lang}}-nonexistent.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: auto-detect file tag name
test_auto_detect_tag() {
    "$PTC_CLI" -s en -p 'sample-{{lang}}.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: explicit file tag name
test_explicit_tag() {
    "$PTC_CLI" -s en -p 'sample-{{lang}}.json' -t test-branch -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: WordPress plugin translations
test_wordpress_plugin_pattern() {
    "$PTC_CLI" -s en -p 'languages/plugins/wpsite/wpsite-{{lang}}_US.po' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: WordPress theme translations
test_wordpress_theme_pattern() {
    "$PTC_CLI" -s en -p 'languages/themes/wpsite-theme/{{lang}}_US.po' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: specific files with output file paths
test_files_with_outputs() {
    "$PTC_CLI" -s en -f 'sample-en.json,locales/de/common.json' -o 'sample-{{lang}}.json,locales/{{lang}}/common.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: error when files specified without output file paths
test_files_without_outputs() {
    ! "$PTC_CLI" -s en -f 'sample-en.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: error when files count doesn't match output file paths count
test_files_count_mismatch() {
    ! "$PTC_CLI" -s en -f 'sample-en.json,locales/de/common.json' -o 'sample-{{lang}}.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: error when both patterns and files are specified
test_patterns_and_files_together() {
    ! "$PTC_CLI" -s en -p 'sample-{{lang}}.json' -f 'sample-en.json' -o 'sample-{{lang}}.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Test: file not found error
test_file_not_found() {
    ! "$PTC_CLI" -s en -f 'nonexistent.json' -o 'nonexistent-{{lang}}.json' -d "$FIXTURES_DIR" --dry-run >/dev/null 2>&1
}

# Main function
main() {
    echo "Running PTC CLI tests..."
    echo "========================"
    
    # Check that main script exists
    if [[ ! -f "$PTC_CLI" ]]; then
        echo "Error: PTC CLI script not found: $PTC_CLI"
        exit 1
    fi
    
    # Make script executable
    chmod +x "$PTC_CLI"
    
    # Test environment setup
    setup_fixtures
    
    # Run tests
    run_test "Show help" test_help
    run_test "Show version" test_version
    run_test "Error when no arguments" test_no_args
    run_test "Search by simple pattern" test_simple_pattern
    run_test "Search by complex pattern" test_complex_pattern
    run_test "Multiple patterns" test_multiple_patterns
    run_test "WordPress plugin pattern" test_wordpress_plugin_pattern
    run_test "WordPress theme pattern" test_wordpress_theme_pattern
    run_test "Auto-detect file tag name" test_auto_detect_tag
    run_test "Explicit file tag name" test_explicit_tag
    run_test "Files with output file paths" test_files_with_outputs
    run_test "Files without output file paths (should fail)" test_files_without_outputs
    run_test "Files count mismatch (should fail)" test_files_count_mismatch
    run_test "Patterns and files together (should fail)" test_patterns_and_files_together
    run_test "File not found (should fail)" test_file_not_found
    run_test "Missing files" test_missing_files
    
    # Cleanup
    cleanup_fixtures
    
    # Results
    echo
    echo "Test results:"
    echo "============="
    echo "Total tests: $test_count"
    echo -e "Passed: ${GREEN}$passed_count${NC}"
    echo -e "Failed: ${RED}$failed_count${NC}"
    
    if [[ $failed_count -eq 0 ]]; then
        echo -e "${GREEN}All tests passed successfully!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
