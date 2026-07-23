#!/bin/bash

# PTC CLI - Private Translation Cloud CLI
# Processes translation files based on language patterns

set -euo pipefail  # Strict mode: exit on errors, undefined variables and pipe errors

# Constants
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.1"
readonly PTC_USER_AGENT="ptc-cli/${VERSION}"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Default variables with PTC_ prefix to avoid conflicts
PTC_SOURCE_LOCALE=""
PTC_PATTERNS=()
PTC_CONFIG_FILE=""
PTC_PROJECT_DIR="$(pwd)"
PTC_FILE_TAG_NAME=""
PTC_API_URL="https://app.ptc.wpml.org/api/v1/"
# The API token is env-first: an inherited PTC_API_TOKEN is honoured across every
# command, and --api-token overrides it. The api_token: config key is deprecated
# and ignored (ci18-7251 §6), so there is nothing else to reconcile — do NOT reset
# this to "", or the translate pipeline would lose the env token.
PTC_API_TOKEN="${PTC_API_TOKEN:-}"
PTC_VERBOSE=false
PTC_DRY_RUN=false
PTC_MONITOR_INTERVAL=5   # seconds between status checks
PTC_MONITOR_MAX_ATTEMPTS=100  # maximum number of status checks
PTC_ACTION=""            # specific action to perform: upload, status, download



# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "$PTC_VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

# All PTC API requests go through this wrapper so every call carries a versioned
# User-Agent (ptc-cli/<VERSION>). It forwards to the real curl - which the test
# suites stub - so the header rides along as an ordinary -H the stubs already skip.
ptc_curl() {
    curl -H "User-Agent: $PTC_USER_AGENT" "$@"
}

# JSON field readers. The API returns compact JSON today, but these tolerate
# pretty-printed output and arbitrary whitespace around the separator so a
# serializer or proxy change cannot silently break status parsing.
# A missing key, or an explicit null, yields an empty string.
json_string_field() {
    local json="$1"
    local key="$2"
    local match
    # ([^"\]|\\.)* keeps backslash-escaped quotes inside the value instead of
    # ending the match at the first one.
    match=$(printf '%s' "$json" | tr '\n' ' ' \
        | grep -Eo "\"${key}\"[[:space:]]*:[[:space:]]*(\"([^\"\\\\]|\\\\.)*\"|null)" \
        | head -n 1) || true
    if [[ -z "$match" ]]; then
        return 0
    fi

    local value
    value=$(printf '%s' "$match" | sed -E "s/^\"${key}\"[[:space:]]*:[[:space:]]*//")

    # Test for JSON null BEFORE unquoting, so that the *string* "null" - which
    # the codebase treats as a real status - does not collapse to empty.
    if [[ "$value" == "null" ]]; then
        return 0
    fi

    printf '%s' "$value" | sed -E 's/^"(.*)"$/\1/'
}

json_number_field() {
    local json="$1"
    local key="$2"
    local match
    match=$(printf '%s' "$json" | tr '\n' ' ' \
        | grep -Eo "\"${key}\"[[:space:]]*:[[:space:]]*-?[0-9]+(\.[0-9]+)?" \
        | head -n 1) || true
    if [[ -n "$match" ]]; then
        printf '%s' "$match" | sed -E "s/^\"${key}\"[[:space:]]*:[[:space:]]*//"
    fi
}

json_bool_field() {
    local json="$1"
    local key="$2"
    local match
    match=$(printf '%s' "$json" | tr '\n' ' ' \
        | grep -Eo "\"${key}\"[[:space:]]*:[[:space:]]*(true|false)" \
        | head -n 1) || true
    if [[ -n "$match" ]]; then
        printf '%s' "$match" | sed -E "s/^\"${key}\"[[:space:]]*:[[:space:]]*//"
    fi
}

# ci18-7342 - a rejected request reaches us in one of two shapes, depending on
# which server build answers:
#
#   older: HTTP 200  + {"success":false,"message":"Unprocessable Entity","code":422,...}
#   newer: HTTP 422  + the same body
#
# Trusting the status alone reads the first shape as success. That is how a
# rejected `process` call used to print "processing started successfully" and
# leave CI green with no translations, and how `download` used to save the JSON
# error body as a .zip and try to unpack it. Production and staging will not
# flip on the same day, so the CLI has to read both the same way - the body is
# the authority when it disagrees with the status.
#
# Returns 0 (true, in shell terms) when the response is a failure.
response_indicates_failure() {
    local http_code="$1" body="${2:-}"

    # Anything outside 2xx is a failure regardless of what the body claims.
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    fi

    # A 2xx that carries an explicit "success": false is the older shape.
    [[ "$(json_bool_field "$body" "success")" == "false" ]]
}

# Human-readable reason for a rejected response, for the log line that follows.
# The API answers with a numeric code array (`"errors":[1]`) and no prose, so
# there is a limit to how specific this can be - surface what there is rather
# than dropping it.
describe_api_failure() {
    local http_code="$1" body="${2:-}"
    local message codes

    message=$(json_string_field "$body" "message")
    codes=$(printf '%s' "$body" | tr '\n' ' ' \
        | grep -Eo '"errors"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
        | head -n 1 | sed -E 's/^"errors"[[:space:]]*:[[:space:]]*//') || true

    local description="HTTP $http_code"
    [[ -n "$message" ]] && description="$description: $message"
    [[ -n "$codes" ]] && description="$description (error codes: $codes)"
    printf '%s' "$description"
}

# Returns a nested object as raw JSON, so a caller can read a field from it
# without colliding with a same-named key elsewhere in the document
# (for example "iso", which appears in both source_language and languages[]).
# Tolerates one level of nesting inside the object; a regex cannot balance
# braces to arbitrary depth, so callers must treat "" as "could not read it"
# rather than as "the key was absent".
json_object_field() {
    local json="$1"
    local key="$2"
    local match
    match=$(printf '%s' "$json" | tr '\n' ' ' \
        | grep -Eo "\"${key}\"[[:space:]]*:[[:space:]]*\{[^{}]*(\{[^{}]*\}[^{}]*)*\}" \
        | head -n 1) || true
    if [[ -n "$match" ]]; then
        printf '%s' "$match" | sed -E "s/^\"${key}\"[[:space:]]*:[[:space:]]*//"
    fi
}

# Reads a response header by name, case-insensitively. Takes the last match so
# that a redirect's earlier header block cannot win.
http_header_value() {
    local header_file="$1"
    local name="$2"
    local match
    match=$(grep -i "^${name}:" "$header_file" 2>/dev/null | tail -n 1) || true
    if [[ -n "$match" ]]; then
        printf '%s' "$match" | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
    fi
}

# Statuses that will never turn into "completed", however long we poll.
# Polling one of these to the attempt limit is what made failures look like
# ~8-minute timeouts. These are the two terminal entries of the server's
# STATUS_PRIORITY list (TranslationMemory::STATUS_PRIORITY =
# failed, out_of_credit, queued, in_progress, completed), and both are reachable
# on /api/v1 - "failed" wins first, since the server reports worst-status-wins.
is_terminal_failure_status() {
    case "$1" in
        failed|out_of_credit)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Decides what a monitoring loop should do with one file's status, and explains
# itself on the way out. Both step-based loops share this so a new status only
# has to be classified once - the two loops previously carried byte-identical
# copies of this logic, which is how the terminal case reached one caller and
# not the other.
# Returns: 0 = ready to download, 1 = give up on this file, 2 = keep polling.
classify_monitored_status() {
    local status="$1"
    local relative_file_path="$2"

    if [[ "$status" == "completed" ]]; then
        return 0
    fi

    if is_terminal_failure_status "$status"; then
        log_error "Translation failed for $relative_file_path (status: $status)"
        return 1
    fi

    case "$status" in
        error|not_found)
            # Could be transient - the status endpoint 404s briefly after
            # processing starts - so keep polling, but say so rather than
            # looking indistinguishable from healthy progress.
            log_warning "Status unavailable for $relative_file_path ($status); will retry"
            ;;
        draft)
            # SourceFile#status reports "draft" when no original file is
            # attached, so nothing will ever translate. Left pollable in case
            # the attachment is still landing, but it must not pass for progress.
            log_warning "No uploaded file behind $relative_file_path (status: draft); will retry"
            ;;
    esac

    return 2
}

# Help function
show_help() {
    local current_branch
    current_branch=$(get_current_branch)
    
    echo -e "$SCRIPT_NAME v$VERSION - Private Translation Cloud CLI

USAGE:
    $SCRIPT_NAME init [OPTIONS]
    $SCRIPT_NAME [OPTIONS] --source-locale LOCALE --patterns PATTERN1,PATTERN2,...
    $SCRIPT_NAME [OPTIONS] --config-file CONFIG.yml
    $SCRIPT_NAME [OPTIONS] --action ACTION_NAME

COMMANDS:
    init                           Scaffold a .ptc-config.yml from your repository
                                   (scans files, calls detect_config, writes config
                                   + a CI snippet). See '$SCRIPT_NAME init --help'.

OPTIONS:
    -s, --source-locale LOCALE     Source language (e.g.: en, de, fr)
    -p, --patterns PATTERNS        File patterns separated by commas (e.g.: '{{lang}}.json')
    -c, --config-file FILE         YAML configuration file with all settings
    -t, --file-tag-name TAG        File tag name/branch name (default: ${GREEN}$current_branch${NC})
    -d, --project-dir DIR          Project directory (default: current)
    --api-url URL                  PTC API base URL (default: https://app.ptc.wpml.org/api/v1/)
    --api-token TOKEN              API token override (prefer the PTC_API_TOKEN env var)
    --monitor-interval SECONDS     Seconds between status checks (default: 5)
    --monitor-max-attempts COUNT   Maximum status check attempts (default: 100)
    --action ACTION                Perform isolated action: upload, status, download
    -v, --verbose                  Verbose output
    -n, --dry-run                  Show what would be done without executing
    -h, --help                     Show this help
    --version                      Show version

PATTERN EXAMPLES:
    'sample-{{lang}}.json'         Finds: sample-en.json, sample-de.json, sample-fr.json
    '{{lang}}/**/*.json'           Finds: en/**/*.json, de/**/*.json
    'locales/{{lang}}/messages.json' Finds: locales/en/messages.json, locales/de/messages.json
    'i18n/{{lang}}/app.properties' Finds: i18n/en/app.properties, i18n/de/app.properties
    'languages/wpsite.pot'        Finds: languages/wpsite.pot (WordPress template)

CONFIG FILE FORMAT:
    YAML configuration with complete settings:
    # config.yml
    source_locale: en
    file_tag_name: main
    api_url: https://app.ptc.wpml.org/api/v1/
    # Do NOT put api_token here - it is deprecated and ignored.
    # Provide the token via the PTC_API_TOKEN environment variable.

    files:
      - file: src/locales/en.json
        output: src/locales/{{lang}}.json
        additional_translation_files:
          - type: mo
            path: dist/{{lang}}.mo
          - type: php
            path: includes/lang-{{lang}}.php
      
      - file: admin/en.json
        output: admin/{{lang}}.json

USAGE EXAMPLES:
    # Scaffold a config for a new project:
    $SCRIPT_NAME init
    $SCRIPT_NAME init --dry-run --verbose

    # Using patterns (automatic file discovery):
    $SCRIPT_NAME -s en -p 'sample-{{lang}}.json'
    $SCRIPT_NAME -s en -p '{{lang}}/**/*.json,{{lang}}.properties' -d /path/to/project
    $SCRIPT_NAME -s en -p 'i18n/{{lang}}/app.json' -t feature-branch --verbose
    $SCRIPT_NAME --source-locale en --patterns 'languages/wpsite.pot' --file-tag-name main --verbose
    
    # Using configuration file:
    $SCRIPT_NAME -c config.yml
    $SCRIPT_NAME --config-file config/translation-config.yml --verbose
    
    # Using isolated actions:
    $SCRIPT_NAME -c config.yml --action upload                   # Only upload files
    $SCRIPT_NAME -c config.yml --action status --verbose         # Check translation status
    $SCRIPT_NAME -c config.yml --action download                 # Download completed translations
"
}

# Version function
show_version() {
    echo "$SCRIPT_NAME v$VERSION"
}

# Function to get current git branch
get_current_branch() {
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main"
    else
        echo "main"
    fi
}

# Function to get base directory (git root or current working directory)
get_base_directory() {
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # Return git repository root
        git rev-parse --show-toplevel 2>/dev/null
    else
        # Return current working directory if not in git
        pwd
    fi
}

# Function to get relative path from base directory
get_relative_path() {
    local absolute_path="$1"
    local base_dir="$2"
    
    # Convert to absolute paths to ensure consistency
    absolute_path=$(cd "$(dirname "$absolute_path")" && pwd)/$(basename "$absolute_path")
    base_dir=$(cd "$base_dir" && pwd)
    
    # Calculate relative path
    local relative_path="${absolute_path#$base_dir/}"
    
    # If the path didn't change, it means the file is not under base_dir
    if [[ "$relative_path" == "$absolute_path" ]]; then
        # Return original path if not under base directory
        echo "$absolute_path"
    else
        echo "$relative_path"
    fi
}

# Argument validation
validate_args() {
    # If config file is specified, parse it first
    if [[ -n "$PTC_CONFIG_FILE" ]]; then
        if [[ ! -f "$PTC_CONFIG_FILE" ]]; then
            log_error "Config file not found: $PTC_CONFIG_FILE"
            return 1
        fi
        
        if ! parse_config_file "$PTC_CONFIG_FILE"; then
            return 1
        fi
    fi

    # Validate action if specified
    if [[ -n "$PTC_ACTION" ]]; then
        case "$PTC_ACTION" in
            upload|status|download)
                log_debug "Valid action specified: $PTC_ACTION"
                ;;
            *)
                log_error "Invalid action: $PTC_ACTION. Valid actions are: upload, status, download"
                return 1
                ;;
        esac
    fi

    if [[ -z "$PTC_SOURCE_LOCALE" ]]; then
        log_error "Source locale not specified (--source-locale)"
        return 1
    fi

    # Check if either patterns or config file are specified
    if [[ ${#PTC_PATTERNS[@]} -eq 0 ]] && [[ -z "$PTC_CONFIG_FILE" ]]; then
        log_error "Either patterns (--patterns) or config file (--config-file) must be specified"
        return 1
    fi

    # If both patterns and config file are specified, it's an error
    if [[ ${#PTC_PATTERNS[@]} -gt 0 ]] && [[ -n "$PTC_CONFIG_FILE" ]]; then
        log_error "Cannot use both --patterns and --config-file options together"
        return 1
    fi

    # Auto-detect git branch if file tag name is not provided
    if [[ -z "$PTC_FILE_TAG_NAME" ]]; then
        PTC_FILE_TAG_NAME=$(get_current_branch)
        log_debug "Auto-detected file tag name from git branch: $PTC_FILE_TAG_NAME"
    fi

    if [[ -z "$PTC_FILE_TAG_NAME" ]]; then
        log_error "File tag name not specified (--file-tag-name) and could not auto-detect git branch"
        return 1
    fi

    if [[ ! -d "$PTC_PROJECT_DIR" ]]; then
        log_error "Project directory does not exist: $PTC_PROJECT_DIR"
        return 1
    fi

    log_debug "Source locale: $PTC_SOURCE_LOCALE"
    if [[ ${#PTC_PATTERNS[@]} -gt 0 ]]; then
        log_debug "Patterns: ${PTC_PATTERNS[*]}"
    fi
    if [[ -n "$PTC_CONFIG_FILE" ]]; then
        log_debug "Config file: $PTC_CONFIG_FILE"
    fi
    log_debug "File tag name: $PTC_FILE_TAG_NAME"
    log_debug "Project directory: $PTC_PROJECT_DIR"
}

# Function to substitute {{lang}} in pattern
substitute_pattern() {
    local pattern="$1"
    local locale="$2"
    echo "${pattern//\{\{lang\}\}/$locale}"
}

# Function to extract additional_translation_files for a specific file from YAML
# Now supports only array format with type and path properties:
# additional_translation_files:
#   - type: mo
#     path: languages/{{lang}}.mo
#   - type: php  
#     path: includes/lang-{{lang}}.php
extract_additional_files() {
    local config_file="$1"
    local target_file="$2"
    
    log_debug "Extracting additional files for: $target_file"
    
    # Find the section for this specific file
    local file_section_start
    file_section_start=$(grep -A999 '^files:' "$config_file" | grep -n "^ *- file: *$target_file" | head -1 | cut -d: -f1)
    
    if [[ -z "$file_section_start" ]]; then
        return 0  # No additional files found
    fi
    
    # Extract the next file section start (or end of file)
    local next_file_line
    next_file_line=$(grep -A999 '^files:' "$config_file" | tail -n +$((file_section_start + 1)) | grep -n "^ *- file:" | head -1 | cut -d: -f1)
    
    local end_line
    if [[ -n "$next_file_line" ]]; then
        end_line=$((file_section_start + next_file_line - 1))
    else
        end_line=$(grep -A999 '^files:' "$config_file" | wc -l | tr -d ' ')
    fi
    
    # Extract the section for this file
    local file_block
    file_block=$(grep -A999 '^files:' "$config_file" | sed -n "${file_section_start},${end_line}p")
    
    # Check if this block has additional_translation_files
    if ! echo "$file_block" | grep -q '^ *additional_translation_files:'; then
        return 0  # No additional files
    fi
    
    # Extract additional files array (new format with type and path)
    local additional_section
    additional_section=$(echo "$file_block" | grep -A50 '^ *additional_translation_files:')
    
    # Extract array items (lines starting with "- type:" or "  type:")
    local array_items
    array_items=$(echo "$additional_section" | grep -A1 '^ *- type:')
    
    if [[ -z "$array_items" ]]; then
        return 0
    fi
    
    # Convert to JSON array format
    local json_objects=()
    local current_type=""
    local current_path=""
    
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            if echo "$line" | grep -q '^ *- type:'; then
                # New array item, save previous if exists
                if [[ -n "$current_type" && -n "$current_path" ]]; then
                    json_objects+=("{\"type\":\"$current_type\",\"path\":\"$current_path\"}")
                fi
                # Extract type
                current_type=$(echo "$line" | sed 's/^[^:]*: *//' | sed 's/^["\s]*//' | sed 's/["\s]*$//')
                current_path=""
            elif echo "$line" | grep -q '^ *path:'; then
                # Extract path
                current_path=$(echo "$line" | sed 's/^[^:]*: *//' | sed 's/^["\s]*//' | sed 's/["\s]*$//')
            fi
        fi
    done <<< "$array_items"
    
    # Add last item if exists
    if [[ -n "$current_type" && -n "$current_path" ]]; then
        json_objects+=("{\"type\":\"$current_type\",\"path\":\"$current_path\"}")
    fi
    
    if [[ ${#json_objects[@]} -gt 0 ]]; then
        local json_array="[$(IFS=','; echo "${json_objects[*]}")]"
        echo "$json_array"
        log_debug "Additional files JSON array: $json_array"
    fi
}

# Function to parse and load configuration from YAML file
parse_config_file() {
    local config_file="$1"
    
    log_debug "Parsing YAML config file: $config_file"
    
    # Load configuration values (CLI args override config file)
    if [[ -z "$PTC_SOURCE_LOCALE" ]]; then
        local config_source_locale
        config_source_locale=$(grep '^source_locale:' "$config_file" 2>/dev/null | sed 's/^source_locale: *//' | sed 's/ *$//')
        if [[ -n "$config_source_locale" ]]; then
            PTC_SOURCE_LOCALE="$config_source_locale"
            log_debug "Loaded source_locale from config: $PTC_SOURCE_LOCALE"
        fi
    fi
    
    if [[ -z "$PTC_FILE_TAG_NAME" ]]; then
        local config_file_tag
        config_file_tag=$(grep '^file_tag_name:' "$config_file" 2>/dev/null | sed 's/^file_tag_name: *//' | sed 's/ *$//')
        if [[ -n "$config_file_tag" ]]; then
            PTC_FILE_TAG_NAME="$config_file_tag"
            log_debug "Loaded file_tag_name from config: $PTC_FILE_TAG_NAME"
        fi
    fi
    
    if [[ "$PTC_API_URL" == "https://app.ptc.wpml.org/api/v1/" ]]; then
        local config_api_url
        config_api_url=$(grep '^api_url:' "$config_file" 2>/dev/null | sed 's/^api_url: *//' | sed 's/ *$//')
        if [[ -n "$config_api_url" ]]; then
            PTC_API_URL="$config_api_url"
            log_debug "Loaded api_url from config: $PTC_API_URL"
        fi
    fi
    
    # ci18-7342 - the README has always documented these two as config keys, but
    # nothing read them: they were flags only. In CI that made the polling
    # ceiling (100 x 5s ~ 8.3 min) unreachable, because the GitHub action and the
    # GitLab component pass neither flag - a big project timed out and, with the
    # old exit handling, still went green. Flags still win over the config.
    if [[ "$PTC_MONITOR_INTERVAL" == "5" ]]; then
        local config_monitor_interval
        config_monitor_interval=$(grep '^monitor_interval:' "$config_file" 2>/dev/null | sed 's/^monitor_interval: *//' | sed 's/ *$//')
        if [[ "$config_monitor_interval" =~ ^[0-9]+$ ]] && [[ "$config_monitor_interval" -gt 0 ]]; then
            PTC_MONITOR_INTERVAL="$config_monitor_interval"
            log_debug "Loaded monitor_interval from config: $PTC_MONITOR_INTERVAL"
        elif [[ -n "$config_monitor_interval" ]]; then
            log_warning "Ignoring invalid 'monitor_interval: $config_monitor_interval' in $config_file (expected a positive integer)."
        fi
    fi

    if [[ "$PTC_MONITOR_MAX_ATTEMPTS" == "100" ]]; then
        local config_monitor_attempts
        config_monitor_attempts=$(grep '^monitor_max_attempts:' "$config_file" 2>/dev/null | sed 's/^monitor_max_attempts: *//' | sed 's/ *$//')
        if [[ "$config_monitor_attempts" =~ ^[0-9]+$ ]] && [[ "$config_monitor_attempts" -gt 0 ]]; then
            PTC_MONITOR_MAX_ATTEMPTS="$config_monitor_attempts"
            log_debug "Loaded monitor_max_attempts from config: $PTC_MONITOR_MAX_ATTEMPTS"
        elif [[ -n "$config_monitor_attempts" ]]; then
            log_warning "Ignoring invalid 'monitor_max_attempts: $config_monitor_attempts' in $config_file (expected a positive integer)."
        fi
    fi

    # The api_token: config key is deprecated (ci18-7251 §6): a token in a
    # committed file is a leak waiting to happen. Warn whenever the key is present
    # (even with an empty value) and ignore it; the token must come from the
    # PTC_API_TOKEN environment variable or --api-token.
    if grep -q '^api_token:' "$config_file" 2>/dev/null; then
        log_warning "Ignoring deprecated 'api_token:' in $config_file. Set the PTC_API_TOKEN environment variable (or pass --api-token) instead."
    fi
    
    # Validate files section exists
    if ! grep -q '^files:' "$config_file" 2>/dev/null; then
        log_error "Missing 'files:' section in config file: $config_file"
        return 1
    fi
    
    # Count file entries
    local files_count
    files_count=$(grep -A999 '^files:' "$config_file" | grep '^ *- file:' | wc -l | tr -d ' ')
    if [[ "$files_count" -eq 0 ]]; then
        log_error "No file entries found in 'files:' section of config file: $config_file"
        return 1
    fi
    
    log_debug "Found $files_count file(s) in config"
    
    # Validate each file entry has required fields
    local file_entries
    file_entries=$(grep -A999 '^files:' "$config_file" | grep '^ *- file:' | sed 's/^ *- file: *//')
    local output_entries
    output_entries=$(grep -A999 '^files:' "$config_file" | grep '^ *output:' | sed 's/^ *output: *//')
    
    local file_count_check
    local output_count_check
    file_count_check=$(echo "$file_entries" | wc -l | tr -d ' ')
    output_count_check=$(echo "$output_entries" | wc -l | tr -d ' ')
    
    if [[ "$file_count_check" -ne "$output_count_check" ]]; then
        log_error "Mismatch between file entries ($file_count_check) and output entries ($output_count_check) in config"
        return 1
    fi
    
    local entry_num=1
    while IFS= read -r file_path && IFS= read -r output_path <&3; do
        if [[ -z "$file_path" ]]; then
            log_error "Empty 'file' field in entry $entry_num"
            return 1
        fi
        
        if [[ -z "$output_path" ]]; then
            log_error "Empty 'output' field in entry $entry_num"
            return 1
        fi
        
        log_debug "Config entry $entry_num: $file_path -> $output_path"
        ((entry_num++))
    done <<< "$file_entries" 3<<< "$output_entries"
    
    return 0
}

# Function to find files by pattern
find_files_by_pattern() {
    local pattern="$1"
    local search_dir="$PTC_PROJECT_DIR"
    
    log_debug "Searching files by pattern: $pattern in $search_dir"
    
    # Check if pattern contains globbing characters
    if [[ "$pattern" == *"*"* ]] || [[ "$pattern" == *"?"* ]]; then
        # Use find with globbing
        find "$search_dir" -path "*/$pattern" -type f 2>/dev/null || true
    else
        # Direct file path
        local full_path="$search_dir/$pattern"
        if [[ -f "$full_path" ]]; then
            echo "$full_path"
        fi
    fi
}

# Main processing function
process_files() {
    local found_files=()
    
    if [[ -n "$PTC_CONFIG_FILE" ]]; then
        # Config file mode: process files from YAML configuration
        log_info "Processing files from config for source locale: $PTC_SOURCE_LOCALE"
        
        # Extract file and output patterns from YAML
        local file_entries
        local output_entries
        file_entries=$(grep -A999 '^files:' "$PTC_CONFIG_FILE" | grep '^ *- file:' | sed 's/^ *- file: *//')
        output_entries=$(grep -A999 '^files:' "$PTC_CONFIG_FILE" | grep '^ *output:' | sed 's/^ *output: *//')
        
        # Process each file from config
        local entry_num=1
        while IFS= read -r file_entry && IFS= read -r output_entry <&3; do
            if [[ -z "$file_entry" ]] || [[ -z "$output_entry" ]]; then
                break
            fi
            
            local file_path="$file_entry"
            local output_pattern="$output_entry"
            
            # Make file path absolute if it's relative
            if [[ "$file_path" != /* ]]; then
                file_path="$PTC_PROJECT_DIR/$file_path"
            fi
            
            if [[ ! -f "$file_path" ]]; then
                log_error "File not found: $file_entry"
                return 1
            fi
            
            found_files+=("$file_path")
            log_success "Found file: $file_entry -> output: $output_pattern"
            
            # Check for additional_translation_files (simplified for now)
            # Look for additional files in the current entry block
            local additional_section_start
            additional_section_start=$(grep -A999 '^files:' "$PTC_CONFIG_FILE" | grep -n "^ *- file: *$file_entry" | head -1 | cut -d: -f1)
            if [[ -n "$additional_section_start" ]]; then
                local additional_files_section
                additional_files_section=$(grep -A999 '^files:' "$PTC_CONFIG_FILE" | sed -n "${additional_section_start},/^ *- file:/p" | grep '^ *additional_translation_files:' -A10 | grep '^ *[a-zA-Z_]*:' | grep -v 'additional_translation_files:')
                if [[ -n "$additional_files_section" ]]; then
                    log_debug "Additional translation files specified for: $file_entry"
                    while IFS= read -r additional_line; do
                        if [[ -n "$additional_line" ]]; then
                            local key=$(echo "$additional_line" | sed 's/^ *//' | sed 's/:.*//')
                            local value=$(echo "$additional_line" | sed 's/^[^:]*: *//')
                            log_debug "  $key: $value"
                        fi
                    done <<< "$additional_files_section"
                fi
            fi
            
            ((entry_num++))
        done <<< "$file_entries" 3<<< "$output_entries"
        
        log_info "Total specified ${#found_files[@]} file(s)"
        
        # Check if specific action is requested
        if [[ -n "$PTC_ACTION" ]]; then
            case "$PTC_ACTION" in
                upload)
                    perform_upload_action_with_config "${found_files[@]}"
                    ;;
                status)
                    perform_status_action "${found_files[@]}"
                    ;;
                download)
                    perform_download_action "${found_files[@]}"
                    ;;
                *)
                    log_error "Invalid action: $PTC_ACTION"
                    return 1
                    ;;
            esac
        else
            # Step-based processing workflow with config file support
            process_files_in_steps_with_config "${found_files[@]}"
        fi
    else
        # Patterns mode: discover files automatically 
        log_info "Starting file search for source locale: $PTC_SOURCE_LOCALE"
        
        for pattern in "${PTC_PATTERNS[@]}"; do
            local substituted_pattern
            substituted_pattern=$(substitute_pattern "$pattern" "$PTC_SOURCE_LOCALE")
            
            log_debug "Processing pattern: $pattern -> $substituted_pattern"
            
            local files=()
            # Use portable way to read files into array (compatible with Bash 3.2+)
            local temp_output
            temp_output=$(find_files_by_pattern "$substituted_pattern")
            if [[ -n "$temp_output" ]]; then
                while IFS= read -r file; do
                    if [[ -n "$file" ]]; then
                        files+=("$file")
                    fi
                done <<< "$temp_output"
            fi
            
            if [[ ${#files[@]} -eq 0 ]]; then
                log_warning "No files found for pattern: $substituted_pattern"
            else
                found_files+=("${files[@]}")
                log_success "Found ${#files[@]} file(s) for pattern: $substituted_pattern"
                
                if [[ "$PTC_VERBOSE" == "true" ]]; then
                    for file in "${files[@]}"; do
                        log_debug "  - $file"
                    done
                fi
            fi
        done
        
        if [[ ${#found_files[@]} -eq 0 ]]; then
            log_error "No files found"
            return 1
        fi
        
        log_info "Total found ${#found_files[@]} file(s)"
        
        # Check if specific action is requested
        if [[ -n "$PTC_ACTION" ]]; then
            case "$PTC_ACTION" in
                upload)
                    perform_upload_action "${found_files[@]}"
                    ;;
                status)
                    perform_status_action "${found_files[@]}"
                    ;;
                download)
                    perform_download_action "${found_files[@]}"
                    ;;
                *)
                    log_error "Invalid action: $PTC_ACTION"
                    return 1
                    ;;
            esac
        else
            # Step-based processing workflow
            process_files_in_steps "${found_files[@]}"
        fi
    fi
}

# Function to perform only upload action
perform_upload_action() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local uploaded_files=()
    
    log_info "=== UPLOAD ACTION: Uploading all files ==="
    for file in "${files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would upload file: $relative_file_path"
            uploaded_files+=("$file")
        else
            log_info "Uploading file: $relative_file_path"
            
            # Prepare API call parameters
            local filename=$(basename "$relative_file_path")
            local dirname=$(dirname "$relative_file_path")
            local lang_placeholder="{{lang}}"
            local output_filename="${filename//$PTC_SOURCE_LOCALE/$lang_placeholder}"
            
            local output_file_path
            if [[ "$dirname" == "." ]]; then
                output_file_path="$output_filename"
            else
                output_file_path="$dirname/$output_filename"
            fi
            
            # Extract additional_translation_files if using config file
            local additional_files_json=""
            if [[ -n "$PTC_CONFIG_FILE" ]]; then
                additional_files_json=$(extract_additional_files "$PTC_CONFIG_FILE" "$relative_file_path")
            fi
            
            if make_ptc_api_call "$file" "$relative_file_path" "$output_file_path" "$PTC_FILE_TAG_NAME" "$additional_files_json"; then
                uploaded_files+=("$file")
                log_success "Upload completed: $relative_file_path"
            else
                log_error "Upload failed: $relative_file_path"
            fi
        fi
    done
    
    if [[ ${#uploaded_files[@]} -eq 0 ]]; then
        log_error "No files were uploaded successfully"
        return 1
    fi
    
    log_success "Successfully uploaded ${#uploaded_files[@]} file(s)"
    return 0
}

# Function to perform only upload action with config file support
perform_upload_action_with_config() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local uploaded_files=()
    
    log_info "=== UPLOAD ACTION: Uploading all files ==="
    for file in "${files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would upload file: $relative_file_path"
            uploaded_files+=("$file")
        else
            log_info "Uploading file: $relative_file_path"
            
            # Get output pattern from config for this file
            local output_pattern
            output_pattern=$(grep -A999 '^files:' "$PTC_CONFIG_FILE" | grep -A1 "^ *- file: *$relative_file_path" | grep '^ *output:' | sed 's/^ *output: *//' | head -1)
            
            if [[ -z "$output_pattern" ]]; then
                # Fallback: generate output pattern automatically
                local filename=$(basename "$relative_file_path")
                local dirname=$(dirname "$relative_file_path")
                local lang_placeholder="{{lang}}"
                local output_filename="${filename//$PTC_SOURCE_LOCALE/$lang_placeholder}"
                
                if [[ "$dirname" == "." ]]; then
                    output_pattern="$output_filename"
                else
                    output_pattern="$dirname/$output_filename"
                fi
                log_debug "Using generated output pattern: $output_pattern"
            else
                log_debug "Using config output pattern: $output_pattern"
            fi
            
            # Extract additional_translation_files for this file
            local additional_files_json=""
            additional_files_json=$(extract_additional_files "$PTC_CONFIG_FILE" "$relative_file_path")
            
            if make_ptc_api_call "$file" "$relative_file_path" "$output_pattern" "$PTC_FILE_TAG_NAME" "$additional_files_json"; then
                uploaded_files+=("$file")
                log_success "Upload completed: $relative_file_path"
            else
                log_error "Upload failed: $relative_file_path"
            fi
        fi
    done
    
    if [[ ${#uploaded_files[@]} -eq 0 ]]; then
        log_error "No files were uploaded successfully"
        return 1
    fi
    
    log_success "Successfully uploaded ${#uploaded_files[@]} file(s)"
    return 0
}

# Function to perform only status check action
perform_status_action() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local checked_files=()
    local problem_files=()
    
    log_info "=== STATUS ACTION: Checking translation status for all files ==="
    for file in "${files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would check status for file: $relative_file_path"
            checked_files+=("$file")
        else
            log_info "Checking status for file: $relative_file_path"
            
            if check_translation_status "$relative_file_path" "$PTC_FILE_TAG_NAME"; then
                log_success "Status check completed: $relative_file_path (Ready for download)"
                checked_files+=("$file")
            else
                local status_result=$?
                if [[ $status_result -eq 1 ]]; then
                    log_warning "Status check failed or no translations found: $relative_file_path"
                    problem_files+=("$file")
                elif [[ $status_result -eq 2 ]]; then
                    log_info "Translation still in progress: $relative_file_path"
                elif [[ $status_result -eq 3 ]]; then
                    log_error "Translation failed and will not complete: $relative_file_path"
                    problem_files+=("$file")
                fi
                checked_files+=("$file")
            fi
        fi
    done

    log_info "Status check completed for ${#checked_files[@]} file(s)"

    # ci18-7342 - "still in progress" is a legitimate answer and stays exit 0,
    # but a terminal failure or an unreadable status must not. This used to
    # return 0 unconditionally, so a gate built on `--action status` passed
    # even when the translation had definitively failed.
    if [[ ${#problem_files[@]} -gt 0 ]]; then
        log_error "Status check found ${#problem_files[@]} file(s) that failed or could not be read"
        return 1
    fi

    return 0
}

# Function to perform only download action
perform_download_action() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local downloaded_files=()
    local failed_files=()
    
    log_info "=== DOWNLOAD ACTION: Downloading completed translations for all files ==="
    for file in "${files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would download translations for file: $relative_file_path"
            downloaded_files+=("$file")
        else
            log_info "Downloading translations for file: $relative_file_path"
            
            # First check if translations are ready
            if check_translation_status "$relative_file_path" "$PTC_FILE_TAG_NAME" >/dev/null 2>&1; then
                # Translations are ready, download them
                if download_translations "$relative_file_path" "$PTC_FILE_TAG_NAME" "$base_dir"; then
                    downloaded_files+=("$file")
                    log_success "Download completed: $relative_file_path"
                else
                    failed_files+=("$file")
                    log_error "Download failed: $relative_file_path"
                fi
            else
                local status_result=$?
                if [[ $status_result -eq 1 ]]; then
                    log_warning "No translations found or error occurred: $relative_file_path"
                    failed_files+=("$file")
                elif [[ $status_result -eq 2 ]]; then
                    log_warning "Translations not ready yet: $relative_file_path"
                    failed_files+=("$file")
                elif [[ $status_result -eq 3 ]]; then
                    log_error "Translation failed and will not complete: $relative_file_path"
                    failed_files+=("$file")
                else
                    # Never silently drop a file: an unexpected code must still
                    # land in a result list, or the run reports success for it.
                    log_error "Unexpected status code $status_result for: $relative_file_path"
                    failed_files+=("$file")
                fi
            fi
        fi
    done
    
    log_info "=== DOWNLOAD RESULTS ==="
    if [[ ${#downloaded_files[@]} -gt 0 ]]; then
        log_success "Successfully downloaded ${#downloaded_files[@]} file(s)"
        for file in "${downloaded_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_success "  ✓ $relative_file_path"
        done
    fi
    
    if [[ ${#failed_files[@]} -gt 0 ]]; then
        log_warning "Failed to download ${#failed_files[@]} file(s)"
        for file in "${failed_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_warning "  ✗ $relative_file_path"
        done
    fi
    
    # Return success if at least one file was downloaded successfully
    if [[ ${#downloaded_files[@]} -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Function to process files in steps (upload all, process all, monitor all)
process_files_in_steps() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local uploaded_files=()
    local processed_files=()
    
    # Step 1: Upload all files
    log_info "=== STEP 1: Uploading all files ==="
    for file in "${files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would upload file: $relative_file_path"
            uploaded_files+=("$file")
        else
            log_info "Uploading file: $relative_file_path"
            
            # Prepare API call parameters
            local filename=$(basename "$relative_file_path")
            local dirname=$(dirname "$relative_file_path")
            local lang_placeholder="{{lang}}"
            local output_filename="${filename//$PTC_SOURCE_LOCALE/$lang_placeholder}"
            
            local output_file_path
            if [[ "$dirname" == "." ]]; then
                output_file_path="$output_filename"
            else
                output_file_path="$dirname/$output_filename"
            fi
            
            # Extract additional_translation_files if using config file
            local additional_files_json=""
            if [[ -n "$PTC_CONFIG_FILE" ]]; then
                additional_files_json=$(extract_additional_files "$PTC_CONFIG_FILE" "$relative_file_path")
            fi
            
            if make_ptc_api_call "$file" "$relative_file_path" "$output_file_path" "$PTC_FILE_TAG_NAME" "$additional_files_json"; then
                uploaded_files+=("$file")
                log_success "Upload completed: $relative_file_path"
            else
                log_error "Upload failed: $relative_file_path"
            fi
        fi
    done
    
    if [[ ${#uploaded_files[@]} -eq 0 ]]; then
        log_error "No files were uploaded successfully"
        return 1
    fi
    
    log_info "Successfully uploaded ${#uploaded_files[@]} file(s)"
    
    # Step 2: Start processing for all uploaded files
    log_info "=== STEP 2: Starting processing for all uploaded files ==="
    for file in "${uploaded_files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would start processing: $relative_file_path"
            processed_files+=("$file")
        else
            log_info "Starting processing: $relative_file_path"
            
            if start_processing "$file" "$relative_file_path" "$PTC_FILE_TAG_NAME"; then
                processed_files+=("$file")
                log_success "Processing started: $relative_file_path"
            else
                log_error "Failed to start processing: $relative_file_path"
            fi
        fi
    done
    
    if [[ ${#processed_files[@]} -eq 0 ]]; then
        log_error "No files started processing successfully"
        return 1
    fi
    
    log_info "Successfully started processing for ${#processed_files[@]} file(s)"
    
    # Step 3: Monitor and download all processed files
    log_info "=== STEP 3: Monitoring and downloading translations ==="
    
    if [[ "$PTC_DRY_RUN" == "true" ]]; then
        for file in "${processed_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_info "[DRY RUN] Would monitor and download: $relative_file_path"
        done
        log_success "[DRY RUN] All files would be processed successfully"
        return 0
    fi
    
    # Monitor all files in parallel-like fashion (check each file in rounds)
    local completed_files=()
    local failed_files=()
    local monitoring_files=()
    
    # Initialize monitoring list and file statuses
    for file in "${processed_files[@]}"; do
        monitoring_files+=("$file")
    done
    
    # Create arrays to track file statuses (compatible with older bash)
    local file_status_keys=()
    local file_status_values=()
    for file in "${processed_files[@]}"; do
        file_status_keys+=("$file")
        file_status_values+=("unknown")
    done
    
    local round=1
    echo -e "\n${BLUE}[INFO]${NC} Starting translation monitoring..."
    
    while [[ ${#monitoring_files[@]} -gt 0 && $round -le $PTC_MONITOR_MAX_ATTEMPTS ]]; do
        local still_monitoring=()
        
        for file in "${monitoring_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            
            # Check status quietly
            local status_output
            status_output=$(get_translation_status_quiet "$relative_file_path" "$PTC_FILE_TAG_NAME")
            local status_result=$?
            
            if [[ $status_result -eq 0 ]]; then
                # Translation completed, download it
                set_file_status "$file" "completed"
                # ci18-7342 - 2 means the archive is not ready yet (HTTP 202);
                # keep the file in the loop rather than failing it. Same
                # handling as the config path.
                local download_result=0
                download_translations "$relative_file_path" "$PTC_FILE_TAG_NAME" "$base_dir" >/dev/null 2>&1 || download_result=$?

                case $download_result in
                    0) completed_files+=("$file") ;;
                    2) still_monitoring+=("$file"); set_file_status "$file" "processing" ;;
                    *) failed_files+=("$file"); set_file_status "$file" "failed" ;;
                esac
            elif [[ $status_result -eq 1 ]]; then
                # Error occurred
                failed_files+=("$file")
                set_file_status "$file" "failed"
            elif [[ $status_result -eq 3 ]]; then
                # Terminal failure - stop polling this file, it cannot recover
                local terminal_status=$(echo "$status_output" | cut -d'|' -f1)
                log_error "Translation failed for $relative_file_path (status: $terminal_status)"
                failed_files+=("$file")
                set_file_status "$file" "$terminal_status"
            elif [[ $status_result -eq 2 ]]; then
                # Still in progress - extract actual status
                local actual_status=$(echo "$status_output" | cut -d'|' -f1)
                if [[ -z "$actual_status" || "$actual_status" == "null" ]]; then
                    actual_status="status_unknown"
                fi
                set_file_status "$file" "$actual_status"
                still_monitoring+=("$file")
            fi
        done
        
        # Build status string
        local status_string=""
        for file in "${processed_files[@]}"; do
            local file_status
            file_status=$(get_file_status "$file")
            local status_char
            status_char=$(get_status_char "$file_status")
            status_string="${status_string}${status_char}"
        done
        
        # Display compact status
        display_file_status "${#completed_files[@]}" "${#processed_files[@]}" "$round" "$PTC_MONITOR_MAX_ATTEMPTS" "$status_string"
        
        if [[ ${#still_monitoring[@]} -gt 0 ]]; then
            monitoring_files=("${still_monitoring[@]}")
        else
            monitoring_files=()
        fi
        
        if [[ ${#monitoring_files[@]} -gt 0 ]]; then
            if [[ $round -lt $PTC_MONITOR_MAX_ATTEMPTS ]]; then
                sleep "$PTC_MONITOR_INTERVAL"
            fi
        fi
        
        ((round++))
    done
    
    # Final newline after compact status
    echo
    
    # Report final results
    log_info "=== FINAL RESULTS ==="
    log_success "Completed files: ${#completed_files[@]}"
    if [[ ${#completed_files[@]} -gt 0 ]]; then
        for file in "${completed_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_success "  ✓ $relative_file_path"
        done
    fi
    
    if [[ ${#failed_files[@]} -gt 0 ]]; then
        log_error "Failed files: ${#failed_files[@]}"
        for file in "${failed_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_error "  ✗ $relative_file_path"
        done
    fi
    
    if [[ ${#monitoring_files[@]} -gt 0 ]]; then
        log_warning "Timed out files: ${#monitoring_files[@]}"
        for file in "${monitoring_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_warning "  ⏱ $relative_file_path"
            log_info "  You can check status manually with:"
            log_info "    curl -H \"Authorization: Bearer \$TOKEN\" \"${PTC_API_URL}source_files/translation_status?file_path=$relative_file_path&file_tag_name=$PTC_FILE_TAG_NAME\""
        done
    fi
    
    # ci18-7342 - a partial run is not a success. This used to return 0 as soon
    # as ONE file completed, so nine failures out of ten still exited green and
    # the pipeline reported a translation run that never happened. Anything
    # failed or still unfinished is a non-zero exit; CI decides what to do with
    # it. Exit codes are documented in the README under "Exit codes".
    if [[ ${#failed_files[@]} -gt 0 || ${#monitoring_files[@]} -gt 0 ]]; then
        log_error "Run incomplete: ${#completed_files[@]} completed, ${#failed_files[@]} failed, ${#monitoring_files[@]} unfinished"
        return 1
    fi

    if [[ ${#completed_files[@]} -gt 0 ]]; then
        log_success "Step-based processing completed successfully"
        return 0
    fi

    log_error "No files completed successfully"
    return 1
}

# Function to process files in steps with config file support (for --config-file mode)
process_files_in_steps_with_config() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local uploaded_files=()
    local processed_files=()
    
    # Step 1: Upload all files
    log_info "=== STEP 1: Uploading all files ==="
    for file in "${files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would upload file: $relative_file_path"
            uploaded_files+=("$file")
        else
            log_info "Uploading file: $relative_file_path"
            
            # Get output pattern from config for this file
            local output_pattern
            # Use full relative path to match YAML config
            output_pattern=$(grep -A999 '^files:' "$PTC_CONFIG_FILE" | grep -A1 "^ *- file: *$relative_file_path" | grep '^ *output:' | sed 's/^ *output: *//' | head -1)
            
            if [[ -z "$output_pattern" ]]; then
                # Fallback: generate output pattern automatically
                local filename=$(basename "$relative_file_path")
                local dirname=$(dirname "$relative_file_path")
                local lang_placeholder="{{lang}}"
                local output_filename="${filename//$PTC_SOURCE_LOCALE/$lang_placeholder}"
                
                if [[ "$dirname" == "." ]]; then
                    output_pattern="$output_filename"
                else
                    output_pattern="$dirname/$output_filename"
                fi
                log_debug "Using generated output pattern: $output_pattern"
            else
                log_debug "Using config output pattern: $output_pattern"
            fi
            
            # Extract additional_translation_files for this file
            local additional_files_json=""
            additional_files_json=$(extract_additional_files "$PTC_CONFIG_FILE" "$relative_file_path")
            
            if make_ptc_api_call "$file" "$relative_file_path" "$output_pattern" "$PTC_FILE_TAG_NAME" "$additional_files_json"; then
                uploaded_files+=("$file")
                log_success "Upload completed: $relative_file_path"
            else
                log_error "Upload failed: $relative_file_path"
            fi
        fi
    done
    
    if [[ ${#uploaded_files[@]} -eq 0 ]]; then
        log_error "No files were uploaded successfully"
        return 1
    fi
    
    log_info "Successfully uploaded ${#uploaded_files[@]} file(s)"
    
    # Step 2: Start processing for all uploaded files
    log_info "=== STEP 2: Starting processing for all uploaded files ==="
    for file in "${uploaded_files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would start processing: $relative_file_path"
            processed_files+=("$file")
        else
            log_info "Starting processing: $relative_file_path"
            
            if start_processing "$file" "$relative_file_path" "$PTC_FILE_TAG_NAME"; then
                processed_files+=("$file")
                log_success "Processing started: $relative_file_path"
            else
                log_error "Processing failed to start: $relative_file_path"
            fi
        fi
    done
    
    if [[ ${#processed_files[@]} -eq 0 ]]; then
        log_error "No files were processed successfully"
        return 1
    fi
    
    log_info "Successfully started processing for ${#processed_files[@]} file(s)"
    
    # Step 3: Monitor and download all processed files
    log_info "=== STEP 3: Monitoring and downloading translations ==="
    
    if [[ "$PTC_DRY_RUN" == "true" ]]; then
        for file in "${processed_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_info "[DRY RUN] Would monitor and download: $relative_file_path"
        done
        log_success "Step-based processing completed successfully"
        return 0
    fi
    
    # Initialize file status tracking
    local file_status_keys=()
    local file_status_values=()
    local monitoring_files=("${processed_files[@]}")
    local completed_files=()
    local failed_files=()
    local round=1
    
    # Initialize all files as unknown status
    for file in "${monitoring_files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        set_file_status "$relative_file_path" "unknown"
    done
    
    log_info ""
    log_info "Starting translation monitoring..."
    
    # Monitoring loop
    while [[ ${#monitoring_files[@]} -gt 0 ]] && [[ $round -le $PTC_MONITOR_MAX_ATTEMPTS ]]; do
        local still_monitoring=()
        
        for file in "${monitoring_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            
            # Get current status
            local status_output
            status_output=$(get_translation_status_quiet "$relative_file_path" "$PTC_FILE_TAG_NAME")
            local status=$(echo "$status_output" | cut -d'|' -f1)
            set_file_status "$relative_file_path" "$status"
            
            local file_action=0
            classify_monitored_status "$status" "$relative_file_path" || file_action=$?

            case $file_action in
                0)
                    # ci18-7342 - a file counts as completed only once its
                    # translations are actually on disk. This used to add it to
                    # completed_files BEFORE downloading and downgrade a failed
                    # download to a warning, so a run that fetched nothing still
                    # ended "completed successfully" with exit 0.
                    #
                    # 2 means the archive is not ready yet (HTTP 202) - keep
                    # polling rather than deciding either way. translation_status
                    # routinely reports a file ready a moment before its archive
                    # is, so treating that as failure would fail healthy runs.
                    local download_result=0
                    download_translations "$relative_file_path" "$PTC_FILE_TAG_NAME" "$base_dir" || download_result=$?

                    case $download_result in
                        0)
                            log_debug "Downloaded translations for: $relative_file_path"
                            completed_files+=("$file")
                            ;;
                        2)
                            still_monitoring+=("$file")
                            ;;
                        *)
                            log_warning "Failed to download translations for: $relative_file_path"
                            failed_files+=("$file")
                            ;;
                    esac
                    ;;
                1)
                    failed_files+=("$file")
                    ;;
                *)
                    still_monitoring+=("$file")
                    ;;
            esac
        done
        
        # Build status string
        local status_string=""
        for file in "${monitoring_files[@]}"; do
            local relative_file_path_status=$(get_relative_path "$file" "$base_dir")
            local file_status
            file_status=$(get_file_status "$relative_file_path_status")
            local status_char
            status_char=$(get_status_char "$file_status")
            status_string="${status_string}${status_char}"
        done
        
        # Display compact status
        display_file_status "${#completed_files[@]}" "${#monitoring_files[@]}" "$round" "$PTC_MONITOR_MAX_ATTEMPTS" "$status_string"
        
        # Update monitoring array for next round
        if [[ ${#still_monitoring[@]} -gt 0 ]]; then
            monitoring_files=("${still_monitoring[@]}")
        else
            monitoring_files=()
        fi
        
        # Wait before next round if files are still being monitored
        if [[ ${#monitoring_files[@]} -gt 0 ]] && [[ $round -lt $PTC_MONITOR_MAX_ATTEMPTS ]]; then
            sleep "$PTC_MONITOR_INTERVAL"
        fi
        
        ((round++))
    done
    
    # Final newline after compact status
    echo
    
    # Report final results
    log_info "=== FINAL RESULTS ==="
    log_success "Completed files: ${#completed_files[@]}"
    if [[ ${#completed_files[@]} -gt 0 ]]; then
        for file in "${completed_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_success "  ✓ $relative_file_path"
        done
    fi
    
    if [[ ${#failed_files[@]} -gt 0 ]]; then
        log_error "Failed files: ${#failed_files[@]}"
        for file in "${failed_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_error "  ✗ $relative_file_path"
        done
    fi
    
    if [[ ${#monitoring_files[@]} -gt 0 ]]; then
        log_warning "Timed out files: ${#monitoring_files[@]}"
        for file in "${monitoring_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_warning "  ⏱ $relative_file_path"
            log_info "  You can check status manually with:"
            log_info "    curl -H \"Authorization: Bearer \$TOKEN\" \"${PTC_API_URL}source_files/translation_status?file_path=$relative_file_path&file_tag_name=$PTC_FILE_TAG_NAME\""
        done
    fi
    
    # ci18-7342 - a partial run is not a success. This used to return 0 as soon
    # as ONE file completed, so nine failures out of ten still exited green and
    # the pipeline reported a translation run that never happened. Anything
    # failed or still unfinished is a non-zero exit; CI decides what to do with
    # it. Exit codes are documented in the README under "Exit codes".
    if [[ ${#failed_files[@]} -gt 0 || ${#monitoring_files[@]} -gt 0 ]]; then
        log_error "Run incomplete: ${#completed_files[@]} completed, ${#failed_files[@]} failed, ${#monitoring_files[@]} unfinished"
        return 1
    fi

    if [[ ${#completed_files[@]} -gt 0 ]]; then
        log_success "Step-based processing completed successfully"
        return 0
    fi

    log_error "No files completed successfully"
    return 1
}

# Validates the token and reports account state before any work starts, so the
# run fails in seconds with a specific reason instead of surfacing as a late,
# generic upload error. Both endpoints used here sit outside the rate limiter
# and the subscription gate, so they still answer when the account is in a bad
# state - which is exactly when this needs to work.
#
# Aborts ONLY where the server has definitively said the run cannot work: no
# token, a rejected token, or an inactive subscription. Everything else - an
# unreachable API, a 5xx, a zero balance, a locale mismatch - warns and lets the
# run proceed. Preflight adds a network call to a path that previously had none,
# so a false abort here would break CI runs that used to succeed; the upload and
# status calls still report their own failures.
preflight_check() {
    if [[ -z "$PTC_API_TOKEN" ]]; then
        log_error "Preflight failed: no API token provided."
        log_info "Set the PTC_API_TOKEN environment variable."
        return 1
    fi

    local header_file
    header_file=$(mktemp)

    local response http_code body
    response=$(ptc_curl -s -D "$header_file" -w "%{http_code}" \
        -X GET \
        -H "Authorization: Bearer $PTC_API_TOKEN" \
        "${PTC_API_URL}languages" 2>/dev/null) || true
    http_code="${response: -3}"
    body="${response%???}"

    log_debug "Preflight: GET ${PTC_API_URL}languages -> HTTP $http_code"
    log_debug "Preflight languages body: $body"

    case "$http_code" in
        200)
            ;;
        401)
            rm -f "$header_file"
            log_error "Preflight failed: PTC rejected the API token (HTTP 401)."
            log_info "The token is unknown or past its expiration date. Generate a new one in PTC."
            return 1
            ;;
        *)
            # Anything else - 5xx, a proxy hiccup, 429, or curl failing outright
            # - is not proof that the run cannot work. Preflight is a new call on
            # a path that used to have none, so it must not become a fresh single
            # point of failure: warn and let the real work report its own errors.
            rm -f "$header_file"
            log_warning "Preflight: could not reach the PTC API (HTTP ${http_code:-none}); continuing."
            log_info "Endpoint: ${PTC_API_URL}languages"
            if [[ -n "$body" ]]; then
                log_info "Server said: $body"
            fi
            return 0
            ;;
    esac

    # The balance headers ride on every api/v1 response, so the languages call
    # above already carries them - no separate request needed for the numbers.
    local trial_balance prepaid_balance
    trial_balance=$(http_header_value "$header_file" "X-PTC-TRIAL-BALANCE")
    prepaid_balance=$(http_header_value "$header_file" "X-PTC-PREPAID-BALANCE")
    rm -f "$header_file"

    # Source locale check. The server translates from the project's configured
    # source language regardless of what this run claims, so a mismatch means
    # the wrong files are about to be uploaded.
    local project_source
    project_source=$(json_string_field "$(json_object_field "$body" "source_language")" "iso")

    if [[ -n "$PTC_SOURCE_LOCALE" && -n "$project_source" && "$PTC_SOURCE_LOCALE" != "$project_source" ]]; then
        log_warning "Source locale mismatch: this run uses '$PTC_SOURCE_LOCALE', but the PTC project's source language is '$project_source'."
        log_warning "PTC will treat uploaded files as '$project_source'."
    fi

    # Plan and active state come from /balance.
    # plan/active must be initialised: on bash 4.4+ a bare `local x` leaves the
    # variable unset, and reading it under `set -u` is fatal - not catchable by
    # the `if ! preflight_check` at the call site. (bash 3.2 yields "" instead,
    # so this cannot be reproduced on macOS.)
    local plan_response plan_code plan_body
    local plan=""
    local active=""
    local sub_status=""
    plan_response=$(ptc_curl -s -w "%{http_code}" \
        -X GET \
        -H "Authorization: Bearer $PTC_API_TOKEN" \
        "${PTC_API_URL}balance" 2>/dev/null) || true
    plan_code="${plan_response: -3}"
    plan_body="${plan_response%???}"

    log_debug "Preflight: GET ${PTC_API_URL}balance -> HTTP $plan_code"
    log_debug "Preflight balance body: $plan_body"

    if [[ "$plan_code" == "200" ]]; then
        plan=$(json_string_field "$plan_body" "plan")
        active=$(json_bool_field "$plan_body" "active")
        sub_status=$(json_string_field "$plan_body" "status")

        if [[ "$active" == "false" ]]; then
            log_error "Preflight failed: the PTC subscription is not active (plan: ${plan:-unknown})."
            log_info "Uploads will be rejected until the subscription is renewed."
            return 1
        fi
    else
        # Not fatal: the plan lookup is a nicety, the token is already proven.
        log_warning "Preflight: could not read the subscription plan (HTTP $plan_code); continuing."
    fi

    # Which wallet pays depends on the plan, so report the relevant one.
    local balance_note
    if [[ "$sub_status" == "unlimited" ]]; then
        # An unlimited subscription reports 0 in both wallets because it does
        # not draw on them at all. Warning about a zero here would cry wolf on
        # every run of a perfectly healthy account. (Confirmed against
        # production: plan=pro, status=unlimited, active=true, both wallets 0.)
        balance_note="unlimited"
    elif [[ "$plan" == "trial" ]]; then
        balance_note="${trial_balance:-unknown} trial words"
        if [[ "$trial_balance" == "0" ]]; then
            log_warning "Trial word balance is 0 - translations will not be produced until it is topped up."
        fi
    elif [[ -n "$plan" ]]; then
        balance_note="${prepaid_balance:-unknown} prepaid words"
        if [[ "$prepaid_balance" == "0" ]]; then
            log_warning "Prepaid word balance is 0 - translations will not be produced until it is topped up."
        fi
    else
        # Plan unknown, so report both wallets rather than guessing which one
        # pays - and stay quiet about a zero in a wallet that may be unused.
        balance_note="${trial_balance:-unknown} trial / ${prepaid_balance:-unknown} prepaid words"
    fi

    log_success "Preflight OK: source=${project_source:-unknown}, plan=${plan:-unknown}, balance=${balance_note}"
    return 0
}

# Function to make API call to PTC
make_ptc_api_call() {
    local absolute_file_path="$1"  # Absolute path for file access
    local relative_file_path="$2"  # Relative path for API
    local output_file_path="$3"    # Relative output path for API
    local file_tag_name="$4"
    local additional_files_json="$5"  # Optional: JSON string for additional_translation_files
    
    # Check if file exists
    if [[ ! -f "$absolute_file_path" ]]; then
        log_error "File not found: $absolute_file_path"
        return 1
    fi
    
    # PTC API endpoint
    local api_url="${PTC_API_URL}source_files"
    
    if [[ "$PTC_VERBOSE" == "true" ]]; then
        log_info "=== API REQUEST DETAILS ==="
        log_info "Uploading file: $relative_file_path"
        log_info "API endpoint: $api_url"
        log_info "Output pattern: $output_file_path"
        log_info "File tag: $file_tag_name"
        if [[ -n "$additional_files_json" ]]; then
            log_info "Additional translation files JSON:"
            log_info "$additional_files_json"
        else
            log_info "No additional translation files specified"
        fi
        log_info "=========================="
    fi
    
    log_debug "Uploading file to PTC API: $api_url"
    
    # Prepare headers for authentication
    local auth_header=""
    if [[ -n "$PTC_API_TOKEN" ]]; then
        auth_header="-H \"Authorization: Bearer $PTC_API_TOKEN\""
        log_debug "Using API token for authentication"
    else
        log_warning "No API token provided, request may fail"
    fi
    
    # Prepare additional curl parameters
    local additional_curl_params=""
    if [[ -n "$additional_files_json" ]]; then
        additional_curl_params="-F \"additional_translation_files=$additional_files_json\""
        log_debug "Including additional_translation_files: $additional_files_json"
    fi

    # Make multipart/form-data request using curl
    local response
    if [[ -n "$PTC_API_TOKEN" ]]; then
        if [[ -n "$additional_files_json" ]]; then
            # When additional_files are specified, send as JSON instead of form-data
            if [[ "$PTC_VERBOSE" == "true" ]]; then
                log_info "Executing JSON request with additional files..."
                log_info "Additional files: $additional_files_json"
            fi
            
            # Create JSON payload (no file content needed)
            local json_payload
            json_payload=$(cat << EOF
{
    "file_path": "$relative_file_path",
    "output_file_path": "$output_file_path", 
    "file_tag_name": "$file_tag_name",
    "additional_translation_files": $additional_files_json
}
EOF
)
            
            if [[ "$PTC_VERBOSE" == "true" ]]; then
                log_info "Sending JSON payload:"
                echo "$json_payload"
                log_info "curl -X POST \\"
                log_info "  -H \"Authorization: Bearer [TOKEN]\" \\"
                log_info "  -H \"Content-Type: application/json\" \\"
                log_info "  -d '[JSON_PAYLOAD]' \\"
                log_info "  \"$api_url\""
            fi
            
            response=$(ptc_curl -s -w "%{http_code}" \
                -X POST \
                -H "Authorization: Bearer $PTC_API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$json_payload" \
                "$api_url" 2>/dev/null)
        else
            if [[ "$PTC_VERBOSE" == "true" ]]; then
                log_info "Executing curl command without additional files..."
                log_info "curl -X POST \\"
                log_info "  -H \"Authorization: Bearer [TOKEN]\" \\"
                log_info "  -F \"file_path=$relative_file_path\" \\"
                log_info "  -F \"output_file_path=$output_file_path\" \\"
                log_info "  -F \"file_tag_name=$file_tag_name\" \\"
                log_info "  -F \"file=@$absolute_file_path\" \\"
                log_info "  \"$api_url\""
            fi
            response=$(ptc_curl -s -w "%{http_code}" \
                -X POST \
                -H "Authorization: Bearer $PTC_API_TOKEN" \
                -F "file_path=$relative_file_path" \
                -F "output_file_path=$output_file_path" \
                -F "file_tag_name=$file_tag_name" \
                -F "file=@$absolute_file_path" \
                "$api_url" 2>/dev/null)
        fi
    else
        if [[ -n "$additional_files_json" ]]; then
            # When additional_files are specified, send as JSON instead of form-data
            local json_payload
            json_payload=$(cat << EOF
{
    "file_path": "$relative_file_path",
    "output_file_path": "$output_file_path", 
    "file_tag_name": "$file_tag_name",
    "additional_translation_files": $additional_files_json
}
EOF
)
            
            response=$(ptc_curl -s -w "%{http_code}" \
                -X POST \
                -H "Content-Type: application/json" \
                -d "$json_payload" \
                "$api_url" 2>/dev/null)
        else
            response=$(ptc_curl -s -w "%{http_code}" \
                -X POST \
                -F "file_path=$relative_file_path" \
                -F "output_file_path=$output_file_path" \
                -F "file_tag_name=$file_tag_name" \
                -F "file=@$absolute_file_path" \
                "$api_url" 2>/dev/null)
        fi
    fi
    
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    # A 201 that still carries "success": false is a rejected upload dressed as
    # a created one - the content-validation path answers that way (ci18-7342).
    if [[ "$http_code" == "201" ]] && ! response_indicates_failure "$http_code" "$response_body"; then
        log_success "File uploaded successfully: $relative_file_path"
        if [[ "$PTC_VERBOSE" == "true" ]]; then
            log_info "=== API RESPONSE ==="
            log_info "HTTP Status: $http_code (Created)"
            if [[ -n "$response_body" ]]; then
                log_info "Response body: $response_body"
            fi
            log_info "===================="
        fi
        log_debug "API response: $response_body"
    else
        log_error "Failed to upload file: $relative_file_path ($(describe_api_failure "$http_code" "$response_body"))"
        if [[ "$PTC_VERBOSE" == "true" ]]; then
            log_info "=== API ERROR RESPONSE ==="
            log_info "HTTP Status: $http_code"
            if [[ -n "$response_body" ]]; then
                log_info "Error response: $response_body"
            fi
            log_info "=========================="
        fi
        log_debug "API response: $response_body"
        return 1
    fi
}

# Function to start processing of uploaded file
start_processing() {
    local absolute_file_path="$1"
    local relative_file_path="$2"
    local file_tag_name="$3"
    
    # Check if file exists
    if [[ ! -f "$absolute_file_path" ]]; then
        log_error "File not found: $absolute_file_path"
        return 1
    fi
    
    # PTC Process API endpoint
    local process_url="${PTC_API_URL}source_files/process"
    
    log_debug "Starting file processing via PTC API: $process_url"
    
    # Make multipart/form-data request using curl
    local response
    if [[ -n "$PTC_API_TOKEN" ]]; then
        response=$(ptc_curl -s -w "%{http_code}" \
            -X PUT \
            -H "Authorization: Bearer $PTC_API_TOKEN" \
            -F "file_path=$relative_file_path" \
            -F "file_tag_name=$file_tag_name" \
            -F "file=@$absolute_file_path" \
            "$process_url" 2>/dev/null)
    else
        log_error "API token required for file processing"
        return 1
    fi
    
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    if response_indicates_failure "$http_code" "$response_body"; then
        log_error "Failed to start file processing: $relative_file_path ($(describe_api_failure "$http_code" "$response_body"))"
        log_debug "Process API response: $response_body"
        return 1
    fi

    log_success "File processing started successfully: $relative_file_path"
    log_debug "Process API response: $response_body"
    return 0
}

# Function to get translation status quietly (for compact monitoring)
get_translation_status_quiet() {
    local relative_file_path="$1"
    local file_tag_name="$2"
    
    # PTC Translation Status API endpoint
    local status_url="${PTC_API_URL}source_files/translation_status"
    
    # Prepare query parameters
    local query_params="file_path=$(printf '%s' "$relative_file_path" | sed 's/ /%20/g')"
    if [[ -n "$file_tag_name" ]]; then
        query_params="${query_params}&file_tag_name=$(printf '%s' "$file_tag_name" | sed 's/ /%20/g')"
    fi
    
    local full_url="${status_url}?${query_params}"
    
    # DETAILED LOGGING FOR DEBUGGING
    log_debug "=== STATUS CHECK API CALL ==="
    log_debug "URL: $full_url"
    log_debug "Token: ${PTC_API_TOKEN:0:10}..."
    
    local response
    if [[ -n "$PTC_API_TOKEN" ]]; then
        response=$(ptc_curl -s -w "%{http_code}" \
            -X GET \
            -H "Authorization: Bearer $PTC_API_TOKEN" \
            "$full_url" 2>/dev/null)
    else
        log_debug "No API token provided"
        return 1
    fi
    
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    # DETAILED LOGGING FOR DEBUGGING
    log_debug "HTTP Code: $http_code"
    log_debug "Response Body: $response_body"
    
    # A rejected status query answers 200-with-"success":false on older servers
    # (ci18-7342); without this it parses as an absent status and polls on.
    if [[ "$http_code" == "200" ]] && response_indicates_failure "$http_code" "$response_body"; then
        log_debug "Status query rejected: $(describe_api_failure "$http_code" "$response_body")"
        return 1
    fi

    if [[ "$http_code" == "200" ]]; then
        # Fields live under a "translation_status" wrapper; see the note in
        # check_translation_status.
        local status_scope
        status_scope=$(json_object_field "$response_body" "translation_status")
        status_scope="${status_scope:-$response_body}"

        local status
        status=$(json_string_field "$status_scope" "status")
        # Null/absent status: no translation memory for the file yet.
        status="${status:-pending}"

        log_debug "Parsed Status: $status"

        # Output the status and response body for caller
        echo "$status|$response_body"

        # Return status code based on completion
        if [[ "$status" == "completed" ]]; then
            return 0  # Ready for download
        elif is_terminal_failure_status "$status"; then
            return 3  # Terminal failure - further polling cannot help
        else
            return 2  # Still in progress
        fi
    elif [[ "$http_code" == "404" ]]; then
        log_debug "File not found in translation system"
        echo "not_found|"
        return 1
    else
        log_debug "API error: HTTP $http_code"
        echo "error|"
        return 1
    fi
}

# Function to check translation status
check_translation_status() {
    local relative_file_path="$1"
    local file_tag_name="$2"
    
    # PTC Translation Status API endpoint
    local status_url="${PTC_API_URL}source_files/translation_status"
    
    log_debug "Checking translation status via PTC API: $status_url"
    
    # Prepare query parameters
    local query_params="file_path=$(printf '%s' "$relative_file_path" | sed 's/ /%20/g')"
    if [[ -n "$file_tag_name" ]]; then
        query_params="${query_params}&file_tag_name=$(printf '%s' "$file_tag_name" | sed 's/ /%20/g')"
    fi
    
    local full_url="${status_url}?${query_params}"
    
    log_debug "Full status URL: $full_url"
    log_debug "Using API token: ${PTC_API_TOKEN:0:10}..."
    
    local response
    if [[ -n "$PTC_API_TOKEN" ]]; then
        response=$(ptc_curl -s -w "%{http_code}" \
            -X GET \
            -H "Authorization: Bearer $PTC_API_TOKEN" \
            "$full_url" 2>/dev/null)
    else
        log_error "API token required for translation status check"
        return 1
    fi
    
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    # Same two-shape rejection as elsewhere (ci18-7342): do not report a
    # rejected query as a retrieved status.
    if [[ "$http_code" == "200" ]] && response_indicates_failure "$http_code" "$response_body"; then
        log_error "Failed to check translation status: $relative_file_path ($(describe_api_failure "$http_code" "$response_body"))"
        return 1
    fi

    if [[ "$http_code" == "200" ]]; then
        log_success "Translation status retrieved successfully: $relative_file_path"
        log_debug "Status API response: $response_body"

        # The API nests the fields under a "translation_status" object
        # (source_files/translation_status.json.jbuilder). Read that scope
        # rather than the whole document, so a "status" added elsewhere in the
        # response later cannot shadow this one. Fall back to a flat read.
        local status_scope
        status_scope=$(json_object_field "$response_body" "translation_status")
        status_scope="${status_scope:-$response_body}"

        local status
        status=$(json_string_field "$status_scope" "status")
        local completeness
        completeness=$(json_number_field "$status_scope" "completeness")
        completeness="${completeness:-0}"

        # A null/absent status means no translation memory exists for the file
        # yet. That is still pending, but say so rather than reporting it as an
        # unnamed in-progress state.
        if [[ -z "$status" ]]; then
            log_info "Translation Status: pending (no translation memory yet)"
            return 2
        fi

        log_info "Translation Status: $status (${completeness}% complete)"

        # Return status code based on completion
        if [[ "$status" == "completed" ]]; then
            return 0  # Ready for download
        elif is_terminal_failure_status "$status"; then
            return 3  # Terminal failure - further polling cannot help
        else
            return 2  # Still in progress
        fi
    elif [[ "$http_code" == "404" ]]; then
        log_warning "No translations found for file: $relative_file_path"
        return 1
    elif [[ "$http_code" == "302" ]]; then
        log_warning "Translation status endpoint redirected (HTTP 302) - may not be available on this server"
        return 1
    else
        log_error "Failed to check translation status: $relative_file_path (HTTP $http_code)"
        log_debug "Status API response: $response_body"
        return 1
    fi
}

# Helper functions for file status tracking (compatible with older bash)
get_file_status() {
    local target_file="$1"
    local i
    for i in "${!file_status_keys[@]}"; do
        if [[ "${file_status_keys[$i]}" == "$target_file" ]]; then
            echo "${file_status_values[$i]}"
            return 0
        fi
    done
    echo "unknown"
}



set_file_status() {
    local target_file="$1"
    local new_status="$2"
    local i
    for i in "${!file_status_keys[@]}"; do
        if [[ "${file_status_keys[$i]}" == "$target_file" ]]; then
            file_status_values[$i]="$new_status"
            return 0
        fi
    done
}

# Function to display compact file status
display_file_status() {
    local completed_count="$1"
    local total_count="$2"
    local round="$3"
    local max_round="$4"
    local status_string="$5"
    
    # Clear current line and move cursor to beginning
    echo -ne "\r\033[K"
    
    # Display compact status: XX round/max_round
    echo -ne "${status_string} ${CYAN}${round}/${max_round}${NC}"
    
    # Flush output
    echo -ne ""
}

# Function to get file status character with color
get_status_char() {
    local status="$1"
    case "$status" in
        "completed")
            echo -e "${GREEN}C${NC}"
            ;;
        "queued")
            echo -e "${BLUE}Q${NC}"
            ;;
        "in_progress"|"processing")
            echo -e "${BLUE}P${NC}"
            ;;
        "failed"|"error")
            echo -e "${RED}F${NC}"
            ;;
        "out_of_credit")
            echo -e "${RED}\$${NC}"
            ;;
        "pending")
            echo -e "${YELLOW}.${NC}"
            ;;
        "draft")
            echo -e "${YELLOW}D${NC}"
            ;;
        "null"|"status_unknown"|"unknown"|*)
            echo -e "${YELLOW}U${NC}"
            ;;
    esac
}

# Function to monitor translation status until completion
monitor_translation_status() {
    local relative_file_path="$1"
    local file_tag_name="$2"
    local max_attempts="${3:-100}" # Default 100 attempts
    local wait_interval="${4:-5}"  # Default 5 seconds between checks
    
    log_info "Monitoring translation status for: $relative_file_path"
    log_info "Will check every ${wait_interval}s for up to ${max_attempts} attempts..."
    
    local attempt=1
    local consecutive_errors=0
    # The status endpoint can 404 briefly right after processing starts, before
    # the translation record is visible. Tolerate a few of those in a row, but
    # do not poll a persistently broken endpoint to the attempt limit - that is
    # what made a hard error look like a timeout.
    local max_consecutive_errors=3

    while [[ $attempt -le $max_attempts ]]; do
        # Add delay before each status check (except the first one)
        if [[ $attempt -gt 1 ]]; then
            log_info "Waiting ${wait_interval}s before next status check..."
            log_info "You can interrupt with Ctrl+C if needed"
            sleep "$wait_interval"
        fi

        log_info "Status check attempt $attempt/$max_attempts..."

        # Check translation status. The result must be captured from the call
        # itself: an `if` whose condition is false and which has no `else`
        # exits 0, so reading $? after the block always saw success and left
        # every branch below unreachable.
        local status_result=0
        check_translation_status "$relative_file_path" "$file_tag_name" || status_result=$?

        if [[ $status_result -ne 1 ]]; then
            consecutive_errors=0
        fi

        case $status_result in
            0)
                log_success "Translations are completed! Ready for download."
                return 0
                ;;
            1)
                consecutive_errors=$((consecutive_errors + 1))
                if [[ $consecutive_errors -ge $max_consecutive_errors ]]; then
                    log_error "Failed to check translation status ($consecutive_errors consecutive errors)"
                    return 1
                fi
                if [[ $attempt -eq $max_attempts ]]; then
                    log_error "Failed to check translation status (attempt limit reached while erroring)"
                    return 1
                fi
                log_warning "Status check failed (attempt $attempt); retrying"
                attempt=$((attempt + 1))
                continue
                ;;
            3)
                # Terminal failure - polling cannot change the outcome
                log_error "Translation failed for: $relative_file_path"
                log_info "The translation reached a terminal state and will not complete."
                log_info "Check the file in PTC, or re-upload it after resolving the cause."
                return 3
                ;;
        esac

        # Still in progress
        if [[ $attempt -eq $max_attempts ]]; then
            log_warning "Reached maximum attempts ($max_attempts). Translations may still be in progress."
            log_info "You can check status manually with:"
            log_info "  curl -H \"Authorization: Bearer \$TOKEN\" \"${PTC_API_URL}source_files/translation_status?file_path=$relative_file_path&file_tag_name=$file_tag_name\""
            return 2
        fi
        log_info "Translations still in progress."

        attempt=$((attempt + 1))
    done
    
    return 2  # Timeout
}

# Function to download completed translations
download_translations() {
    local relative_file_path="$1"
    local file_tag_name="$2"
    local base_dir="$3"
    
    # PTC Download Translations API endpoint
    local download_url="${PTC_API_URL}source_files/download_translations"
    
    log_debug "Downloading translations via PTC API: $download_url"
    
    # Prepare query parameters
    local query_params="file_path=$(printf '%s' "$relative_file_path" | sed 's/ /%20/g')"
    if [[ -n "$file_tag_name" ]]; then
        query_params="${query_params}&file_tag_name=$(printf '%s' "$file_tag_name" | sed 's/ /%20/g')"
    fi
    
    local full_url="${download_url}?${query_params}"
    
    # Verbose logging for download details
    if [[ "$PTC_VERBOSE" == "true" ]]; then
        log_info "=== DOWNLOAD DETAILS ==="
        log_info "Downloading translations for: $relative_file_path"
        log_info "API endpoint: $download_url"
        log_info "Target directory: $base_dir"
        log_info "File tag: $file_tag_name"
    fi
    
    log_debug "=== DOWNLOAD API CALL ==="
    log_debug "Full download URL: $full_url"
    log_debug "File path: $relative_file_path"
    log_debug "Tag name: $file_tag_name"
    log_debug "Base directory: $base_dir"
    
    # Create temporary file for download
    local temp_zip=$(mktemp /tmp/ptc_translations_XXXXXX.zip)
    log_debug "Created temporary ZIP file: $temp_zip"
    
    local http_code
    if [[ -n "$PTC_API_TOKEN" ]]; then
        if [[ "$PTC_VERBOSE" == "true" ]]; then
            log_info "Starting download from API..."
        fi
        log_debug "Starting curl download with token: ${PTC_API_TOKEN:0:10}..."
        http_code=$(ptc_curl -s -w "%{http_code}" \
            -X GET \
            -H "Authorization: Bearer $PTC_API_TOKEN" \
            -o "$temp_zip" \
            "$full_url" 2>/dev/null)
        log_debug "Download completed with HTTP code: $http_code"
        
        # Check file size to verify download
        if [[ -f "$temp_zip" ]]; then
            local file_size=$(stat -f%z "$temp_zip" 2>/dev/null || stat -c%s "$temp_zip" 2>/dev/null || echo "unknown")
            log_debug "Downloaded file size: $file_size bytes"
            if [[ "$PTC_VERBOSE" == "true" ]]; then
                log_info "Downloaded ZIP file: $file_size bytes"
            fi
        fi
    else
        log_error "API token required for translation download"
        rm -f "$temp_zip"
        return 1
    fi
    
    # curl wrote the body straight to $temp_zip, so on the older server shape a
    # rejected download lands here as a 200 whose "zip" is really the JSON error
    # envelope. Read the file back before trusting the status (ci18-7342).
    local download_body=""
    if [[ -f "$temp_zip" ]] && [[ "$(head -c 1 "$temp_zip" 2>/dev/null)" == "{" ]]; then
        download_body=$(head -c 4096 "$temp_zip" 2>/dev/null)
    fi

    if response_indicates_failure "$http_code" "$download_body"; then
        log_error "Failed to download translations: $relative_file_path ($(describe_api_failure "$http_code" "$download_body"))"
        rm -f "$temp_zip"
        return 1
    fi

    # ci18-7342 - 202 is the API saying "the archive is not ready yet"
    # (TranslationInProgressError, with a Retry-After header), not a download
    # error and not a terminal outcome. It happens routinely because
    # translation_status can report a file ready a moment before its archive
    # is: seen against QA on a file that downloaded fine on the next poll.
    # Returns 2 so the caller keeps the file in the monitoring loop instead of
    # either failing the run or claiming success with nothing on disk.
    if [[ "$http_code" == "202" ]]; then
        local retry_after
        retry_after=$(json_number_field "$download_body" "retry_after")
        log_info "Translations for $relative_file_path are still being prepared${retry_after:+ (server suggests ${retry_after}s)}; will retry."
        rm -f "$temp_zip"
        return 2
    fi

    if [[ "$http_code" == "200" ]]; then
        log_success "Translations downloaded successfully: $relative_file_path"

        # Unpack ZIP and place files in correct directory structure
        if command -v unzip >/dev/null 2>&1; then
            # Get directory where the original file is located
            local source_dir=$(dirname "$relative_file_path")
            local target_dir="$base_dir"
            if [[ "$source_dir" != "." ]]; then
                target_dir="$base_dir/$source_dir"
                # Create target directory if it doesn't exist
                mkdir -p "$target_dir"
            fi
            
            if [[ "$PTC_VERBOSE" == "true" ]]; then
                log_info "=== EXTRACTION DETAILS ==="
                log_info "Extracting to directory: $target_dir"
                log_info "Source file directory: $source_dir"
            fi
            log_debug "=== EXTRACTION DETAILS ==="
            log_debug "Source file directory: $source_dir"
            log_debug "Target directory: $target_dir"
            log_debug "ZIP file: $temp_zip"
            
            # Create target directory if it doesn't exist
            if [[ ! -d "$target_dir" ]]; then
                log_debug "Creating target directory: $target_dir"
                mkdir -p "$target_dir"
            fi
            
            # Create temporary directory for extraction
            local temp_extract_dir=$(mktemp -d /tmp/ptc_extract_XXXXXX)
            log_debug "Created extraction directory: $temp_extract_dir"
            
            # Extract ZIP to temporary directory first
            if [[ "$PTC_VERBOSE" == "true" ]]; then
                log_info "Extracting ZIP contents..."
            fi
            log_debug "Extracting ZIP contents..."
            if (cd "$temp_extract_dir" && unzip -o "$temp_zip" 2>/dev/null); then
                log_debug "ZIP extraction successful"
                
                # List extracted files for debug and verbose mode
                if [[ "$PTC_VERBOSE" == "true" ]]; then
                    log_info "Files found in archive:"
                    find "$temp_extract_dir" -type f 2>/dev/null | while read -r extracted_file; do
                        local extracted_filename=$(basename "$extracted_file")
                        local extracted_size=$(stat -f%z "$extracted_file" 2>/dev/null || stat -c%s "$extracted_file" 2>/dev/null || echo "unknown")
                        log_info "  - $extracted_filename ($extracted_size bytes)"
                    done
                fi
                
                log_debug "Extracted files:"
                find "$temp_extract_dir" -type f 2>/dev/null | while read -r extracted_file; do
                    local extracted_filename=$(basename "$extracted_file")
                    local extracted_size=$(stat -f%z "$extracted_file" 2>/dev/null || stat -c%s "$extracted_file" 2>/dev/null || echo "unknown")
                    log_debug "  - $extracted_filename ($extracted_size bytes)"
                done
                # Move files from temp directory to target directory, preserving structure
                if [[ "$PTC_VERBOSE" == "true" ]]; then
                    log_info "Moving translation files to target directory..."
                fi
                log_debug "Moving translation files to target directory..."
                local moved_count=0
                if find "$temp_extract_dir" -type f -name "*.json" -o -name "*.po" -o -name "*.pot" -o -name "*.mo" -o -name "*.yml" -o -name "*.yaml" 2>/dev/null | while read -r file; do
                    local filename=$(basename "$file")
                    local target_file="$target_dir/$filename"
                    log_debug "Moving: $filename → $target_file"
                    
                    # Check if target file already exists
                    if [[ -f "$target_file" ]]; then
                        log_debug "Overwriting existing file: $target_file"
                        if [[ "$PTC_VERBOSE" == "true" ]]; then
                            log_info "Overwriting: $filename"
                        fi
                    fi
                    
                    if mv "$file" "$target_file" 2>/dev/null; then
                        # Verify the move was successful
                        if [[ -f "$target_file" ]]; then
                            local final_size=$(stat -f%z "$target_file" 2>/dev/null || stat -c%s "$target_file" 2>/dev/null || echo "unknown")
                            log_debug "Successfully moved $filename ($final_size bytes)"
                            if [[ "$PTC_VERBOSE" == "true" ]]; then
                                log_info "  ✓ $filename ($final_size bytes)"
                            fi
                            moved_count=$((moved_count + 1))
                        else
                            log_warning "File move reported success but target file not found: $target_file"
                            return 1
                        fi
                    else
                        log_warning "Failed to move $filename to $target_file"
                        return 1
                    fi
                done; then
                    log_debug "Moved $moved_count translation files successfully"
                    if [[ "$PTC_VERBOSE" == "true" ]]; then
                        log_info "Successfully moved $moved_count files"
                    fi
                    log_success "Translations unpacked successfully to $target_dir"
                    log_debug "Cleaning up temporary files..."
                    rm -rf "$temp_extract_dir" "$temp_zip"
                    return 0
                else
                    log_error "Failed to move translation files to target directory"
                    log_debug "Cleaning up temporary files after failure..."
                    rm -rf "$temp_extract_dir" "$temp_zip"
                    return 1
                fi
            else
                log_error "Failed to extract translations ZIP"
                rm -rf "$temp_extract_dir" "$temp_zip"
                return 1
            fi
        else
            log_error "unzip command not found. Please install unzip utility"
            rm -f "$temp_zip"
            return 1
        fi
    else
        log_error "Failed to download translations: $relative_file_path (HTTP $http_code)"
        rm -f "$temp_zip"
        return 1
    fi
}

# Cleanup function on exit
cleanup() {
    log_debug "Performing cleanup..."
    # Clean up any temporary files
    rm -f /tmp/ptc_translations_*.zip 2>/dev/null || true
}

# Signal handler
trap cleanup EXIT INT TERM

# ============================================================================
# `ptc init` — scaffold .ptc-config.yml from POST /api/v1/detect_config
# ============================================================================

# Escapes a value so it can be embedded inside a JSON string literal. Only
# backslash and double-quote need handling for file paths; control characters
# do not occur in paths on any filesystem this runs on.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Counts non-empty lines in a string (used for "N files" summaries). Avoids
# `grep -c` so an empty string reports 0 rather than 1 for a trailing newline.
_count_lines() {
    local text="$1"
    local count=0 line
    [[ -z "$text" ]] && { printf '0'; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] && count=$((count + 1))
    done <<< "$text"
    printf '%s' "$count"
}

# Emits each top-level element of the JSON array named KEY, one per line, with
# interior newlines removed. Handles nested objects/arrays and quoted strings
# (including backslash-escaped quotes). Empty output means the key is absent or
# the array is empty. This is the one array-aware reader the status/config
# parsers lack; detect_config's files[] with nested additional_translation_files
# is deeper than anything json_object_field can reach, hence a real scanner.
_json_array_elements() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | awk -v key="$key" '
    { s = s $0 }
    END {
        n = length(s)
        pat = "\"" key "\""
        ki = index(s, pat)
        if (ki == 0) { exit }
        i = ki + length(pat)
        # Advance to the opening bracket; anything other than ":" or blanks
        # between the key and "[" means this key is not an array.
        while (i <= n && substr(s, i, 1) != "[") {
            c = substr(s, i, 1)
            if (c != ":" && c != " " && c != "\t") { exit }
            i++
        }
        if (i > n) { exit }
        i++                          # skip "["
        depth = 0; instr = 0; esc = 0; buf = ""
        while (i <= n) {
            c = substr(s, i, 1)
            if (instr) {
                buf = buf c
                if (esc) { esc = 0 }
                else if (c == "\\") { esc = 1 }
                else if (c == "\"") { instr = 0 }
            } else if (c == "\"") {
                instr = 1; buf = buf c
            } else if (c == "{" || c == "[") {
                depth++; buf = buf c
            } else if (c == "}") {
                depth--; buf = buf c
            } else if (c == "]") {
                if (depth == 0) {
                    sub(/^[ \t]+/, "", buf); sub(/[ \t]+$/, "", buf)
                    if (length(buf) > 0) { print buf }
                    exit
                }
                depth--; buf = buf c
            } else if (c == "," && depth == 0) {
                sub(/^[ \t]+/, "", buf); sub(/[ \t]+$/, "", buf)
                if (length(buf) > 0) { print buf }
                buf = ""
            } else {
                buf = buf c
            }
            i++
        }
    }'
}

# Lists candidate paths for detection, relative to DIR. Prefers git so that
# .gitignore is honoured for free (tracked + untracked-not-ignored); falls back
# to a plain find when DIR is not a git work tree.
collect_repo_files() {
    local dir="$1"
    # `|| true` keeps a partial listing usable: git ls-files or find can exit
    # non-zero (e.g. an unreadable subdirectory), which under `set -o pipefail`
    # would otherwise abort the caller's `file_list=$(...)` assignment.
    if command -v git >/dev/null 2>&1 && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        ( cd "$dir" && git ls-files --cached --others --exclude-standard 2>/dev/null ) || true
    else
        ( cd "$dir" && find . -type f -not -path '*/.git/*' 2>/dev/null | sed -E 's#^\./##' ) || true
    fi
}

# True when PATH matches a single .ptcignore PATTERN. Pragmatic gitignore-ish
# semantics (not a full implementation): trailing "/" = directory prefix; a
# pattern containing "/" is globbed against the whole path; a bare name matches
# any path component or basename glob. Bash `case` globs are intentionally
# unquoted so the pattern applies.
_path_matches_ignore() {
    local path="$1"
    local pat="$2"
    case "$pat" in
        */)
            local p="${pat%/}"
            case "$path" in
                "$p"/*) return 0 ;;
            esac
            return 1
            ;;
        */*)
            # shellcheck disable=SC2254
            case "$path" in
                $pat) return 0 ;;
                $pat/*) return 0 ;;
            esac
            return 1
            ;;
        *)
            local base="${path##*/}"
            # shellcheck disable=SC2254
            case "$base" in
                $pat) return 0 ;;
            esac
            case "/$path/" in
                *"/$pat/"*) return 0 ;;
            esac
            return 1
            ;;
    esac
}

# Reads newline-separated paths on stdin and drops any matched by DIR/.ptcignore.
# With no .ptcignore it is a pass-through.
filter_ptcignore() {
    local dir="$1"
    local ignore_file="$dir/.ptcignore"
    if [[ ! -f "$ignore_file" ]]; then
        cat
        return 0
    fi
    local patterns=()
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"                                   # strip CR from CRLF files
        line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        [[ -z "$line" ]] && continue
        case "$line" in \#*) continue ;; esac
        patterns+=("$line")
    done < "$ignore_file"

    # A .ptcignore with only blanks/comments leaves no patterns. Expanding an
    # empty "${patterns[@]}" under `set -u` is fatal on bash < 4.4, so short out.
    if [[ ${#patterns[@]} -eq 0 ]]; then
        cat
        return 0
    fi

    local path keep pat
    while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -z "$path" ]] && continue
        keep=true
        for pat in "${patterns[@]}"; do
            if _path_matches_ignore "$path" "$pat"; then
                keep=false
                break
            fi
        done
        [[ "$keep" == "true" ]] && printf '%s\n' "$path"
    done
    # The loop's last command is a `&&` that is false whenever the final path is
    # ignored; without this the function returns 1 and, under `set -o pipefail`,
    # aborts the `file_list=$(... | filter_ptcignore)` assignment in cmd_init.
    return 0
}

# Reads newline-separated paths on stdin, prints {"file_paths":[...]}.
build_detect_payload() {
    local first=true path
    printf '{"file_paths":['
    while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -z "$path" ]] && continue
        if [[ "$first" == "true" ]]; then first=false; else printf ','; fi
        printf '"%s"' "$(_json_escape "$path")"
    done
    printf ']}'
}

# POSTs the payload to detect_config and echoes curl's raw "body+http_code"
# response, so the caller splits it with the codebase's ${resp: -3}/${resp%???}
# idiom. Isolated for testability: a stubbed curl feeds it a fixture.
call_detect_config() {
    local payload="$1"
    local response
    response=$(ptc_curl -s -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer $PTC_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${PTC_API_URL}detect_config" 2>/dev/null) || true
    printf '%s' "$response"
}

# Renders the full .ptc-config.yml content for a detect_config BODY to stdout.
# kind:"any" or an empty files[] takes the commented-template branch so init
# never hard-fails on an unrecognised layout.
render_ptc_config() {
    local body="$1"
    local kind source_locale files_elems
    kind=$(json_string_field "$body" "kind")
    source_locale=$(json_string_field "$body" "source_locale")
    [[ -z "$source_locale" ]] && source_locale="en"
    files_elems=$(_json_array_elements "$body" "files")

    if [[ -z "$files_elems" || "$kind" == "any" ]]; then
        _render_config_template "$source_locale" "$kind"
    else
        _render_config_detected "$source_locale" "$kind" "$files_elems"
    fi
}

_render_config_detected() {
    local source_locale="$1" kind="$2" files_elems="$3"
    printf '# .ptc-config.yml — generated by `%s init`\n' "$SCRIPT_NAME"
    [[ -n "$kind" ]] && printf '# Detected project kind: %s\n' "$kind"
    printf '# Never commit an API token — provide it via the PTC_API_TOKEN environment variable.\n'
    printf '\n'
    printf 'source_locale: %s\n' "$source_locale"
    printf '\n'
    printf 'files:\n'
    local elem file output addl_elems addl a_type a_path
    while IFS= read -r elem || [[ -n "$elem" ]]; do
        [[ -z "$elem" ]] && continue
        file=$(json_string_field "$elem" "file")
        [[ -z "$file" ]] && continue
        output=$(json_string_field "$elem" "output")
        printf '  - file: %s\n' "$file"
        printf '    output: %s\n' "$output"
        addl_elems=$(_json_array_elements "$elem" "additional_translation_files")
        if [[ -n "$addl_elems" ]]; then
            printf '    additional_translation_files:\n'
            while IFS= read -r addl || [[ -n "$addl" ]]; do
                [[ -z "$addl" ]] && continue
                a_type=$(json_string_field "$addl" "type")
                a_path=$(json_string_field "$addl" "path")
                printf '      - type: %s\n' "$a_type"
                printf '        path: %s\n' "$a_path"
            done <<< "$addl_elems"
        fi
    done <<< "$files_elems"
}

_render_config_template() {
    local source_locale="$1" kind="${2:-}"
    printf '# .ptc-config.yml — generated by `%s init`\n' "$SCRIPT_NAME"
    printf '# ptc init could not auto-detect translatable files in this project'
    [[ -n "$kind" ]] && printf ' (kind: %s)' "$kind"
    printf '.\n'
    printf '# Fill in the files you want translated and uncomment the block below.\n'
    printf '# Reference: https://github.com/OnTheGoSystems/ptc-cli#configuration-file-format\n'
    printf '# Never commit an API token — provide it via the PTC_API_TOKEN environment variable.\n'
    printf '\n'
    printf 'source_locale: %s\n' "$source_locale"
    printf '\n'
    printf '# files:\n'
    printf '#   - file: path/to/%s.json\n' "$source_locale"
    printf '#     output: path/to/{{lang}}.json\n'
}

# Human-readable "what was detected" block, printed for confirmation before the
# file is written. detect_config returns a single kind per repo, so the grouping
# is kind + counts + the file mapping.
print_detect_summary() {
    local body="$1"
    local kind source_locale files_elems locales_elems
    kind=$(json_string_field "$body" "kind"); [[ -z "$kind" ]] && kind="any"
    source_locale=$(json_string_field "$body" "source_locale")
    files_elems=$(_json_array_elements "$body" "files")
    locales_elems=$(_json_array_elements "$body" "available_locales")

    local line locales="" elem file output
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        line=$(printf '%s' "$line" | sed -E 's/^"(.*)"$/\1/')
        locales="${locales:+$locales, }$line"
    done <<< "$locales_elems"

    printf '\n'
    printf 'Detected project configuration:\n'
    printf '  kind:           %s\n' "$kind"
    printf '  source_locale:  %s\n' "${source_locale:-<unknown>}"
    printf '  target locales: %s\n' "${locales:-<none detected>}"
    printf '  files (%s):\n' "$(_count_lines "$files_elems")"
    while IFS= read -r elem || [[ -n "$elem" ]]; do
        [[ -z "$elem" ]] && continue
        file=$(json_string_field "$elem" "file")
        output=$(json_string_field "$elem" "output")
        printf '    %s -> %s\n' "$file" "$output"
    done <<< "$files_elems"
    printf '\n'
}

# Detects the CI system from the origin remote and on-disk markers.
detect_ci_provider() {
    local dir="$1"
    local origin=""
    if command -v git >/dev/null 2>&1; then
        origin=$(git -C "$dir" config --get remote.origin.url 2>/dev/null || echo "")
    fi
    if [[ -d "$dir/.github" ]] || [[ "$origin" == *github.com* ]]; then
        echo "github"
    elif [[ -f "$dir/.gitlab-ci.yml" ]] || [[ "$origin" == *gitlab* ]]; then
        echo "gitlab"
    else
        echo "unknown"
    fi
}

render_ci_github() {
    cat <<'EOF'
name: PTC Translations
on:
  workflow_dispatch:

jobs:
  translate:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - name: Run PTC CLI
        env:
          PTC_API_TOKEN: ${{ secrets.PTC_API_TOKEN }}
        run: |
          curl -fsSL https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/v1.0.0/ptc-cli.sh -o ptc-cli.sh
          chmod +x ptc-cli.sh
          ./ptc-cli.sh --config-file .ptc-config.yml --verbose
EOF
}

render_ci_gitlab() {
    cat <<'EOF'
ptc_translations:
  stage: deploy
  script:
    - curl -fsSL https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/v1.0.0/ptc-cli.sh -o ptc-cli.sh
    - chmod +x ptc-cli.sh
    - ./ptc-cli.sh --config-file .ptc-config.yml --verbose
  variables:
    PTC_API_TOKEN: "$PTC_API_TOKEN"
  rules:
    - if: $CI_PIPELINE_SOURCE == "web"
EOF
}

# Prints the CI snippet matching the detected provider (both, when unknown).
print_ci_block() {
    local dir="$1"
    local provider
    provider=$(detect_ci_provider "$dir")
    printf '\n'
    log_info "Store your token as a CI secret named PTC_API_TOKEN, then add this pipeline:"
    case "$provider" in
        github)
            printf '\n# .github/workflows/ptc.yml\n'
            render_ci_github
            ;;
        gitlab)
            printf '\n# append to .gitlab-ci.yml\n'
            render_ci_gitlab
            ;;
        *)
            printf '\n# GitHub Actions — .github/workflows/ptc.yml:\n'
            render_ci_github
            printf '\n# GitLab CI — .gitlab-ci.yml:\n'
            render_ci_gitlab
            ;;
    esac
    printf '\n'
}

show_init_help() {
    echo -e "$SCRIPT_NAME init - scaffold a .ptc-config.yml from your repository

USAGE:
    $SCRIPT_NAME init [OPTIONS]

DESCRIPTION:
    Scans the current checkout (respecting .gitignore and .ptcignore), sends the
    file paths (paths only, no contents) to the PTC detect_config endpoint, and
    writes a ready-to-use .ptc-config.yml plus a CI snippet. Unrecognised
    layouts get a commented template instead of an error.

OPTIONS:
    --api-url URL          PTC API base URL (default: $PTC_API_URL)
    --api-token TOKEN      API token (default: \$PTC_API_TOKEN environment variable)
    -d, --project-dir DIR  Directory to scan and write into (default: current)
    -f, --force            Overwrite an existing .ptc-config.yml
    -y, --yes              Do not prompt for confirmation
    -n, --dry-run          Print what would be written without touching disk
    -v, --verbose          Verbose output
    -h, --help             Show this help

NOTE:
    detect_config is currently on the QA environment. Until it reaches
    production, point --api-url at the QA host."
}

# `ptc init` entry point.
cmd_init() {
    local force=false assume_yes=false
    local project_dir="$PTC_PROJECT_DIR"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-url) PTC_API_URL="$2"; shift 2 ;;
            --api-url=*) PTC_API_URL="${1#*=}"; shift ;;
            --api-token) PTC_API_TOKEN="$2"; shift 2 ;;
            --api-token=*) PTC_API_TOKEN="${1#*=}"; shift ;;
            -d|--project-dir) project_dir="$2"; shift 2 ;;
            --project-dir=*) project_dir="${1#*=}"; shift ;;
            -f|--force) force=true; shift ;;
            -y|--yes) assume_yes=true; shift ;;
            -v|--verbose) PTC_VERBOSE=true; shift ;;
            -n|--dry-run) PTC_DRY_RUN=true; shift ;;
            -h|--help) show_init_help; return 0 ;;
            *)
                log_error "Unknown option for 'init': $1"
                log_info "Run '$SCRIPT_NAME init --help' for usage."
                return 1
                ;;
        esac
    done

    # The endpoint is formed as "${PTC_API_URL}detect_config", so a --api-url
    # without a trailing slash would request ".../api/v1detect_config".
    case "$PTC_API_URL" in
        */) ;;
        *) PTC_API_URL="${PTC_API_URL}/" ;;
    esac

    if [[ ! -d "$project_dir" ]]; then
        log_error "Project directory not found: $project_dir"
        return 1
    fi

    local config_path="$project_dir/.ptc-config.yml"

    # Refuse to clobber an existing config unless forced; a dry run still previews.
    if [[ -f "$config_path" && "$force" != "true" && "$PTC_DRY_RUN" != "true" ]]; then
        log_error "$config_path already exists. Re-run with --force to overwrite."
        return 1
    fi

    if [[ -z "$PTC_API_TOKEN" ]]; then
        log_error "No API token provided. Set PTC_API_TOKEN or pass --api-token."
        return 1
    fi

    log_info "Scanning $project_dir for translatable files..."
    local file_list file_count
    file_list=$(collect_repo_files "$project_dir" | filter_ptcignore "$project_dir")
    file_count=$(_count_lines "$file_list")
    log_debug "Collected $file_count candidate path(s)"

    local body=""
    if [[ "$file_count" -eq 0 ]]; then
        log_warning "No files found to send for detection; writing a template config."
    else
        local payload response http_code
        payload=$(printf '%s\n' "$file_list" | build_detect_payload)
        log_debug "POST ${PTC_API_URL}detect_config with $file_count path(s)"
        response=$(call_detect_config "$payload")
        http_code="${response: -3}"
        body="${response%???}"

        case "$http_code" in
            200) : ;;
            422)
                log_error "detect_config rejected the request (HTTP 422)."
                log_debug "Response: $body"
                return 1
                ;;
            401|403)
                log_error "detect_config rejected the API token (HTTP $http_code)."
                return 1
                ;;
            404)
                log_error "detect_config is not available on this server (HTTP 404)."
                log_info "This endpoint is currently on the QA environment; point --api-url at the QA host."
                return 1
                ;;
            ""|000)
                log_error "Could not reach the API at ${PTC_API_URL}detect_config."
                return 1
                ;;
            *)
                log_error "detect_config failed (HTTP $http_code)."
                log_debug "Response: $body"
                return 1
                ;;
        esac
    fi

    local yaml_content
    if [[ -n "$body" ]]; then
        print_detect_summary "$body"
        yaml_content=$(render_ptc_config "$body")
    else
        yaml_content=$(render_ptc_config '{"kind":"any"}')
    fi

    if [[ "$PTC_DRY_RUN" == "true" ]]; then
        log_info "Dry run: would write $config_path with:"
        printf '%s\n' "$yaml_content"
        print_ci_block "$project_dir"
        return 0
    fi

    if [[ "$assume_yes" != "true" && -t 0 ]]; then
        printf 'Write %s? [y/N] ' "$config_path" >&2
        local reply=""
        read -r reply || true
        case "$reply" in
            y|Y|yes|YES|Yes) ;;
            *) log_info "Aborted; nothing was written."; return 0 ;;
        esac
    fi

    printf '%s\n' "$yaml_content" > "$config_path"
    log_success "Wrote $config_path"
    print_ci_block "$project_dir"
    return 0
}

# Main function
main() {
    # `init` is a subcommand, not a flag: it scaffolds a config and must run
    # before the translate-pipeline validation (which requires a source locale
    # and patterns/config that do not exist yet), so it short-circuits here.
    if [[ "${1:-}" == "init" ]]; then
        shift
        cmd_init "$@"
        exit $?
    fi

    # Argument parsing
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--source-locale)
                PTC_SOURCE_LOCALE="$2"
                shift 2
                ;;
            -p|--patterns)
                IFS=',' read -ra PTC_PATTERNS <<< "$2"
                shift 2
                ;;
            -c|--config-file)
                PTC_CONFIG_FILE="$2"
                shift 2
                ;;
            -t|--file-tag-name)
                PTC_FILE_TAG_NAME="$2"
                shift 2
                ;;
            -d|--project-dir)
                PTC_PROJECT_DIR="$2"
                shift 2
                ;;
            --api-url)
                PTC_API_URL="$2"
                shift 2
                ;;
            --api-url=*)
                PTC_API_URL="${1#*=}"
                shift
                ;;
            --api-token)
                PTC_API_TOKEN="$2"
                shift 2
                ;;
            --api-token=*)
                PTC_API_TOKEN="${1#*=}"
                shift
                ;;
            --monitor-interval)
                PTC_MONITOR_INTERVAL="$2"
                shift 2
                ;;
            --monitor-interval=*)
                PTC_MONITOR_INTERVAL="${1#*=}"
                shift
                ;;
            --monitor-max-attempts)
                PTC_MONITOR_MAX_ATTEMPTS="$2"
                shift 2
                ;;
            --monitor-max-attempts=*)
                PTC_MONITOR_MAX_ATTEMPTS="${1#*=}"
                shift
                ;;
            --action)
                PTC_ACTION="$2"
                shift 2
                ;;
            --action=*)
                PTC_ACTION="${1#*=}"
                shift
                ;;
            -v|--verbose)
                PTC_VERBOSE=true
                shift
                ;;
            -n|--dry-run)
                PTC_DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for help"
                exit 1
                ;;
        esac
    done
    
    # Argument validation
    if ! validate_args; then
        echo "Use --help for help"
        exit 1
    fi
    
    # Main logic
    log_info "Starting $SCRIPT_NAME v$VERSION"

    if [[ "$PTC_DRY_RUN" == "true" ]]; then
        log_info "Dry run mode enabled"
        log_info "Skipping preflight (no API calls are made in dry run)"
    elif ! preflight_check; then
        exit 1
    fi

    if ! process_files; then
        log_error "Error processing files"
        exit 1
    fi
    
    log_success "Processing completed successfully"
}

# Check if script is run directly, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
