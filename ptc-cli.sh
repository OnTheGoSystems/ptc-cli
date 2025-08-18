#!/bin/bash

# PTC CLI - Private Translation Cloud CLI
# Processes translation files based on language patterns

set -euo pipefail  # Strict mode: exit on errors, undefined variables and pipe errors

# Constants
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.0"

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
PTC_API_TOKEN=""
PTC_VERBOSE=false
PTC_DRY_RUN=false
PTC_MONITOR_INTERVAL=5   # seconds between status checks
PTC_MONITOR_MAX_ATTEMPTS=100  # maximum number of status checks

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

# Help function
show_help() {
    local current_branch
    current_branch=$(get_current_branch)
    
    echo -e "$SCRIPT_NAME v$VERSION - Private Translation Cloud CLI

USAGE:
    $SCRIPT_NAME [OPTIONS] --source-locale LOCALE --patterns PATTERN1,PATTERN2,...
    $SCRIPT_NAME [OPTIONS] --config-file CONFIG.yml

OPTIONS:
    -s, --source-locale LOCALE     Source language (e.g.: en, de, fr)
    -p, --patterns PATTERNS        File patterns separated by commas (e.g.: '{{lang}}.json')
    -c, --config-file FILE         YAML configuration file with all settings
    -t, --file-tag-name TAG        File tag name/branch name (default: ${GREEN}$current_branch${NC})
    -d, --project-dir DIR          Project directory (default: current)
    --api-url URL                  PTC API base URL (default: https://app.ptc.wpml.org/api/v1/)
    --api-token TOKEN              PTC API authentication token
    --monitor-interval SECONDS     Seconds between status checks (default: 5)
    --monitor-max-attempts COUNT   Maximum status check attempts (default: 100)
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
    api_token: your-token-here
    
    files:
      - file: src/locales/en.json
        output: src/locales/{{lang}}.json
        additional_translation_files:
          mo: dist/{{lang}}.mo
          php: includes/lang-{{lang}}.php
      
      - file: admin/en.json
        output: admin/{{lang}}.json

USAGE EXAMPLES:
    # Using patterns (automatic file discovery):
    $SCRIPT_NAME -s en -p 'sample-{{lang}}.json'
    $SCRIPT_NAME -s en -p '{{lang}}/**/*.json,{{lang}}.properties' -d /path/to/project
    $SCRIPT_NAME -s en -p 'i18n/{{lang}}/app.json' -t feature-branch --verbose
    $SCRIPT_NAME --source-locale en --patterns 'languages/wpsite.pot' --file-tag-name main --verbose
    
    # Using configuration file:
    $SCRIPT_NAME -c config.yml
    $SCRIPT_NAME --config-file config/translation-config.yml --verbose
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
    
    # Extract additional files as JSON object
    local additional_files
    additional_files=$(echo "$file_block" | grep -A20 '^ *additional_translation_files:' | grep '^ *[a-zA-Z_]*:' | grep -v 'additional_translation_files:')
    
    if [[ -z "$additional_files" ]]; then
        return 0
    fi
    
    # Convert to JSON format
    local json_parts=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local key=$(echo "$line" | sed 's/^ *//' | sed 's/:.*//')
            local value=$(echo "$line" | sed 's/^[^:]*: *//' | sed 's/^["\s]*//' | sed 's/["\s]*$//')
            json_parts+=("\"$key\":\"$value\"")
        fi
    done <<< "$additional_files"
    
    if [[ ${#json_parts[@]} -gt 0 ]]; then
        local json_string="{$(IFS=','; echo "${json_parts[*]}")}"
        echo "$json_string"
        log_debug "Additional files JSON: $json_string"
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
    
    if [[ -z "$PTC_API_TOKEN" ]]; then
        local config_api_token
        config_api_token=$(grep '^api_token:' "$config_file" 2>/dev/null | sed 's/^api_token: *//' | sed 's/ *$//')
        if [[ -n "$config_api_token" ]]; then
            PTC_API_TOKEN="$config_api_token"
            log_debug "Loaded api_token from config"
        fi
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
        
        # Step-based processing workflow with config file support
        process_files_in_steps_with_config "${found_files[@]}"
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
        
        # Step-based processing workflow
        process_files_in_steps "${found_files[@]}"
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
                if download_translations "$relative_file_path" "$PTC_FILE_TAG_NAME" "$base_dir" >/dev/null 2>&1; then
                    completed_files+=("$file")
                else
                    failed_files+=("$file")
                    set_file_status "$file" "failed"
                fi
            elif [[ $status_result -eq 1 ]]; then
                # Error occurred
                failed_files+=("$file")
                set_file_status "$file" "failed"
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
    
    # Return success if at least one file completed successfully
    if [[ ${#completed_files[@]} -gt 0 ]]; then
        log_success "Step-based processing completed successfully"
        return 0
    else
        log_error "No files completed successfully"
        return 1
    fi
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
            local config_file_name=$(basename "$relative_file_path")
            output_pattern=$(grep -A999 '^files:' "$PTC_CONFIG_FILE" | grep -A1 "^ *- file: *$config_file_name" | grep '^ *output:' | sed 's/^ *output: *//' | head -1)
            
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
            additional_files_json=$(extract_additional_files "$PTC_CONFIG_FILE" "$config_file_name")
            
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
            
            if [[ "$status" == "completed" ]]; then
                completed_files+=("$file")
                # Download translations
                if download_translations "$relative_file_path" "$PTC_FILE_TAG_NAME" "$base_dir"; then
                    log_debug "Downloaded translations for: $relative_file_path"
                else
                    log_warning "Failed to download translations for: $relative_file_path"
                fi
            elif [[ "$status" == "failed" ]]; then
                failed_files+=("$file")
            else
                still_monitoring+=("$file")
            fi
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
    
    # Return success if at least one file completed successfully
    if [[ ${#completed_files[@]} -gt 0 ]]; then
        log_success "Step-based processing completed successfully"
        return 0
    else
        log_error "No files completed successfully"
        return 1
    fi
}

# Function to process files in steps with explicit output files (for --files mode)
process_files_in_steps_with_outputs() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local uploaded_files=()
    local processed_files=()
    
    # Parse output files array
    local -a output_files_array
    IFS=',' read -ra output_files_array <<< "$PTC_OUTPUT_FILE_PATHS"
    
    # Step 1: Upload all files
    log_info "=== STEP 1: Uploading all files ==="
    for i in "${!files[@]}"; do
        local file="${files[$i]}"
        local output_pattern="${output_files_array[$i]}"
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would upload file: $relative_file_path with output: $output_pattern"
            uploaded_files+=("$file")
        else
            log_info "Uploading file: $relative_file_path with output: $output_pattern"
            
            if make_ptc_api_call "$file" "$relative_file_path" "$output_pattern" "$PTC_FILE_TAG_NAME" ""; then
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
            
            if [[ "$status" == "completed" ]]; then
                completed_files+=("$file")
                # Download translations
                if download_translations "$relative_file_path" "$PTC_FILE_TAG_NAME" "$base_dir"; then
                    log_debug "Downloaded translations for: $relative_file_path"
                else
                    log_warning "Failed to download translations for: $relative_file_path"
                fi
            elif [[ "$status" == "failed" ]]; then
                failed_files+=("$file")
            else
                still_monitoring+=("$file")
            fi
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
    
    # Return success if at least one file completed successfully
    if [[ ${#completed_files[@]} -gt 0 ]]; then
        log_success "Step-based processing completed successfully"
        return 0
    else
        log_error "No files completed successfully"
        return 1
    fi
}

# Function to process a single file
process_single_file() {
    local file="$1"
    
    # Get base directory and relative paths
    local base_dir=$(get_base_directory)
    local relative_file_path=$(get_relative_path "$file" "$base_dir")
    
    if [[ "$PTC_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Processing file: $relative_file_path"
        log_debug "[DRY RUN] File tag name: $PTC_FILE_TAG_NAME"
        log_debug "[DRY RUN] Base directory: $base_dir"
        
        # Generate output pattern for dry run display
        local filename=$(basename "$relative_file_path")
        local dirname=$(dirname "$relative_file_path")
        local lang_placeholder="{{lang}}"
        local output_filename="${filename//$PTC_SOURCE_LOCALE/$lang_placeholder}"
        
        if [[ "$dirname" == "." ]]; then
            local output_pattern="$output_filename"
        else
            local output_pattern="$dirname/$output_filename"
        fi
        
        log_debug "[DRY RUN] Output pattern: $output_pattern"
        log_info "[DRY RUN] Would upload file to PTC API"
        log_info "[DRY RUN] Would start file processing"
        log_info "[DRY RUN] Would monitor translation status"
        log_info "[DRY RUN] Would download and unpack translations if ready"
    else
        log_info "Processing file: $relative_file_path"
        log_debug "File tag name: $PTC_FILE_TAG_NAME"
        log_debug "Base directory: $base_dir"
        
        # Prepare API call parameters using relative paths
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
        
        log_debug "Making API call to PTC..."
        log_debug "  file_path: $relative_file_path"
        log_debug "  output_file_path: $output_file_path" 
        log_debug "  file_tag_name: $PTC_FILE_TAG_NAME"
        
        # Make API call to PTC with relative paths
        if make_ptc_api_call "$file" "$relative_file_path" "$output_file_path" "$PTC_FILE_TAG_NAME" ""; then
            # After successful upload, start file processing
            log_info "Starting file processing..."
            
            if start_processing "$file" "$relative_file_path" "$PTC_FILE_TAG_NAME"; then
                # After successful processing start, monitor translation status until completion
                log_info "Starting translation monitoring..."
                
                if monitor_translation_status "$relative_file_path" "$PTC_FILE_TAG_NAME" "$PTC_MONITOR_MAX_ATTEMPTS" "$PTC_MONITOR_INTERVAL"; then
                    # Translations completed, download them
                    log_info "Downloading completed translations..."
                    if download_translations "$relative_file_path" "$PTC_FILE_TAG_NAME" "$base_dir"; then
                        log_success "Translation workflow completed successfully"
                    else
                        log_warning "Download failed, but translations are ready"
                    fi
                else
                    local monitor_result=$?
                    case $monitor_result in
                        1)
                            log_warning "Translation status monitoring failed, but file processing was successful"
                            ;;
                        2)
                            log_warning "Translation monitoring timed out. Translations may still be in progress."
                            log_info "You can check status manually with:"
                            log_info "  curl -H \"Authorization: Bearer \$TOKEN\" \"${PTC_API_URL}source_files/translation_status?file_path=$relative_file_path&file_tag_name=$PTC_FILE_TAG_NAME\""
                            ;;
                    esac
                fi
            else
                log_warning "File processing failed, but file upload was successful"
            fi
        fi
    fi
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
            response=$(curl -s -w "%{http_code}" \
                -X POST \
                -H "Authorization: Bearer $PTC_API_TOKEN" \
                -F "file_path=$relative_file_path" \
                -F "output_file_path=$output_file_path" \
                -F "file_tag_name=$file_tag_name" \
                -F "additional_translation_files=$additional_files_json" \
                -F "file=@$absolute_file_path" \
                "$api_url" 2>/dev/null)
        else
            response=$(curl -s -w "%{http_code}" \
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
            response=$(curl -s -w "%{http_code}" \
                -X POST \
                -F "file_path=$relative_file_path" \
                -F "output_file_path=$output_file_path" \
                -F "file_tag_name=$file_tag_name" \
                -F "additional_translation_files=$additional_files_json" \
                -F "file=@$absolute_file_path" \
                "$api_url" 2>/dev/null)
        else
            response=$(curl -s -w "%{http_code}" \
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
    
    if [[ "$http_code" == "201" ]]; then
        log_success "File uploaded successfully: $relative_file_path"
        log_debug "API response: $response_body"
    else
        log_error "Failed to upload file: $relative_file_path (HTTP $http_code)"
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
        response=$(curl -s -w "%{http_code}" \
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
    
    if [[ "$http_code" == "200" ]]; then
        log_success "File processing started successfully: $relative_file_path"
        log_debug "Process API response: $response_body"
        return 0
    else
        log_error "Failed to start file processing: $relative_file_path (HTTP $http_code)"
        log_debug "Process API response: $response_body"
        return 1
    fi
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
        response=$(curl -s -w "%{http_code}" \
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
    
    if [[ "$http_code" == "200" ]]; then
        # Parse status from response
        local status=$(echo "$response_body" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "unknown")
        
        log_debug "Parsed Status: $status"
        
        # Output the status and response body for caller
        echo "$status|$response_body"
        
        # Return status code based on completion
        if [[ "$status" == "completed" ]]; then
            return 0  # Ready for download
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
        response=$(curl -s -w "%{http_code}" \
            -X GET \
            -H "Authorization: Bearer $PTC_API_TOKEN" \
            "$full_url" 2>/dev/null)
    else
        log_error "API token required for translation status check"
        return 1
    fi
    
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    if [[ "$http_code" == "200" ]]; then
        log_success "Translation status retrieved successfully: $relative_file_path"
        log_debug "Status API response: $response_body"
        
        # Parse status from response
        local status=$(echo "$response_body" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "unknown")
        local completeness=$(echo "$response_body" | grep -o '"completeness":[0-9.]*' | cut -d':' -f2 2>/dev/null || echo "0")
        
        log_info "Translation Status: $status (${completeness}% complete)"
        
        # Return status code based on completion
        if [[ "$status" == "completed" ]]; then
            return 0  # Ready for download
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
    while [[ $attempt -le $max_attempts ]]; do
        # Add delay before each status check (except the first one)
        if [[ $attempt -gt 1 ]]; then
            log_info "Waiting ${wait_interval}s before next status check..."
            log_info "You can interrupt with Ctrl+C if needed"
            sleep "$wait_interval"
        fi
        
        log_info "Status check attempt $attempt/$max_attempts..."
        
        # Check translation status
        if check_translation_status "$relative_file_path" "$file_tag_name"; then
            log_success "Translations are completed! Ready for download."
            return 0
        fi
        
        local status_result=$?
        if [[ $status_result -eq 1 ]]; then
            # Error occurred
            log_error "Failed to check translation status"
            return 1
        elif [[ $status_result -eq 2 ]]; then
            # Still in progress
            if [[ $attempt -eq $max_attempts ]]; then
                log_warning "Reached maximum attempts ($max_attempts). Translations may still be in progress."
                log_info "You can check status manually with:"
                log_info "  curl -H \"Authorization: Bearer \$TOKEN\" \"${PTC_API_URL}source_files/translation_status?file_path=$relative_file_path&file_tag_name=$file_tag_name\""
                return 2
            fi
            log_info "Translations still in progress."
        fi
        
        ((attempt++))
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
    
    # Create temporary file for download
    local temp_zip=$(mktemp /tmp/ptc_translations_XXXXXX.zip)
    
    local http_code
    if [[ -n "$PTC_API_TOKEN" ]]; then
        http_code=$(curl -s -w "%{http_code}" \
            -X GET \
            -H "Authorization: Bearer $PTC_API_TOKEN" \
            -o "$temp_zip" \
            "$full_url" 2>/dev/null)
    else
        log_error "API token required for translation download"
        rm -f "$temp_zip"
        return 1
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
            
            log_info "Unpacking translations to: $target_dir"
            log_debug "Source file directory: $source_dir"
            
            # Create temporary directory for extraction
            local temp_extract_dir=$(mktemp -d /tmp/ptc_extract_XXXXXX)
            
            # Extract ZIP to temporary directory first
            if (cd "$temp_extract_dir" && unzip -o "$temp_zip" 2>/dev/null); then
                # Move files from temp directory to target directory, preserving structure
                if find "$temp_extract_dir" -type f -name "*.json" -o -name "*.po" -o -name "*.pot" -o -name "*.mo" -o -name "*.yml" -o -name "*.yaml" 2>/dev/null | while read -r file; do
                    local filename=$(basename "$file")
                    local target_file="$target_dir/$filename"
                    log_debug "Moving $filename to $target_file"
                    mv "$file" "$target_file" 2>/dev/null || {
                        log_warning "Failed to move $filename to target location"
                        return 1
                    }
                done; then
                    log_success "Translations unpacked successfully to $target_dir"
                    rm -rf "$temp_extract_dir" "$temp_zip"
                    return 0
                else
                    log_error "Failed to move translation files to target directory"
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

# Main function
main() {
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
