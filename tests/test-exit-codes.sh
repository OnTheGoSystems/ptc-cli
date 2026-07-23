#!/bin/bash

# Tests for ci18-7342 - the run verdict and the polling knobs.
#
# Two behaviours are covered:
#
#   1. A partial run must not exit 0. The step loops used to return success as
#      soon as ONE file completed, so nine failures out of ten still produced a
#      green pipeline reporting a translation run that never happened.
#
#   2. `monitor_interval` / `monitor_max_attempts` must be readable from
#      .ptc-config.yml. The README documented them as config keys from the
#      start, but only the flags were ever parsed - and neither the GitHub
#      action nor the GitLab component passes those flags, which left the
#      ~8.3-minute polling ceiling unreachable from CI.

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI_UNDER_TEST="$(dirname "$TEST_DIR")/ptc-cli.sh"

# shellcheck disable=SC1090
source "$CLI_UNDER_TEST"   # main() is guarded by a BASH_SOURCE check

set +e

test_count=0
passed_count=0
failed_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; passed_count=$((passed_count + 1)); test_count=$((test_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; failed_count=$((failed_count + 1)); test_count=$((test_count + 1)); }

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$desc"
    else
        fail "$desc (got '$got', want '$want')"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *) fail "$desc (expected '$needle' in '$haystack')" ;;
    esac
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

write_config() {
    local path="$WORK_DIR/$1"; shift
    printf '%s\n' "$@" > "$path"
    printf '%s' "$path"
}

echo "=== monitor_* are read from the config file ==="

PTC_SOURCE_LOCALE=""; PTC_FILE_TAG_NAME=""; PTC_MONITOR_INTERVAL="5"; PTC_MONITOR_MAX_ATTEMPTS="100"
cfg=$(write_config full.yml \
    'source_locale: en' \
    'monitor_interval: 30' \
    'monitor_max_attempts: 240' \
    'files:' \
    '  - file: locales/en.json' \
    '    output: locales/{{lang}}.json')
parse_config_file "$cfg" >/dev/null 2>&1
assert_eq "monitor_interval comes from the config" "$PTC_MONITOR_INTERVAL" "30"
assert_eq "monitor_max_attempts comes from the config" "$PTC_MONITOR_MAX_ATTEMPTS" "240"

echo
echo "=== an explicit flag still beats the config ==="

PTC_SOURCE_LOCALE=""; PTC_FILE_TAG_NAME=""; PTC_MONITOR_INTERVAL="7"; PTC_MONITOR_MAX_ATTEMPTS="12"
parse_config_file "$cfg" >/dev/null 2>&1
assert_eq "flag-set interval survives the config" "$PTC_MONITOR_INTERVAL" "7"
assert_eq "flag-set max_attempts survives the config" "$PTC_MONITOR_MAX_ATTEMPTS" "12"

echo
echo "=== a malformed value is rejected, not silently applied ==="

PTC_SOURCE_LOCALE=""; PTC_FILE_TAG_NAME=""; PTC_MONITOR_INTERVAL="5"; PTC_MONITOR_MAX_ATTEMPTS="100"
bad_cfg=$(write_config bad.yml \
    'source_locale: en' \
    'monitor_interval: soon' \
    'monitor_max_attempts: 0' \
    'files:' \
    '  - file: locales/en.json' \
    '    output: locales/{{lang}}.json')
output=$(parse_config_file "$bad_cfg" 2>&1)
assert_eq "non-numeric interval leaves the default" "$PTC_MONITOR_INTERVAL" "5"
assert_eq "zero max_attempts leaves the default" "$PTC_MONITOR_MAX_ATTEMPTS" "100"
assert_contains "a malformed interval is reported" "$output" "Ignoring invalid 'monitor_interval"
assert_contains "a malformed max_attempts is reported" "$output" "Ignoring invalid 'monitor_max_attempts"

echo
echo "=== a config without the keys keeps the defaults ==="

PTC_SOURCE_LOCALE=""; PTC_FILE_TAG_NAME=""; PTC_MONITOR_INTERVAL="5"; PTC_MONITOR_MAX_ATTEMPTS="100"
plain_cfg=$(write_config plain.yml \
    'source_locale: en' \
    'files:' \
    '  - file: locales/en.json' \
    '    output: locales/{{lang}}.json')
parse_config_file "$plain_cfg" >/dev/null 2>&1
assert_eq "interval default intact" "$PTC_MONITOR_INTERVAL" "5"
assert_eq "max_attempts default intact" "$PTC_MONITOR_MAX_ATTEMPTS" "100"

echo
echo "=== --action status: a terminal failure is not exit 0 ==="

PTC_DRY_RUN="false"
PTC_FILE_TAG_NAME="main"
STATUS_VERDICT=3   # terminal failure, per check_translation_status's contract
check_translation_status() { return "$STATUS_VERDICT"; }
get_base_directory() { printf '%s' "$WORK_DIR"; }
get_relative_path() { printf '%s' "locales/en.json"; }

output=$(perform_status_action "$WORK_DIR/locales/en.json" 2>&1)
rc=$?
assert_eq "a terminal failure exits non-zero" "$rc" "1"
assert_contains "the terminal failure is named" "$output" "failed or could not be read"

STATUS_VERDICT=1   # status unreadable
output=$(perform_status_action "$WORK_DIR/locales/en.json" 2>&1)
rc=$?
assert_eq "an unreadable status exits non-zero" "$rc" "1"

STATUS_VERDICT=2   # still translating - a legitimate answer, not a failure
output=$(perform_status_action "$WORK_DIR/locales/en.json" 2>&1)
rc=$?
assert_eq "in-progress still exits zero" "$rc" "0"

STATUS_VERDICT=0   # ready
output=$(perform_status_action "$WORK_DIR/locales/en.json" 2>&1)
rc=$?
assert_eq "ready exits zero" "$rc" "0"

echo
echo "=========================================="
echo "Total:  $test_count"
echo -e "Passed: ${GREEN}${passed_count}${NC}"
echo -e "Failed: ${RED}${failed_count}${NC}"
echo "=========================================="

[[ "$failed_count" -eq 0 ]]
