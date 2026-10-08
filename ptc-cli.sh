#!/bin/bash

# PTC CLI - Private Translation Cloud CLI
# Processes translation files based on language patterns

set -euo pipefail  # Strict mode: exit on errors, undefined variables and pipe errors

# Constants
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.4.0"
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
# Environment first (B2): PTC_API_URL points every command at another PTC instance; --api-url still wins.
PTC_API_URL="${PTC_API_URL:-https://app.ptc.wpml.org/api/v1/}"
# The API token is env-first: an inherited PTC_API_TOKEN is honoured across every
# command, and --api-token overrides it. The api_token: config key is deprecated
# and ignored, so there is nothing else to reconcile — do NOT reset
# this to "", or the translate pipeline would lose the env token.
PTC_API_TOKEN="${PTC_API_TOKEN:-}"
PTC_VERBOSE=false
PTC_DRY_RUN=false
PTC_MONITOR_INTERVAL=5   # seconds between status checks
PTC_MONITOR_MAX_ATTEMPTS=100  # maximum number of status checks (left unset: max(100, 20 x files), see scale_monitor_max_attempts)
PTC_MONITOR_MAX_ATTEMPTS_SET=false  # true once a flag or the config file names it
# S2-R3B F-2 (CI-16): a wall-clock bound on the whole run, counted from the first upload and kept below the CI job's own
# limit (the recipes set 3 h). Unset: 45 minutes; --monitor-max-minutes, PTC_MONITOR_MAX_MINUTES or `monitor_max_minutes:`
# in the config name another (flag > environment > config). PTC_MONITOR_MAX_SECONDS (environment only) sets it in seconds,
# for a test. Reached with files still translating, the run stops, keeps what completed, prints the options and exits 7
# (report_still_translating); the attempts cap below is the second bound and ends the same way.
PTC_MONITOR_MAX_MINUTES_SET=false; [[ -n "${PTC_MONITOR_MAX_MINUTES:-}" ]] && PTC_MONITOR_MAX_MINUTES_SET=true
PTC_MONITOR_MAX_MINUTES="${PTC_MONITOR_MAX_MINUTES:-45}"
PTC_MONITOR_MAX_SECONDS="${PTC_MONITOR_MAX_SECONDS:-}"
PTC_MONITOR_DEADLINE=""  # the SECONDS value at which the bound is reached (start_monitor_clock)
# S2-R3B C-4: every temporary file a guide command makes, removed by cleanup (ptc_mktemp).
PTC_TMP_FILES=()
PTC_ACTION=""            # specific action to perform: upload, status, download
# Where to record every file this run writes, for a CI job that must commit the
# translations and nothing else. Empty means "do not record".
PTC_WRITTEN_MANIFEST=""
# The project an agent token works on (X-PTC-Project-Id): PTC_PROJECT_ID wins, else guide.project_id.
PTC_GUIDE_PROJECT_ID="${PTC_PROJECT_ID:-}"




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
# User-Agent (ptc-cli/<VERSION>) and X-PTC-CLI-Version: <VERSION>. It forwards to the real curl - which the test
# suites stub - so the header rides along as an ordinary -H the stubs already skip.
ptc_curl() {
    # PTC_HEADER_DUMP lets a caller read response headers without every call
    # site having to thread a -D through its own curl invocation. Only the
    # rate-limit retry sets it; everything else runs exactly as before.
    # PTC_GUIDE_PROJECT_ID (from `guide.project_id` in the config, or PTC_PROJECT_ID) names the project for an
    # agent token (agent guide ruling b: one CI secret for every product); a project token ignores it.
    # L11 (SF-31): this CLI prints the conversion pushes PTC attaches to a guide answer (suggestion, subscribe), so PTC may
    # count the switch-to-CI suggestion as told on its answers (once per delivery).
    local extra=(-H "X-PTC-Pushes: shown")
    [[ -n "${PTC_GUIDE_PROJECT_ID:-}" ]] && extra+=(-H "X-PTC-Project-Id: $PTC_GUIDE_PROJECT_ID")
    if [[ -n "${PTC_HEADER_DUMP:-}" ]]; then
        curl -H "User-Agent: $PTC_USER_AGENT" -H "X-PTC-CLI-Version: $VERSION" ${extra[@]+"${extra[@]}"} -D "$PTC_HEADER_DUMP" "$@"
    else
        curl -H "User-Agent: $PTC_USER_AGENT" -H "X-PTC-CLI-Version: $VERSION" ${extra[@]+"${extra[@]}"} "$@"
    fi
}

# `guide.project_id` of a .ptc-config.yml (empty when absent). PTC writes it when the agent guide sets a repo up.
ptc_config_project_id() { ptc_config_guide_field "$1" project_id; }

# guide.<field> of a .ptc-config.yml (project_id, session_id); empty when absent.
ptc_config_guide_field() {
    local cfg="$1" field="$2"
    [[ -f "$cfg" ]] || return 0
    awk -v f="$field" '/^guide:[[:space:]]*$/ { g = 1; next }
         g && /^[^[:space:]#]/ { g = 0 }
         g && $0 ~ "^[[:space:]]+" f ":" { v = $0; sub("^[[:space:]]+" f ":[[:space:]]*", "", v); sub(/[[:space:]]+#.*$/, "", v);
                                           gsub(/["\047]/, "", v); gsub(/[[:space:]]+$/, "", v); print v; exit }' "$cfg"
}

# --- rate limiting -----------------------------------------------------------
# create + process + bulk share ONE bucket of PTC_RATE_LIMIT_HINT requests per
# minute, and a run spends two of them per file, so any project past a handful
# of files meets a 429 partway through. Failing there is the worst outcome
# available: the files uploaded before it are already registered and the words
# may already be paid for, so the run must wait rather than abort.
readonly PTC_RATE_LIMIT_MAX_RETRIES=5
readonly PTC_RATE_LIMIT_BASE_DELAY=15
readonly PTC_RATE_LIMIT_MAX_DELAY=60
# Internal signal between a request function and the retry wrapper. It never
# reaches the shell: the wrapper turns it into 0 (recovered) or 1 (gave up).
readonly PTC_RATE_LIMITED=8
# S2-R12: a 5xx or no HTTP answer at all (curl's 000) is a transport failure between the CLI and PTC - a proxy,
# a tunnel, a restarting web worker - not PTC refusing the file. The request function returns PTC_TRANSIENT; the
# wrapper retries it with backoff, and after PTC_TRANSIENT_MAX_RETRIES returns PTC_UNREACHABLE so the caller can
# report the file as "could not reach PTC" instead of "rejected by PTC". Both values stay internal to the run.
readonly PTC_TRANSIENT=9
readonly PTC_UNREACHABLE=10
readonly PTC_TRANSIENT_MAX_RETRIES=3
# L14 (SF-43): PTC refused the push itself (HTTP 402, the trial's free automatic deliveries are used up): the run stops
# processing at the first one - the remaining files are not sent (each would be refused and recorded again) - and the
# refusal is printed once. The files count as refused, so the exit code is the one a refused run always had.
readonly PTC_REFUSED=11
PTC_TRANSIENT_BASE_DELAY="${PTC_TRANSIENT_BASE_DELAY:-5}"
[[ "$PTC_TRANSIENT_BASE_DELAY" =~ ^[0-9]+$ ]] || PTC_TRANSIENT_BASE_DELAY=5

# True for an HTTP status that says "the request did not get a PTC answer": 5xx, or 000 / empty (no response).
is_transient_http_code() {
    local code="${1:-}"
    [[ -z "$code" || "$code" == "000" || "$code" =~ ^5[0-9][0-9]$ ]]
}

# A short, single-line hint about WHO answered a transient failure: a proxy's own error code (ngrok sends an
# ngrok-error-code header and an ERR_NGROK_nnnn page; Cloudflare, nginx and ELBs put their name in the body or in
# Server), else the first 160 characters of a non-JSON body. Empty when there is nothing to add.
describe_transient_origin() {
    local body="${1:-}" header_file="${2:-}" hint="" server=""
    if [[ -n "$header_file" && -f "$header_file" ]]; then
        hint=$(grep -i '^ngrok-error-code:' "$header_file" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -E 's/^[^:]*:[[:space:]]*//')
        server=$(grep -i '^server:' "$header_file" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -E 's/^[^:]*:[[:space:]]*//')
    fi
    [[ -z "$hint" ]] && hint=$(printf '%s' "$body" | grep -Eo 'ERR_NGROK_[0-9]+' | head -n 1) || true
    if [[ -z "$hint" && -n "$body" && "${body:0:1}" != "{" ]]; then
        hint=$(printf '%s' "$body" | sed -E 's/<[^>]*>/ /g' | tr -s ' \t\r\n' ' ' | sed -E 's/^ //' | cut -c1-160)
    fi
    local out=""
    [[ -n "$hint" ]] && out="$hint"
    [[ -n "$server" ]] && out="${out:+$out; }server: $server"
    printf '%s' "$out"
}

# Seconds to wait before attempt N. Honours Retry-After when the server sends
# one; PTC does not today (checked 2026-08-04), so the fallback walks towards
# the one-minute window the limit is measured over.
rate_limit_delay() {
    local attempt="$1" header_file="${2:-}"
    local retry_after=""

    if [[ -n "$header_file" && -f "$header_file" ]]; then
        retry_after=$(grep -i '^retry-after:' "$header_file" 2>/dev/null \
            | tail -n 1 | tr -d '\r' \
            | sed -E 's/^[Rr]etry-[Aa]fter:[[:space:]]*//')
    fi

    if [[ "$retry_after" =~ ^[0-9]+$ ]] && (( retry_after > 0 )); then
        (( retry_after > 300 )) && retry_after=300   # a bad header must not hang the job
        printf '%s' "$retry_after"
        return 0
    fi

    local delay=$(( PTC_RATE_LIMIT_BASE_DELAY * attempt ))
    (( delay > PTC_RATE_LIMIT_MAX_DELAY )) && delay=$PTC_RATE_LIMIT_MAX_DELAY
    printf '%s' "$delay"
}

# Runs a request function, waiting out HTTP 429 instead of failing on it.
# The function must return PTC_RATE_LIMITED to ask for a retry; any other exit
# status is passed straight through, so non-429 failures still fail fast.
call_with_rate_limit_retry() {
    local attempt=1 delay rc header_dump=""

    header_dump=$(mktemp "${TMPDIR:-/tmp}/ptc-headers.XXXXXX" 2>/dev/null) || header_dump=""

    local transient_attempt=1
    while :; do
        PTC_HEADER_DUMP="$header_dump" "$@"
        rc=$?

        if (( rc == PTC_TRANSIENT )); then
            if (( transient_attempt > PTC_TRANSIENT_MAX_RETRIES )); then
                [[ -n "$header_dump" ]] && rm -f "$header_dump"
                log_error "Gave up after $PTC_TRANSIENT_MAX_RETRIES retries: could not reach PTC (the request got no PTC answer; this is not a rejection of the file)."
                return $PTC_UNREACHABLE
            fi
            delay=$(( PTC_TRANSIENT_BASE_DELAY * (1 << (transient_attempt - 1)) ))
            log_warning "No PTC answer (transient). Waiting ${delay}s, then retry ${transient_attempt} of ${PTC_TRANSIENT_MAX_RETRIES}."
            ptc_sleep "$delay"
            transient_attempt=$(( transient_attempt + 1 ))
            continue
        fi

        if (( rc != PTC_RATE_LIMITED )); then
            [[ -n "$header_dump" ]] && rm -f "$header_dump"
            return $rc
        fi

        if (( attempt > PTC_RATE_LIMIT_MAX_RETRIES )); then
            [[ -n "$header_dump" ]] && rm -f "$header_dump"
            log_error "PTC is still rate limiting after $PTC_RATE_LIMIT_MAX_RETRIES retries; giving up."
            log_info "The limit is per organization, so another job or a teammate may be sending requests too."
            return 1
        fi

        delay=$(rate_limit_delay "$attempt" "$header_dump")
        log_warning "PTC rate limit reached (HTTP 429). Waiting ${delay}s, then retry ${attempt} of ${PTC_RATE_LIMIT_MAX_RETRIES}."
        ptc_sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
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

# A rejected request reaches us in one of two shapes, depending on
# which server build answers:
#
#   older: HTTP 200  + {"success":false,"message":"Unprocessable Entity","code":422,...}
#   newer: HTTP 422  + the same body
#
# Trusting the status alone reads the first shape as success. That is how a
# rejected `process` call used to print "processing started successfully" and
# leave CI green with no translations, and how `download` used to save the JSON
# error body as a .zip and try to unpack it. Deployments will not
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
    local message error codes

    message=$(json_string_field "$body" "message")
    # Several endpoints answer with a plain {"error": "..."} instead of the
    # {"message", "errors"} envelope - source_files#create and #process among
    # them. Reading only "message" turned those into a bare "HTTP 422" in the
    # CI log, which is the one place the reason was needed.
    error=$(json_string_field "$body" "error")
    codes=$(printf '%s' "$body" | tr '\n' ' ' \
        | grep -Eo '"errors"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
        | head -n 1 | sed -E 's/^"errors"[[:space:]]*:[[:space:]]*//') || true

    local description="HTTP $http_code"
    if [[ -n "$message" ]]; then
        description="$description: $message"
        # Both keys present and different: keep each, they say different things.
        [[ -n "$error" && "$error" != "$message" ]] && description="$description ($error)"
    elif [[ -n "$error" ]]; then
        description="$description: $error"
    fi
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
# S2-R10 (specs/ci-integrations CI-16): a run PTC parked behind an over-limit approval is terminal for this run too:
# "awaiting_approval" waits for a person in PTC (often longer than any CI job may run), "approval_expired" ended it.
is_terminal_failure_status() {
    case "$1" in
        failed|out_of_credit|awaiting_approval|approval_expired)
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
# Rounds a file may report "draft" before it counts as rejected (E20): a draft has no uploaded file behind it,
# typically because PTC refused to process it (HTTP 422), so waiting cannot change it.
PTC_DRAFT_TERMINAL_ROUNDS="${PTC_DRAFT_TERMINAL_ROUNDS:-3}"
PTC_DRAFT_SEEN=""   # "count<TAB>path" lines; plain strings, so bash 3.2 (macOS) works

# Increments how many rounds PATH has been seen as draft, into PTC_DRAFT_ROUNDS (a global, not stdout: a
# command substitution would run it in a subshell and lose the count).
_ptc_draft_round() {
    local path="$1" line n=0 rest=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "${line#*$'\t'}" == "$path" ]]; then n="${line%%$'\t'*}"; else rest+="$line"$'\n'; fi
    done <<< "$PTC_DRAFT_SEEN"
    n=$((n + 1))
    PTC_DRAFT_SEEN="${rest}${n}"$'\t'"${path}"$'\n'
    PTC_DRAFT_ROUNDS=$n
}

# S2-R19-1 (CI-16): "PTC answered: still translating" vs "PTC could not be asked". A file whose status poll was
# unavailable (no answer, 404, 5xx, a non-JSON body) is recorded with the time of the first poll of the current streak
# and the last HTTP code; any answer from PTC clears it, so one failed poll followed by a good answer changes nothing.
# Lines "path<TAB>since<TAB>code"; plain strings, so bash 3.2 (macOS) works.
PTC_STATUS_UNAVAILABLE=""
_ptc_status_unavailable_mark() {
    local path="$1" code="$2" line since="" rest=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "${line%%$'\t'*}" == "$path" ]]; then since="${line#*$'\t'}"; since="${since%%$'\t'*}"; else rest+="$line"$'\n'; fi
    done <<< "$PTC_STATUS_UNAVAILABLE"
    [[ -z "$since" ]] && since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    PTC_STATUS_UNAVAILABLE="${rest}${path}"$'\t'"${since}"$'\t'"${code}"$'\n'
}
_ptc_status_unavailable_clear() {
    local path="$1" line rest=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "${line%%$'\t'*}" == "$path" ]] || rest+="$line"$'\n'
    done <<< "$PTC_STATUS_UNAVAILABLE"
    PTC_STATUS_UNAVAILABLE="$rest"
}
# Prints "since<TAB>code" for PATH and returns 0 when its status is unavailable since then; 1 otherwise.
_ptc_status_unavailable_get() {
    local path="$1" line
    while IFS= read -r line; do
        [[ -n "$line" && "${line%%$'\t'*}" == "$path" ]] && { printf '%s\n' "${line#*$'\t'}"; return 0; }
    done <<< "$PTC_STATUS_UNAVAILABLE"
    return 1
}
# The bound reached while PTC could not be asked about some files. stdin: "path<TAB>since<TAB>code" lines.
report_status_unreachable() {
    local line path since code n=0 first="" lines=()
    while IFS= read -r line; do [[ -n "$line" ]] && lines+=("$line"); done
    n=${#lines[@]}
    for line in "${lines[@]}"; do
        since="${line#*$'\t'}"; since="${since%%$'\t'*}"
        [[ -z "$first" || "$since" < "$first" ]] && first="$since"
    done
    code="${lines[0]##*$'\t'}"
    log_error "Could not reach PTC for the status of $n file(s) since $first ($(ptc_http_code_phrase "$code")); their state is unknown (not failed, not known to be translating):"
    for line in "${lines[@]}"; do
        path="${line%%$'\t'*}"; since="${line#*$'\t'}"; code="${since#*$'\t'}"; since="${since%%$'\t'*}"
        log_error "  ? $path (status unavailable since $since, $(ptc_http_code_phrase "$code"))"
    done
    log_error "Remedy: check the API URL (${PTC_API_URL}) and the network between this run and PTC, then retry the run once PTC answers; it downloads whatever finished."
}
ptc_http_code_phrase() {
    case "$1" in
        000|"") echo "no HTTP answer" ;;
        *) echo "HTTP $1" ;;
    esac
}

# S2-R10: the reason line for a terminal status, naming the remedy where there is one.
log_terminal_status() {
    local status="$1" relative_file_path="$2"
    case "$status" in
        awaiting_approval)
            log_error "$relative_file_path is waiting for an over-limit approval in PTC (the run costs more than the organization's approval limit); approve it in PTC (the request was emailed to the organization's administrators), then re-run" ;;
        approval_expired)
            log_error "$relative_file_path: the over-limit approval expired with no decision; re-run to ask again, or raise the approval limit in PTC" ;;
        out_of_credit)
            log_error "$relative_file_path is paused out-of-credit in PTC (the organization's credit does not cover it); it resumes when the organization tops up or upgrades" ;;
        *)
            log_error "Translation failed for $relative_file_path (status: $status)" ;;
    esac
}

# S2-R15 (Eran 2026-10-02 D1, specs/ci-integrations CI-16): a file PTC parked behind an over-limit approval is neither
# failed nor delivered: the run writes every other file, lists the parked ones, and exits 6 so CI delivers, then fails.
is_approval_status() {
    [[ "$1" == "awaiting_approval" || "$1" == "approval_expired" ]]
}

# S2-R28-3 (SF-10; translation-pipeline-engines TRN-23/24): a file PTC paused out-of-credit waits for credit the way a
# parked file waits for an approval: the run writes every complete file, lists the paused ones and exits 6, so CI
# delivers what finished; a top-up resumes exactly the paused rows.
is_parked_status() {
    is_approval_status "$1" || [[ "$1" == "out_of_credit" ]]
}

# Summary block + the run's last line for parked files (an over-limit approval, or S2-R28-3 paused out-of-credit).
# Args: completed count, then "path<TAB>status" lines on stdin. Returns 1 when files are paused out-of-credit and nothing
# completed (nothing to deliver: the run failed), else 0.
report_parked_files() {
    local completed="$1" line awaiting=0 expired=0
    local approvals=() credit=() parts=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "${line#*$'\t'}" in
            out_of_credit) credit+=("$line") ;;
            awaiting_approval) approvals+=("$line"); awaiting=$((awaiting + 1)) ;;
            *) approvals+=("$line"); expired=$((expired + 1)) ;;
        esac
    done
    if [[ ${#approvals[@]} -gt 0 ]]; then
        log_error "Parked for an over-limit approval in PTC (not translated yet; the reason is logged above): ${#approvals[@]}"
        for line in "${approvals[@]}"; do log_error "  ⏸ ${line%%$'\t'*} (${line#*$'\t'})"; done
        parts+=("${#approvals[@]} parked for an over-limit approval in PTC")
    fi
    if [[ ${#credit[@]} -gt 0 ]]; then
        log_error "Paused out-of-credit in PTC (not translated yet; they resume when the organization tops up or upgrades): ${#credit[@]}"
        for line in "${credit[@]}"; do log_error "  ⏸ ${line%%$'\t'*} (${line#*$'\t'})"; done
        parts+=("${#credit[@]} paused out-of-credit in PTC")
    fi
    if [[ ${#credit[@]} -gt 0 && "$completed" -eq 0 ]]; then
        log_error "Run failed: nothing completed (${parts[*]}); there is nothing to deliver. Top up or upgrade in PTC (Billing), then re-run"
        return 1
    fi
    (( ${#credit[@]} > 0 )) && write_paused_note "${credit[@]}"
    local joined; joined=$(printf '%s, ' "${parts[@]}"); joined=${joined%, }
    log_error "Run partial: $completed completed and written, $joined"
    (( awaiting > 0 )) && log_error "Remedy: approve the request in PTC (it was emailed to the organization's administrators); the next run picks them up once the approval is given"
    (( expired > 0 )) && log_error "Remedy: the approval expired with no decision; re-run to ask again, or raise the organization's translation approval limit in PTC (Billing > Limits); the next run picks them up once the approval is given"
    (( ${#credit[@]} > 0 )) && log_error "Remedy: the paused files resume when the organization tops up or upgrades in PTC (Billing); the next run delivers them"
    return 0
}

# S2-R28-3: the delivery's pull / merge request names the files paused out-of-credit, next to the preflight's limit note
# (CI-16: GITHUB_OUTPUT limit-note, PTC_LIMIT_NOTE_FILE for the GitLab job's merge request description). Args: "path<TAB>status".
write_paused_note() {
    local paths=() line
    for line in "$@"; do paths+=("${line%%$'\t'*}"); done
    local listed; listed=$(printf '%s, ' "${paths[@]}"); listed=${listed%, }
    local body="**Paused out-of-credit in PTC.** ${#paths[@]} file(s) were not translated because the organization's credit ran out: $listed. They resume when the organization tops up or upgrades in PTC (Billing); the next run delivers them."
    local previous=""
    [[ -n "${PTC_LIMIT_NOTE_FILE:-}" && -s "$PTC_LIMIT_NOTE_FILE" ]] && previous="$(cat "$PTC_LIMIT_NOTE_FILE")"$'\n\n'
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        local delim="PTC_LIMIT_$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
        printf 'limit-note<<%s\n%s\n%s\n' "$delim" "$previous$body" "$delim" >> "$GITHUB_OUTPUT"
    fi
    if [[ -n "${PTC_LIMIT_NOTE_FILE:-}" ]]; then
        printf '%s\n' "$previous$body" > "$PTC_LIMIT_NOTE_FILE"
    fi
    return 0
}

# 0 completed, 1 failed (terminal), 2 keep polling, 4 rejected (terminal: PTC will never translate this file),
# 5 failed segments: download it; a served archive is delivered like a completed file (S2-R2 item 1).
classify_monitored_status() {
    local status="$1"
    local relative_file_path="$2"

    if [[ "$status" == "completed" ]]; then
        return 0
    fi

    # S2-R2 item 1 (Eran 2026-10-01 decision 2, F5; specs/ci-integrations CI-7): one failed segment never blocks the
    # rest. PTC writes a failed segment by the format's missing-translation rule and still serves the file, so a
    # "failed" file is downloaded and, when the archive is served, delivered silently like a completed one.
    if [[ "$status" == "failed" ]]; then
        return 5
    fi

    if [[ "$status" == "rejected" ]]; then
        log_error "PTC rejected $relative_file_path (status: rejected); it will not be translated"
        return 4
    fi

    if is_terminal_failure_status "$status"; then
        log_terminal_status "$status" "$relative_file_path"
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
            # attached, so nothing will ever translate. Pollable for a few rounds
            # in case the attachment is still landing, then terminal (E20): one
            # such file must not keep every other file from being delivered.
            _ptc_draft_round "$relative_file_path"
            local rounds=$PTC_DRAFT_ROUNDS
            if (( rounds >= PTC_DRAFT_TERMINAL_ROUNDS )); then
                log_error "PTC has no uploaded file behind $relative_file_path (still draft after $rounds checks): rejected, not waiting for it"
                return 4
            fi
            (( rounds == 1 )) && log_warning "No uploaded file behind $relative_file_path (status: draft); will retry"
            ;;
    esac

    return 2
}

# S2-R2 item 1: a file whose translation ended with failed segments. PTC serves it with the failed segments written by
# the format's missing-translation rule; a served archive is delivered silently (0). 2 = archive not ready yet (keep
# polling); anything else is the failure it always was, reported.
deliver_failed_status_file() {
    local relative_file_path="$1"
    local base_dir="$2"
    local download_result=0
    download_translations "$relative_file_path" "$PTC_FILE_TAG_NAME" "$base_dir" >/dev/null 2>&1 || download_result=$?
    case $download_result in
        0) log_debug "Delivered $relative_file_path (PTC reported failed segments; served by the missing-translation rule)"; return 0 ;;
        2) return 2 ;;
    esac
    log_error "Translation failed for $relative_file_path (status: failed)"
    return 1
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
    guide next|submit|wait|status|skip  Agent-guide protocol transport (PTC_ORG_TOKEN).
                                   See '$SCRIPT_NAME guide --help'.
    sync [--project-id ID] [-d DIR] [--dry-run] [--json]
                                   The CI job, run locally: report the run, PTC's
                                   check, translate, report the written files
                                   (no branch). See '$SCRIPT_NAME sync --help'.
    scan [--json]                  Census of translation resources + code usages
                                   (deterministic, no network; needs python3).
    config validate [--json]       Check .ptc-config.yml: patterns resolve, {{lang}}
                                   slot, language codes, per-language outputs.
    describe apply --file F.json   Write PTC's string descriptions into gettext #. / Chrome-i18n slots.
    estimate [--json] [--offline] [--exclude PATH]  Quote: words (PTC's rule) x languages x rate over every configured file, vs the balance.
    lint source [--json]           Deterministic source-string checks (FAIL/WARN).
    audit strings [--json] [--runtime]  i18n readiness audit of the code (hardcoded strings, concatenation, plurals, formats).
    glossary fmt|validate FILE     Glossary CSV: canonical form / structure, contradictions, scripts.

OPTIONS:
    -s, --source-locale LOCALE     Source language (e.g.: en, de, fr)
    -p, --patterns PATTERNS        File patterns separated by commas (e.g.: '{{lang}}.json')
    -c, --config-file FILE         YAML configuration file with all settings
    -t, --file-tag-name TAG        File tag name/branch name (default: ${GREEN}$current_branch${NC})
    -d, --project-dir DIR          Project directory (default: current)
    --api-url URL                  PTC API base URL (default: https://app.ptc.wpml.org/api/v1/)
    --api-token TOKEN              API token override (prefer the PTC_API_TOKEN env var)
    --written-manifest FILE        Append every file this run writes to FILE,
                                   NUL-separated and relative to the repository
                                   root, for
                                   git add --pathspec-from-file=FILE --pathspec-file-nul
    --monitor-interval SECONDS     Seconds between status checks (default: 5)
    --monitor-max-attempts COUNT   Maximum status check attempts (default: 100)
    --monitor-max-minutes MINUTES  Wall-clock bound on the run from the first upload (default: 45);
                                   reached with files still translating, the run exits 7 with the options
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

# Records one written file in the manifest, if one was asked for.
#
# A CI job that commits translations has to know which files those are, and it
# cannot work them out: `git add -A` sweeps in whatever else the job left in the
# working directory, and the config's `output:` is not where the files land -
# the archive is unpacked next to the SOURCE file, by basename.
#
# NUL-separated and repository-root-relative, so a job can hand the file
# straight to `git add --pathspec-from-file=FILE --pathspec-file-nul` without
# parsing anything. Appended, never truncated: one manifest can span `ptc init`
# and the translate run that follows it.
# The manifest exists from the moment it is asked for, even when the run writes
# nothing (a monitor-bound stop before the first file, every file rejected): the
# job hands it to `git add --pathspec-from-file` unconditionally, and git treats
# a missing file as fatal where an empty one is "nothing specified", exit 0.
# Append-open, never truncate: one manifest spans `ptc init` and the run after it.
ensure_written_manifest() {
    [[ -n "$PTC_WRITTEN_MANIFEST" ]] || return 0
    : >> "$PTC_WRITTEN_MANIFEST" || log_warning "Could not create the written manifest '$PTC_WRITTEN_MANIFEST'"
}

record_written_path() {
    local absolute="$1" root="$2"

    [[ -n "$PTC_WRITTEN_MANIFEST" ]] || return 0

    local relative="${absolute#"$root"/}"

    # Still absolute means the path was not under the root we were given -
    # which happens when one of them went through a symlink, as /var does on
    # macOS. Recording it would be worse than skipping it: `git add` treats a
    # pathspec that matches nothing as fatal and stages NOTHING at all, losing
    # every other translation in the same call.
    case "$relative" in
        /*)
            log_debug "Not recording '$absolute': outside the repository root '$root'"
            return 0
            ;;
    esac

    # `git add -- <path>` takes a PATHSPEC: `--` stops option parsing, it does
    # not stop globbing. A translation written to messages[1].json - an ordinary
    # Next.js or Nuxt layout - would otherwise stage the caller's
    # messages1.json instead, and git would exit 0 having done it.
    case "$relative" in
        *'*'*|*'?'*|*'['*|:*) relative=":(literal)$relative" ;;
    esac

    printf '%s\0' "$relative" >> "$PTC_WRITTEN_MANIFEST"
}

# Function to get current git branch
#
# CI runners check out a DETACHED HEAD - GitLab, Bitbucket Pipelines and the
# Jenkins git plugin all do. There `git branch --show-current` SUCCEEDS and
# prints an empty string, so the `||` fallbacks below are never reached, and the
# caller ends up with no file tag: the run then stops in validate_args before a
# single API call. That is why every CI recipe had to pass --file-tag-name by
# hand, and why the ones that forgot translated nothing at all.
#
# The runner knows the branch even when git does not, and says so in the
# environment. Those variables are consulted only after git has failed to
# answer, so a normal checkout is unaffected.
get_current_branch() {
    local branch=""

    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        branch=$(git branch --show-current 2>/dev/null)
        if [[ -z "$branch" ]]; then
            branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            # On a detached HEAD this is the literal string "HEAD", which is a
            # worse tag than nothing - it would group every CI run together.
            [[ "$branch" == "HEAD" ]] && branch=""
        fi
    fi

    if [[ -z "$branch" ]]; then
        # GitLab, GitHub Actions, Bitbucket Pipelines, Jenkins, CircleCI.
        branch="${CI_COMMIT_REF_NAME:-${GITHUB_REF_NAME:-${BITBUCKET_BRANCH:-${BRANCH_NAME:-${CIRCLE_BRANCH:-}}}}}"
    fi

    if [[ -z "$branch" ]]; then
        branch="main"
    fi

    echo "$branch"
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

# E23: the config's `file:`/`output:` entries are relative to the project directory
# (-d, the action's project-dir), while every path the API sees is relative to the
# repository root. In a monorepo product directory the two differ, and matching the
# repository-relative path against the config found nothing: the upload then fell
# back to a generated pattern that, for a source without the locale in its name
# (locale/orig/x.pot), was the source path itself - every language was delivered
# under the source's name and the last one overwrote the source file.
#
# Prints the project directory relative to the repository root with a trailing
# slash ("" when they are the same directory).
project_dir_prefix() {
    local base_dir proj
    base_dir=$(cd "$1" 2>/dev/null && pwd) || return 0
    proj=$(cd "$PTC_PROJECT_DIR" 2>/dev/null && pwd) || return 0
    [[ "$proj" == "$base_dir" ]] && return 0
    case "$proj/" in
        "$base_dir"/*) printf '%s/' "${proj#"$base_dir"/}" ;;
    esac
}

# E27: every config entry resolves by one rule. config_entries prints one
# "<file><TAB><output>" line per entry of the files: list, whatever the order of
# the keys inside the entry and whatever sits between them (comments, blank
# lines, additional_translation_files). Values lose YAML quotes, a trailing
# comment, trailing blanks/CR and a leading "./". The lookup below is an exact
# string match on the file value - never a regex or a prefix - so it cannot
# miss an entry because output: is not the very next line, and cannot hit the
# wrong entry because one name is a prefix of another.
config_entries() {
    awk '
        function clean(v) {
            sub(/\r$/, "", v); sub(/^[ \t]+/, "", v)
            if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v) }
            else if (v ~ /^\047/) { sub(/^\047/, "", v); sub(/\047.*$/, "", v) }
            else { sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v) }
            sub(/^\.\//, "", v)
            return v
        }
        function flush() { if (f != "" || o != "") print f "\t" o; f = ""; o = "" }
        /^files:/ { infiles = 1; ind = -1; next }
        !infiles { next }
        /^[^ \t#-]/ { flush(); infiles = 0; next }
        {
            line = $0; sub(/\r$/, "", line)
            if (line ~ /^[ \t]*(#|$)/) next
            match(line, /^[ \t]*/); lead = RLENGTH
            item = (substr(line, lead + 1, 2) == "- ")
            if (item && (ind < 0 || lead <= ind)) { flush(); ind = lead; line = substr(line, 1, lead) "  " substr(line, lead + 3) }
            if (line ~ /^[ \t]*file:/) { v = line; sub(/^[ \t]*file:/, "", v); if (f == "") f = clean(v) }
            else if (line ~ /^[ \t]*output:/) { v = line; sub(/^[ \t]*output:/, "", v); if (o == "") o = clean(v) }
        }
        END { flush() }
    ' "$1"
}

# config_entry_output <config file> <project-relative file>
# The output: of the entry whose file: is exactly that path (nothing when none).
config_entry_output() {
    config_entries "$1" | awk -F '\t' -v k="${2#./}" '$1 == k { print $2; exit }'
}

# config_output_pattern <repo-relative file> <base_dir>
# The config's output pattern for a file, relative to the repository root like the
# file_path it travels with. Prints nothing when the config has no entry for it.
config_output_pattern() {
    local rel="$1" prefix key out
    prefix=$(project_dir_prefix "$2")
    key="$rel"
    [[ -n "$prefix" && "$rel" == "$prefix"* ]] && key="${rel#"$prefix"}"
    out=$(config_entry_output "$PTC_CONFIG_FILE" "$key")
    if [[ -n "$out" ]]; then
        [[ "$key" == "$rel" ]] && prefix=""
        printf '%s%s\n' "$prefix" "$out"
        return 0
    fi
    # A config that already spells repository-relative paths.
    [[ "$key" != "$rel" ]] && config_entry_output "$PTC_CONFIG_FILE" "$rel"
    return 0
}

# E27: the pattern for a file that has no output: of its own. The source locale is
# replaced only where it is a delimited token - a directory of its own (/en/) or
# a name part ending at a dot (-en. _en. .en. or a leading en.) - never inside a
# word: Frontend-ui.pot and deleting-content.pot have no locale in their name, and
# the unbounded substitution this replaces sent Front{{lang}}d-ui.pot and
# cont{{lang}}t.pot. Prints nothing and returns 1 when the name carries no such
# token: the caller must fail the file rather than send a guess.
derive_output_pattern() {
    local rel="$1" loc out
    loc=$(printf '%s' "$PTC_SOURCE_LOCALE" | sed 's/[.]/\\./g')
    out=$(printf '%s\n' "/$rel" | sed -E -e ':a' -e "s#([-_./])${loc}([./])#\\1{{lang}}\\2#" -e 'ta')
    out="${out#/}"
    [[ "$out" == *"{{lang}}"* ]] || return 1
    printf '%s\n' "$out"
}

# config_additional_files <repo-relative file> <base_dir>
# extract_additional_files for a file, looked up and re-anchored like its output.
config_additional_files() {
    local rel="$1" prefix key json
    prefix=$(project_dir_prefix "$2")
    if [[ -n "$prefix" && "$rel" == "$prefix"* ]]; then
        key="${rel#"$prefix"}"
        json=$(extract_additional_files "$PTC_CONFIG_FILE" "$key")
        if [[ -n "$json" ]]; then
            printf '%s\n' "$json" | sed "s#\"path\":\"#\"path\":\"$prefix#g"
            return 0
        fi
    fi
    extract_additional_files "$PTC_CONFIG_FILE" "$rel"
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
        [[ -z "${PTC_GUIDE_PROJECT_ID:-}" ]] && PTC_GUIDE_PROJECT_ID="$(ptc_config_project_id "$PTC_CONFIG_FILE")"
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
    # E27: exact match on the entry's file value (config_entries' cleaning), not a regex prefix.
    file_section_start=$(grep -A999 '^files:' "$config_file" | awk -v k="${target_file#./}" '
        { l = $0; sub(/\r$/, "", l) }
        l ~ /^[ \t]*- file:/ {
            v = l; sub(/^[ \t]*- file:[ \t]*/, "", v)
            if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v) }
            else if (v ~ /^\047/) { sub(/^\047/, "", v); sub(/\047.*$/, "", v) }
            else { sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v) }
            sub(/^\.\//, "", v)
            if (v == k) { print NR; exit }
        }')
    
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
    
    # The README has always documented these two as config keys, but
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
            PTC_MONITOR_MAX_ATTEMPTS_SET=true
            log_debug "Loaded monitor_max_attempts from config: $PTC_MONITOR_MAX_ATTEMPTS"
        elif [[ -n "$config_monitor_attempts" ]]; then
            log_warning "Ignoring invalid 'monitor_max_attempts: $config_monitor_attempts' in $config_file (expected a positive integer)."
        fi
    fi

    # S2-R3B F-2 (CI-16): the wall-clock bound; a flag or PTC_MONITOR_MAX_MINUTES wins over the config.
    if [[ "$PTC_MONITOR_MAX_MINUTES_SET" != "true" ]]; then
        local config_monitor_minutes
        config_monitor_minutes=$(grep '^monitor_max_minutes:' "$config_file" 2>/dev/null | sed 's/^monitor_max_minutes: *//' | sed 's/ *$//')
        if [[ "$config_monitor_minutes" =~ ^[0-9]+$ ]] && [[ "$config_monitor_minutes" -gt 0 ]]; then
            PTC_MONITOR_MAX_MINUTES="$config_monitor_minutes"
            log_debug "Loaded monitor_max_minutes from config: $PTC_MONITOR_MAX_MINUTES"
        elif [[ -n "$config_monitor_minutes" ]]; then
            log_warning "Ignoring invalid 'monitor_max_minutes: $config_monitor_minutes' in $config_file (expected a positive integer)."
        fi
    fi

    # The api_token: config key is deprecated: a token in a
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
    # E27: counted and paired by the same entry parser the upload's output lookup uses.
    local config_pairs
    config_pairs=$(config_entries "$config_file")
    files_count=$(printf '%s' "$config_pairs" | grep -c . || true)
    if [[ "$files_count" -eq 0 ]]; then
        log_error "No file entries found in 'files:' section of config file: $config_file"
        return 1
    fi
    
    log_debug "Found $files_count file(s) in config"
    
    # Validate each file entry has required fields
    local file_entries
    file_entries=$(printf '%s\n' "$config_pairs" | cut -f1)
    local output_entries
    output_entries=$(printf '%s\n' "$config_pairs" | cut -f2-)
    
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
        # E27: the same entry parser the upload's output lookup uses.
        local config_pairs
        config_pairs=$(config_entries "$PTC_CONFIG_FILE")
        file_entries=$(printf '%s\n' "$config_pairs" | cut -f1)
        output_entries=$(printf '%s\n' "$config_pairs" | cut -f2-)
        
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
    local unmapped_files=()  # E27: no output pattern could be resolved; failed loudly, never sent
    
    log_info "=== UPLOAD ACTION: Uploading all files ==="
    for file in "${files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would upload file: $relative_file_path"
            uploaded_files+=("$file")
        else
            log_info "Uploading file: $relative_file_path"
            
            # E27: a delimited source-locale token only; no token, no guess.
            local output_file_path
            if ! output_file_path=$(derive_output_pattern "$relative_file_path"); then
                log_error "No output pattern for $relative_file_path: its path has no delimited '$PTC_SOURCE_LOCALE' token (-$PTC_SOURCE_LOCALE. _$PTC_SOURCE_LOCALE. .$PTC_SOURCE_LOCALE. /$PTC_SOURCE_LOCALE/) to replace with {{lang}}. Not uploaded: give it an explicit output: in a --config-file."
                unmapped_files+=("$file")
                continue
            fi
            
            # Extract additional_translation_files if using config file
            local additional_files_json=""
            if [[ -n "$PTC_CONFIG_FILE" ]]; then
                additional_files_json=$(config_additional_files "$relative_file_path" "$base_dir")
            fi
            
            if call_with_rate_limit_retry make_ptc_api_call "$file" "$relative_file_path" "$output_file_path" "$PTC_FILE_TAG_NAME" "$additional_files_json"; then
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
    if [[ ${#unmapped_files[@]} -gt 0 ]]; then
        log_error "Not uploaded (no output pattern): ${#unmapped_files[@]} file(s)"
        return 1
    fi
    return 0
}

# Function to perform only upload action with config file support
perform_upload_action_with_config() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local uploaded_files=()
    local unmapped_files=()  # E27: no output pattern could be resolved; failed loudly, never sent
    local attempted=0
    
    log_info "=== UPLOAD ACTION: Uploading all files ==="
    for file in "${files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        # L12 (SF-33): `guide upload-sources` names the files PTC does not hold yet; the others are not sent again.
        if [[ -n "${PTC_UPLOAD_ONLY+x}" ]] && ! PTC_LEFT_OUT_FILES="$PTC_UPLOAD_ONLY" is_left_out_file "$relative_file_path"; then
            continue
        fi
        # L12 follow-up (POL-116, AGD-4): a rerun sends only the files whose sha256 changed since PTC stored them.
        if [[ -n "${PTC_UPLOAD_HELD:-}" && -f "$PTC_UPLOAD_HELD" ]] \
            && grep -qxF "$relative_file_path"$'\t'"$(_ptc_file_sha "$file")" "$PTC_UPLOAD_HELD"; then
            [[ -n "${PTC_UPLOAD_SKIPPED:-}" ]] && printf '%s\n' "$relative_file_path" >> "$PTC_UPLOAD_SKIPPED"
            continue
        fi
        attempted=$((attempted + 1))
        
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would upload file: $relative_file_path"
            uploaded_files+=("$file")
        else
            log_info "Uploading file: $relative_file_path"
            
            # Get output pattern from config for this file
            local output_pattern
            output_pattern=$(config_output_pattern "$relative_file_path" "$base_dir")
            
            if [[ -z "$output_pattern" ]]; then
                # E27: no config output resolved. Derive one only from a delimited source-locale token;
                # otherwise fail this file loudly instead of sending a guessed pattern.
                local config_entry="${relative_file_path#"$(project_dir_prefix "$base_dir")"}"
                if ! output_pattern=$(derive_output_pattern "$relative_file_path"); then
                    log_error "No output pattern for config entry '$config_entry' in $PTC_CONFIG_FILE: no output: resolved for it and its path has no delimited '$PTC_SOURCE_LOCALE' token to replace with {{lang}}. Not uploaded: add an output: to that entry."
                    unmapped_files+=("$file")
                    continue
                fi
                log_warning "Config entry '$config_entry' in $PTC_CONFIG_FILE resolved no output:; using the derived pattern $output_pattern"
            else
                log_debug "Using config output pattern: $output_pattern"
            fi
            
            # Extract additional_translation_files for this file
            local additional_files_json=""
            additional_files_json=$(config_additional_files "$relative_file_path" "$base_dir")
            
            # L12 (SF-33): `guide upload-sources` stores the bytes too - the process door with translate=false (the register
            # door keeps no bytes); nothing is translated and no free delivery is used.
            if call_with_rate_limit_retry make_ptc_api_call "$file" "$relative_file_path" "$output_pattern" "$PTC_FILE_TAG_NAME" "$additional_files_json" \
                && { [[ -z "${PTC_UPLOAD_HELD:-}" ]] || PTC_PROCESS_STORE_ONLY=1 call_with_rate_limit_retry start_processing "$file" "$relative_file_path" "$PTC_FILE_TAG_NAME"; }; then
                uploaded_files+=("$file")
                log_success "Upload completed: $relative_file_path"
                [[ -n "${PTC_UPLOAD_LOG:-}" ]] && printf '%s\t%s\n' "$relative_file_path" "$(wc -c < "$file" | tr -d ' ')" >> "$PTC_UPLOAD_LOG"
            else
                log_error "Upload failed: $relative_file_path"
            fi
        fi
    done
    
    if [[ ${#uploaded_files[@]} -eq 0 && -n "${PTC_UPLOAD_HELD:-}" && $attempted -eq 0 && ${#unmapped_files[@]} -eq 0 ]]; then
        log_info "Every file is held by PTC at the same sha256; nothing to upload"
        return 0
    fi
    if [[ ${#uploaded_files[@]} -eq 0 ]]; then
        log_error "No files were uploaded successfully"
        return 1
    fi
    
    log_success "Successfully uploaded ${#uploaded_files[@]} file(s)"
    if [[ ${#unmapped_files[@]} -gt 0 ]]; then
        log_error "Not uploaded (no output pattern): ${#unmapped_files[@]} file(s)"
        return 1
    fi
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

    # "still in progress" is a legitimate answer and stays exit 0,
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
# The default monitor budget scales with the push (agent guide decision 4): a fixed 100 polls x 5 s ran out on
# large pushes queued behind the upload rate limit. Left unset, it is max(100, 20 x files); a value named by
# --monitor-max-attempts or monitor_max_attempts in the config is kept as given.
# S2-R3B F-2 (CI-16): the wall-clock bound starts at the first upload (process_files_in_steps*); monitor_bound_reached
# ends the monitoring loop once it passes.
start_monitor_clock() {
    local secs
    if [[ -n "$PTC_MONITOR_MAX_SECONDS" ]]; then
        secs="$PTC_MONITOR_MAX_SECONDS"
    elif [[ "$PTC_MONITOR_MAX_MINUTES" =~ ^[0-9]+$ ]]; then
        secs=$(( PTC_MONITOR_MAX_MINUTES * 60 ))
    else
        secs=""
    fi
    if ! [[ "$secs" =~ ^[0-9]+$ ]] || [[ "$secs" -eq 0 ]]; then
        log_error "--monitor-max-minutes / monitor_max_minutes must be a positive integer (got '$PTC_MONITOR_MAX_MINUTES')"
        return 1
    fi
    PTC_MONITOR_DEADLINE=$(( SECONDS + secs ))
    log_debug "Monitor bound: ${secs}s from the first upload"
}

monitor_bound_reached() {
    [[ -n "$PTC_MONITOR_DEADLINE" && $SECONDS -ge $PTC_MONITOR_DEADLINE ]]
}

# S2-R3B F-2 (CI-16; Eran 2026-10-04: "explicit options"): the run stopped at a bound (the wall clock, or the attempts cap)
# with files still translating. Every completed file is already on disk. Lists the files with PTC's state for each, then
# the three options with the exact commands: (a) retry the CI job once PTC finishes, (b) check progress, (c) download
# manually and commit. stdin: "relative path<TAB>state" lines; $1 = completed count. The caller exits 7.
report_still_translating() {
    local completed="$1" line path state n=0 bound cmd pid root
    local lines=()
    while IFS= read -r line; do [[ -n "$line" ]] && lines+=("$line"); done
    n=${#lines[@]}
    if monitor_bound_reached; then
        if [[ -n "$PTC_MONITOR_MAX_SECONDS" ]]; then bound="its ${PTC_MONITOR_MAX_SECONDS}-second bound"; else bound="its ${PTC_MONITOR_MAX_MINUTES}-minute bound (monitor_max_minutes)"; fi
    else
        bound="its ${PTC_MONITOR_MAX_ATTEMPTS}-check budget (monitor_max_attempts)"
    fi
    log_warning "Still translating in PTC: $n (the run stopped at $bound; the $completed completed file(s) were written)"
    for line in "${lines[@]}"; do
        path="${line%%$'\t'*}"; state="${line#*$'\t'}"
        log_warning "  ⏱ $path ($state)"
    done
    if [[ -n "$PTC_CONFIG_FILE" ]]; then
        cmd="$SCRIPT_NAME --config-file $PTC_CONFIG_FILE"
        pid=$(ptc_config_project_id "$PTC_CONFIG_FILE")
    else
        cmd="$SCRIPT_NAME --source-locale $PTC_SOURCE_LOCALE --patterns '${PTC_PATTERNS[*]}'"
        pid=""
    fi
    [[ -n "${PTC_FILE_TAG_NAME:-}" ]] && cmd="$cmd --file-tag-name $PTC_FILE_TAG_NAME"
    pid="${pid:-${PTC_PROJECT_ID:-}}"
    if [[ "${PTC_STATUS_UNREACHABLE_COUNT:-0}" -gt 0 ]]; then
        log_info "PTC is still translating the file(s) above; ${PTC_STATUS_UNREACHABLE_COUNT} other file(s) could not be asked about (listed under \"Could not reach PTC\" below). Your options:"
    else
        log_info "PTC is still translating; nothing failed. Your options:"
    fi
    log_info "  (a) Retry this CI job once PTC finishes (GitLab: Retry on the job; GitHub: Re-run jobs), or push the next commit: the run downloads what finished."
    log_info "  (b) Check progress: $cmd --action status"
    if [[ -n "$pid" ]]; then
        root="${PTC_API_URL%%/api/*}"
        log_info "      and the project page: ${root}/dashboard/projects/${pid}"
    fi
    log_info "  (c) Download manually: $cmd --action download   (writes the finished translations; then commit them)"
}

scale_monitor_max_attempts() {
    local files="${1:-0}"
    [[ "$PTC_MONITOR_MAX_ATTEMPTS_SET" == "true" ]] && return 0
    [[ "$files" =~ ^[0-9]+$ ]] || return 0
    local scaled=$((files * 20))
    [[ $scaled -lt 100 ]] && scaled=100
    PTC_MONITOR_MAX_ATTEMPTS=$scaled
    log_debug "Monitor budget: $PTC_MONITOR_MAX_ATTEMPTS polls for $files file(s)"
}

process_files_in_steps() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local uploaded_files=()
    start_monitor_clock || return 1
    local unmapped_files=()  # E27: no output pattern could be resolved; failed loudly, never sent
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
            
            # E27: a delimited source-locale token only; no token, no guess.
            local output_file_path
            if ! output_file_path=$(derive_output_pattern "$relative_file_path"); then
                log_error "No output pattern for $relative_file_path: its path has no delimited '$PTC_SOURCE_LOCALE' token (-$PTC_SOURCE_LOCALE. _$PTC_SOURCE_LOCALE. .$PTC_SOURCE_LOCALE. /$PTC_SOURCE_LOCALE/) to replace with {{lang}}. Not uploaded: give it an explicit output: in a --config-file."
                unmapped_files+=("$file")
                continue
            fi
            
            # Extract additional_translation_files if using config file
            local additional_files_json=""
            if [[ -n "$PTC_CONFIG_FILE" ]]; then
                additional_files_json=$(config_additional_files "$relative_file_path" "$base_dir")
            fi
            
            if call_with_rate_limit_retry make_ptc_api_call "$file" "$relative_file_path" "$output_file_path" "$PTC_FILE_TAG_NAME" "$additional_files_json"; then
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
            
            local start_rc=0
            call_with_rate_limit_retry start_processing "$file" "$relative_file_path" "$PTC_FILE_TAG_NAME" || start_rc=$?
            if (( start_rc == 0 )); then
                processed_files+=("$file")
                log_success "Processing started: $relative_file_path"
            elif (( start_rc == PTC_REFUSED )); then
                refused_rest "$file" "${uploaded_files[@]}" >/dev/null
                break
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
    [[ ${#unmapped_files[@]} -gt 0 ]] && failed_files+=("${unmapped_files[@]}")  # E27: failed loudly at upload
    local parked_files=()   # S2-R15: "path<TAB>status" of files parked for an over-limit approval
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
    scale_monitor_max_attempts "${#monitoring_files[@]}"
    echo -e "\n${BLUE}[INFO]${NC} Starting translation monitoring..."
    
    # S2-R3B F-2: the first status round always runs (so a file the bound catches has PTC's state, not "unknown").
    while [[ ${#monitoring_files[@]} -gt 0 && $round -le $PTC_MONITOR_MAX_ATTEMPTS ]] && { [[ $round -eq 1 ]] || ! monitor_bound_reached; }; do
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
                # 2 means the archive is not ready yet (HTTP 202);
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
                local partial_result=1
                if [[ "$terminal_status" == "failed" ]]; then
                    deliver_failed_status_file "$relative_file_path" "$base_dir" >/dev/null 2>&1
                    partial_result=$?
                fi
                case $partial_result in
                    0) completed_files+=("$file"); set_file_status "$file" "completed" ;;
                    2) still_monitoring+=("$file"); set_file_status "$file" "processing" ;;
                    *)
                        log_terminal_status "$terminal_status" "$relative_file_path"
                        if is_parked_status "$terminal_status"; then
                            parked_files+=("$relative_file_path"$'\t'"$terminal_status")
                        else
                            failed_files+=("$file")
                        fi
                        set_file_status "$file" "$terminal_status"
                        ;;
                esac
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
                ptc_sleep "$PTC_MONITOR_INTERVAL"
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
    
    # S2-R3B F-2 (CI-16): files still translating when a bound ended the loop, with PTC's state for each.
    local still_lines=()
    if [[ ${#monitoring_files[@]} -gt 0 ]]; then
        for file in "${monitoring_files[@]}"; do
            still_lines+=("$(get_relative_path "$file" "$base_dir")"$'\t'"$(get_file_status "$file")")
        done
        printf '%s\n' "${still_lines[@]}" | report_still_translating "${#completed_files[@]}"
    fi
    
    # A partial run is not a success. This used to return 0 as soon
    # as ONE file completed, so nine failures out of ten still exited green and
    # the pipeline reported a translation run that never happened. Anything
    # failed or still unfinished is a non-zero exit; CI decides what to do with
    # it. Exit codes are documented in the README under "Exit codes".
    # S2-R15 D1: only parked files are missing - the rest is written (deliverable); exit 6 fails the job after delivery.
    if [[ ${#parked_files[@]} -gt 0 && ${#failed_files[@]} -eq 0 && ${#monitoring_files[@]} -eq 0 ]]; then
        printf '%s\n' "${parked_files[@]}" | report_parked_files "${#completed_files[@]}" || return 1
        return 6
    fi
    if [[ ${#parked_files[@]} -gt 0 ]]; then
        printf '%s\n' "${parked_files[@]}" | report_parked_files "${#completed_files[@]}"
    fi

    # S2-R3B F-2 (CI-16): nothing failed, PTC is still translating: the completed files are written, exit 7 tells CI so.
    if [[ ${#monitoring_files[@]} -gt 0 && ${#failed_files[@]} -eq 0 ]]; then
        log_error "Run stopped: ${#completed_files[@]} completed and written, ${#monitoring_files[@]} still translating in PTC"
        return 7
    fi

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
# L3-2 (POL-116): `ptc sync` reads the translate run's counts from PTC_RUN_SUMMARY (set by sync only; unset: no file).
write_run_summary() {  # uploaded completed parked rejected
    [[ -n "${PTC_RUN_SUMMARY:-}" ]] || return 0
    printf '{"uploaded": %d, "completed": %d, "parked": %d, "rejected": %d}\n' "$1" "$2" "$3" "$4" > "$PTC_RUN_SUMMARY" 2>/dev/null || true
}

process_files_in_steps_with_config() {
    local files=("$@")
    local base_dir=$(get_base_directory)
    local uploaded_files=()
    start_monitor_clock || return 1
    local unmapped_files=()  # E27: no output pattern could be resolved; failed loudly, never sent
    local processed_files=()
    # E20: files PTC refused (processing 4xx, or a draft that never gets its file). Terminal; the rest still deliver.
    local rejected_files=()
    # S2-R12: files whose processing request never got a PTC answer after retries (5xx / no response). Not rejected.
    local unreachable_files=()
    
    # Step 1: Upload all files
    log_info "=== STEP 1: Uploading all files ==="
    for file in "${files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        
        if is_left_out_file "$relative_file_path"; then
            log_warning "Left out (over the balance, census order): $relative_file_path"
            continue
        fi
        if [[ "$PTC_DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would upload file: $relative_file_path"
            uploaded_files+=("$file")
        else
            log_info "Uploading file: $relative_file_path"
            
            # Get output pattern from config for this file
            local output_pattern
            output_pattern=$(config_output_pattern "$relative_file_path" "$base_dir")
            
            if [[ -z "$output_pattern" ]]; then
                # E27: no config output resolved. Derive one only from a delimited source-locale token;
                # otherwise fail this file loudly instead of sending a guessed pattern.
                local config_entry="${relative_file_path#"$(project_dir_prefix "$base_dir")"}"
                if ! output_pattern=$(derive_output_pattern "$relative_file_path"); then
                    log_error "No output pattern for config entry '$config_entry' in $PTC_CONFIG_FILE: no output: resolved for it and its path has no delimited '$PTC_SOURCE_LOCALE' token to replace with {{lang}}. Not uploaded: add an output: to that entry."
                    unmapped_files+=("$file")
                    continue
                fi
                log_warning "Config entry '$config_entry' in $PTC_CONFIG_FILE resolved no output:; using the derived pattern $output_pattern"
            else
                log_debug "Using config output pattern: $output_pattern"
            fi
            
            # Extract additional_translation_files for this file
            local additional_files_json=""
            additional_files_json=$(config_additional_files "$relative_file_path" "$base_dir")
            
            if call_with_rate_limit_retry make_ptc_api_call "$file" "$relative_file_path" "$output_pattern" "$PTC_FILE_TAG_NAME" "$additional_files_json"; then
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
            
            local start_rc=0
            call_with_rate_limit_retry start_processing "$file" "$relative_file_path" "$PTC_FILE_TAG_NAME" || start_rc=$?
            if (( start_rc == 0 )); then
                processed_files+=("$file")
                log_success "Processing started: $relative_file_path"
            elif (( start_rc == PTC_REFUSED )); then
                local refused_file
                while IFS= read -r refused_file; do rejected_files+=("$refused_file"); done < <(refused_rest "$file" "${uploaded_files[@]}")
                break
            elif (( start_rc == PTC_UNREACHABLE )); then
                log_error "Processing could not be started (could not reach PTC): $relative_file_path"
                unreachable_files+=("$file")
            else
                log_error "Processing failed to start: $relative_file_path"
                rejected_files+=("$file")
            fi
        fi
    done
    
    if [[ ${#processed_files[@]} -eq 0 ]]; then
        log_error "No files were processed successfully"
        return 1
    fi
    
    log_info "Successfully started processing for ${#processed_files[@]} file(s)"
    [[ ${#rejected_files[@]} -gt 0 ]] && log_warning "${#rejected_files[@]} file(s) were refused by PTC; the other files continue"
    [[ ${#unreachable_files[@]} -gt 0 ]] && log_warning "${#unreachable_files[@]} file(s) could not reach PTC after retries; the other files continue"
    
    # Step 3: Monitor and download all processed files
    log_info "=== STEP 3: Monitoring and downloading translations ==="
    
    if [[ "$PTC_DRY_RUN" == "true" ]]; then
        for file in "${processed_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_info "[DRY RUN] Would monitor and download: $relative_file_path"
        done
        write_run_summary "${#uploaded_files[@]}" 0 0 0
        log_success "Step-based processing completed successfully"
        return 0
    fi
    
    # Initialize file status tracking
    local file_status_keys=()
    local file_status_values=()
    local monitoring_files=("${processed_files[@]}")
    local completed_files=()
    local failed_files=()
    [[ ${#unmapped_files[@]} -gt 0 ]] && failed_files+=("${unmapped_files[@]}")  # E27: failed loudly at upload
    local parked_files=()   # S2-R15: "path<TAB>status" of files parked for an over-limit approval
    local round=1
    
    # Initialize all files as unknown status. S2-R3B F-2: the keys are registered here (they never were in config
    # mode, so every status read was "unknown"); the bound summary and the progress letters read PTC's last state.
    for file in "${monitoring_files[@]}"; do
        local relative_file_path=$(get_relative_path "$file" "$base_dir")
        file_status_keys+=("$relative_file_path")
        file_status_values+=("unknown")
    done
    
    scale_monitor_max_attempts "${#monitoring_files[@]}"
    log_info ""
    log_info "Starting translation monitoring..."
    
    # Monitoring loop
    # S2-R3B F-2: the first status round always runs (so a file the bound catches has PTC's state, not "unknown").
    while [[ ${#monitoring_files[@]} -gt 0 ]] && [[ $round -le $PTC_MONITOR_MAX_ATTEMPTS ]] && { [[ $round -eq 1 ]] || ! monitor_bound_reached; }; do
        local still_monitoring=()
        
        for file in "${monitoring_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            
            # Get current status
            local status_output
            status_output=$(get_translation_status_quiet "$relative_file_path" "$PTC_FILE_TAG_NAME")
            local status=$(echo "$status_output" | cut -d'|' -f1)
            set_file_status "$relative_file_path" "$status"
            case "$status" in
                error|not_found) _ptc_status_unavailable_mark "$relative_file_path" "${status_output#*|}" ;;
                *) _ptc_status_unavailable_clear "$relative_file_path" ;;
            esac
            
            local file_action=0
            classify_monitored_status "$status" "$relative_file_path" || file_action=$?

            case $file_action in
                0)
                    # A file counts as completed only once its
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
                    if is_parked_status "$status"; then
                        parked_files+=("$relative_file_path"$'\t'"$status")
                    else
                        failed_files+=("$file")
                    fi
                    ;;
                4)
                    rejected_files+=("$file")
                    ;;
                5)
                    deliver_failed_status_file "$relative_file_path" "$base_dir"
                    case $? in
                        0) completed_files+=("$file") ;;
                        2) still_monitoring+=("$file") ;;
                        *) failed_files+=("$file") ;;
                    esac
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
            ptc_sleep "$PTC_MONITOR_INTERVAL"
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
    
    # S2-R3B F-2 (CI-16): files still translating when a bound ended the loop, with PTC's state for each.
    # S2-R19-1: a file PTC could not be asked about since some poll (and still not at the bound) is not "still
    # translating": it is listed under "Could not reach PTC" with since when and the HTTP code, and counts as unreachable.
    local still_lines=() status_unreachable_lines=() in_progress_files=() unavailable
    if [[ ${#monitoring_files[@]} -gt 0 ]]; then
        for file in "${monitoring_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            if unavailable=$(_ptc_status_unavailable_get "$relative_file_path"); then
                status_unreachable_lines+=("$relative_file_path"$'\t'"$unavailable")
                unreachable_files+=("$file")
            else
                in_progress_files+=("$file")
                still_lines+=("$relative_file_path"$'\t'"$(get_file_status "$relative_file_path")")
            fi
        done
        if [[ ${#in_progress_files[@]} -gt 0 ]]; then
            monitoring_files=("${in_progress_files[@]}")
        else
            monitoring_files=()
        fi
        if [[ ${#still_lines[@]} -gt 0 ]]; then
            printf '%s\n' "${still_lines[@]}" | PTC_STATUS_UNREACHABLE_COUNT=${#status_unreachable_lines[@]} report_still_translating "${#completed_files[@]}"
        fi
        if [[ ${#status_unreachable_lines[@]} -gt 0 ]]; then
            printf '%s\n' "${status_unreachable_lines[@]}" | report_status_unreachable
        fi
    fi

    if [[ ${#rejected_files[@]} -gt 0 ]]; then
        log_error "Rejected by PTC (not translated; the reason is logged once above): ${#rejected_files[@]}"
        for file in "${rejected_files[@]}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_error "  ⊘ $relative_file_path"
        done
    fi

    local upload_unreachable_count=$(( ${#unreachable_files[@]} - ${#status_unreachable_lines[@]} ))
    if [[ $upload_unreachable_count -gt 0 ]]; then
        log_error "Could not reach PTC (5xx or no response after ${PTC_TRANSIENT_MAX_RETRIES} retries; not rejected, re-run to translate): $upload_unreachable_count"
        for file in "${unreachable_files[@]:0:$upload_unreachable_count}"; do
            local relative_file_path=$(get_relative_path "$file" "$base_dir")
            log_error "  ✗ $relative_file_path"
        done
    fi

    write_run_summary "${#uploaded_files[@]}" "${#completed_files[@]}" "${#parked_files[@]}" "$(( ${#rejected_files[@]} + ${#unreachable_files[@]} ))"

    # S2-R15 D1 (CI-16): every file reached a terminal state and the parked ones (plus any rejected / unreachable) are
    # all that is missing: the completed translations are on disk, CI delivers them, and exit 6 then fails the job with
    # the approval as the reason. A re-run after the approval picks the parked files up.
    if [[ ${#parked_files[@]} -gt 0 ]]; then
        if [[ ${#failed_files[@]} -eq 0 && ${#monitoring_files[@]} -eq 0 ]]; then
            printf '%s\n' "${parked_files[@]}" | report_parked_files "${#completed_files[@]}" || return 1
            return 6
        fi
        printf '%s\n' "${parked_files[@]}" | report_parked_files "${#completed_files[@]}"
    fi

    # E20: every file reached a terminal state and only PTC-rejected (or, S2-R12, unreachable) files are missing: the
    # completed translations are on disk (deliverable), and exit 5 tells CI the run was partial.
    local missing_count=$(( ${#rejected_files[@]} + ${#unreachable_files[@]} ))
    if [[ $missing_count -gt 0 && ${#failed_files[@]} -eq 0 && ${#monitoring_files[@]} -eq 0 ]]; then
        log_error "Run partial: ${#completed_files[@]} completed and written, ${#rejected_files[@]} rejected by PTC, ${#unreachable_files[@]} could not reach PTC"
        return 5
    fi

    # S2-R3B F-2 (CI-16): nothing failed, PTC is still translating (parked / rejected files are listed above): the
    # completed files are written, exit 7 tells CI so; a re-run picks up what finishes.
    if [[ ${#monitoring_files[@]} -gt 0 && ${#failed_files[@]} -eq 0 ]]; then
        log_error "Run stopped: ${#completed_files[@]} completed and written, ${#monitoring_files[@]} still translating in PTC$( (( ${#unreachable_files[@]} > 0 )) && printf ', %s could not reach PTC' "${#unreachable_files[@]}")"
        return 7
    fi
    
    # A partial run is not a success. This used to return 0 as soon
    # as ONE file completed, so nine failures out of ten still exited green and
    # the pipeline reported a translation run that never happened. Anything
    # failed or still unfinished is a non-zero exit; CI decides what to do with
    # it. Exit codes are documented in the README under "Exit codes".
    if [[ ${#failed_files[@]} -gt 0 || ${#monitoring_files[@]} -gt 0 ]]; then
        log_error "Run incomplete: ${#completed_files[@]} completed, ${#failed_files[@]} failed, ${#rejected_files[@]} rejected, ${#monitoring_files[@]} unfinished"
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

    if [[ "$sub_status" != "unlimited" ]]; then
        local gate_balance="$prepaid_balance"
        [[ "$plan" == "trial" ]] && gate_balance="$trial_balance"
        census_limit_check "$gate_balance"
    fi

    log_success "Preflight OK: source=${project_source:-unknown}, plan=${plan:-unknown}, balance=${balance_note}"
    return 0
}

# S2-R2 item 4 (Eran 2026-10-01, decision 5, F13; specs/ci-integrations): the preflight knows the balance and, from
# the config, the census. When the local estimate (`ptc estimate`, PTC's word rule) is over the balance it says so up
# front: the files that fit are translated in census order, the rest are left out (PTC_LEFT_OUT_FILES), and the note
# naming the limit and the left-out files goes to the pull request body (GITHUB_OUTPUT limit-note) and to
# PTC_LIMIT_NOTE_FILE when set (the GitLab job's merge request description).
PTC_LEFT_OUT_FILES=""
census_limit_check() {
    local balance="$1"
    [[ -n "$balance" && "$balance" =~ ^[0-9]+$ && -n "${PTC_CONFIG_FILE:-}" && -f "${PTC_CONFIG_FILE:-}" ]] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    local est out
    est=$(_ptc_py estimate "$(dirname "$PTC_CONFIG_FILE")" json "$PTC_CONFIG_FILE" "${PTC_TARGET_LANGUAGES:-}" "" "$balance" 2>/dev/null) || return 0
    out=$(printf '%s' "$est" | python3 -c '
import json, sys
d = json.load(sys.stdin)
bal, langs = float(d["balance_words"] or 0), max(1, len(d["languages"]))
if not d.get("shortfall_words"):
    sys.exit(0)
used, left = 0.0, []
for f in d["files"]:
    need = f["words"] * langs
    if used + need <= bal:
        used += need
    else:
        left.append(f["path"])
print("NOTE\tThe census is %d words (%d files x %d languages); the balance covers %d: %d words short. "
      "The files that fit are translated in census order; left out: %s."
      % (d["words_total"], len(d["files"]), langs, bal, d["shortfall_words"], ", ".join(left) or "none"))
for p in left:
    print("LEFT\t" + p)
' 2>/dev/null) || return 0
    [[ -z "$out" ]] && return 0
    local note
    note=$(printf '%s\n' "$out" | sed -n 's/^NOTE\t//p')
    PTC_LEFT_OUT_FILES=$(printf '%s\n' "$out" | sed -n 's/^LEFT\t//p')
    log_warning "Preflight: $note"
    local body="**Translation limit reached (PTC balance).** $note Top up or raise the limit in PTC (Billing), then push again to translate the rest."
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        local delim="PTC_LIMIT_$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
        printf 'limit-note<<%s\n%s\n%s\n' "$delim" "$body" "$delim" >> "$GITHUB_OUTPUT"
    fi
    if [[ -n "${PTC_LIMIT_NOTE_FILE:-}" ]]; then
        printf '%s\n' "$body" > "$PTC_LIMIT_NOTE_FILE"
    fi
    return 0
}

# True when the config entry was left out by the preflight's census limit (S2-R2 item 4).
is_left_out_file() {
    local rel="$1" p
    [[ -z "$PTC_LEFT_OUT_FILES" ]] && return 1
    while IFS= read -r p; do
        [[ -n "$p" && ( "$rel" == "$p" || "$rel" == */"$p" ) ]] && return 0
    done <<< "$PTC_LEFT_OUT_FILES"
    return 1
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
    
    # Log the auth posture; each curl invocation below inlines its own headers.
    if [[ -n "$PTC_API_TOKEN" ]]; then
        log_debug "Using API token for authentication"
    else
        log_warning "No API token provided, request may fail"
    fi

    if [[ -n "$additional_files_json" ]]; then
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
    
    # Ask the caller to wait and try again rather than reporting a failed
    # upload: nothing was uploaded, so this file is still worth retrying.
    if [[ "$http_code" == "429" ]]; then
        return $PTC_RATE_LIMITED
    fi
    if is_transient_http_code "$http_code"; then
        local origin; origin=$(describe_transient_origin "$response_body" "${PTC_HEADER_DUMP:-}")
        log_warning "Upload got no PTC answer: $relative_file_path (HTTP ${http_code:-000}${origin:+; $origin})"
        log_debug "API response: $response_body"
        return $PTC_TRANSIENT
    fi

    # A 201 that still carries "success": false is a rejected upload dressed as
    # a created one - the content-validation path answers that way.
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

# L14 (SF-43): PTC refused the push at FILE (HTTP 402): print FILE and every file after it in the list (one per line; the
# caller counts them refused, never sent) and say the stop once on stderr. Usage: refused_rest FILE LIST...
refused_rest() {
    local file="$1" seen=false f n=0; shift
    for f in "$@"; do
        [[ "$f" == "$file" ]] && seen=true
        [[ "$seen" == "true" ]] && { printf '%s\n' "$f"; n=$((n + 1)); }
    done
    log_error "PTC refused this push (HTTP 402); the other $(( n - 1 )) file(s) were not sent: PTC refuses every file of it the same way. The refusal above says what to do." >&2
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
            ${PTC_PROCESS_STORE_ONLY:+-F "translate=false"} \
            "$process_url" 2>/dev/null)
    else
        log_error "API token required for file processing"
        return 1
    fi
    
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    # Same bucket as the upload above, so the same treatment: the file is
    # uploaded but not yet processing, and only a retry can finish the job.
    if [[ "$http_code" == "429" ]]; then
        return $PTC_RATE_LIMITED
    fi

    # S2-R12: a 5xx / no response is the path to PTC failing, not PTC refusing the file - retry it.
    if is_transient_http_code "$http_code"; then
        local origin; origin=$(describe_transient_origin "$response_body" "${PTC_HEADER_DUMP:-}")
        log_warning "Starting file processing got no PTC answer: $relative_file_path (HTTP ${http_code:-000}${origin:+; $origin})"
        log_debug "Process API response: $response_body"
        return $PTC_TRANSIENT
    fi

    if response_indicates_failure "$http_code" "$response_body"; then
        log_error "Failed to start file processing: $relative_file_path ($(describe_api_failure "$http_code" "$response_body"))"
        log_debug "Process API response: $response_body"
        # L14 (SF-43): the trial cap refuses the whole push, so every later file would be refused the same way.
        [[ "$http_code" == "402" ]] && return $PTC_REFUSED
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
    log_debug "Token: set (${#PTC_API_TOKEN} chars)"
    
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
    # without this it parses as an absent status and polls on.
    if [[ "$http_code" == "200" ]] && response_indicates_failure "$http_code" "$response_body"; then
        log_debug "Status query rejected: $(describe_api_failure "$http_code" "$response_body")"
        return 1
    fi

    # S2-R19-1: an unavailable answer carries its HTTP code ("000" = no answer), so the monitor can say PTC could not be
    # asked. A 200 that is not JSON came from something in between (a proxy, a tunnel's page), not from PTC.
    if [[ "$http_code" == "200" && ! "$response_body" =~ ^[[:space:]]*\{ ]]; then
        log_debug "Status answer is not JSON"
        echo "error|200, not JSON"
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
        echo "not_found|$http_code"
        return 1
    else
        log_debug "API error: HTTP $http_code"
        echo "error|$http_code"
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
    log_debug "Using API token: set (${#PTC_API_TOKEN} chars)"
    
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
    
    # Same two-shape rejection as elsewhere: do not report a
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
    elif [[ "$(json_string_field "$response_body" "code")" == "no_target_languages" ]]; then
        # F15: polling cannot help until PTC accepts the config commit and creates the target languages.
        log_error "Failed to check translation status: $relative_file_path ($(describe_api_failure "$http_code" "$response_body"))"
        return 3
    elif [[ "$http_code" == "404" ]]; then
        log_warning "No translations found for file: $relative_file_path"
        return 1
    elif [[ "$http_code" == "302" ]]; then
        log_warning "Translation status endpoint redirected (HTTP 302) - may not be available on this server"
        return 1
    else
        log_error "Failed to check translation status: $relative_file_path ($(describe_api_failure "$http_code" "$response_body"))"
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
        "awaiting_approval"|"approval_expired")
            echo -e "${RED}A${NC}"
            ;;
        "pending")
            echo -e "${YELLOW}.${NC}"
            ;;
        "draft")
            echo -e "${YELLOW}D${NC}"
            ;;
        "rejected")
            echo -e "${RED}R${NC}"
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
            ptc_sleep "$wait_interval"
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
    
    # Create temporary file for download.
    #
    # No .zip suffix in the template: busybox mktemp (alpine, and therefore
    # every GitLab job that uses the image we recommend) rejects anything
    # after the XXXXXX and exits 1 with "Invalid argument". GNU mktemp allows
    # it, which is why this only ever failed outside GitHub runners. unzip
    # identifies the archive by content, so the name costs nothing.
    local temp_zip=$(mktemp /tmp/ptc_translations_XXXXXX)
    log_debug "Created temporary ZIP file: $temp_zip"
    
    local http_code
    if [[ -n "$PTC_API_TOKEN" ]]; then
        if [[ "$PTC_VERBOSE" == "true" ]]; then
            log_info "Starting download from API..."
        fi
        log_debug "Starting curl download (token set, ${#PTC_API_TOKEN} chars)"
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
    # envelope. Read the file back before trusting the status.
    local download_body=""
    if [[ -f "$temp_zip" ]] && [[ "$(head -c 1 "$temp_zip" 2>/dev/null)" == "{" ]]; then
        download_body=$(head -c 4096 "$temp_zip" 2>/dev/null)
    fi

    if response_indicates_failure "$http_code" "$download_body"; then
        log_error "Failed to download translations: $relative_file_path ($(describe_api_failure "$http_code" "$download_body"))"
        rm -f "$temp_zip"
        return 1
    fi

    # 202 is the API saying "the archive is not ready yet"
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
                # Parenthesised, because `-o` binds looser than the implicit
                # `-a`: without the group, `-type f` applied only to the first
                # -name, so a DIRECTORY named e.g. "x.po" matched and was moved
                # wholesale.
                #
                # .php and .properties are here because they are documented -
                # `type: php` as an additional_translation_files companion, and
                # .properties as a source pattern. Both were dropped silently:
                # the archive carried them, the filter did not, and the user was
                # left waiting for a compiled companion that never arrived.
                #
                # E23: an entry is written to the path it is named with. PTC names
                # each one after the file's output pattern (Translation#
                # translated_filename), directories included and relative to the
                # repository root like the file_path; a bare name (no output
                # pattern) goes next to the source. Collapsing every entry onto its
                # basename in the source's directory made same-named outputs
                # (de/x.po, fr/x.po) overwrite each other and the source itself.
                local source_abs="$base_dir/$relative_file_path"
                if find "$temp_extract_dir" -type f \( -name "*.json" -o -name "*.po" -o -name "*.pot" -o -name "*.mo" -o -name "*.yml" -o -name "*.yaml" -o -name "*.php" -o -name "*.properties" -o -name "*.xml" -o -name "*.strings" -o -name "*.resx" \) 2>/dev/null | while read -r file; do
                    local filename="${file#"$temp_extract_dir"/}"
                    local target_file
                    case "/$filename/" in
                        */../*|*/./*)
                            log_error "Refusing archive entry outside the repository: $filename"
                            return 1
                            ;;
                    esac
                    if [[ "$filename" == */* ]]; then
                        target_file="$base_dir/$filename"
                    else
                        target_file="$target_dir/$filename"
                    fi
                    if [[ "$target_file" == "$source_abs" ]]; then
                        log_error "Refusing to overwrite the source file with a translation: $relative_file_path"
                        return 1
                    fi
                    mkdir -p "$(dirname "$target_file")"
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
                            # Recorded here, where the file is proven on disk,
                            # so the manifest never names something that is not
                            # there - a pathspec matching nothing is fatal to
                            # `git add` and takes the whole staging call with it.
                            record_written_path "$target_file" "$base_dir"
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
    # S2-R3B C-4: the guide commands' temporary files (and a `<file>.err` beside a request body).
    local f
    for f in ${PTC_TMP_FILES[@]+"${PTC_TMP_FILES[@]}"}; do rm -f "$f" "$f.err" 2>/dev/null || true; done
}

# S2-R3B C-4: mktemp whose file cleanup removes (an agent session runs hundreds of guide calls).
ptc_mktemp() {
    local f
    f=$(mktemp) || return 1
    PTC_TMP_FILES+=("$f")
    printf '%s' "$f"
}

# Signal handling (E18): cleanup runs on every exit; a signal then ENDS the run with the conventional 128+n
# status. The old `trap cleanup EXIT INT TERM` ran cleanup and carried on, so `timeout`, a CI cancel or a job
# timeout could not stop a monitoring loop.
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# sleep that a signal interrupts at once: bash defers a trap until a foreground child exits, but `wait`
# returns as soon as a trapped signal arrives.
ptc_sleep() {
    sleep "$1" &
    local pid=$!
    wait "$pid" 2>/dev/null || true
}

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
    # Only send Authorization when a token exists. detect_config is
    # anonymous, so an empty "Bearer " header is pointless and, on a stricter
    # proxy, could be rejected as a malformed credential.
    #
    # An empty "${auth[@]}" under `set -u` is fatal on bash < 4.4 (macOS ships
    # 3.2), so this only names the array when it is non-empty - same guard the
    # pattern loop above uses.
    local -a auth=()
    [[ -n "$PTC_API_TOKEN" ]] && auth=(-H "Authorization: Bearer $PTC_API_TOKEN")
    if [[ ${#auth[@]} -gt 0 ]]; then
        response=$(ptc_curl -s -w "%{http_code}" \
            -X POST \
            "${auth[@]}" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "${PTC_API_URL}detect_config" 2>/dev/null) || true
    else
        response=$(ptc_curl -s -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "${PTC_API_URL}detect_config" 2>/dev/null) || true
    fi
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

# The snippet runs through ptc-action rather than curling the CLI
# itself. The action SHA-pins ptc-cli and third-party actions, ships the right
# runner image, and is loop-safe (stable PR branch + a [skip translations]
# guard) - none of which a hand-rolled curl step gets for free. This is the same
# recipe the product prints, so the CLI, the product
# and the action README no longer drift. The CLI stays usable on its own - see
# the standalone note print_ci_block adds below.
render_ci_github() {
    cat <<'EOF'
name: PTC Translations
on:
  push:
    branches: [main]
  workflow_dispatch: {}

permissions:
  contents: write
  pull-requests: write
  id-token: write   # the run's identity token proves to PTC that this CI ran the commit (agent guide)

jobs:
  translate:
    runs-on: ubuntu-latest
    timeout-minutes: 180   # a first translation of a large project; the CLI stops at its own 45-minute bound (exit 7)
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 2   # HEAD's parent: lets the run name the files its commit changed (agent guide)
      - uses: OnTheGoSystems/ptc-action@v1
        with:
          api-token: ${{ secrets.PTC_API_TOKEN }}
          config-file: .ptc-config.yml
          create-pr: true
EOF
}

# GitLab resolves `include: component:` only against its OWN instance - the
# $CI_SERVER_FQDN in a component address is always the customer's server. A
# component we publish on one GitLab is therefore unreachable from gitlab.com
# or from any self-hosted instance, so the component address was a recipe that
# could never resolve for a customer. This prints the job inline instead: same
# loop-safe rules and same stable ptc/translations branch as the component, no
# cross-instance dependency. The CLI is pinned to this script's own version tag
# so the snippet is reproducible; add a sha256sum check if you want the same
# checksum guarantee the GitHub action gets from vendoring.
render_ci_gitlab() {
    cat <<EOF
ptc-translate:
  stage: deploy
  image: alpine:3.22
  # A first translation of a large project outlives GitLab's default 1 h job limit (CI-16). 3 h covers it; the CLI stops
  # on its own at a 45-minute bound (monitor_max_minutes in .ptc-config.yml), delivers what finished and exits 7.
  timeout: 3h
  # The preflight writes the CI-time limit note here (balance short of the census); the merge request description
  # below carries it, as a GitHub pull request body does.
  variables:
    PTC_LIMIT_NOTE_FILE: /tmp/ptc-limit-note
  # The job's identity token proves to PTC that this CI ran the commit (agent guide provenance).
  id_tokens:
    PTC_ID_TOKEN:
      aud: ptc
  # Loop-safe twice over: the job only runs on a push to the default branch (the
  # translation push targets ptc/translations, so it cannot retrigger this job),
  # and rules: below refuses a commit marked [skip translations].
  rules:
    # The second condition is what keeps this loop-safe, and it has to live
    # here: GitLab evaluates rules: against the commit message, whereas
    # \`[skip ci]\` in the message would suppress the pipeline of the merge
    # request itself - leaving the translations untested and, with "Pipelines
    # must succeed" enabled, unmergeable.
    - if: '\$CI_PIPELINE_SOURCE == "push" && \$CI_COMMIT_BRANCH == \$CI_DEFAULT_BRANCH && \$CI_COMMIT_MESSAGE !~ /\[skip translations\]/'
  before_script:
    # jq is never invoked by the CLI. unzip is - it unpacks the downloaded
    # translations; alpine already provides it as a busybox applet, so it is
    # named here only to keep the job working if the image is ever changed.
    # git is needed by the push step below, not by the CLI.
    - apk add --no-cache bash curl git unzip python3
  script:
    # Downloaded OUTSIDE the checkout: anything this job writes into the working
    # tree is a file the commit below could sweep into the merge request, and
    # the CLI is 100+ KB of it.
    # A CI/CD variable PTC_CLI_URL pins another copy of the CLI (curl accepts
    # file://, e.g. file://\$CI_PROJECT_DIR/cli/ptc-cli.sh for the repository's own).
    - curl -fsSL "\${PTC_CLI_URL:-https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/v${VERSION}/ptc-cli.sh}" -o /tmp/ptc-cli.sh
    - chmod +x /tmp/ptc-cli.sh
    - rm -f /tmp/ptc-written /tmp/ptc-limit-note
    # Report the run to PTC's agent guide (scan, config digests, identity token); never fails the job.
    - /tmp/ptc-cli.sh guide action-run --config-file .ptc-config.yml || true
    # Check first (agent guide): PTC reports missing information for this commit; it never withholds the translation.
    - PTC_ORG_TOKEN="\${PTC_ORG_TOKEN:-\$PTC_API_TOKEN}" /tmp/ptc-cli.sh guide check --json --config-file .ptc-config.yml > /tmp/ptc-check.json || true
    # The merge request's description carries PTC's findings (set by the push below; the project setting in PTC turns
    # them off). They are printed here too, so every job log shows them, also when there is nothing new to push.
    - ptc_mr_description="\$(/tmp/ptc-cli.sh guide mr-description --file /tmp/ptc-check.json)"
    # Exit 5 = partial: PTC rejected some files or could not be reached for them, and
    # every other file was written.
    # Exit 6 = partial: some files wait in PTC (an over-limit approval, or paused
    # out-of-credit) and every other file was written. Exit 7 = the translation is still running in PTC at the
    # CLI's monitor bound and every finished file was written. Deliver those below,
    # then fail the job at the end with the reason.
    - ptc_rc=0
    - /tmp/ptc-cli.sh --config-file .ptc-config.yml --written-manifest /tmp/ptc-written || ptc_rc=\$?
    - if [ "\$ptc_rc" -ne 0 ] && [ "\$ptc_rc" -ne 5 ] && [ "\$ptc_rc" -ne 6 ] && [ "\$ptc_rc" -ne 7 ]; then exit "\$ptc_rc"; fi
    # Exit 7: the delivery-commit report below tells PTC the run stopped while it was still translating.
    - ptc_stopped=""; if [ "\$ptc_rc" -eq 7 ]; then ptc_stopped="--stopped-reason monitor_bound"; fi
    # Pushing needs a token that may write to the repository. CI_JOB_TOKEN can,
    # but ONLY if a maintainer turns on Settings > CI/CD > Job token permissions
    # > "Allow Git push requests to the repository" (GitLab 18.4+, off by
    # default). Otherwise set PTC_GIT_PUSH_TOKEN to a project access token with
    # the write_repository scope, as a masked CI/CD variable.
    # Staged from the manifest, so the merge request carries the translations and
    # nothing else - not this job's downloads, not whatever an earlier step in
    # your pipeline left in the working directory.
    #
    # \`|| true\` is not cosmetic: if a translation lands on a path your
    # .gitignore covers, git exits 1 while still staging everything else, and
    # GitLab would abort the job on that exit code alone.
    #
    # Staging comes BEFORE the check, and the check reads the index: on the
    # first run the translations are new files, and a plain \`git diff\` only
    # looks at tracked ones - it would report "nothing changed", skip the push,
    # and leave a green job that produced no merge request.
    - |
      git config user.email "ci@ptc"
      git config user.name "PTC Translate"
      git checkout -B ptc/translations
      git add --pathspec-from-file=/tmp/ptc-written --pathspec-file-nul || true
      if ! git diff --cached --quiet; then
        git commit -m "chore(i18n): update translations via PTC [skip translations]"
        ptc_mr_description="\$(/tmp/ptc-cli.sh guide mr-description --file /tmp/ptc-check.json)"
        git push -o merge_request.create \\
                 -o merge_request.target="\$CI_DEFAULT_BRANCH" \\
                 -o merge_request.title="Update translations from PTC" \\
                 -o merge_request.description="\$ptc_mr_description" \\
                 -f "https://gitlab-ci-token:\${PTC_GIT_PUSH_TOKEN:-\$CI_JOB_TOKEN}@\${CI_SERVER_HOST}/\${CI_PROJECT_PATH}.git" HEAD:ptc/translations
        # PTC observes its delivery on the translations branch (P4 T14): the commit and its delivered files'
        # sha256 (S2-R14: a trusted report of PTC's delivery on the translations branch is the delivery proof).
        /tmp/ptc-cli.sh guide delivery-commit --commit "\$(git rev-parse HEAD)" --branch ptc/translations --source-commit "\$CI_COMMIT_SHA" --config-file .ptc-config.yml \$ptc_stopped || true
      elif [ -n "\$ptc_stopped" ]; then
        # Nothing finished inside the bound: PTC still hears that this run stopped, so the guide says "re-run the job".
        /tmp/ptc-cli.sh guide delivery-commit \$ptc_stopped --source-commit "\$CI_COMMIT_SHA" --config-file .ptc-config.yml || true
      fi
    - if [ "\$ptc_rc" -eq 5 ]; then echo "PTC rejected some files or could not be reached for them (see 'Rejected by PTC' / 'Could not reach PTC' above); the rest was delivered."; exit 5; fi
    - if [ "\$ptc_rc" -eq 6 ]; then echo "Some files wait in PTC - parked for an over-limit approval, or paused out-of-credit (see the lists above); the rest was delivered. Approve in PTC or top up the credit, then re-run."; exit 6; fi
    - if [ "\$ptc_rc" -eq 7 ]; then echo "The translation is still running in PTC (see 'Still translating in PTC' above); the finished files were delivered. Retry this job once PTC finishes, or check progress / download manually with the commands printed there."; exit 7; fi
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
            printf '\n# GitLab CI — .gitlab-ci.yml (store PTC_API_TOKEN as a masked CI/CD variable):\n'
            render_ci_gitlab
            ;;
    esac
    # The action/component is the maintained path - it pins ptc-cli by checksum,
    # brings its own runner image and is loop-safe. The CLI still runs on its
    # own for any other CI, a cron, or a local check; wrap this in any step:
    printf '\n# Prefer the pipeline above. To run the CLI directly instead:\n'
    printf '#   ./ptc-cli.sh --config-file .ptc-config.yml\n'
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
    detect_config is anonymous — init needs no API token. A token is only
    required later, to upload and translate."
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

    # `ptc init` requires no token. detect_config is
    # anonymous, and config generation is the step a developer runs
    # BEFORE they have a token - so demanding one here blocked the exact
    # first-use path it exists to serve, including trial orgs that cannot mint a
    # token at all. A token, if present, is still forwarded (harmless; the
    # endpoint ignores it), so a token-in-env run is unchanged.
    if [[ -z "$PTC_API_TOKEN" ]]; then
        log_debug "No API token set; detect_config is anonymous, continuing without one."
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
                log_info "Check --api-url. The endpoint is live on the default host; a self-hosted instance may predate it."
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

# ============================================================================
# Agent guide: `ptc guide`, `ptc scan`, `ptc config validate`
# ============================================================================
# The structured work (YAML/PO/JSON parsing, JSON output) runs in python3, which
# these commands require; the translate pipeline itself still needs only bash +
# curl. The helper is embedded so the CLI stays a single file.
PTC_GUIDE_DIR=".ptc"
PTC_PY_HELPER=$(cat <<'PTC_PY_EOF'
import glob
import collections, json, os, re, subprocess, sys

LANGS = set("""aa ab af ak am an ar as av ay az ba be bg bh bi bm bn bo br bs ca ce ch co cr cs cu cv cy da de dv dz ee el en eo es et eu fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy hz ia id ie ig ii ik io is it iu ja jv ka kg ki kj kk kl km kn ko kr ks ku kv kw ky la lb lg li ln lo lt lu lv mg mh mi mk ml mn mr ms mt my na nb nd ne ng nl nn no nr nv ny oc oj om or os pa pi pl ps pt qu rm rn ro ru rw sa sc sd se sg si sk sl sm sn so sq sr ss st su sv sw ta te tg th ti tk tl tn to tr ts tt tw ty ug uk ur uz ve vi vo wa wo xh yi yo za zh zu fil haw yue""".split())
LANG_RE = re.compile(r"^([a-z]{2,3})(?:(?:_|-)(?:[A-Z]{2}|[A-Z][a-z]{3}|[0-9]{3})(?:[_-][A-Z]{2})?|-[a-z]{2})?$")
NON_PRODUCT = re.compile(r"(^|/)(spec|specs|test|tests|__tests__|fixtures|samples|examples|e2e)(/|$)")
SKIP_DIRS = {".git", "node_modules", "vendor", "tmp", "log", "coverage", "dist", "build", ".bundle", "public/packs", ".ptc"}
CODE_EXT = {".rb", ".erb", ".haml", ".slim", ".js", ".jsx", ".ts", ".tsx", ".vue", ".php", ".twig", ".svelte", ".mjs", ".cjs"}
PLURAL_KEYS = {"zero", "one", "two", "few", "many", "other"}
# Never part of the census: dependencies, scratch, fixtures and task notes (plus the repo's .ptcignore).
EXCLUDE_PREFIXES = ("node_modules/", "vendor/", "tmp/", "spec/fixtures/", "test/fixtures/", "tests/fixtures/", "tasks/", ".git/")


def ptcignore_patterns(root):
    try:
        lines = open(os.path.join(root, ".ptcignore"), encoding="utf-8").read().splitlines()
    except OSError:
        return []
    return [l.strip() for l in lines if l.strip() and not l.strip().startswith("#")]


def excluded(path, patterns):
    import fnmatch
    if path.startswith(EXCLUDE_PREFIXES) or any(("/" + x) in "/" + path for x in EXCLUDE_PREFIXES[:6]):
        return True
    for pat in patterns:
        pat = pat.lstrip("/")
        if pat.endswith("/"):
            if path.startswith(pat) or ("/" + pat) in "/" + path:
                return True
        elif fnmatch.fnmatch(path, pat) or fnmatch.fnmatch(os.path.basename(path), pat) or path.startswith(pat.rstrip("*") + "/"):
            return True
    return False


def is_lang(code):
    m = LANG_RE.match(code or "")
    return bool(m) and m.group(1) in LANGS


def list_files(root):
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                             capture_output=True, check=True).stdout.decode("utf-8", "replace")
        files = [f for f in out.split("\0") if f]
    except Exception:
        files = []
        for d, dirs, fs in os.walk(root):
            dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
            for f in fs:
                files.append(os.path.relpath(os.path.join(d, f), root))
    res = []
    ignore = ptcignore_patterns(root)
    for f in files:
        parts = f.split("/")
        if any(p in SKIP_DIRS for p in parts[:-1]) or excluded(f, ignore):
            continue
        res.append(f)
    return sorted(set(res))


def git(root, *args):
    try:
        return subprocess.run(["git", "-c", "safe.directory=*", "-C", root] + list(args), capture_output=True, check=True).stdout.decode().strip()
    except Exception:
        return ""


# ---------------- parsers ----------------
YAML_ESCAPES = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f", "r": "\r",
                "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0", "L": "\u2028",
                "P": "\u2029"}
YAML_ESCAPE_RE = re.compile(r"\\(x[0-9A-Fa-f]{2}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)")


def unquote(s):
    """A YAML scalar as PyYAML reads it on one line: double quotes resolve their escapes (F27: `\\"` and `\\n`),
    single quotes their doubled quote."""
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] == '"':
        def esc(m):
            e = m.group(1)
            return chr(int(e[1:], 16)) if len(e) > 1 else YAML_ESCAPES.get(e, m.group(0))
        return YAML_ESCAPE_RE.sub(esc, s[1:-1])
    if len(s) >= 2 and s[0] == s[-1] == "'":
        return s[1:-1].replace("''", "'")
    return s


def parse_yaml_leaves(text):
    """Minimal YAML reader for locale files: nested maps of scalars, with anchors
    (`&name`), aliases (`*name`) and merge keys (`<<: *name`, `<<: [*a, *b]`)
    expanded the way PyYAML reads them, so a scan counts the same strings with
    or without PyYAML. Returns (leaves: list of (dotted_key, value), comments)."""
    leaves, stack, comments = {}, [], 0
    explicit = set()  # keys written out in the file; a merge never overrides them
    map_anchors, scalar_anchors = {}, {}
    lines = text.split("\n")
    i, n = 0, len(lines)

    def copy_anchor(name, target):
        if name in scalar_anchors:
            if target not in explicit:
                leaves[target] = scalar_anchors[name]
            return
        prefix = map_anchors.get(name)
        if prefix is None:
            return
        for k, v in list(leaves.items()):
            if k.startswith(prefix + "."):
                dest = target + k[len(prefix):] if target else k[len(prefix) + 1:]
                if dest not in explicit and dest not in leaves:
                    leaves[dest] = v

    while i < n:
        raw = lines[i]
        s = raw.strip()
        i += 1
        if not s or s == "---":
            continue
        if s.startswith("#"):
            comments += 1
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if s.startswith("- "):
            continue  # list items belong to the key above (counted once)
        m = re.match(r"""^("(?:[^"\\]|\\.)*"|'[^']*'|[^:#][^:]*?)\s*:(?:\s+(.*))?$""", s)
        if not m:
            continue
        key, val = unquote(m.group(1)), (m.group(2) or "").strip()
        while stack and stack[-1][0] >= indent:
            stack.pop()
        parent = ".".join(k for _, k in stack)
        path = [k for _, k in stack] + [key]
        dotted = ".".join(path)
        if val.startswith("#"):
            val = ""
        if key == "<<" and m.group(1) == "<<":
            for name in re.findall(r"\*([^\s,\]\[]+)", val):
                copy_anchor(name, parent)
            continue
        anchor = None
        am = re.match(r"^&([^\s]+)(?:\s+(.*))?$", val)
        if am:
            anchor, val = am.group(1), (am.group(2) or "").strip()
            if val.startswith("#"):
                val = ""
        if val.startswith("*") and re.match(r"^\*[^\s]+$", val):
            explicit.add(dotted)
            name = val[1:]
            if name in scalar_anchors:
                leaves[dotted] = scalar_anchors[name]
            else:
                copy_anchor(name, dotted)
            continue
        if val == "":
            # map or list follows
            j = i
            while j < n and (not lines[j].strip() or lines[j].strip().startswith("#")):
                j += 1
            # F27: a key with nothing under it is null to PyYAML: one empty string (PTC's en.yml `service_errors:`).
            no_children = j >= n or (len(lines[j]) - len(lines[j].lstrip(" ")) <= indent and not lines[j].strip().startswith("- "))
            if no_children or lines[j].strip().startswith("- "):
                leaves[dotted] = ""
                explicit.add(dotted)
                if anchor:
                    scalar_anchors[anchor] = ""
                continue
            if anchor:
                map_anchors[anchor] = dotted
            stack.append((indent, key))
            continue
        if val[0] in "|>":
            buf = []
            while i < n and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip(" ")) > indent):
                buf.append(lines[i].strip())
                i += 1
            val = "\n".join(buf)
        leaves[dotted] = unquote(val)
        explicit.add(dotted)
        if anchor:
            scalar_anchors[anchor] = unquote(val)
    return list(leaves.items()), comments


PH_RE = re.compile(r"%\{\w+\}|%<\w+>[sd]|%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?[sdifFeEgGxXuc]|\{\{\s*[\w.]+\s*\}\}|\{\w+\}")


def count_ph(s):
    return len(PH_RE.findall(s or ""))


def yaml_leaves(text):
    """Leaves of a locale YAML file. PyYAML when it is installed (anchors, merge
    keys and flow maps resolve exactly as Rails reads them); otherwise the
    built-in reader, which covers plain nested maps."""
    try:
        import yaml
    except ImportError:
        return parse_yaml_leaves(text)
    try:
        doc = yaml.load(text, Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader))
    except Exception:
        return parse_yaml_leaves(text)
    out = []

    def walk(o, pre):
        if isinstance(o, dict):
            for k in o:
                walk(o[k], pre + [str(k)])
        else:
            out.append((".".join(pre), "" if o is None or isinstance(o, (list, dict)) else str(o)))
    walk(doc, [])
    comments = sum(1 for line in text.split("\n") if line.strip().startswith("#"))
    return out, comments


def stats_yaml(text):
    leaves, comments = yaml_leaves(text)
    # drop the locale root
    keys, ph, plural_groups = [], 0, set()
    for k, v in leaves:
        parts = k.split(".")
        if len(parts) > 1 and is_lang(parts[0]):
            parts = parts[1:]
        if parts[-1] in PLURAL_KEYS and len(parts) > 1:
            plural_groups.add(".".join(parts[:-1]))
        keys.append(".".join(parts))
        ph += count_ph(v)
    # a plural group is ONE entry
    entries = [k for k in keys if not (k.rsplit(".", 1)[-1] in PLURAL_KEYS and k.rsplit(".", 1)[0] in plural_groups)]
    entries += sorted(plural_groups)
    return {"count": len(entries), "placeholders": ph, "plurals": len(plural_groups), "contexts": 0,
            "comments": comments}, set(entries)


def po_unescape(s):
    return s.encode("utf-8").decode("unicode_escape").encode("latin-1", "replace").decode("utf-8", "replace") if "\\" in s else s


def parse_po(text):
    entries, cur, field, comm = [], {}, None, False

    def flush():
        if "msgid" in cur and cur["msgid"] != "":
            entries.append(dict(cur, _comment=comm))
    for line in text.split("\n"):
        s = line.strip()
        if not s:
            if cur:
                flush(); cur, field, comm = {}, None, False
            continue
        if s.startswith("#"):
            if s.startswith("#~"):
                continue
            if cur and "msgid" in cur and field and field != "_":
                flush(); cur, field, comm = {}, None, False
            if s.startswith("#.") or s.startswith("# ") or s == "#":
                comm = comm or s.startswith("#.") or s.startswith("# ")
            continue
        m = re.match(r'^(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s+"(.*)"$', s)
        if m:
            if m.group(1) in ("msgctxt",) and "msgid" in cur:
                flush(); cur, comm = {}, False
            if m.group(1) == "msgid" and "msgid" in cur:
                flush(); cur, comm = {}, False
            field = m.group(1)
            cur[field] = m.group(2)
        elif s.startswith('"') and field:
            cur[field] = cur.get(field, "") + s[1:-1]
    if cur:
        flush()
    return entries


def stats_po(text):
    es = parse_po(text)
    ph = sum(count_ph(e.get("msgid", "")) for e in es)
    return {"count": len(es), "placeholders": ph, "plurals": sum(1 for e in es if "msgid_plural" in e),
            "contexts": sum(1 for e in es if "msgctxt" in e), "comments": sum(1 for e in es if e["_comment"])}, \
        set(po_unescape(e["msgid"]) for e in es)


def flatten_json(obj, prefix=""):
    if isinstance(obj, dict):
        for k in sorted(obj):
            yield from flatten_json(obj[k], f"{prefix}.{k}" if prefix else str(k))
    elif isinstance(obj, list):
        yield prefix, json.dumps(obj)
    else:
        yield prefix, "" if obj is None else str(obj)


def stats_json(text):
    try:
        obj = json.loads(text)
    except Exception:
        return None, set()
    leaves = list(flatten_json(obj))
    plural_re = re.compile(r"_(zero|one|two|few|many|other|plural)$")
    groups = set(plural_re.sub("", k) for k, _ in leaves if plural_re.search(k))
    keys = set(plural_re.sub("", k) for k, _ in leaves)
    return {"count": len(keys), "placeholders": sum(count_ph(v) for _, v in leaves), "plurals": len(groups),
            "contexts": sum(1 for k, _ in leaves if re.search(r"_context$|_ctx$", k)), "comments": 0}, keys


# ---------------- detection ----------------
def lang_template(path):
    """Return (pattern_with_{{lang}}, lang) or None when no language slot is visible in the path."""
    parts = path.split("/")
    fn = parts[-1]
    stem, ext = os.path.splitext(fn)
    # filename is the language: en.yml, de_DE.po
    if is_lang(stem):
        return "/".join(parts[:-1] + ["{{lang}}" + ext]), stem
    # name.en.yml / name-de_DE.po / name_de.json
    m = re.match(r"^(.*?)([._-])([A-Za-z]{2,3}(?:[_-][A-Za-z]{2,4})?)$", stem)
    if m and is_lang(m.group(3)):
        return "/".join(parts[:-1] + [m.group(1) + m.group(2) + "{{lang}}" + ext]), m.group(3)
    # a directory is the language: locales/de/common.json
    for i in range(len(parts) - 2, -1, -1):
        if is_lang(parts[i]) and parts[i] not in ("js", "ts", "db", "lib", "app", "src", "api", "bin", "css", "doc", "id", "it", "is", "to", "am", "as", "be", "no", "or", "my"):
            return "/".join(parts[:i] + ["{{lang}}"] + parts[i + 1:]), parts[i]
    return None


def classify(path, root):
    ext = os.path.splitext(path)[1].lower()
    if ext in (".pot", ".po"):
        return "po"
    if ext in (".yml", ".yaml"):
        low = path.lower()
        if "locale" in low or "/i18n/" in "/" + low:
            try:
                with open(os.path.join(root, path), encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        s = line.strip()
                        if not s or s.startswith("#") or s == "---":
                            continue
                        return "yaml" if re.match(r"^['\"]?([A-Za-z_-]+)['\"]?:\s*$", s) and is_lang(re.match(r"^['\"]?([A-Za-z_-]+)", s).group(1)) else None
            except OSError:
                return None
        return None
    if ext == ".json":
        low = "/" + path.lower()
        if any(x in low for x in ("/locales/", "/locale/", "/i18n/", "/lang/", "/translations/", "/messages/")) and lang_template(path):
            return "json"
    return None


def workspace_fingerprint(root, sets, named=None):
    # L2 (POL-116): the run key when there is no commit. sha256 over the sorted "<path>\n<sha256 of the bytes>\n" list of
    # every source file in every resource set (paths relative to the scan root, forward slashes); an unreadable file
    # counts with an empty digest. Stable across runs, changes with one byte. SF-22 (L8): `named` ({path: bytes}, the
    # files guide tasks named, `ptc guide action-run`) adds their entries, so a run after an edit to one gets a new key.
    import hashlib
    entries = set("%s\n%s\n" % (path, hashlib.sha256(data).hexdigest()) for path, data in (named or {}).items())
    for s in sets:
        for sf in s["source_files"]:
            try:
                with open(os.path.join(root, sf["path"]), "rb") as fh:
                    digest = hashlib.sha256(fh.read()).hexdigest()
            except OSError:
                digest = ""
            entries.add("%s\n%s\n" % (sf["path"].replace(os.sep, "/"), digest))
    return hashlib.sha256("".join(sorted(entries)).encode("utf-8")).hexdigest()


def scan(root, source_locale, config_pairs):
    root = os.path.abspath(root)
    files = list_files(root)
    groups = {}  # (format, pattern) -> {lang: [paths]}
    pots = []
    for f in files:
        if NON_PRODUCT.search(f):
            continue
        fmt = classify(f, root)
        if not fmt:
            continue
        if f.endswith(".pot"):
            pots.append(f)
            continue
        lt = lang_template(f)
        if not lt:
            continue
        pat, lang = lt
        groups.setdefault((fmt, pat), {}).setdefault(lang, []).append(f)

    src = source_locale or "en"
    sets, usage_keys = [], {}

    def add_set(fmt, pattern, source_paths, langs):
        sf = []
        for p in sorted(set(source_paths)):
            try:
                text = open(os.path.join(root, p), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            st, keys = (stats_yaml if fmt == "yaml" else stats_po if fmt == "po" else stats_json)(text)
            if st is None:
                continue
            lang = lang_template(p)[1] if lang_template(p) else src
            sf.append(dict({"path": p, "lang": lang}, **st))
            usage_keys[p] = (fmt, keys)
        if sf:
            sets.append({"format": "yaml" if fmt == "yaml" else "po" if fmt == "po" else "json",
                         "source_pattern": pattern, "source_files": sf,
                         "existing_languages": sorted(l for l in langs if l.split("_")[0].split("-")[0] != src.split("_")[0].split("-")[0])})

    # gettext: a .pot is the source; .po siblings in the same dir give the languages
    # Compiled/derived siblings count as existing translations too: WordPress
    # plugins ship name-de_DE.mo next to (or one level above) pot/name.pot, and
    # JED JSON as name-de_DE-handle.json.
    by_dir = {}
    for f in files:
        if f.endswith((".po", ".mo", ".json")) and not NON_PRODUCT.search(f):
            by_dir.setdefault(os.path.dirname(f), []).append(f)
    for pot in sorted(pots):
        d = os.path.dirname(pot)
        stem = os.path.splitext(os.path.basename(pot))[0]
        found = {}  # ext -> (pattern, langs)
        for dd in sorted({d, os.path.dirname(d)}):
            for f in by_dir.get(dd, []):
                name, ext = os.path.splitext(os.path.basename(f))
                segs = name.split("-")
                for i, seg in enumerate(segs):
                    if is_lang(seg) and "-".join(segs[:i] + segs[i + 1:]) == stem:
                        pat = "/".join(filter(None, [dd, "-".join(segs[:i] + ["{{lang}}"] + segs[i + 1:]) + ext]))
                        e = found.setdefault(ext, [pat, set()])
                        e[1].add(seg)
                        break
                else:
                    if ext == ".po" and is_lang(name) and dd == d:
                        e = found.setdefault(ext, [dd + "/{{lang}}.po" if dd else "{{lang}}.po", set()])
                        e[1].add(name)
        langs = set()
        for ext in found:
            langs |= found[ext][1]
        pat = next((found[e][0] for e in (".po", ".mo", ".json") if e in found), None)
        for k in [k for k in groups if k[0] == "po" and os.path.dirname(k[1]) == d]:
            groups.pop(k)
        add_set("po", pat or pot, [pot], langs)
    for (fmt, pat), bylang in sorted(groups.items()):
        srcs = [p for l, ps in bylang.items() for p in ps
                if l == src or l.replace("-", "_") in (src + "_US", src + "_GB")]
        if not srcs:
            continue
        add_set(fmt, pat, srcs, set(bylang))
    # configured sources that the heuristics missed
    seen = {sf["path"] for s in sets for sf in s["source_files"]}
    for fpat, out in config_pairs:
        paths = [f for f in files if fnmatch_path(f, fpat)]
        paths = [p for p in paths if p not in seen]
        if paths:
            ext = os.path.splitext(paths[0])[1].lower()
            fmt = "po" if ext in (".po", ".pot") else "yaml" if ext in (".yml", ".yaml") else "json"
            add_set(fmt, out, paths, set())

    usages = build_usages(root, files, usage_keys)
    fw = set()
    for s in sets:
        fw.add({"yaml": "rails-i18n", "po": "gettext", "json": "i18next"}[s["format"]])
    head = git(root, "rev-parse", "HEAD")
    db = git(root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").split("/", 1)[-1] or git(root, "rev-parse", "--abbrev-ref", "HEAD") or "main"
    v2 = census_v2(root, files, sets)
    prefix = git(root, "rev-parse", "--show-prefix").rstrip("/")
    return {"schema": 2, "cli_version": os.environ.get("PTC_CLI_VERSION", ""),
            "repo": {"root": ".", "head_sha": head or None, "default_branch": db, "prefix": prefix,
                     "workspace_fingerprint": workspace_fingerprint(root, sets)},
            "frameworks": sorted(fw) or ["unknown"],
            "resource_sets": sets, "usages": usages,
            "products": scan_products(root, sets),
            "other_string_sources": v2["other_string_sources"], "partition": v2["partition"],
            "existing_translations": v2["existing_translations"], "runtime": v2["runtime"],
            "none_reason": None if sets else "no translation resource files found (looked for Rails YAML, gettext .pot/.po, JSON locale files)"}


# ---------------- census v2 (schema 2) ----------------
# Linear-time patterns only (a real monorepo has minified one-liners); the word tests run in Python.
TEXT_NODE_RE = re.compile(r">([^<>]{3,300})<")
WORD_RE = re.compile(r"[A-Za-z]{2,}")


def prose(txt, min_words):
    """Visible prose: enough words, no template/interpolation syntax."""
    t = txt.strip()
    return bool(t) and not any(c in t for c in "{}%$=;") and len(WORD_RE.findall(t)) >= min_words
JSX_TEXT_EXT = {".jsx", ".tsx", ".vue", ".svelte"}
TEMPLATE_EXT = {".erb", ".haml", ".slim", ".twig", ".php", ".html", ".htm", ".hbs", ".mustache", ".liquid", ".njk", ".blade.php"}
JS_EXT = {".js", ".ts", ".mjs", ".cjs"}
JS_LITERAL_RE = re.compile(r""""([^"\\\n]{8,200})"|'([^'\\\n]{8,200})'""")
SENTENCE_RE = re.compile(r"^[A-Z][A-Za-z']*(?:[ ,]+[A-Za-z'.,!?-]+){2,}$")
SEO_RE = re.compile(r"""<title[\s>]|<meta\s+[^>]*(?:name|property)\s*=\s*["'](?:description|og:title|og:description|twitter:title|twitter:description|keywords)["']|content_for\s*[:(]\s*:?(?:title|description|meta_description)""", re.I)
EMAIL_PATH_RE = re.compile(r"(^|/)(mailers?|emails?|mail_templates|notifications?/mail)(/|$)|_mailer/|\.mjml$|\.eml$|\.email\.", re.I)
PDF_PATH_RE = re.compile(r"(^|/)pdfs?(/|$)|_pdf\.|\.pdf\.", re.I)
AUDIENCE_RULES = [  # (audience, rule regex over the lower-cased path) — first match wins
    ("vendor", re.compile(r"(^|/)(vendor|vendors|third[_-]?party|thirdparty|libraries|external|bower_components|node_modules)(/|$)")),
    ("developer_only", re.compile(r"(^|/)(dev|debug|docs?|storybook|stories|examples?|samples?|scripts|tools|spec|specs|tests?|fixtures|e2e)(/|$)")),
    ("staff_only", re.compile(r"(^|/|[._-])(admin|active_admin|activeadmin|backoffice|back[_-]office|staff|internal|support[_-]?tools?|ops)([._/-]|$)")),
]
I18N_INIT_RE = re.compile(r"""i18next\s*\.\s*(?:use\([^)]*\)\s*\.\s*)*init\s*\(|createI18n\s*\(|new\s+VueI18n\s*\(|I18n\.(?:default_locale|available_locales|load_path)\s*[=+<]|config\.i18n\.[a-z_]+\s*[=+<]|i18n\.load_path|IntlProvider|next-i18next|setLocaleData\s*\(|wp_set_script_translations\s*\(|load_(?:plugin|theme|muplugin)_textdomain\s*\(""")
TEXT_DOMAIN_RE = re.compile(r"^[\s*#/]*Text Domain:\s*([A-Za-z0-9_.-]+)", re.M)
DOMAIN_PATH_RE = re.compile(r"^[\s*#/]*Domain Path:\s*(\S+)", re.M)
LOAD_TD_RE = re.compile(r"""load_(plugin|theme|muplugin|child_theme)_textdomain\s*\(\s*['"]([^'"]+)['"]""")


def call_rest(line, start):
    """The remaining arguments of a call whose '(' is already open at `start` (balanced parentheses)."""
    depth, i = 1, start
    while i < len(line):
        depth += {"(": 1, ")": -1}.get(line[i], 0)
        if depth == 0:
            break
        i += 1
    return line[start:i].lstrip(" ,") or None
MAX_SAMPLES = 5


def audience_for(path):
    low = path.lower()
    for aud, rx in AUDIENCE_RULES:
        m = rx.search(low)
        if m:
            return aud, f"path matches '{m.group(0).strip('/._-')}'"
    return "client", "default (no staff/vendor/developer path rule matched)"


def census_v2(root, files, sets):
    """Schema-2 additions: other string sources, partition proposal, existing-translation facts, runtime metadata.
    Cheap, deterministic heuristics only (no model); every count is a lower-bound estimate."""
    other = {k: {"kind": k, "files": 0, "occurrences": 0, "samples": []} for k in
             ("templates", "html", "js_literals", "emails", "pdf", "seo_meta")}
    runtime = {"text_domains": [], "domain_paths": [], "load_textdomain": [], "i18n_init": []}
    resource_paths = {sf["path"] for s in sets for sf in s["source_files"]}

    def hit(kind, path, line_no, text, n=1):
        o = other[kind]
        o["occurrences"] += n
        if len(o["samples"]) < MAX_SAMPLES and line_no is not None:
            o["samples"].append({"path": path, "line": line_no, "text": text.strip()[:160]})

    for f in files:
        if NON_PRODUCT.search(f) or f in resource_paths:
            continue
        low = f.lower()
        ext = os.path.splitext(low)[1]
        if ext == ".pdf":
            other["pdf"]["files"] += 1
            hit("pdf", f, None, "")
            continue
        is_tpl = ext in TEMPLATE_EXT or low.endswith(".blade.php")
        is_code = ext in CODE_EXT or is_tpl or ext in JSX_TEXT_EXT
        if not is_code and not EMAIL_PATH_RE.search(f):
            continue
        try:
            with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
                lines = fh.read(400000).splitlines()
        except OSError:
            continue
        counted = set()
        for no, line in enumerate(lines, 1):
            if len(line) > 2000:
                continue
            if ext == ".php" and no <= 60:
                m = TEXT_DOMAIN_RE.match(line)
                if m:
                    runtime["text_domains"].append({"path": f, "line": no, "domain": m.group(1)})
                m = DOMAIN_PATH_RE.match(line)
                if m:
                    runtime["domain_paths"].append({"path": f, "line": no, "domain_path": m.group(1)})
            if ext in CODE_EXT or ext in JSX_TEXT_EXT:
                m = LOAD_TD_RE.search(line)
                if m:
                    runtime["load_textdomain"].append({"path": f, "line": no, "kind": m.group(1), "domain": m.group(2),
                                                       "args": (call_rest(line, m.end()) or "")[:160] or None})
                elif I18N_INIT_RE.search(line) and len(runtime["i18n_init"]) < 50 and not line.lstrip().startswith(("#", "//", "*")):
                    runtime["i18n_init"].append({"path": f, "line": no, "text": line.strip()[:200]})
            if SEO_RE.search(line):
                hit("seo_meta", f, no, line); counted.add("seo_meta")
            if is_tpl or ext in JSX_TEXT_EXT:
                for m in TEXT_NODE_RE.finditer(line):
                    txt = m.group(1).strip()
                    if not prose(txt, 2):
                        continue
                    if re.search(r"\b(t|__|_e|esc_html__|I18n\.t|\$t|translate)\s*\(", txt):
                        continue
                    kind = "emails" if EMAIL_PATH_RE.search(f) else "pdf" if PDF_PATH_RE.search(f) else \
                        "html" if ext in (".html", ".htm") else "templates"
                    hit(kind, f, no, txt); counted.add(kind)
            if ext in JS_EXT or ext in JSX_TEXT_EXT:
                if "import " in line or "require(" in line:
                    continue
                for m in JS_LITERAL_RE.finditer(line):
                    lit = m.group(1) if m.group(1) is not None else m.group(2)
                    if "/" in lit or not SENTENCE_RE.match(lit):
                        continue
                    hit("js_literals", f, no, lit); counted.add("js_literals")
        for k in counted:
            other[k]["files"] += 1

    partition = []
    for s in sets:
        aud, rule = audience_for(s["source_pattern"])
        partition.append({"source_pattern": s["source_pattern"], "audience": aud, "rule": rule})

    existing = existing_translations(root, files, sets, runtime)
    return {"other_string_sources": [o for o in other.values() if o["occurrences"] or o["files"]],
            "partition": partition, "existing_translations": existing, "runtime": runtime}


def _base_lang(code):
    return re.split(r"[_-]", code)[0].lower()


def existing_translations(root, files, sets, runtime):
    """Per resource set: the translation files on disk with their entry counts, plus duplicate language variants
    and catalogues the runtime would not load (WordPress: domain-name mismatch, .po without its compiled .mo)."""
    by_set, all_langs, duplicates, non_loading = [], set(), [], []
    fileset = set(files)
    domains = {d["domain"] for d in runtime["text_domains"]} | {d["domain"] for d in runtime["load_textdomain"]}
    for s in sets:
        pat = s["source_pattern"]
        if "{{lang}}" not in pat:
            by_set.append({"source_pattern": pat, "languages": s.get("existing_languages", []), "files": []})
            continue
        rx = re.compile("^" + re.escape(pat).replace(re.escape("{{lang}}"), r"(?P<lang>[A-Za-z]{2,3}(?:[_-][A-Za-z0-9]{2,4})?)") + "$")
        found = []
        for f in files:
            m = rx.match(f)
            if not m or not is_lang(m.group("lang")) or f in {sf["path"] for sf in s["source_files"]}:
                continue
            entry = {"lang": m.group("lang"), "path": f, "entries": None, "translated": None}
            try:
                text = open(os.path.join(root, f), encoding="utf-8", errors="replace").read()
                if f.endswith(".po"):
                    ents = parse_po(text)
                    entry["entries"] = len(ents)
                    entry["translated"] = sum(1 for e in ents if any(v for k, v in e.items() if k.startswith("msgstr")))
                elif f.endswith((".yml", ".yaml")):
                    entry["entries"] = (stats_yaml(text)[0] or {}).get("count")
                elif f.endswith(".json"):
                    entry["entries"] = (stats_json(text)[0] or {}).get("count")
            except Exception:
                pass
            found.append(entry)
            all_langs.add(m.group("lang"))
            # WordPress loads <domain>-<locale>.mo; a .po alone, or a file named for another domain, never loads.
            if f.endswith(".po") and domains:
                stem = os.path.basename(f)[:-3]
                if (f[:-3] + ".mo") not in fileset:
                    non_loading.append({"path": f, "reason": "no compiled .mo next to it (WordPress loads the .mo)"})
                pref = stem[: -len(m.group("lang"))].rstrip("-_") if stem.endswith(m.group("lang")) else stem
                if pref and pref not in domains:
                    non_loading.append({"path": f, "reason": f"named for domain '{pref}', runtime text domain(s): {', '.join(sorted(domains))}"})
        langs = sorted({e["lang"] for e in found})
        groups = {}
        for l in langs:
            groups.setdefault(_base_lang(l), []).append(l)
        for base, variants in sorted(groups.items()):
            # A duplicate = the bare code beside its own default region (de + de_DE, fr + fr-FR): the same
            # language twice. pt-BR / pt-PT or sr-Cyrl / sr-Latn are distinct variants, not duplicates.
            dup = [v for v in variants if v == base or re.split(r"[_-]", v)[-1].lower() == base]
            if len(dup) > 1 and base in dup:
                variants = dup
                duplicates.append({"source_pattern": pat, "language": base, "variants": variants})
        by_set.append({"source_pattern": pat, "languages": sorted(set(langs) | set(s.get("existing_languages", []))),
                       "files": sorted(found, key=lambda e: e["path"])})
        all_langs |= set(s.get("existing_languages", []))
    return {"languages_on_disk": sorted(all_langs), "by_set": by_set, "duplicates": duplicates,
            "non_loading": non_loading}


def is_product_dir(path):
    """A product = a top-level directory with its own package manifest or a WordPress plugin main file."""
    if any(os.path.isfile(os.path.join(path, m)) for m in ("composer.json", "package.json")):
        return True
    try:
        names = sorted(os.listdir(path))
    except OSError:
        return False
    for n in names:
        if n.endswith(".php") and os.path.isfile(os.path.join(path, n)):
            try:
                with open(os.path.join(path, n), encoding="utf-8", errors="replace") as fh:
                    if "Plugin Name:" in fh.read(8192):
                        return True
            except OSError:
                pass
    return False


def scan_products(root, sets):
    """Resource sets grouped by top-level product directory (multi-product repositories)."""
    tops = sorted({s["source_pattern"].split("/", 1)[0] for s in sets if "/" in s["source_pattern"]})
    return [{"dir": d, "resource_sets": [s["source_pattern"] for s in sets if s["source_pattern"].startswith(d + "/")]}
            for d in tops if is_product_dir(os.path.join(root, d))]


def fnmatch_path(path, pattern):
    rx = "^" + re.escape(pattern).replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*").replace(r"\*", "[^/]*").replace(r"\?", "[^/]") + "$"
    return re.match(rx, path) is not None or re.match(rx, path.split("/", 1)[-1] if False else path) is not None


RAILS_RE = re.compile(r"""(?<![\w.])(?:I18n\.)?(?:t|translate)\(?\s*(['"])([\w.:\-/]+)\1""")
GETTEXT_RE = re.compile(r"""\b(?:__|_e|_x|_ex|_n|_nx|esc_html__|esc_html_e|esc_attr__|esc_attr_e|esc_html_x|esc_attr_x)\(\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")""")


def build_usages(root, files, usage_keys):
    key_index, msgid_index, ns_index = {}, {}, {}
    for path, (fmt, keys) in usage_keys.items():
        for k in keys:
            if fmt == "po":
                msgid_index.setdefault(k, []).append(path)
            else:
                key_index.setdefault(k, []).append(path)
                if fmt == "json":
                    ns_index.setdefault((os.path.splitext(os.path.basename(path))[0], k), []).append(path)
    usages = {}

    def add(src_paths, key, path, line, text):
        for sp in src_paths:
            usages.setdefault(sp, {}).setdefault(key, []).append({"path": path, "line": line, "text": text})
    if not (key_index or msgid_index):
        return {}
    for f in files:
        ext = os.path.splitext(f)[1].lower()
        if ext not in CODE_EXT:
            continue
        try:
            with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        lazy_prefix = None
        if f.startswith("app/views/"):
            base = re.sub(r"\..*$", "", f[len("app/views/"):])
            lazy_prefix = ".".join(x.lstrip("_") for x in base.split("/"))
        for no, line in enumerate(lines, 1):
            if key_index and "t" in line:
                for m in RAILS_RE.finditer(line):
                    k = m.group(2)
                    if k.startswith(".") and lazy_prefix:
                        k = lazy_prefix + k
                    if ":" in k:
                        ns, kk = k.split(":", 1)
                        if (ns, kk) in ns_index:
                            add(ns_index[(ns, kk)], kk, f, no, line.strip()[:200])
                        continue
                    if k in key_index:
                        add(key_index[k], k, f, no, line.strip()[:200])
            if msgid_index and "_" in line:
                for m in GETTEXT_RE.finditer(line):
                    raw = m.group(1) if m.group(1) is not None else m.group(2)
                    msgid = re.sub(r"\\(['\"\\])", r"\1", raw)
                    if msgid in msgid_index:
                        add(msgid_index[msgid], msgid, f, no, line.strip()[:200])
    return {sp: {k: v for k, v in sorted(m.items())} for sp, m in sorted(usages.items())}


# ---------------- config ----------------
def read_config(path):
    text = open(path, encoding="utf-8").read()
    cfg, files, cur, guide, section = {}, [], None, {}, None
    for line in text.split("\n"):
        if not line.strip() or line.strip().startswith("#"):
            continue
        m = re.match(r"^(\w+):\s*(.*?)\s*$", line)
        if m:
            section = m.group(1)
            if m.group(2):
                v = m.group(2)
                cfg[section] = [unquote(x.strip()) for x in v[1:-1].split(",") if x.strip()] if v.startswith("[") and v.endswith("]") else unquote(v)
            continue
        if section == "files":
            m = re.match(r"^\s*-\s*file:\s*(.+?)\s*$", line)
            if m:
                cur = {"file": unquote(m.group(1))}; files.append(cur); continue
            m = re.match(r"^\s*output:\s*(.+?)\s*$", line)
            if m and cur is not None:
                cur["output"] = unquote(m.group(1))
        elif section == "guide":
            m = re.match(r"^\s+(\w+):\s*(.*?)\s*$", line)
            if m:
                v = m.group(2)
                if v.startswith("[") and v.endswith("]"):
                    v = [unquote(x) for x in v[1:-1].split(",") if x.strip()]
                else:
                    v = unquote(v)
                guide[m.group(1)] = v
    cfg["files"] = files
    if guide:
        cfg["guide"] = guide
    return cfg


def config_validate(root, path):
    errors, warnings, report = [], [], []
    try:
        cfg = read_config(path)
    except OSError as e:
        return {"valid": False, "errors": [f"cannot read {path}: {e}"], "config": None, "files": []}
    all_files = list_files(root)
    src = cfg.get("source_locale", "")
    if not src:
        errors.append("source_locale is missing")
    elif not is_lang(src):
        errors.append(f"source_locale '{src}' is not a known language code")
    if not cfg["files"]:
        errors.append("files: has no '- file:' entries")
    langs = cfg.get("languages") or cfg.get("guide", {}).get("languages") or []
    if isinstance(langs, str):
        langs = [x.strip() for x in langs.split(",") if x.strip()]
    for l in langs:
        if not is_lang(l):
            errors.append(f"guide.languages: '{l}' is not a known language code")
    for i, e in enumerate(cfg["files"], 1):
        fpat, out = e.get("file", ""), e.get("output", "")
        matches = [f for f in all_files if fnmatch_path(f, fpat)]
        entry = {"file": fpat, "output": out, "matches": len(matches), "outputs": {}}
        if not matches:
            errors.append(f"files[{i}].file '{fpat}' matches no file")
        if not out:
            errors.append(f"files[{i}] has no output")
        elif "{{lang}}" not in out:
            errors.append(f"files[{i}].output '{out}' has no {{{{lang}}}} slot")
        else:
            targets = langs
            if not targets:
                rx = "^" + re.escape(out).replace(re.escape("{{lang}}"), "([^/]+)") + "$"
                targets = sorted({m.group(1) for f in all_files for m in [re.match(rx, f)] if m and is_lang(m.group(1)) and m.group(1) != src})
            for l in targets:
                entry["outputs"][l] = out.replace("{{lang}}", l)
        report.append(entry)
    seen = {}
    for i, e in enumerate(cfg["files"], 1):
        out = e.get("output", "")
        if out and out in seen:
            errors.append(f"files[{i}].output '{out}' is also the output of files[{seen[out]}]: two sources would overwrite one file")
        seen.setdefault(out, i)
    errors.extend(sibling_output_clashes(root, path, [e.get("output", "") for e in cfg["files"]]))
    ignored = ignored_outputs(root, report)
    for p, rule in ignored:
        errors.append(f"output '{p}' is ignored by git ({rule}): translated files written there can never be committed")
    if "api_token" in cfg:
        warnings.append("api_token: is deprecated and ignored; use PTC_API_TOKEN")
    return {"valid": not errors, "errors": errors, "warnings": warnings, "config": cfg, "files": report,
            "ignored_outputs": [p for p, _ in ignored]}


def ignored_outputs(root, report):
    """E35: every entry's output instantiated with its first target language, checked with `git check-ignore` (tracked
    files are not ignored). -> [(path, "<source>:<line>:<pattern>")] in entry order; [] outside a git work tree."""
    paths = []
    for entry in report:
        outs = entry.get("outputs") or {}
        if outs:
            first = outs[next(iter(outs))]
            if first not in paths:
                paths.append(first)
    if not paths:
        return []
    try:
        res = subprocess.run(["git", "-c", "safe.directory=*", "-C", root, "check-ignore", "-v", "--stdin"],
                             input="\n".join(paths) + "\n", capture_output=True, text=True)
    except Exception:
        return []
    if res.returncode not in (0, 1):
        return []
    hits = {}
    for line in res.stdout.splitlines():
        rule, _, p = line.partition("\t")
        if p:
            hits[p] = rule
    return [(p, hits[p]) for p in paths if p in hits]


def sibling_output_clashes(root, path, outputs):
    """Multi-product repos: another product's .ptc-config.yml must not write an output path this one writes."""
    try:
        top = subprocess.run(["git", "-C", root, "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return []
    here = os.path.relpath(os.path.dirname(os.path.abspath(path)), top)
    mine = {os.path.normpath(os.path.join(here, o)) for o in outputs if o}
    errs = []
    for other in sorted(glob.glob(os.path.join(top, "*", ".ptc-config.yml")) + [os.path.join(top, ".ptc-config.yml")]):
        if not os.path.isfile(other) or os.path.abspath(other) == os.path.abspath(path):
            continue
        odir = os.path.relpath(os.path.dirname(other), top)
        try:
            theirs = {os.path.normpath(os.path.join(odir, e.get("output", ""))) for e in read_config(other)["files"] if e.get("output")}
        except OSError:
            continue
        for clash in sorted(mine & theirs):
            errs.append(f"output '{clash}' is also written by {os.path.relpath(other, top)}: two products would overwrite one file")
    return errs


# ---------------- describe apply ----------------
def _po_unquote(s):
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)


def _po_blocks(lines):
    """Yield (start, end, msgctxt, msgid) per entry block; start = first comment line of the block."""
    i, n = 0, len(lines)
    while i < n:
        while i < n and not lines[i].strip():
            i += 1
        if i >= n:
            break
        start = i
        ctx = mid = None
        field = None
        while i < n and lines[i].strip():
            s = lines[i].strip()
            m = re.match(r'^(msgctxt|msgid|msgid_plural|msgstr(?:\[\d+\])?)\s+"(.*)"$', s)
            if m:
                field = m.group(1)
                if field == "msgctxt":
                    ctx = _po_unquote(m.group(2))
                elif field == "msgid":
                    mid = _po_unquote(m.group(2))
            elif s.startswith('"') and field in ("msgctxt", "msgid"):
                if field == "msgctxt":
                    ctx = (ctx or "") + _po_unquote(s[1:-1])
                else:
                    mid = (mid or "") + _po_unquote(s[1:-1])
            i += 1
        yield start, i, ctx, mid


def _prettier_ignored(root, path):
    try:
        pats = [l.strip() for l in open(os.path.join(root, ".prettierignore")) if l.strip() and not l.startswith("#")]
    except OSError:
        return False
    return any(fnmatch_path(path, p) or path.startswith(p.rstrip("/") + "/") for p in pats)


BLOCK_COMMENT_EXT = {".php", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".c", ".cc", ".cpp", ".h", ".java", ".cs", ".go", ".swift", ".kt"}
HASH_COMMENT_EXT = {".py", ".rb", ".sh", ".pl"}


def _key_on_line(line, key):
    variants = {key, key.replace("'", "\\'"), key.replace('"', '\\"'), key.replace("\n", "\\n")}
    return any(v and v in line for v in variants)


def _translators_comment(ext, desc):
    if ext in HASH_COMMENT_EXT:
        return "# translators: " + desc
    if ext == ".twig":
        return "{# translators: " + desc.replace("#}", "# }") + " #}"
    return "/* translators: " + desc.replace("*/", "* /") + " */"


TRANSLATORS_LINE_RE = re.compile(r"^\s*(?:/\*|//|#|\{#)\s*translators:", re.I)
# S2-R2 F8: any translators note line (a `<?php /* translators: */ ?>` template line included), and PTC's own format.
TRANSLATORS_ANY_RE = re.compile(r"^\s*(?:<\?php\s+)?(?:/\*|//|#|\{#)\s*translators:", re.I)
PTC_NOTE_RE = re.compile(r"^(?:<\?php )?(?:/\* translators: .* \*/|# translators: .*|\{# translators: .* #\})(?: \?>)?$")
PHP_OPEN_RE = re.compile(r"<\?(?:php\b|=)")


def describe_source_comments(root, ds, res, dry_run, usage_map):
    """gettext write-back that survives template regeneration: a `translators:` comment right above (or, inside an
    inline `<?php ... ?>` template line, right before) the call site, which xgettext --add-comments=translators: and
    `wp i18n make-pot` extract into the template's `#.` lines."""
    edits = {}  # usage path -> {line index: (d, desc)}
    for d in ds:
        u = d.get("usage") or {}
        if not u.get("path") or not u.get("line"):
            found = ((usage_map() or {}).get(d["file"]) or {}).get(d["key"]) or []
            u = found[0] if found else {}
        if not u.get("path") or not u.get("line"):
            res["skipped"].append({"file": d["file"], "key": d["key"], "reason": "no usage (path:line) for this msgid: pass usage, or use --into-template"})
            continue
        edits.setdefault(u["path"], []).append((d, int(u["line"])))
    for upath, items in sorted(edits.items()):
        full = os.path.join(root, upath)
        if os.path.relpath(os.path.realpath(full), os.path.realpath(root)).startswith(".."):
            res["skipped"] += [{"file": d["file"], "key": d["key"], "reason": "usage path is outside the repository"} for d, _ in items]
            continue
        try:
            text = open(full, encoding="utf-8").read()
        except OSError as e:
            res["skipped"] += [{"file": d["file"], "key": d["key"], "reason": f"cannot read {upath}: {e.strerror}"} for d, _ in items]
            continue
        lines = text.split("\n")
        ext = os.path.splitext(upath)[1].lower()
        plan = {}  # line index -> [d, ...]: strings sharing a line get ONE combined comment (S2-R2 F8)
        for d, ln in items:
            idx = next((i for i in [ln - 1] + [ln - 1 + o for o in (-1, 1, -2, 2, -3, 3)]
                        if 0 <= i < len(lines) and _key_on_line(lines[i], d["key"])), None)
            if idx is None:
                res["skipped"].append({"file": d["file"], "key": d["key"], "reason": f"{upath}:{ln} does not contain the msgid"})
                continue
            plan.setdefault(idx, []).append(d)
        changed = False
        for idx in sorted(plan, reverse=True):
            ds_at = plan[idx]
            if len(ds_at) == 1:
                text_ = ds_at[0]["description"]
            else:
                text_ = "; ".join('"%s": %s' % (d["key"], d["description"]) for d in ds_at)
            line = lines[idx]
            indent = re.match(r"\s*", line).group(0)
            # S2-R2 F8: a PHP template line (HTML with <?php / <?= tags) gets its note as a PHP comment in its own tag on
            # the line above, never as text the page would show.
            if ext == ".php" and PHP_OPEN_RE.search(line):
                comment = "<?php " + _translators_comment(".php", text_) + " ?>"
            else:
                comment = _translators_comment(ext, text_)
            # The contiguous translators: notes right above the call. A developer's note is never deleted; only a note
            # in PTC's own format is replaced by PTC's current one.
            top = idx
            while top > 0 and TRANSLATORS_ANY_RE.match(lines[top - 1]):
                top -= 1
            block = [l.strip() for l in lines[top:idx]]
            if comment.strip() in block:
                res["unchanged"] += [{"file": d["file"], "key": d["key"]} for d in ds_at]
                continue
            own = next((i for i in range(top, idx) if PTC_NOTE_RE.match(lines[i].strip())), None)
            if own is not None:
                lines[own] = indent + comment
            else:
                lines.insert(top, indent + comment)
            changed = True
            res["applied"] += [{"file": d["file"], "key": d["key"], "slot": f"translators: {upath}:{idx + 1}"} for d in ds_at]
        if changed:
            res["files"].append(upath)
            if not dry_run:
                open(full, "w", encoding="utf-8").write("\n".join(lines))


def describe_apply(root, desc_path, dry_run, into_template=False):
    raw = json.load(open(desc_path))
    items = raw.get("descriptions") if isinstance(raw, dict) else raw
    if not isinstance(items, list):
        raise ValueError("expected {\"descriptions\": [{file, key, description}]}")
    res = {"applied": [], "unchanged": [], "skipped": [], "warnings": [], "files": []}
    by_file = {}
    for d in items:
        if not isinstance(d, dict) or not d.get("file") or d.get("key") is None or not d.get("description"):
            res["skipped"].append({"item": d, "reason": "needs file, key and description"})
            continue
        desc = re.sub(r"[\x00-\x1f\x7f]+", " ", str(d["description"])).strip()[:500]
        by_file.setdefault(d["file"], []).append(dict(d, description=desc))
    cache = {}

    def usage_map():
        if "u" not in cache:
            try:
                cache["u"] = scan(root, "", []).get("usages") or {}
            except Exception:
                cache["u"] = {}
        return cache["u"]
    has_prettier = any(os.path.exists(os.path.join(root, f)) for f in
                       (".prettierrc", ".prettierrc.json", ".prettierrc.js", ".prettierrc.yml", "prettier.config.js"))
    for path, ds in sorted(by_file.items()):
        full = os.path.join(root, path)
        if os.path.relpath(os.path.realpath(full), os.path.realpath(root)).startswith(".."):
            res["skipped"] += [{"file": path, "key": d["key"], "reason": "path is outside the repository"} for d in ds]
            continue
        try:
            text = open(full, encoding="utf-8").read()
        except OSError as e:
            res["skipped"] += [{"file": path, "key": d["key"], "reason": f"cannot read: {e.strerror}"} for d in ds]
            continue
        ext = os.path.splitext(path)[1].lower()
        new = text
        if ext in (".po", ".pot") and not into_template:
            describe_source_comments(root, ds, res, dry_run, usage_map)
            continue
        if ext in (".po", ".pot"):
            lines = text.split("\n")
            inserts = {}
            blocks = {(c, m): (a, b) for a, b, c, m in _po_blocks(lines) if m is not None}
            for d in ds:
                key = (d.get("context"), d["key"])
                if key not in blocks:
                    res["skipped"].append({"file": path, "key": d["key"], "reason": "msgid not found in the catalogue"})
                    continue
                a, b = blocks[key]
                line = "#. " + d["description"]
                if line in (l.rstrip() for l in lines[a:b]):
                    res["unchanged"].append({"file": path, "key": d["key"]})
                    continue
                # after the existing #. lines (translator comments stay first), before #: / #, / msg lines
                pos = a
                while pos < b and lines[pos].startswith(("# ", "#.")) or (pos < b and lines[pos] == "#"):
                    pos += 1
                inserts.setdefault(pos, []).append(line)
                res["applied"].append({"file": path, "key": d["key"], "slot": "#."})
            for pos in sorted(inserts, reverse=True):
                lines[pos:pos] = inserts[pos]
            new = "\n".join(lines)
        elif ext == ".json":
            try:
                doc = json.loads(text)
            except ValueError:
                doc = None
            chrome = isinstance(doc, dict) and doc and all(isinstance(v, dict) and "message" in v for v in doc.values())
            if not chrome:
                res["skipped"] += [{"file": path, "key": d["key"], "reason": "no description slot PTC's parser reads in this JSON layout (only Chrome-i18n {message, description})"} for d in ds]
                continue
            for d in ds:
                entry = doc.get(d["key"])
                if not isinstance(entry, dict):
                    res["skipped"].append({"file": path, "key": d["key"], "reason": "key not found"})
                elif entry.get("description") == d["description"]:
                    res["unchanged"].append({"file": path, "key": d["key"]})
                else:
                    entry["description"] = d["description"]
                    res["applied"].append({"file": path, "key": d["key"], "slot": "description"})
            indent = 4 if re.search(r'^\{\n {4}"', text) else 2
            new = json.dumps(doc, indent=indent, ensure_ascii=False) + ("\n" if text.endswith("\n") else "")
            if new != text and has_prettier and not _prettier_ignored(root, path):
                res["warnings"].append(f"prettier may reformat {path}; to keep PTC's edit as written add it to .prettierignore")
        else:
            res["skipped"] += [{"file": path, "key": d["key"], "reason": "no description slot PTC's parser reads for this format"} for d in ds]
            continue
        if new != text:
            res["files"].append(path)
            if not dry_run:
                open(full, "w", encoding="utf-8").write(new)
    return res


# ---------------- lint source ----------------
SPELLING_PAIRS = [("color", "colour"), ("favorite", "favourite"), ("center", "centre"), ("organize", "organise"),
                  ("organization", "organisation"), ("customize", "customise"), ("license", "licence"),
                  ("canceled", "cancelled"), ("canceling", "cancelling"), ("analyze", "analyse"), ("behavior", "behaviour"),
                  ("catalog", "catalogue"), ("gray", "grey"), ("optimize", "optimise"), ("recognize", "recognise"),
                  ("authorize", "authorise"), ("synchronize", "synchronise"), ("initialize", "initialise"),
                  ("personalize", "personalise"), ("prioritize", "prioritise"), ("summarize", "summarise"),
                  ("labeled", "labelled"), ("modeling", "modelling"), ("traveled", "travelled"), ("fulfill", "fulfil")]
TAG_RE = re.compile(r"<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^<>]*?(/?)>")
VOID_TAGS = {"br", "hr", "img", "input", "meta", "link", "wbr", "source", "area", "col", "embed", "param", "track"}
ENTITY_RE = re.compile(r"&(?:[a-zA-Z]{2,8}|#\d{2,5}|#x[0-9a-fA-F]{2,4});")
URL_RE = re.compile(r"\b(?:https?://|www\.)[^\s<>\"')]+", re.I)
CAMEL_RE = re.compile(r"\b[A-Z][a-z]+[A-Z][A-Za-z]+\b")


# S2-R5 F19 (AGD-3): PTC never translates, so never quotes, a value that is not text or is a bare code token
# (Utils::TranslatableValue, ruling #739): (A) two or more [A-Za-z][A-Za-z0-9]* / [0-9]+ tokens joined by "." or "_" with
# a letter somewhere (GitLab.com, settings_title_key, v1.2.3, AuthKey_X.p8); (B) lowerCamelCase of three or more words.
ID_TOKEN = r"(?:[A-Za-z][A-Za-z0-9]*|[0-9]+)"
ID_SEPARATED = re.compile(r"\A" + ID_TOKEN + r"(?:[._]" + ID_TOKEN + r")+\Z")
ID_CAMEL = re.compile(r"\A[a-z][a-z0-9]+(?:[A-Z][a-z0-9]+){2,}\Z")


def translatable(value):
    if not isinstance(value, str):
        return False
    v = value.strip()
    if not v:
        return False
    return not ((ID_SEPARATED.match(v) and re.search(r"[A-Za-z]", v)) or ID_CAMEL.match(v))


def json_strings(obj, prefix=""):
    # The string leaves PTC's JSON parser reads: inside objects AND arrays; numbers, booleans and null are data.
    if isinstance(obj, dict):
        for k in sorted(obj):
            yield from json_strings(obj[k], f"{prefix}.{k}" if prefix else str(k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from json_strings(v, f"{prefix}[{i}]")
    elif isinstance(obj, str):
        yield prefix, obj


def source_strings(root, path):
    text = open(os.path.join(root, path), encoding="utf-8", errors="replace").read()
    ext = os.path.splitext(path)[1].lower()
    if ext in (".po", ".pot"):
        pairs = [(e.get("msgid"), po_unescape(e.get("msgid", ""))) for e in parse_po(text)]
    elif ext in (".yml", ".yaml"):
        pairs = yaml_leaves(text)[0]
    elif ext == ".json":
        try:
            pairs = list(json_strings(json.loads(text)))
        except ValueError:
            return []
    else:
        return []
    return [(k, v) for k, v in pairs if translatable(v)]


# S2-R2 item 2 (decision 5; specs/agent-guide AGD-3): PTC's word rule, Operations::Utils::CalculateWords, line for line.
# Whitespace is Ruby's String#split whitespace (ASCII only: a no-break or ideographic space joins words); `&nbsp;` is a
# space; a text with CJK counts each Han character, each hiragana run and each katakana run as a word, plus the
# whitespace-split words of the rest. backend/spec/fixtures/files/word_count_cases.json pins both counters.
WC_SPACE = re.compile(r"[ \t\n\v\f\r]+")
WC_HAN = "⺀-⺙⺛-⻳⼀-⿕々〇〡-〩〸-〻㐀-䶿一-鿿豈-舘並-龎\U00020000-\U0003134a"
WC_HIRA = "ぁ-ゖゝ-ゟ"
WC_KATA = "ァ-ヺヽ-ヿㇰ-ㇿ㋐-㋾㌀-㍗ｦ-ｯｱ-ﾝ"
WC_CJK = re.compile("[" + WC_HAN + WC_HIRA + WC_KATA + "ー]")
WC_HAN_RE = re.compile("[" + WC_HAN + "]")
WC_KANA_RUN = re.compile("[" + WC_HIRA + "]+|[" + WC_KATA + "ー]+")


def ws_split(text):
    return [w for w in WC_SPACE.split(text) if w]


def count_words(text):
    if not text or not text.strip(" \t\n\v\f\r"):
        return 0
    text = text.replace("&nbsp;", " ")
    if not WC_CJK.search(text):
        return len(ws_split(text))
    return len(WC_HAN_RE.findall(text)) + len(WC_KANA_RUN.findall(text)) + len(ws_split(WC_CJK.sub(" ", text)))


def estimate(root, paths, langs, rate, balance, remote=None):
    # remote: {path: source words per language} from PTC's dry-run estimate (S2-R3 item 3) for the files no local
    # reader covers; a path without a quote there stays in `unquoted`.
    files, unquoted = [], []
    remote = remote or {}
    for p in paths:
        try:
            strings = source_strings(root, p)
        except OSError:
            strings = None
        if not strings and os.path.splitext(p)[1].lower() not in (".po", ".pot", ".yml", ".yaml", ".json"):
            if isinstance(remote.get(p), (int, float)):
                w = remote[p]
                files.append({"path": p, "strings": None, "words": int(w) if float(w).is_integer() else w, "counted_by": "ptc"})
            else:
                unquoted.append(p)
            continue
        files.append({"path": p, "strings": len(strings or []), "words": sum(count_words(v) for _, v in (strings or []))})
    per_lang = sum(f["words"] for f in files)
    words_total = per_lang * len(langs)
    num = lambda x: int(x) if float(x).is_integer() else round(x, 2)
    credits_lang = {l: num(per_lang * rate) for l in langs} if rate is not None else {}
    res = {"files": files, "unquoted": unquoted, "languages": langs, "words_per_language": per_lang,
           "words_total": words_total, "word_cost": num(rate) if rate is not None else None,
           "credits_per_language": credits_lang, "credits_total": num(words_total * rate) if rate is not None else None,
           "balance_words": num(balance) if balance is not None else None,
           "shortfall_words": num(max(0, words_total - balance)) if balance is not None else None}
    return res


def lint_source(root, paths, template, template_cmd):
    findings = []

    def add(check, level, path, key, text, detail):
        findings.append({"check": check, "level": level, "file": path, "key": key, "text": (text or "")[:200], "detail": detail})
    corpus = []
    for p in paths:
        try:
            corpus += [(p, k, v) for k, v in source_strings(root, p)]
        except OSError as e:
            add("read", "FAIL", p, None, None, f"cannot read: {e.strerror}")
    words = {}
    for p, k, v in corpus:
        for w in re.findall(r"[A-Za-z]+", v.lower()):
            words.setdefault(w, []).append((p, k, v))
    # 1. spelling-variant mix (US vs UK in one corpus)
    for us, uk in SPELLING_PAIRS:
        a = [x for w, xs in words.items() if w.startswith(us) for x in xs]
        b = [x for w, xs in words.items() if w.startswith(uk) for x in xs]
        if a and b:
            add("spelling_variant_mix", "WARN", b[0][0], b[0][1], b[0][2],
                f"'{us}' ({len(a)}x, e.g. {a[0][1]}) and '{uk}' ({len(b)}x) both appear: pick one spelling")
    straight = [x for x in corpus if "'" in x[2] and re.search(r"[A-Za-z]'[A-Za-z]", x[2])]
    curly = [x for x in corpus if "’" in x[2]]
    if straight and curly:
        add("quote_class_mix", "WARN", curly[0][0], curly[0][1], curly[0][2],
            f"straight apostrophes ({len(straight)} strings) and curly ones ({len(curly)} strings) are mixed")
    dots = [x for x in corpus if "..." in x[2]]
    ell = [x for x in corpus if "…" in x[2]]
    if dots and ell:
        add("ellipsis_mix", "WARN", ell[0][0], ell[0][1], ell[0][2],
            f"'...' ({len(dots)} strings) and '…' ({len(ell)} strings) are mixed")
    for p, k, v in corpus:
        # 2. leftover markup
        stack = []
        for m in TAG_RE.finditer(v):
            close, tag, selfc = m.group(1), m.group(2).lower(), m.group(3)
            if tag in VOID_TAGS or selfc:
                continue
            if close:
                if stack and stack[-1] == tag:
                    stack.pop()
                else:
                    stack.append("/" + tag)
                    break
            else:
                stack.append(tag)
        if stack:
            add("leftover_markup", "FAIL", p, k, v, f"unbalanced HTML tag(s): {', '.join(stack)}")
        elif TAG_RE.search(v):
            add("inline_markup", "WARN", p, k, v, "HTML inside the string: translators must keep it intact")
        if ENTITY_RE.search(v) and not p.endswith((".html", ".htm")):
            add("html_entity", "WARN", p, k, v, f"HTML entity {ENTITY_RE.search(v).group(0)} in a plain-text string")
        if v != v.strip():
            add("edge_whitespace", "WARN", p, k, v, "leading/trailing whitespace (often a concatenated fragment)")
        if "  " in v.strip():
            add("double_space", "WARN", p, k, v, "double space inside the string")
        # 4. URLs inside strings
        for m in URL_RE.finditer(v):
            add("url_in_string", "WARN", p, k, v, f"URL {m.group(0)} inside the text: pass it as a placeholder so it can be localised")
        # 5. feature / product names inside sentences
        toks = v.split()
        if len(toks) >= 4:
            mids = [t.strip(".,:;!?()\"'") for i, t in enumerate(toks) if i > 0 and not toks[i - 1].endswith((".", "!", "?", ":"))]
            cam = [t for t in mids if CAMEL_RE.fullmatch(t)]
            runs, cur = [], []
            for t in mids + [""]:
                if t[:1].isupper() and t[1:].islower() and len(t) > 1:
                    cur.append(t)
                else:
                    if len(cur) >= 2:
                        runs.append(" ".join(cur))
                    cur = []
            names = cam + runs
            if names:
                add("feature_name_in_sentence", "WARN", p, k, v,
                    f"name(s) inside a sentence: {', '.join(names)} - decide translate vs keep, or pass as a placeholder")
    # 6. template regeneration diff
    tmpl = None
    if template_cmd and template:
        full = os.path.join(root, template)
        try:
            before = open(full, "rb").read()
        except OSError:
            before = None
        old = {e.get("msgid") for e in parse_po(before.decode("utf-8", "replace"))} if before else set()
        try:
            r = subprocess.run(["bash", "-c", template_cmd], cwd=root, capture_output=True, timeout=600)
            after = open(full, "rb").read()
            new = {e.get("msgid") for e in parse_po(after.decode("utf-8", "replace"))}
            lost = sorted(old - new)
            tmpl = {"template": template, "command": template_cmd, "exit": r.returncode, "committed": len(old),
                    "regenerated": len(new), "lost": lost[:50], "added": len(new - old)}
            if r.returncode != 0:
                add("template_regeneration", "FAIL", template, None, None, f"the template command exited {r.returncode}: {r.stderr.decode()[-300:]}")
            elif lost:
                add("template_regeneration", "FAIL", template, None, None,
                    f"regenerating loses {len(lost)} of {len(old)} entries (e.g. {lost[0]!r}): the committed template is not what the build produces")
            elif new - old:
                add("template_regeneration", "WARN", template, None, None, f"regenerating adds {len(new - old)} entries the committed template lacks: commit the regenerated template")
        except (OSError, subprocess.TimeoutExpired) as e:
            add("template_regeneration", "FAIL", template, None, None, f"could not regenerate: {e}")
        finally:
            if before is not None:
                open(full, "wb").write(before)
    fails = sum(1 for f in findings if f["level"] == "FAIL")
    return {"files": paths, "strings": len(corpus), "fail": fails, "warn": len(findings) - fails,
            "findings": findings, "template": tmpl}


# ---------------- glossary fmt | validate ----------------
# PTC's glossary CSV import (GlossaryActions::CsvImport::Parser): a header row of ISO codes (the project's
# source language plus target languages), one term per row.
LANG_SCRIPTS = {"ru": {"CYRILLIC"}, "uk": {"CYRILLIC"}, "bg": {"CYRILLIC"}, "mk": {"CYRILLIC"}, "be": {"CYRILLIC"},
                "kk": {"CYRILLIC"}, "sr": {"CYRILLIC", "LATIN"}, "el": {"GREEK"}, "ar": {"ARABIC"}, "fa": {"ARABIC"},
                "ur": {"ARABIC"}, "he": {"HEBREW"}, "hi": {"DEVANAGARI"}, "mr": {"DEVANAGARI"}, "ne": {"DEVANAGARI"},
                "th": {"THAI"}, "ko": {"HANGUL"}, "ja": {"CJK", "HIRAGANA", "KATAKANA"}, "zh": {"CJK"},
                "ka": {"GEORGIAN"}, "hy": {"ARMENIAN"}, "bn": {"BENGALI"}, "ta": {"TAMIL"}, "am": {"ETHIOPIC"}}


def scripts_of(text):
    import unicodedata
    out = {}
    for ch in text:
        if ch.isalpha():
            try:
                s = unicodedata.name(ch).split()[0]
            except ValueError:
                continue
            out[s] = out.get(s, 0) + 1
    return out


def expected_scripts(code):
    base = re.split(r"[_-]", code)[0].lower()
    if code.lower().endswith(("-latn", "_latn")):
        return {"LATIN"}
    if code.lower().endswith(("-cyrl", "_cyrl")):
        return {"CYRILLIC"}
    return LANG_SCRIPTS.get(base, {"LATIN"})


def read_glossary(path):
    import csv, io
    text = open(path, encoding="utf-8-sig", errors="replace").read()
    return list(csv.reader(io.StringIO(text)))


def glossary_validate(path, source):
    rows = read_glossary(path)
    findings = []

    def add(level, check, row, detail):
        findings.append({"level": level, "check": check, "row": row, "detail": detail})
    if not rows:
        add("FAIL", "structure", None, "empty file")
        return {"rows": 0, "languages": [], "fail": 1, "warn": 0, "findings": findings}
    header = [h.strip() for h in rows[0]]
    src = source or header[0]
    low = [h.lower() for h in header]
    if src.lower() not in low:
        add("FAIL", "structure", 1, f"no column for the source language '{src}' (PTC's import needs it)")
    for i, h in enumerate(header):
        if not h:
            add("FAIL", "structure", 1, f"column {i + 1} has no language code")
        elif not is_lang(h.replace("-", "_").split("_")[0]):
            add("FAIL", "structure", 1, f"column '{h}' is not a language code")
    dup_cols = sorted({h for h in low if h and low.count(h) > 1})
    if dup_cols:
        add("FAIL", "structure", 1, f"language column(s) repeated: {', '.join(dup_cols)}")
    si = low.index(src.lower()) if src.lower() in low else 0
    seen = {}  # normalised source -> (row, {lang: translation})
    folds = {}  # case-folded source -> (first row, exact source, cells)
    for n, r in enumerate(rows[1:], 2):
        if not any(c.strip() for c in r):
            continue
        if len(r) != len(header):
            add("FAIL", "structure", n, f"{len(r)} cells, the header has {len(header)}")
        cells = {header[i]: (r[i].strip() if i < len(r) else "") for i in range(len(header))}
        term = cells.get(header[si], "")
        if not term:
            add("FAIL", "structure", n, "no source term (PTC skips the row)")
            continue
        # S2-G1 (POL-7; TMG-15): a term is its exact source, as PTC's server validator has it; case variants are distinct
        # terms (WARN case_variant). S2-G2 (ruling c): rendered differently in one language they contradict each other (a
        # lowercase term matches case-insensitively): FAIL case_contradiction, which PTC asks the human about.
        key = re.sub(r"\s+", " ", term)
        folded = key.casefold()
        if folded in folds and folds[folded][1] != key:
            first_row, first_key, first_cells = folds[folded]
            clash = [h for h in header if h != header[si] and cells[h] and first_cells.get(h)
                     and cells[h].casefold() != first_cells[h].casefold()]
            if clash:
                add("FAIL", "case_contradiction", n, f"'{term}' and '{first_key}' (row {first_row}) differ only in case but are "
                    f"translated differently for {', '.join(clash)}")
            else:
                add("WARN", "case_variant", n, f"'{term}' differs only in case from row {first_row}: kept as a distinct term")
        folds.setdefault(folded, (n, key, cells))
        if key in seen:
            prev_row, prev = seen[key]
            clash = [h for h in header if h != header[si] and cells[h] and prev.get(h) and cells[h] != prev[h]]
            if clash:
                add("FAIL", "self_contradiction", n, f"'{term}' is translated differently than row {prev_row} for {', '.join(clash)}")
            else:
                add("WARN", "duplicate", n, f"'{term}' repeats row {prev_row} (PTC imports the first one)")
        else:
            seen[key] = (n, cells)
        for h in header:
            v = cells[h]
            if h == header[si] or not v or v == term:
                continue
            want = expected_scripts(h)
            got = scripts_of(v)
            if not got or set(got) & want:
                continue
            level = "WARN" if set(got) == {"LATIN"} else "FAIL"
            add(level, "wrong_script", n, f"{h} cell '{v}' is written in {', '.join(sorted(got))}, expected {', '.join(sorted(want))}")
    fails = sum(1 for f in findings if f["level"] == "FAIL")
    return {"validator": "local-precheck", "note": "an offline pre-check: PTC re-runs its own validator (--remote) on import and on guide submit",
            "rows": len([r for r in rows[1:] if any(c.strip() for c in r)]), "languages": header, "source": header[si] if header else None,
            "fail": fails, "warn": len(findings) - fails, "findings": findings}


def glossary_fmt(path):
    """Canonical form: UTF-8 without BOM, trimmed NFC cells, blank rows dropped, rows padded to the header."""
    import csv, io, unicodedata
    rows = read_glossary(path)
    if not rows:
        return ""
    width = len(rows[0])
    out = io.StringIO()
    w = csv.writer(out, lineterminator="\n")
    for i, r in enumerate(rows):
        cells = [unicodedata.normalize("NFC", re.sub(r"\s+", " ", c).strip()) for c in r]
        if i and not any(cells):
            continue
        w.writerow((cells + [""] * width)[:max(width, len(cells))])
    return out.getvalue()


# ---------------- audit strings (G7 readiness audit) ----------------
AUDIT_MAX_FINDINGS = 500
AUDIT_MAX_EXCERPT = 4096
AUDIT_MINIFIED_RE = re.compile(r"\.min\.(js|css)$|(^|/)(dist|build|public/packs|public/assets|assets/build)/")
PROSE_RE = re.compile(r"[A-Za-z][A-Za-z']+(?:[ ,.!?:;-]+[A-Za-z][A-Za-z']*)+")
WP_GETTEXT = r"(?:__|_e|_x|_ex|_n|_nx|esc_html__|esc_html_e|esc_attr__|esc_attr_e|esc_html_x|esc_attr_x)"
# (framework, rule, class, extensions, regex, fix_hint); group "t" (when present) is the user-visible literal.
AUDIT_RULES = [
    ("wordpress", "php_echo_literal", "hardcoded_string", {".php"},
     re.compile(r"""\b(?:echo|print)\s+(['"])(?P<t>[^'"]*?[A-Za-z]{2,}[^'"]*)\1"""),
     "wrap the text in esc_html__( '...', 'text-domain' ) / esc_html_e()"),
    ("wordpress", "php_html_text", "hardcoded_string", {".php"}, re.compile(r">(?P<t>[^<>]{3,300})<"),
     "wrap the HTML text in esc_html_e( '...', 'text-domain' )"),
    ("wordpress", "gettext_concat_fragment", "concatenation", {".php"},
     re.compile(WP_GETTEXT + r"""\(\s*(['"])[^'"]*\1[^()]*\)\s*\.\s*(?:['"][^'"]*['"]\s*\.\s*)?\$\w+|\$\w+\s*\.\s*(?:['"][^'"]*['"]\s*\.\s*)?""" + WP_GETTEXT + r"\("),
     "one sentence with a placeholder: sprintf( __( 'Welcome to %s', 'domain' ), $x )"),
    ("wordpress", "gettext_variable_domain", "i18n_call_misuse", {".php"},
     re.compile(WP_GETTEXT + r"""\(\s*(['"])(?P<t>[^'"]*)\1\s*,\s*\$\w+"""),
     "the text domain must be a literal string, or the extractor cannot attribute the string"),
    ("wordpress", "gettext_concat_msgid", "i18n_call_misuse", {".php"},
     re.compile(WP_GETTEXT + r"""\(\s*(?:\$\w+|(['"])[^'"]*\1\s*\.)"""),
     "the msgid must be one literal string; move variables into sprintf placeholders"),
    ("wordpress", "plural_ternary", "plural", {".php"},
     re.compile(r"\$\w+\s*===?\s*1\s*\)?\s*\?\s*" + WP_GETTEXT + r"\("),
     "use _n( 'single', 'plural', $n, 'domain' ): other languages have other plural rules"),
    ("wordpress", "date_literal_format", "locale_format", {".php"}, re.compile(r"(?<![\w>$])date\(\s*['\"]"),
     "use date_i18n( get_option( 'date_format' ) ) or wp_date()"),
    ("js", "jsx_text_literal", "hardcoded_string", {".jsx", ".tsx"}, re.compile(r">\s*(?P<t>[^<>{}]*[A-Za-z]{2,}[^<>{}]*?)\s*<"),
     "wrap the JSX text in t('...') (or <Trans>)"),
    ("js", "jsx_attr_literal", "hardcoded_string", {".jsx", ".tsx"},
     re.compile(r"""\b(?:placeholder|title|alt|aria-label|label)=(['"])(?P<t>[^'"]*[A-Za-z]{2,}[^'"]*)\1"""),
     "pass the attribute through t('...')"),
    ("js", "t_result_plus_join", "concatenation", {".js", ".jsx", ".ts", ".tsx", ".mjs"},
     re.compile(r"""\bt\([^()]*\)\s*\+|\+\s*t\("""), "one key with an interpolation: t('greeting', { name })"),
    ("js", "template_literal_concat", "concatenation", {".js", ".jsx", ".ts", ".tsx", ".mjs"},
     re.compile(r"`[^`]*\$\{\s*t\([^`]*`"), "one key with an interpolation instead of a template literal around t()"),
    ("js", "number_without_locale", "locale_format", {".js", ".jsx", ".ts", ".tsx", ".mjs"}, re.compile(r"\.toFixed\(\d\)"),
     "format numbers with toLocaleString() / Intl.NumberFormat for the user's locale"),
    ("rails", "view_text_literal", "hardcoded_string", {".erb"}, re.compile(r">(?P<t>[^<>]{3,300})<"),
     "move the text to config/locales and render it with t('.key')"),
    ("rails", "helper_literal", "hardcoded_string", {".erb", ".haml", ".slim"},
     re.compile(r"""\b(?:link_to|button_to|submit|label_tag)\s*\(?\s*(['"])(?P<t>[^'"]*[A-Za-z]{2,}[^'"]*)\1"""),
     "pass t('.key') instead of the literal"),
    ("rails", "string_plus_t", "concatenation", {".erb", ".haml", ".slim", ".rb"},
     re.compile(r"""['"]\s*\+\s*(?:I18n\.)?t\(|(?<![\w.])(?:I18n\.)?t\([^()]*\)\s*\+\s*['"]"""),
     "one key with an interpolation: t('.greeting', name: x)"),
    ("rails", "pluralize_helper", "plural", {".erb", ".haml", ".slim"}, re.compile(r"\bpluralize\("),
     "use a t() key with one/other (count:) so each language gets its plural rules"),
    ("rails", "strftime_literal", "locale_format", {".erb", ".haml", ".slim"}, re.compile(r"\.strftime\(\s*['\"]"),
     "use l(date, format: :short) with formats in the locale files"),
]
GETTEXT_CALL_RE = re.compile(r"\b" + WP_GETTEXT + r"\(")
STRING_LITERAL_RE = re.compile(r"""'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*\"""")


def gettext_string_spans(line):
    """(start, end) of every quoted string inside the argument list of a __()-family call on the line (an unterminated
    one runs to the end of the line). Text there is the msgid (or context / domain) itself, never a hardcoded string:
    a literal HTML fragment in a msgid (`esc_html__( 'The <em>Plugin</em> is on' )`) is translated as a whole (E30)."""
    spans = []
    for call in GETTEXT_CALL_RE.finditer(line):
        depth, i = 1, call.end()
        while i < len(line) and depth:
            ch = line[i]
            if ch in "'\"":
                lit = STRING_LITERAL_RE.match(line, i)
                end = lit.end() if lit else len(line)
                spans.append((i, end))
                i = end
                continue
            depth += (ch == "(") - (ch == ")")
            i += 1
    return spans


AUDIT_WEIGHTS = {"hardcoded_string": 1.0, "concatenation": 1.0, "i18n_call_misuse": 1.0, "plural": 1.0, "locale_format": 0.5}
COMMENT_LINE_RE = re.compile(r"^\s*(?://|#|\*|/\*|<!--|<%#)")


def audit_frameworks(root, files, census):
    fw = set(census.get("frameworks") or [])
    rt = census.get("runtime") or {}
    exts = {os.path.splitext(f)[1].lower() for f in files}
    names = set(files)
    out = []
    if ".php" in exts and ("gettext" in fw or rt.get("text_domains") or rt.get("load_textdomain")):
        out.append("wordpress")
    pkg = ""
    if "package.json" in names:
        try:
            pkg = open(os.path.join(root, "package.json"), encoding="utf-8", errors="replace").read()
        except OSError:
            pkg = ""
    if "i18next" in fw or re.search(r'"(react|react-i18next|i18next|react-intl)"', pkg) or exts & {".jsx", ".tsx"}:
        out.append("js")
    if "rails-i18n" in fw or "Gemfile" in names and re.search(r"gem ['\"]rails['\"]", open(os.path.join(root, "Gemfile"), encoding="utf-8", errors="replace").read()):
        out.append("rails")
    return out


def audit_line_findings(framework, path, no, line):
    res = []
    if COMMENT_LINE_RE.match(line):
        return res
    ext = os.path.splitext(path)[1].lower()
    gettext_spans = gettext_string_spans(line) if framework == "wordpress" else []
    for fw, rule, cls, rexts, rx, hint in AUDIT_RULES:
        if fw != framework or ext not in rexts:
            continue
        for m in rx.finditer(line):
            text = (m.groupdict().get("t") or "").strip()
            if cls == "hardcoded_string":
                if not PROSE_RE.search(text) and not re.fullmatch(r"[A-Z][a-z]{2,}", text):
                    continue
                if "<?" in text or "<%" in text or "{" in text or "$" in text or text.startswith(("//", "/*")):
                    continue
                if rule.endswith("_text") and re.search(r"""[()";=]|'\s*\.|\.\s*'""", text):
                    continue  # code between two tags (`'<b>' . __( 'x' ) . '</b>'`), not a text node
                start = m.start("t") if m.groupdict().get("t") is not None else m.start()
                if any(a <= start < b for a, b in gettext_spans):
                    continue  # inside the string argument of a gettext call: the msgid itself (E30)
                before = line[:m.start()]
                if rule in ("php_html_text",) and before.count("<?php") > before.count("?>"):
                    continue
            f = {"class": cls, "file": path, "line": no, "excerpt": line.strip()[:AUDIT_MAX_EXCERPT], "rule": rule, "fix_hint": hint}
            if text:
                f["text"] = text[:AUDIT_MAX_EXCERPT]
            res.append(f)
            break
    return res


def audit_strings(root, with_runtime):
    census = scan(root, "en", [])
    files = list_files(root)
    frameworks = audit_frameworks(root, files, census)
    findings, scanned, skipped = [], 0, 0
    for f in files:
        ext = os.path.splitext(f)[1].lower()
        if ext not in CODE_EXT | {".jsx", ".tsx", ".erb"}:
            continue
        if AUDIT_MINIFIED_RE.search(f) or NON_PRODUCT.search(f):
            skipped += 1
            continue
        try:
            text = open(os.path.join(root, f), encoding="utf-8", errors="replace").read()
        except OSError:
            skipped += 1
            continue
        if any(len(l) > 2000 for l in text.splitlines()[:5]):
            skipped += 1  # minified / generated
            continue
        scanned += 1
        for fw in frameworks:
            for no, line in enumerate(text.splitlines(), 1):
                findings += audit_line_findings(fw, f, no, line)
    counts = {}
    for x in findings:
        counts[x["class"]] = counts.get(x["class"], 0) + 1
    out = {"schema": 1, "framework": frameworks, "findings": findings[:AUDIT_MAX_FINDINGS],
           "truncated": len(findings) > AUDIT_MAX_FINDINGS, "counts": {"by_class": counts},
           "coverage": {"files_scanned": scanned, "files_skipped": skipped}}
    if with_runtime:
        out["runtime"] = audit_runtime(root, files, census)
    return out


SCRIPT_TR_RE = re.compile(r"""wp_set_script_translations\(\s*['"]([^'"]+)['"]\s*(?:,\s*['"]([^'"]+)['"])?""")
CATALOGUE_RE = re.compile(r"^(?P<domain>.+?)-(?P<lang>[a-z]{2,3}(?:_[A-Z]{2})?)(?:-(?P<rest>[^/]+))?\.(?P<ext>po|mo|json)$")


def audit_runtime(root, files, census):
    """WordPress runtime loading: script handle <-> jed json, text domain <-> .pot/.po names, unreferenced catalogues,
    stale compiled catalogues (.mo / jed .json older than their .po)."""
    rt = census.get("runtime") or {}
    domains = {d["domain"] for d in rt.get("text_domains", [])} | {d["domain"] for d in rt.get("load_textdomain", [])}
    findings, handles = [], []
    for f in files:
        if not f.endswith(".php") or NON_PRODUCT.search(f):
            continue
        try:
            lines = open(os.path.join(root, f), encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        for no, line in enumerate(lines, 1):
            for m in SCRIPT_TR_RE.finditer(line):
                handles.append({"file": f, "line": no, "handle": m.group(1), "domain": m.group(2) or "default"})
                domains.add(m.group(2) or "default")
    cats = []
    for f in files:
        m = CATALOGUE_RE.match(os.path.basename(f))
        if m:
            cats.append((f, m.group("domain"), m.group("lang"), m.group("rest"), m.group("ext")))
    pots = {os.path.splitext(os.path.basename(f))[0] for f in files if f.endswith(".pot")}
    for h in handles:
        jsons = [c for c in cats if c[4] == "json" and c[1] == h["domain"]]
        if jsons and not any(c[3] == h["handle"] or re.fullmatch(r"[0-9a-f]{32}", c[3] or "") for c in jsons):
            findings.append({"class": "script_catalogue_name", "file": h["file"], "line": h["line"],
                             "detail": f"script handle '{h['handle']}' (domain '{h['domain']}') matches no jed catalogue "
                                       f"{h['domain']}-<locale>-{h['handle']}.json or -<md5>.json"})
    for d in sorted(domains):
        if d != "default" and d not in pots and not any(c[1] == d and c[4] == "po" for c in cats):
            findings.append({"class": "textdomain_catalogue_name", "file": None, "line": None,
                             "detail": f"text domain '{d}' has no {d}.pot or {d}-<locale>.po catalogue"})
    if domains:
        for f, d, lang, rest, ext in cats:
            if d not in domains:
                findings.append({"class": "unreferenced_catalogue", "file": f, "line": None,
                                 "detail": f"catalogue domain '{d}' is not loaded by any text domain or script translation call"})
    po = {(os.path.dirname(f), d, lang): f for f, d, lang, rest, ext in cats if ext == "po" and not rest}
    for f, d, lang, rest, ext in cats:
        src = po.get((os.path.dirname(f), d, lang))
        if ext in ("mo", "json") and src and os.path.getmtime(os.path.join(root, f)) < os.path.getmtime(os.path.join(root, src)):
            findings.append({"class": "stale_compiled_catalogue", "file": f, "line": None,
                             "detail": f"{ext} is older than {src}: WordPress loads the stale compiled catalogue; recompile it"})
    counts = {}
    for x in findings:
        counts[x["class"]] = counts.get(x["class"], 0) + 1
    return {"script_translations": handles, "text_domains": sorted(domains), "findings": findings, "counts": {"by_class": counts}}


# ---------------- guide ----------------
def semver_lt(a, b):
    def p(v):
        return [int(x) for x in re.findall(r"\d+", v or "0")[:3]] + [0] * 3
    return p(a)[:3] < p(b)[:3]


def render_option(o):
    """SF-24 (L8): an ask_human option as people read it: a plain string as is; an object (delivery_channel's
    {id, label, available, reason, hint}) as `id`: label, plus why it is not available."""
    if not isinstance(o, dict):
        return str(o)
    text = "`%s`: %s" % (o.get("id"), o.get("label") or "") if o.get("id") is not None else (o.get("label") or json.dumps(o))
    if o.get("available") is False:
        text += " (not available: %s)" % (o.get("reason") or "PTC says so")
    elif o.get("hint"):
        text += " (%s)" % o["hint"]
    return text


def render_task(t):
    out = [f"Task {t.get('id')} [{t.get('type')}] (stage {t.get('stage')}): {t.get('title', '')}"]
    for k in ("why", "instructions"):
        if t.get(k):
            out.append(f"\n{k.capitalize()}:\n  {t[k]}")
    if t.get("allowed_scope"):
        out.append("\nAllowed scope: " + ", ".join(t["allowed_scope"]))
    if t.get("cli_commands"):
        out.append("\nCommands:\n" + "\n".join("  " + c for c in t["cli_commands"]))
    ah = t.get("ask_human")
    if ah:
        out.append("\nAsk the human: " + ah.get("question", ""))
        if ah.get("options"):
            out.append("  options:")
            for o in ah["options"]:
                out.append("    - " + render_option(o))
        out.extend(default_lines(ah))
        out.append(answer_via_line(ah))
    for also in t.get("also_ask_human") or []:
        if isinstance(also, dict):
            out.append("\nAlso ask the human (%s): %s" % (also.get("task_id") or "", also.get("question", "")))
            for o in also.get("options") or []:
                out.append("    - " + render_option(o))
            out.extend(default_lines(also))
            out.append(answer_via_line(also))
    return "\n".join(out)


def default_lines(ask):
    """L14 (SF-41): the ask's default - PTC's generated draft or the value the human is asked to confirm - in full, every
    line of it, so an agent without --json can show the human what PTC wrote."""
    d = ask.get("default")
    if d is None or d == "" or d == []:
        return []
    if isinstance(d, list):
        return ["  default (show the human; they confirm or change it): " + ", ".join(str(x) for x in d)]
    if isinstance(d, dict):
        d = json.dumps(d, ensure_ascii=False)
    return ["  default (PTC's draft; show it to the human verbatim):"] + ["    " + line for line in str(d).splitlines()]


def answer_via_line(ask):
    """L13 (SF-38): where the human answers, as PTC names it: the chat, and the guide page only when PTC names "app"."""
    via = ask.get("answer_via") or ["chat"]
    if "chat" not in via:
        return "  the human answers in PTC: " + " ".join(str(v) for v in via if v != "app")
    if "app" in via:
        return "  the human answers here in the chat, or on the guide page in PTC"
    return "  the human answers here in the chat (relay their reply)"


def render_pushes(resp):
    """L11 (SF-31): the conversion pushes PTC attaches to an answer, in full: the switch-to-CI `suggestion` (told once per
    delivery; relay it to the human once) and the `subscribe` push (a trial limit that bit), with its link."""
    out = []
    if not isinstance(resp, dict):
        return out
    if resp.get("suggestion"):
        out.append("PTC suggests (tell your user once; a suggestion, not a task): " + str(resp["suggestion"]))
    sub = resp.get("subscribe")
    if isinstance(sub, dict) and (sub.get("text") or sub.get("url")):
        out.append("PTC asks your user to subscribe (%s): %s" % (sub.get("reason") or "trial limit", sub.get("text") or ""))
        if sub.get("url"):
            out.append("  Billing: " + str(sub["url"]))
    return out


def guide_render(kind, body_path, as_json, version):
    """Print the response; exit code per the protocol."""
    try:
        resp = json.load(open(body_path))
    except Exception:
        sys.stderr.write("PTC answered with a body that is not JSON\n")
        return 1
    cli = resp.get("cli") or {}
    if cli.get("min_version") and semver_lt(version, cli["min_version"]):
        sys.stderr.write(f"This ptc CLI is {version}; PTC requires at least {cli['min_version']}. Upgrade:\n"
                         "  curl -fsSL https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/main/ptc-cli.sh -o ptc-cli.sh && chmod +x ptc-cli.sh\n")
        if as_json:
            print(json.dumps(resp, indent=2, sort_keys=True))
        return 4
    if as_json:
        print(json.dumps(resp, indent=2, sort_keys=True))
    code = 0
    if kind in ("submit", "skip", "wait"):
        v = resp.get("verdict")
        code = {"accepted": 0, "skipped": 0, "rejected": 2, "needs_more": 3}.get(v, 1)
        if not as_json:
            print(f"Verdict: {v}")
            for r in resp.get("reasons") or []:
                print(f"  - {r}")
            nxt = resp.get("next")
            if isinstance(nxt, dict) and nxt.get("id"):
                print("\nNext:\n" + render_task(nxt))
            elif resp.get("done") is True:
                # L13 (SF-36, CLI-13): the answer that closed the last task carries PTC's done message; printed whole.
                print("\n" + (resp.get("message") or "All guide tasks are done."))
            pushes = render_pushes(resp)
            if pushes:
                print("\n" + "\n".join(pushes))
    elif kind == "next":
        # SF-12 (staging walk 3): "done" only on PTC's explicit done; a {task: null, waiting: ...} answer is a wait
        # (exit 3, the needs_more / still-waiting code) and prints the step PTC names.
        task = resp.get("task")
        if not task and resp.get("done") is not True:
            code = 3
        if not as_json:
            if resp.get("product_dir"):
                print(f"Product {resp['product_dir']} (session {resp.get('session_id')}):")
            if task:
                print(render_task(task))
            elif resp.get("done") is True:
                # L13 (SF-36, CLI-13): PTC's done message (on the API channel it names `ptc sync`), never a fixed sentence.
                print(resp.get("message") or "All guide tasks are done.")
            else:
                print("PTC is waiting: " + (resp.get("waiting") or resp.get("instructions")
                                            or "no task to hand out yet; run 'ptc guide next' again"))
            pushes = render_pushes(resp)
            if pushes:
                print("\n" + "\n".join(pushes))
    elif kind == "status":
        if not as_json:
            print(f"Stage {resp.get('stage')}  readiness {resp.get('readiness')}")
            for t in resp.get("tasks") or []:
                print(f"  {t.get('id')}  {t.get('type')}  {t.get('state')}  {t.get('verdict') or ''}")
            for q in resp.get("pending_ask_human") or []:
                print(f"  waiting on the human: {q.get('question') if isinstance(q, dict) else q}")
            for p in resp.get("products") or []:
                print(f"  product {p.get('dir')}: session {p.get('session_id')}  {p.get('state')}  readiness {p.get('readiness')}")
    elif kind == "start":
        if not as_json:
            print(f"Guide session {resp.get('session_id')} (stage {resp.get('stage')}, readiness {resp.get('readiness')})")
    return code


def read_changed(path):
    """None when no base was found (unknown), else the changed paths."""
    try:
        lines = [l.rstrip("\n") for l in open(path) if l.strip()]
    except OSError:
        return None
    if not any(l.startswith("--base ") for l in lines):
        return None
    return [l for l in lines if not l.startswith("--base ")]


CONFIG_FILE_RE = re.compile(r"(^|/)\.ptc-config\.ya?ml$|^\.github/workflows/[^/]+\.ya?ml$|^\.gitlab-ci\.ya?ml$|^\.gitlab/ptc\.ya?ml$")


def config_files_sha(root):
    """sha256 of every CI/config file PTC generates (.ptc-config.yml at any depth, GitHub workflows, .gitlab-ci.yml, .gitlab/ptc.yml),
    read from the commit (git HEAD blob) so the digest is the committed content, falling back to the working tree."""
    import hashlib
    out = {}
    # E1: a product's action run (project-dir: <dir>) still reports the repository's config files, keyed by
    # repository-root paths (<dir>/.ptc-config.yml, .github/workflows/ptc.yml), as commit_config hands them out.
    top = git(root, "rev-parse", "--show-toplevel") or root
    root = top
    pats = ptcignore_patterns(root)
    for f in list_files(root):
        if not CONFIG_FILE_RE.search(f) or excluded(f, pats):
            continue
        data = None
        try:
            data = subprocess.run(["git", "-c", "safe.directory=*", "-C", root, "cat-file", "blob", "HEAD:" + f],
                                  capture_output=True, check=True).stdout
        except Exception:
            try:
                data = open(os.path.join(root, f), "rb").read()
            except OSError:
                continue
        out[f] = hashlib.sha256(data).hexdigest()
    return dict(sorted(out.items()))


FILES_SHA_MAX = 200


def changed_files_sha(root, changed, out):
    """E32: add the sha256 of the committed HEAD blob of every path this commit changed (the changed_files list plus the
    HEAD commit's own diff, so a checkout without a base ref still reports its edits) to `out`, up to FILES_SHA_MAX keys in
    all (a root commit adds nothing: it is the whole tree; a shallow HEAD fetches its one parent first, F22). PTC's source_fixes check matches the sha256 the agent reports
    for each edited file against these."""
    import hashlib
    top = git(root, "rev-parse", "--show-toplevel") or root
    own = (git(top, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD") or "").splitlines()
    if not own and not git(top, "rev-parse", "-q", "--verify", "HEAD^") and git(top, "rev-parse", "--is-shallow-repository") == "true":
        # S2-R6 F22: actions/checkout's default depth 1 leaves HEAD without its parent, so the diff above is empty
        # (and `--root` or `git show` would list the whole tree). Fetch the one parent commit and diff again; on any
        # failure the run reports the config files only, as before. A true root commit is not shallow: nothing added.
        try:
            subprocess.run(["git", "-c", "safe.directory=*", "-C", top, "fetch", "-q", "--no-tags", "--deepen=1", "origin"],
                           capture_output=True, check=True, timeout=60, env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
            own = (git(top, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD") or "").splitlines()
        except Exception:
            pass
    for f in list(changed or []) + own:
        if len(out) >= FILES_SHA_MAX:
            break
        if not f or f in out:
            continue
        try:
            data = subprocess.run(["git", "-c", "safe.directory=*", "-C", top, "cat-file", "blob", "HEAD:" + f],
                                  capture_output=True, check=True).stdout
        except Exception:
            continue  # deleted by the commit
        out[f] = hashlib.sha256(data).hexdigest()
    return dict(sorted(out.items()))


DELIVERED_FILES_MAX = 500
# L3-1 (POL-116): the census source files' digests ride in files_sha beside the config and changed files (PTC's door keeps
# up to 2000 keys); a bigger census reports its first SOURCES_SHA_MAX sources.
SOURCES_SHA_MAX = 1500


def census_sources_sha(root, scan_doc, out):
    """L3-1 (POL-116, AGD-4): add the sha256 of every census source file (every source file of every resource set of the
    scan), read from the BYTES ON DISK at run time, keyed by repository-root path as files_sha is. A key already present
    (a config file, or a changed file read from the commit) keeps its value. PTC proves the run's content on these."""
    import hashlib
    prefix = git(root, "rev-parse", "--show-prefix").strip()
    added = 0
    for s in scan_doc.get("resource_sets", []):
        for sf in s.get("source_files", []):
            key = prefix + sf["path"]
            if key in out or added >= SOURCES_SHA_MAX:
                continue
            try:
                data = open(os.path.join(root, sf["path"]), "rb").read()
            except OSError:
                continue
            out[key] = hashlib.sha256(data).hexdigest()
            added += 1
    return dict(sorted(out.items()))


def output_regex(out_pat):
    """The config output pattern as a regex over run-relative paths; group "lang" is the language slot."""
    return re.compile("^" + re.escape(out_pat).replace(re.escape("{{lang}}"), r"(?P<lang>[A-Za-z]{2,3}(?:[_-][A-Za-z0-9]{2,4})?)")
                      .replace(r"\*\*/", "(?:.*/)?").replace(r"\*", "[^/]*") + "$")


def delivered_files_sha(root, cfg):
    """sha256 of the committed HEAD blob of every delivered translation file: a file matching a config entry's output
    pattern with a language in the {{lang}} slot, not the entry's source. Keys are repository-root paths (as files_sha);
    capped at DELIVERED_FILES_MAX files. PTC compares them with the files it delivered (delivery_proof: no git edit)."""
    import hashlib
    entries = [e for e in (cfg or {}).get("files") or [] if e.get("file") and "{{lang}}" in (e.get("output") or "")]
    if not entries:
        return {}
    files = list_files(root)
    prefix = git(root, "rev-parse", "--show-prefix")
    found = []
    for e in entries:
        rx = output_regex(e["output"])
        srcs = {f for f in files if fnmatch_path(f, e["file"])}
        for f in files:
            m = rx.match(f)
            if m and f not in srcs and is_lang(m.group("lang")) and f not in found:
                found.append(f)
    out = {}
    for f in sorted(found)[:DELIVERED_FILES_MAX]:
        data = None
        try:
            data = subprocess.run(["git", "-c", "safe.directory=*", "-C", root, "cat-file", "blob", "HEAD:./" + f],
                                  capture_output=True, check=True).stdout
        except Exception:
            try:
                data = open(os.path.join(root, f), "rb").read()
            except OSError:
                continue
        out[prefix + f] = hashlib.sha256(data).hexdigest()
    return out


def delivered_files_sha_at(root, cfg, rev):
    """P4 T14: delivered_files_sha of commit `rev` (the translations-branch commit the pull-request step made), read from
    the commit itself, not the working tree: the files are listed with ls-tree and hashed from their blobs at `rev`."""
    import hashlib
    entries = [e for e in (cfg or {}).get("files") or [] if e.get("file") and "{{lang}}" in (e.get("output") or "")]
    if not entries:
        return {}
    prefix = git(root, "rev-parse", "--show-prefix")
    listed = git(root, "ls-tree", "-r", "--name-only", "--full-name", rev, "--", ".")
    files = sorted({f[len(prefix):] for f in listed.splitlines() if f.startswith(prefix)})
    found = []
    for e in entries:
        rx = output_regex(e["output"])
        for f in files:
            m = rx.match(f)
            if m and not fnmatch_path(f, e["file"]) and is_lang(m.group("lang")) and f not in found:
                found.append(f)
    out = {}
    for f in sorted(found)[:DELIVERED_FILES_MAX]:
        try:
            data = subprocess.run(["git", "-c", "safe.directory=*", "-C", root, "cat-file", "blob", rev + ":" + prefix + f],
                                  capture_output=True, check=True).stdout
        except Exception:
            continue
        out[prefix + f] = hashlib.sha256(data).hexdigest()
    return out


# S2-R14 (Eran 2026-10-02): no validate result any more (PTC validates what it generates); extra args are ignored.
def delivery_body(cfg_path, project_id, sha, branch, source_sha, root, stopped="", *_ignored):
    cfg = json.load(open(cfg_path)).get("config") if cfg_path else None
    pid = project_id or ((cfg or {}).get("guide") or {}).get("project_id")
    # S2-R3B F-2: stopped_reason (monitor_bound) rides with the commit, or alone when nothing finished inside the bound.
    body = {"project_id": int(pid) if str(pid or "").isdigit() else (pid or None), "commit_sha": sha or None, "branch": branch or None,
            "source_commit_sha": source_sha or None, "ci_id_token": os.environ.get("PTC_CI_ID_TOKEN_VALUE") or None,
            "delivered_files_sha": delivered_files_sha_at(root, cfg, sha) if sha else {}}
    if stopped:
        body["stopped_reason"] = stopped
    # L3-2 (POL-116): `ptc sync`'s branch-less report: the working tree's fingerprint keys it (no commit) and the files
    # are exactly the ones this run wrote (the written manifest), hashed from the bytes on disk, repository-root keys.
    if os.environ.get("PTC_DC_FINGERPRINT"):
        body["workspace_fingerprint"] = os.environ["PTC_DC_FINGERPRINT"]
    if os.environ.get("PTC_DC_WRITTEN"):
        body["delivered_files_sha"] = written_files_sha(root, os.environ["PTC_DC_WRITTEN"])
    if os.environ.get("PTC_AGENT_LOCAL") == "1":
        body["provenance_request"] = "agent_local"
    print(json.dumps(body, sort_keys=True))
    return 0


def written_files_sha(root, manifest):
    """L3-2: {repository-root path: sha256 of the bytes on disk} of every file in a --written-manifest (NUL-separated,
    relative to the repository root, or to `root` without git; a ":(literal)" pathspec prefix is dropped)."""
    import hashlib
    top = git(root, "rev-parse", "--show-toplevel") or root
    out = {}
    try:
        entries = open(manifest, "rb").read().decode("utf-8", "replace").split("\0")
    except OSError:
        return out
    for rel in entries:
        rel = rel[len(":(literal)"):] if rel.startswith(":(literal)") else rel
        if not rel or rel in out or len(out) >= DELIVERED_FILES_MAX:
            continue
        try:
            out[rel] = hashlib.sha256(open(os.path.join(top, rel), "rb").read()).hexdigest()
        except OSError:
            continue
    return dict(sorted(out.items()))


NAMED_FILES_MAX = 100
NAMED_FILE_MAX_BYTES = 1024 * 1024


def named_files(root, listing):
    """SF-22 (L8): {repository-root path: bytes} of the files named in `listing` (one path per line: the --file arguments
    and the paths guide tasks named, .ptc/session.json named_files) that exist under the repository root; a path that
    leaves the root, a missing file and a file over NAMED_FILE_MAX_BYTES are left out."""
    top = os.path.realpath(git(root, "rev-parse", "--show-toplevel") or root)
    out = {}
    for raw in listing.splitlines():
        path = raw.strip().replace(os.sep, "/")
        while path.startswith("./"):
            path = path[2:]
        if not path or path in out or len(out) >= NAMED_FILES_MAX:
            continue
        full = os.path.realpath(os.path.join(top, path))
        if not full.startswith(top + os.sep) or not os.path.isfile(full) or os.path.getsize(full) > NAMED_FILE_MAX_BYTES:
            continue
        with open(full, "rb") as fh:
            out[path] = fh.read()
    return out


def action_body(scan_path, cfg_path, project_id, sha, branch, root, limit, changed_path=None):
    scan_doc = json.load(open(scan_path))
    cfg_doc = json.load(open(cfg_path)) if cfg_path else {}
    cfg = cfg_doc.get("config")
    changed = read_changed(changed_path) if changed_path else None
    # S2-R21-2: a source file the commit changed is always sent, beyond the cap, so a source fix is provable without
    # raising PTC_FILES_SAMPLE_LIMIT (changed paths are repository-root paths; scan paths are relative to the run dir).
    prefix = git(root, "rev-parse", "--show-prefix").strip()
    changed_set = set(changed or [])
    sample, total = {}, 0
    for s in scan_doc.get("resource_sets", []):
        for sf in s.get("source_files", []):
            p = os.path.join(root, sf["path"])
            try:
                data = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            size = len(data.encode("utf-8"))
            if total + size > limit and (prefix + sf["path"]) not in changed_set:
                continue
            sample[sf["path"]] = data
            total += size
    pid = project_id or ((cfg or {}).get("guide") or {}).get("project_id")
    body = {"project_id": int(pid) if str(pid or "").isdigit() else (pid or None), "commit_sha": sha, "branch": branch,
            "config": cfg, "scan": scan_doc, "files_sample": sample,
            # S2-R3F B1-3 (AGD-4, POL-11): the checkout's own `ptc config validate --json` ignored_outputs (the output paths
            # git ignores, E35), so PTC's commit_config checks the run's list, never the agent's claim. None: no config read.
            "ignored_outputs": cfg_doc.get("ignored_outputs") if cfg else None,
            # P1 provenance: the CI platform's identity token (JWT; None = unverified provenance) and the
            # committed config files' digests, which commit_config compares with what PTC generated.
            "ci_id_token": os.environ.get("PTC_CI_ID_TOKEN_VALUE") or None,
            # E1: the run's directory relative to the repository root ("" at the root): scan and upload paths are
            # relative to it (the product slice), files_sha keys are repository-root paths.
            "repo_prefix": git(root, "rev-parse", "--show-prefix").rstrip("/"),
            # E32: plus every path the commit changed (source_fixes proof).
            "files_sha": None,
            # P2 delivery_proof: the delivered translation files at the commit, so PTC can refuse a git edit of them.
            "delivered_files_sha": delivered_files_sha(root, cfg)}
    body["files_sha"] = census_sources_sha(root, scan_doc, changed_files_sha(root, changed, config_files_sha(root)))
    # SF-22 (L8, POL-116): the files a guide task named (and each --file) ride with their bytes, so PTC proves an edit to
    # a file it stores no upload of (a code file a source fix edits) on the run's own copy (Guide::RunEvidence), with
    # or without git; the fingerprint, the run key without a commit, covers them too.
    named = named_files(root, os.environ.get("PTC_NAMED_FILES", ""))
    import hashlib
    for path, data in named.items():
        digest = hashlib.sha256(data).hexdigest()
        if body["files_sha"].get(path, digest) != digest:
            continue  # git reported the committed blob of this path: the commit is the proof, as before
        body["files_sha"][path] = digest
        sample[path] = data.decode("utf-8", errors="replace")
    body["files_sha"] = dict(sorted(body["files_sha"].items()))
    # L3-1 (POL-116): the working tree's fingerprint (`ptc scan`), the run key when there is no commit (Guide::RunKey);
    # without git no commit_sha is sent at all.
    body["workspace_fingerprint"] = (scan_doc.get("repo") or {}).get("workspace_fingerprint")
    if named and body["workspace_fingerprint"]:
        body["workspace_fingerprint"] = workspace_fingerprint(root, scan_doc.get("resource_sets", []), named)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", sha or ""):  # an empty repository's rev-parse prints "HEAD"
        del body["commit_sha"]
    # Outside CI (no CI marker, no identity token) the run asks to be recorded agent_local; PTC decides (API-32).
    if os.environ.get("PTC_AGENT_LOCAL") == "1":
        body["provenance_request"] = "agent_local"
    if changed is not None:
        body["changed_files"] = changed
    print(json.dumps(body, sort_keys=True))
    return 0


def project_answer(path):
    """SF-18 (L8): POST /api/v1/projects' answer. A project -> its id on stdout and the created / rejoined text on stderr.
    PTC's "which organization" answer (the token acts in several organizations, none named) -> the organizations as a
    readable list and the remedy on stderr, exit 3. Anything else -> PTC's error, exit 1."""
    try:
        d = json.load(open(path))
    except Exception:
        sys.stderr.write("PTC answered with a body that is not JSON\n")
        return 1
    if d.get("project_id") is not None:
        if d.get("rejoined"):
            sys.stderr.write("Rejoined PTC project %s: continuing guide session %s (named by this directory's config, or this "
                             "repository's).\n" % (d["project_id"], d.get("session_id")))
        else:
            u = d.get("token_page_url") or ""
            u = u if "/agent-tokens" in u else "PTC > Agent tokens"
            sys.stderr.write("Created PTC project %s.\nThe human adds the CI secret PTC_API_TOKEN = the organization agent token (the same token "
                             "the agent uses), from: %s\nThe project has no target languages yet: the human sets them in the PTC dashboard "
                             "(the project's target languages), or through the guide's target_languages task when an agent runs the "
                             "guide.\n" % (d["project_id"], u))
        print(d["project_id"])
        return 0
    orgs = d.get("organizations")
    if isinstance(orgs, list) and orgs:
        out = ["PTC asks %s the project belongs to: your agent token acts in %d organizations." % (d.get("ask") or "which organization", len(orgs))]
        for o in orgs:
            o = o if isinstance(o, dict) else {"id": o}
            out.append("  %s  %s" % (o.get("id"), o.get("name") or ""))
        if d.get("error"):
            out.insert(0, "PTC refused: %s" % d["error"])
        out.append("Ask the human which one, then run: ptc guide start --organization-id ID (the same options as before).")
        sys.stderr.write("\n".join(out) + "\n")
        return 3
    sys.stderr.write("PTC created no project: %s\n" % (d.get("error") or json.dumps(d)))
    return 1


def main(argv):
    cmd = argv[0]
    if cmd == "scan":
        pairs = []
        for a in argv[3:]:
            f, _, o = a.partition("\t")
            pairs.append((f, o))
        print(json.dumps(scan(argv[1], argv[2], pairs), indent=2, sort_keys=False))
        return 0
    if cmd == "config":
        res = config_validate(argv[1], argv[2])
        if argv[3] == "json":
            print(json.dumps(res, indent=2))
        else:
            for e in res["files"]:
                print(f"{e['file']}  ({e['matches']} file(s))")
                for l, o in sorted(e["outputs"].items()):
                    print(f"  {l}: {o}")
            for w in res.get("warnings", []):
                print(f"warning: {w}")
            for e in res["errors"]:
                print(f"error: {e}")
            print("config is valid" if res["valid"] else "config is NOT valid")
        return 0 if res["valid"] else 2
    if cmd == "render":
        return guide_render(argv[1], argv[2], argv[3] == "json", argv[4])
    if cmd == "pushes":
        # L11 (SF-31): the pushes of a door's answer (action-run, delivery-commit, a suite product walked past).
        try:
            resp = json.load(open(argv[1]))
        except Exception:
            return 0
        for line in render_pushes(resp):
            print(line)
        return 0
    if cmd == "project-answer":
        return project_answer(argv[1])
    if cmd == "field":
        v = json.load(open(argv[1]))
        for k in argv[2].split("."):
            v = v.get(k) if isinstance(v, dict) else None
        print("" if v is None else v)
        return 0
    if cmd == "body":
        print(json.dumps(json.loads(argv[1])))
        return 0
    if cmd == "action-body":
        return action_body(argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], int(argv[7]), argv[8] if len(argv) > 8 else None)
    if cmd == "delivery-body":
        return delivery_body(argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], *argv[7:9])
    if cmd == "sess":
        return guide_sessions(argv[1], argv[2:])
    if cmd == "glossary-remote":
        res = json.load(open(argv[1], encoding="utf-8"))
        if argv[2] == "json":
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            for f in res.get("findings", []):
                where = " ".join(x for x in [f.get("term") or "", f"({f['language']})" if f.get("language") else ""] if x)
                print(f"{f['level']} {f['check']}: {where + ': ' if where else ''}{f['detail']}")
            print(f"{res.get('rows')} term(s), languages {', '.join(res.get('languages') or [])}: {res.get('fail')} FAIL, {res.get('warn')} WARN (PTC's validator)")
        return 2 if res.get("fail") else 0
    if cmd == "glossary":
        op, path, fmt, source, write = argv[1], argv[2], argv[3], argv[4], argv[5] == "1"
        if op == "fmt":
            out = glossary_fmt(path)
            if write:
                open(path, "w", encoding="utf-8").write(out)
            else:
                sys.stdout.write(out)
            return 0
        res = glossary_validate(path, source)
        if fmt == "json":
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            for f in res["findings"]:
                print(f"{f['level']} {f['check']}: row {f['row']}: {f['detail']}")
            print(f"{res['rows']} term(s), languages {', '.join(res['languages'])}: {res['fail']} FAIL, {res['warn']} WARN "
                  "(local pre-check; PTC re-runs its own validator: --remote)")
        return 2 if res["fail"] else 0
    if cmd == "audit-strings":
        res = audit_strings(argv[1], argv[3] == "1")
        if argv[2] == "json":
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            for f in res["findings"]:
                print(f"{f['class']} {f['file']}:{f['line']} [{f['rule']}] {f['excerpt'][:160]}")
            for f in res.get("runtime", {}).get("findings", []):
                print(f"runtime {f['class']}: {f['file'] or '-'}: {f['detail']}")
            print(f"frameworks: {', '.join(res['framework']) or 'none'}; {len(res['findings'])} finding(s)"
                  + (" (truncated)" if res["truncated"] else "") + f" in {res['coverage']['files_scanned']} file(s)")
        return 2 if not res["framework"] else 0
    if cmd == "word-count-cases":
        cases = json.load(open(argv[1], encoding="utf-8"))["cases"]
        bad = [(c["text"], c["words"], count_words(c["text"])) for c in cases if count_words(c["text"]) != c["words"]]
        for text, want, got in bad:
            print(f"MISMATCH {text!r}: PTC counts {want}, the CLI counts {got}")
        print(f"{len(cases) - len(bad)} of {len(cases)} cases agree with PTC's word rule")
        return 1 if bad else 0
    if cmd == "estimate":
        root, fmt, cfg_path, langs_csv, rate, balance = argv[1:7]
        paths = argv[7:]
        cfg = read_config(cfg_path) if cfg_path and os.path.isfile(cfg_path) else {}
        if not paths:
            paths = [f["file"] for f in cfg.get("files", []) if f.get("file")]
        if not paths:
            d = scan(root, "", [])
            paths = [sf["path"] for st in d["resource_sets"] for sf in st["source_files"]]
        # S2-R28-2: `--exclude PATH` (repeatable) quotes the scope a 'fewer files' answer names.
        excluded = set(p for p in os.environ.get("PTC_ESTIMATE_EXCLUDE", "").split("\n") if p)
        paths = [p for p in paths if p not in excluded]
        langs = [l for l in (langs_csv.split(",") if langs_csv else cfg.get("languages") or []) if l]
        if isinstance(langs, str):
            langs = [langs]
        if not langs:
            sys.stderr.write("ptc estimate: no target languages (set languages: in the config, or pass --languages de,fr)\n")
            return 1
        remote = {}
        if os.environ.get("PTC_REMOTE_ESTIMATE") and os.path.isfile(os.environ["PTC_REMOTE_ESTIMATE"]):
            for line in open(os.environ["PTC_REMOTE_ESTIMATE"], encoding="utf-8"):
                path, _, body = line.rstrip("\n").partition("\t")
                try:
                    q = json.loads(body)
                    br = (q.get("usage_estimate") or {}).get("per_language_breakdown") or {}
                    if br:
                        remote[path] = round(float(q.get("words_required") or sum(br.values())) / len(br), 2)
                except Exception:
                    pass
        res = estimate(root, paths, langs, float(rate) if rate else None, float(balance) if balance else None, remote)
        if fmt == "unquoted":
            print("\n".join(res["unquoted"]))
            return 0
        if fmt == "json":
            print(json.dumps(res, indent=2, ensure_ascii=False))
            return 0
        for f in res["files"]:
            if f.get("counted_by") == "ptc":
                print(f"{f['path']}: {f['words']} words (PTC's dry-run estimate)")
            else:
                print(f"{f['path']}: {f['strings']} strings, {f['words']} words")
        for p in res["unquoted"]:
            print(f"{p}: not counted (no local reader for this format; without --offline PTC's dry-run estimate counts it)")
        for l, c in res["credits_per_language"].items():
            print(f"{l}: {res['words_per_language']} words, {c} credits")
        cost = f", {res['credits_total']} credits" if res["credits_total"] is not None else ""
        print(f"Total: {res['words_total']} words{cost} ({len(res['languages'])} languages)")
        if res["balance_words"] is not None:
            short = res["shortfall_words"]
            print(f"Balance: {res['balance_words']} words" + (f", short by {short} words" if short else ", covers the estimate"))
        return 0
    if cmd == "lint-source":
        root, fmt, template, tcmd = argv[1], argv[2], argv[3], argv[4]
        paths = argv[5:]
        if not paths:
            d = scan(root, "", [])
            paths = [sf["path"] for st in d["resource_sets"] for sf in st["source_files"]]
        res = lint_source(root, paths, template, tcmd)
        if fmt == "json":
            print(json.dumps(res, indent=2))
        else:
            for f in res["findings"]:
                loc = f["file"] + (f" [{f['key']}]" if f["key"] else "")
                print(f"{f['level']} {f['check']}: {loc}: {f['detail']}")
            print(f"{res['strings']} strings in {len(res['files'])} file(s): {res['fail']} FAIL, {res['warn']} WARN")
        return 2 if res["fail"] else 0
    if cmd == "describe-apply":
        try:
            res = describe_apply(argv[1], argv[2], argv[3] == "1", len(argv) > 5 and argv[5] == "1")
        except (ValueError, OSError) as e:
            sys.stderr.write(f"describe apply: {e}\n")
            return 1
        if argv[4] == "json":
            print(json.dumps(res, indent=2))
        else:
            verb = "would write" if argv[3] == "1" else "wrote"
            print(f"{len(res['applied'])} description(s) {verb}, {len(res['unchanged'])} already present, {len(res['skipped'])} skipped")
            for x in res["skipped"]:
                print(f"  skipped {x.get('file', '')} {x.get('key', '')}: {x['reason']}")
            for w in res["warnings"]:
                print(f"warning: {w}")
        return 2 if res["skipped"] else 0
    return 1


def task_named_paths(task):
    """SF-22 (L8): the repository paths a task's payload names for the agent to edit (proposals, readiness_manual)."""
    payload = task.get("payload") if isinstance(task.get("payload"), dict) else {}
    out = []
    for key in ("proposals", "readiness_manual"):
        for item in payload.get(key) or []:
            path = item.get("path") if isinstance(item, dict) else None
            if isinstance(path, str) and path and not path.startswith("/") and path not in out:
                out.append(path)
    return out


def guide_sessions(op, args):
    """.ptc/session.json of a suite: {session_id, project_id, products:[{dir, session_id, project_id}], tasks:{task_id: session_id}}."""
    path = args[0]
    try:
        d = json.load(open(path))
    except (OSError, ValueError):
        d = {}
    if op == "products":        # save the products of a suite response, print "session_id state dir" per product
        resp = json.load(open(args[1]))
        if resp.get("products"):
            d["products"] = [{"dir": p.get("dir"), "session_id": p.get("session_id"), "project_id": p.get("project_id")}
                             for p in resp["products"]]
            json.dump(d, open(path, "w"))
            for p in resp["products"]:
                print(f"{p.get('session_id')} {p.get('state')} {p.get('dir')}")
        return 0
    if op == "task":            # remember which session handed out the task(s) in a response
        resp = json.load(open(args[1]))
        tasks = d.setdefault("tasks", {})
        for t in (resp.get("task"), resp.get("next")):
            if isinstance(t, dict) and t.get("id"):
                tasks[t["id"]] = args[2]
                # SF-22 (L8): the files the task names (its payload's proposals / readiness_manual paths, e.g. the code files
                # a source fix edits) ride in the next `ptc guide action-run` with their bytes.
                named = d.setdefault("named_files", [])
                for p in task_named_paths(t):
                    if p not in named:
                        named.append(p)
        json.dump(d, open(path, "w"))
        return 0
    if op == "named-files":     # the files guide tasks named, one per line
        print("\n".join(d.get("named_files") or []))
        return 0
    if op == "task-session":    # the session a task belongs to
        print((d.get("tasks") or {}).get(args[1], ""))
        return 0
    return 1


sys.exit(main(sys.argv[1:]))
PTC_PY_EOF
)

_ptc_py() {
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "This command needs python3 (>= 3.6) on PATH."
        return 1
    fi
    PTC_CLI_VERSION="$VERSION" python3 -c "$PTC_PY_HELPER" "$@"
}

_ptc_config_pairs() {  # prints "file<TAB>output" per files: entry
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    local files outputs
    files=$(grep -A999 '^files:' "$cfg" | grep '^ *- file:' | sed 's/^ *- file: *//; s/ *$//')
    outputs=$(grep -A999 '^files:' "$cfg" | grep '^ *output:' | sed 's/^ *output: *//; s/ *$//')
    paste <(printf '%s\n' "$files") <(printf '%s\n' "$outputs") | grep -v '^\s*$' || true
}

cmd_scan() {
    local root="$PTC_PROJECT_DIR" json=false cfg="" src=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) json=true; shift ;;
            -d|--project-dir) root="$2"; shift 2 ;;
            -c|--config-file) cfg="$2"; shift 2 ;;
            -s|--source-locale) src="$2"; shift 2 ;;
            -h|--help) echo "Usage: $SCRIPT_NAME scan [--json] [-d DIR] [-c .ptc-config.yml] [-s en]"; return 0 ;;
            *) log_error "Unknown scan option: $1"; return 1 ;;
        esac
    done
    [[ -z "$cfg" && -f "$root/.ptc-config.yml" ]] && cfg="$root/.ptc-config.yml"
    if [[ -n "$cfg" && -z "$src" ]]; then
        src=$(grep '^source_locale:' "$cfg" 2>/dev/null | sed 's/^source_locale: *//; s/ *$//' | tr -d "\"'")
    fi
    local pairs=()
    if [[ -n "$cfg" ]]; then
        parse_config_file "$cfg" >/dev/null 2>&1 || log_warning "$cfg does not parse as a v1 config; scanning without it"
        while IFS= read -r line; do [[ -n "$line" ]] && pairs+=("$line"); done < <(_ptc_config_pairs "$cfg")
    fi
    local out
    out=$(_ptc_py scan "$root" "${src:-en}" "${pairs[@]+"${pairs[@]}"}") || return 1
    if [[ "$json" == "true" ]]; then
        printf '%s\n' "$out"
    else
        printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("frameworks: "+", ".join(d["frameworks"]))
for s in d["resource_sets"]:
    n=sum(f["count"] for f in s["source_files"])
    print("  %-5s %s  (%d entries; languages: %s)"%(s["format"],s["source_pattern"],n,", ".join(s["existing_languages"]) or "none"))
if d["none_reason"]: print(d["none_reason"])
print("keys with code usages: %d"%sum(len(v) for v in d["usages"].values()))'
    fi
}

cmd_glossary() {
    local sub="${1:-}"; shift || true
    if [[ "$sub" != "fmt" && "$sub" != "validate" ]]; then
        echo "Usage: $SCRIPT_NAME glossary fmt FILE.csv [--write] | glossary validate FILE [--remote [--project-id N]] [--source en] [--json]"
        echo "  PTC glossary CSV: header row of language codes (source first by default), one term per row (--remote: CSV or PTC's YAML)."
        echo "  validate --remote: PTC's own validator (the one the guide and the import run; needs PTC_ORG_TOKEN and the project id:"
        echo "    --project-id, PTC_PROJECT_ID / guide.project_id, or the guide session). Without --remote: an offline pre-check."
        echo "  validate: exit 0 no FAIL, 2 any FAIL (structure, self-contradiction, wrong script), 1 error."
        [[ "$sub" == "-h" || "$sub" == "--help" ]] && return 0
        return 1
    fi
    local file="" fmt=text source="" write=0 remote=0 pid=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) fmt=json; shift ;;
            --remote) remote=1; shift ;;
            --project-id) pid="$2"; shift 2 ;;
            --source) source="$2"; shift 2 ;;
            --write) write=1; shift ;;
            -*) log_error "Unknown option: $1"; return 1 ;;
            *) file="$1"; shift ;;
        esac
    done
    [[ -z "$file" ]] && { log_error "glossary $sub needs a CSV file"; return 1; }
    [[ -f "$file" ]] || { log_error "No such file: $file"; return 1; }
    if [[ "$sub" == "validate" && "$remote" == 1 ]]; then
        _glossary_validate_remote "$file" "$fmt" "$pid"; return $?
    fi
    _ptc_py glossary "$sub" "$file" "$fmt" "$source" "$write"
}

# S2-G1 (POL-7): `glossary validate --remote` = POST guide/glossary/validate, PTC's one glossary validator.
_glossary_validate_remote() {
    local file="$1" fmt="$2" pid="${3:-${PTC_GUIDE_PROJECT_ID:-}}" kind=csv body sf
    if [[ -z "$pid" ]]; then
        sf=$(_guide_session_file)
        [[ -f "$sf" ]] && pid=$(_ptc_py field "$sf" project_id)
    fi
    [[ -z "$pid" || "$pid" == "None" ]] && { log_error "glossary validate --remote needs the project id: --project-id N"; return 1; }
    case "${file,,}" in *.yaml|*.yml) kind=yaml ;; esac
    body=$(mktemp)
    python3 -c 'import base64,json,sys;json.dump({"project_id":sys.argv[2],"file_format":sys.argv[3],"content_base64":base64.b64encode(open(sys.argv[1],"rb").read()).decode()},open(sys.argv[4],"w"))' \
        "$file" "$pid" "$kind" "$body"
    _guide_call POST guide/glossary/validate "$body" || { rm -f "$body"; return 1; }
    rm -f "$body"
    _ptc_py glossary-remote "$GUIDE_RESPONSE" "$fmt"
}

cmd_lint() {
    local sub="${1:-}"; shift || true
    if [[ "$sub" != "source" ]]; then
        echo "Usage: $SCRIPT_NAME lint source [--json] [-d DIR] [--file PATH]... [--template PATH --template-cmd CMD]"
        echo "  Deterministic source-string checks (FAIL/WARN). Exit 0 no FAIL, 2 any FAIL, 1 error."
        [[ "$sub" == "-h" || "$sub" == "--help" ]] && return 0
        return 1
    fi
    local fmt=text root="$PTC_PROJECT_DIR" template="" tcmd="" files=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) fmt=json; shift ;;
            -d|--project-dir) root="$2"; shift 2 ;;
            --file) files+=("$2"); shift 2 ;;
            --template) template="$2"; shift 2 ;;
            --template-cmd) tcmd="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    if [[ -n "$tcmd" && -z "$template" ]] || [[ -z "$tcmd" && -n "$template" ]]; then
        log_error "--template and --template-cmd go together"; return 1
    fi
    _ptc_py lint-source "$root" "$fmt" "$template" "$tcmd" ${files[@]+"${files[@]}"}
}

# S2-R2 item 2 (decision 5; specs/agent-guide AGD-3): a LOCAL quote. Words by PTC's rule over the whole configured
# census x target languages x the per-word credit rate. The rate and the balance are the only remote inputs: one GET
# balance (word_cost, balance_words), skipped when --rate and --balance are given (the guide's estimate task carries them).
cmd_estimate() {
    local fmt=text root="$PTC_PROJECT_DIR" cfg="" langs="" rate="" balance="" cases="" offline=false files=() excludes=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) fmt=json; shift ;;
            --offline) offline=true; shift ;;
            -d|--project-dir) root="$2"; shift 2 ;;
            -c|--config-file) cfg="$2"; shift 2 ;;
            --languages) langs="$2"; shift 2 ;;
            --rate) rate="$2"; shift 2 ;;
            --balance) balance="$2"; shift 2 ;;
            --api-url) PTC_API_URL="$2"; shift 2 ;;
            --file) files+=("$2"); shift 2 ;;
            --exclude) excludes+="$2"$'\n'; shift 2 ;;
            --check-cases) cases="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $SCRIPT_NAME estimate [--json] [--offline] [-d DIR] [-c CONFIG] [--languages de,fr] [--rate CREDITS_PER_WORD] [--balance WORDS] [--file PATH]... [--exclude PATH]..."
                echo "  --exclude PATH  leave a configured file out (repeatable); with --languages it quotes a narrowed scope."
                echo "  Quote: words by PTC's rule over the configured source files x languages x rate. PO/POT, YAML and JSON are"
                echo "  counted locally; every other configured file (PHP, .strings, .properties, XML, ...) is counted by PTC's"
                echo "  dry-run estimate (POST source_files/estimate, one call per file, nothing spent)."
                echo "  --offline  local readers only; the files they cannot count are listed as not counted."
                echo "  Without --rate/--balance it reads both from PTC in one call (GET balance; PTC_API_TOKEN or PTC_ORG_TOKEN)."
                echo "  --check-cases FILE  check the counter against a shared cases file (strings + PTC's counts)."
                return 0 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    if [[ -n "$cases" ]]; then _ptc_py word-count-cases "$cases"; return $?; fi
    export PTC_ESTIMATE_EXCLUDE="$excludes"
    if [[ -z "$cfg" && -f "$root/.ptc-config.yml" ]]; then cfg="$root/.ptc-config.yml"; fi
    _config_api_url_fallback "$cfg"
    if [[ -z "$rate" || -z "$balance" ]]; then
        local token="${PTC_API_TOKEN:-${PTC_ORG_TOKEN:-}}" body
        if [[ -z "$token" ]]; then
            log_error "ptc estimate needs the rate and the balance: pass --rate and --balance, or set PTC_API_TOKEN / PTC_ORG_TOKEN"
            return 1
        fi
        local hdr=() pid=""
        if [[ -n "$cfg" ]]; then
            pid=$(grep -E '^[[:space:]]+project_id:' "$cfg" 2>/dev/null | head -n1 | sed -E 's/.*project_id:[[:space:]]*//; s/[[:space:]]*$//') || true
        fi
        if [[ -n "${PTC_ORG_TOKEN:-}" && -z "${PTC_API_TOKEN:-}" && -n "$pid" ]]; then
            hdr=(-H "X-PTC-Project-Id: $pid")
        fi
        body=$(ptc_curl -sf -H "Authorization: Bearer $token" ${hdr[@]+"${hdr[@]}"} "${PTC_API_URL}balance" 2>/dev/null) || {
            log_error "ptc estimate: could not read the rate and balance from ${PTC_API_URL}balance"; return 1; }
        local vals
        vals=$(printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
b = d.get("balance_words")
if b is None and "balance_words" not in d:
    b = float(d.get("trial_balance") or 0) + float(d.get("prepaid_balance") or 0)
print(d.get("word_cost") if d.get("word_cost") is not None else "", "" if b is None else b)')
        if [[ -z "$rate" ]]; then rate="${vals%% *}"; fi
        if [[ -z "$balance" ]]; then balance="${vals#* }"; fi
    fi
    # S2-R3 item 3 (decision 5): the files no local reader counts go to PTC's dry-run estimate (ci18-7252, its own
    # rate-limit bucket), one call each; their source words per language are added to the quote.
    local remote="" token="${PTC_API_TOKEN:-${PTC_ORG_TOKEN:-}}"
    if [[ "$offline" != true ]]; then
        local uncounted
        uncounted=$(_ptc_py estimate "$root" unquoted "$cfg" "$langs" "$rate" "$balance" ${files[@]+"${files[@]}"} 2>/dev/null) || uncounted=""
        if [[ -n "$uncounted" && -z "$token" ]]; then
            log_warning "ptc estimate: set PTC_API_TOKEN or PTC_ORG_TOKEN to have PTC count the files no local reader covers"
        elif [[ -n "$uncounted" ]]; then
            local pid="" ehdr=() path code hdrs try body_file
            [[ -n "$cfg" ]] && pid=$(grep -E '^[[:space:]]+project_id:' "$cfg" 2>/dev/null | head -n1 | sed -E 's/.*project_id:[[:space:]]*//; s/[[:space:]]*$//') || true
            [[ -n "${PTC_ORG_TOKEN:-}" && -z "${PTC_API_TOKEN:-}" && -n "$pid" ]] && ehdr=(-H "X-PTC-Project-Id: $pid")
            remote=$(mktemp); hdrs=$(mktemp); body_file=$(mktemp)
            while IFS= read -r path; do
                [[ -z "$path" || ! -f "$root/$path" ]] && continue
                for try in 1 2 3; do
                    code=$(ptc_curl -s -o "$body_file" -D "$hdrs" -w '%{http_code}' -X POST -H "Authorization: Bearer $token" \
                        ${ehdr[@]+"${ehdr[@]}"} -F "file=@$root/$path" -F "file_path=$path" "${PTC_API_URL}source_files/estimate" 2>/dev/null) || code=000
                    [[ "$code" != 429 ]] && break
                    local wait_s
                    wait_s=$(grep -i '^retry-after:' "$hdrs" | tr -dc '0-9'); wait_s=${wait_s:-5}; (( wait_s > 60 )) && wait_s=60
                    sleep "$wait_s"
                done
                if [[ "$code" == 200 ]]; then
                    printf '%s\t%s\n' "$path" "$(tr -d '\n' < "$body_file")" >> "$remote"
                else
                    log_warning "ptc estimate: PTC's dry-run estimate for $path answered HTTP $code; it is listed as not counted"
                fi
            done <<< "$uncounted"
            rm -f "$hdrs" "$body_file"
        fi
    fi
    PTC_REMOTE_ESTIMATE="$remote" _ptc_py estimate "$root" "$fmt" "$cfg" "$langs" "$rate" "$balance" ${files[@]+"${files[@]}"}
    local rc=$?
    [[ -n "$remote" ]] && rm -f "$remote"
    return $rc
}

cmd_audit() {
    local sub="${1:-}"; shift || true
    if [[ "$sub" != "strings" ]]; then
        echo "Usage: $SCRIPT_NAME audit strings [--json] [--runtime] [-d DIR]"
        echo "  i18n readiness audit: user-visible text outside the i18n calls, concatenated fragments, plurals and"
        echo "  locale formats outside the i18n API (WordPress/PHP, JS/React, Rails recipes by the census framework)."
        echo "  --runtime adds the runtime loading audit (script handle / text domain vs catalogue names, stale .mo/.json)."
        echo "  Exit 0 (findings or not), 2 no recognised framework, 1 error."
        [[ "$sub" == "-h" || "$sub" == "--help" ]] && return 0
        return 1
    fi
    local fmt=text root="$PTC_PROJECT_DIR" runtime=0
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) fmt=json; shift ;;
            --runtime) runtime=1; shift ;;
            -d|--project-dir) root="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    [[ -d "$root" ]] || { log_error "Project directory not found: $root"; return 1; }
    _ptc_py audit-strings "$root" "$fmt" "$runtime"
}

cmd_describe() {
    local sub="${1:-}"; shift || true
    local file="" dry=0 fmt=text root="$PTC_PROJECT_DIR" into=0
    if [[ "$sub" != "apply" ]]; then
        echo "Usage: $SCRIPT_NAME describe apply --file descriptions.json [--dry-run] [--into-template] [--json] [-d DIR]"
        echo "  Writes PTC-authored string descriptions where PTC reads them back: gettext = a 'translators:' source"
        echo "  comment at the call site (usage path:line; template regeneration extracts it into '#.'); with"
        echo "  --into-template, '#.' lines in the .po/.pot instead. Chrome-i18n JSON: the 'description' sibling."
        echo "  Exit 0 all written/present, 2 some skipped, 1 error."
        [[ "$sub" == "-h" || "$sub" == "--help" ]] && return 0
        return 1
    fi
    while [[ $# -gt 0 ]]; do
        case $1 in
            --file) file="$2"; shift 2 ;;
            --dry-run) dry=1; shift ;;
            --into-template) into=1; shift ;;
            --json) fmt=json; shift ;;
            -d|--project-dir) root="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    [[ -z "$file" ]] && { log_error "describe apply needs --file (PTC's descriptions JSON)"; return 1; }
    [[ -f "$file" ]] || { log_error "No such file: $file"; return 1; }
    _ptc_py describe-apply "$root" "$file" "$dry" "$fmt" "$into"
}

cmd_config() {
    local sub="${1:-}"; shift || true
    if [[ "$sub" != "validate" ]]; then
        echo "Usage: $SCRIPT_NAME config validate [-c .ptc-config.yml] [-d DIR] [--json]"
        [[ "$sub" == "-h" || "$sub" == "--help" ]] && return 0
        return 1
    fi
    local root="$PTC_PROJECT_DIR" cfg="" fmt=text
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) fmt=json; shift ;;
            -d|--project-dir) root="$2"; shift 2 ;;
            -c|--config-file) cfg="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    [[ -z "$cfg" ]] && cfg="$root/.ptc-config.yml"
    if [[ ! -f "$cfg" ]]; then
        log_error "Config file not found: $cfg"
        return 2
    fi
    # The v1 structural checks the translate pipeline applies, verbatim.
    if ! parse_config_file "$cfg" 2>/dev/null; then
        if [[ "$fmt" == "text" ]]; then parse_config_file "$cfg" || true; fi
    fi
    _ptc_py config "$root" "$cfg" "$fmt"
}

# --- guide transport ------------------------------------------------------------
_guide_session_file() { printf '%s/%s/session.json' "$PTC_PROJECT_DIR" "$PTC_GUIDE_DIR"; }

_guide_session_id() {
    if [[ -n "${PTC_GUIDE_SESSION_ID:-}" ]]; then
        printf '%s' "$PTC_GUIDE_SESSION_ID"; return 0
    fi
    local f; f=$(_guide_session_file)
    # L13 (SF-37): the config's `guide:` block is the one source of truth (ptc sync delivers to its project); the cache in
    # .ptc/session.json is used only when it names the same project, or when the config has no block.
    local cfg_sid cfg_pid cfgf="${cfg:-$PTC_PROJECT_DIR/.ptc-config.yml}"
    cfg_sid=$(ptc_config_guide_field "$cfgf" session_id); cfg_pid=$(ptc_config_project_id "$cfgf")
    if [[ -f "$f" ]] && { [[ -z "$cfg_sid" || -z "$cfg_pid" ]] || [[ "$(_ptc_py field "$f" project_id 2>/dev/null)" == "$cfg_pid" ]]; }; then
        _ptc_py field "$f" session_id; return 0
    fi
    if [[ -n "$cfg_sid" ]]; then
        printf '%s' "$cfg_sid"; return 0
    fi
    # B4: no local cache (e.g. the session was opened over MCP) -> ask PTC for the repository's open session.
    local origin q
    origin=$(git -C "$PTC_PROJECT_DIR" remote get-url origin 2>/dev/null || true)
    [[ -z "$origin" ]] && return 0
    q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$origin")
    _guide_call GET "guide/sessions?repo_url=${q}" 2>/dev/null || return 0
    mkdir -p "$PTC_PROJECT_DIR/$PTC_GUIDE_DIR"
    [[ -f "$PTC_PROJECT_DIR/$PTC_GUIDE_DIR/.gitignore" ]] || echo '*' > "$PTC_PROJECT_DIR/$PTC_GUIDE_DIR/.gitignore"
    python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));json.dump({"session_id":d.get("session_id"),"project_id":str(d.get("project_id"))},open(sys.argv[2],"w"));print(d.get("session_id"))' \
        "$GUIDE_RESPONSE" "$f"
}

# guide next on a suite session: its answer lists the products; walk them in order and show the first
# product task (its session is remembered for submit). Plain sessions render as before.
_guide_next_walk() {
    local sid="$1" fmt="$2" f psid pstate pdir tagged
    f=$(_guide_session_file)
    mkdir -p "$(dirname "$f")"
    _ptc_py sess task "$f" "$GUIDE_RESPONSE" "$sid" 2>/dev/null || true
    local products; products=$(_ptc_py sess products "$f" "$GUIDE_RESPONSE" 2>/dev/null)
    if [[ -z "$products" ]]; then
        _ptc_py render next "$GUIDE_RESPONSE" "$fmt" "$VERSION"; return $?
    fi
    while read -r psid pstate pdir; do
        [[ "$pstate" == "done" ]] && continue
        _guide_call GET "guide/next?session_id=${psid}" || return 1
        _ptc_py sess task "$f" "$GUIDE_RESPONSE" "$psid" 2>/dev/null || true
        tagged=$(mktemp)
        PDIR="$pdir" PSID="$psid" python3 -c 'import json,os,sys;d=json.load(open(sys.argv[1]));d["product_dir"]=os.environ["PDIR"];d["session_id"]=int(os.environ["PSID"]) if os.environ["PSID"].isdigit() else os.environ["PSID"];json.dump(d,open(sys.argv[2],"w"))' "$GUIDE_RESPONSE" "$tagged"
        if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d.get("task") or d.get("waiting") else 1)' "$tagged"; then
            _ptc_py render next "$tagged" "$fmt" "$VERSION"; return $?
        fi
        # L11 (SF-31): this product's answer is not rendered, but a push it carried (told once) is printed.
        [[ "$fmt" == "text" ]] && _ptc_py pushes "$tagged"
    done <<< "$products"
    _ptc_py render next "$GUIDE_RESPONSE" "$fmt" "$VERSION"
}

# Repo-root-relative paths changed by HEAD since its merge base with the default branch (none printed when
# no base ref is available, e.g. a depth-1 checkout).
_guide_changed_files() {
    local ref base
    # safe.directory: CI containers often run as root over a checkout owned by another uid.
    local g=(git -c safe.directory='*' -C "$PTC_PROJECT_DIR")
    for ref in origin/HEAD origin/main origin/master origin/staging origin/develop; do
        "${g[@]}" rev-parse --verify -q "$ref" >/dev/null || continue
        base=$("${g[@]}" merge-base "$ref" HEAD 2>/dev/null) || continue
        "${g[@]}" diff --name-only "$base" HEAD
        printf '%s\n' "--base $ref"
        return 0
    done
    return 1
}

# S2-F2 C-2: the guide transport retries a transport failure like the translate path does (S2-R12): a 5xx, no answer (000)
# or a 429 that carries Retry-After is retried PTC_TRANSIENT_MAX_RETRIES times with backoff (Retry-After honoured, capped at
# 300 s; else PTC_TRANSIENT_BASE_DELAY doubling), then the caller is told "Could not reach PTC" with the last HTTP code. A 4xx
# (and a 429 without Retry-After) is final at once. AGD-8: the delivery-commit report IS the delivery proof, so one 503
# behind a tunnel must not lose it.
# _guide_transient_code CODE [HEADER_FILE] -> 0 when the answer is worth a retry
_guide_transient_code() {
    local code="${1:-}" header_file="${2:-}"
    is_transient_http_code "$code" && return 0
    [[ "$code" == "429" && -n "$header_file" && -f "$header_file" ]] && grep -qi '^retry-after:' "$header_file"
}

# _guide_retry_delay ATTEMPT [HEADER_FILE] -> seconds before retry ATTEMPT
_guide_retry_delay() {
    local attempt="$1" header_file="${2:-}" ra=""
    if [[ -n "$header_file" && -f "$header_file" ]]; then
        ra=$(grep -i '^retry-after:' "$header_file" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -E 's/^[^:]*:[[:space:]]*//')
    fi
    if [[ "$ra" =~ ^[0-9]+$ ]] && (( ra > 0 )); then
        (( ra > 300 )) && ra=300
        printf '%s' "$ra"
        return 0
    fi
    printf '%s' $(( PTC_TRANSIENT_BASE_DELAY * (1 << (attempt - 1)) ))
}

# _guide_request WHAT CURL_ARGS... -> runs ptc_curl (the args print the HTTP code: -w '%{http_code}'), retrying a transient
# answer; sets GUIDE_HTTP_CODE; returns 0 on 2xx, 1 otherwise (the caller reports a final non-2xx). GUIDE_RETRIES overrides
# the retry count (guide wait keeps its own in-budget loop and passes 0).
_guide_request() {
    local what="$1"; shift
    local attempt=1 code hdr delay retries="${GUIDE_RETRIES:-$PTC_TRANSIENT_MAX_RETRIES}"
    hdr=$(ptc_mktemp)
    GUIDE_HTTP_CODE=000
    while :; do
        code=$(ptc_curl "$@" -D "$hdr") || code=000
        [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
        GUIDE_HTTP_CODE="$code"
        if ! _guide_transient_code "$code" "$hdr"; then
            rm -f "$hdr"
            [[ "$code" == 2* ]] && return 0
            return 1
        fi
        if (( attempt > retries )); then
            rm -f "$hdr"
            (( retries > 0 )) && log_error "Could not reach PTC for $what: the last answer was HTTP $code after $retries retries (no PTC answer; this is not a rejection)."
            return 1
        fi
        delay=$(_guide_retry_delay "$attempt" "$hdr")
        log_warning "No PTC answer for $what (HTTP $code). Waiting ${delay}s, then retry $attempt of $retries."
        ptc_sleep "$delay"
        attempt=$((attempt + 1))
    done
}

# _guide_call METHOD PATH [BODY_FILE] -> response body in $GUIDE_RESPONSE, returns 0 on 2xx
_guide_call() {
    local method="$1" path="$2" body_file="${3:-}"
    local token="${PTC_ORG_TOKEN:-}"
    if [[ -z "$token" ]]; then
        log_error "PTC_ORG_TOKEN is not set (copy your agent token from PTC's agent token page, /dashboard/agent-tokens)."
        return 1
    fi
    GUIDE_RESPONSE=$(ptc_mktemp)
    local url="${PTC_API_URL%/}/${path}" code
    local args=(-sS -o "$GUIDE_RESPONSE" -w '%{http_code}' -X "$method"
                -H "Authorization: Bearer $token" -H "Accept: application/json")
    [[ -n "$body_file" ]] && args+=(-H "Content-Type: application/json" --data-binary "@$body_file")
    # GUIDE_MAX_TIME bounds one request (guide wait long-polls); GUIDE_HTTP_CODE tells a retrying caller why it failed.
    [[ -n "${GUIDE_MAX_TIME:-}" ]] && args+=(--max-time "$GUIDE_MAX_TIME")
    PTC_GUIDE_PROJECT_ID="" _guide_request "$method /$path" "${args[@]}" "$url" && return 0
    code="$GUIDE_HTTP_CODE"
    # S2-F2 C-2: a transient answer was retried and _guide_request said "Could not reach PTC" (guide wait says it itself).
    _guide_transient_code "$code" && return 1
    log_error "PTC answered HTTP $code for $method /$path: $(head -c 500 "$GUIDE_RESPONSE")"
    [[ "$code" == "404" ]] && log_error "(404: the agent guide is not enabled for this organization, or the session does not exist.)"
    return 1
}

# "20m" / "90s" / "1h" / "600" -> seconds (empty on nonsense)
_guide_seconds() {
    local v="$1"
    case "$v" in
        *h) v="${v%h}"; [[ "$v" =~ ^[0-9]+$ ]] && echo $((v * 3600)) ;;
        *m) v="${v%m}"; [[ "$v" =~ ^[0-9]+$ ]] && echo $((v * 60)) ;;
        *s) v="${v%s}"; [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" ;;
        *)  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" ;;
    esac
    return 0
}

# guide wait: long-poll POST /guide/wait {session_id, task_id, timeout_s} until PTC answers with a verdict
# (status != "waiting") or the overall timeout passes. One request never asks for more than the server cap
# (PTC_GUIDE_WAIT_CAP, default 25 s = Guide::Engine::WAIT_CAP_S, below the gateway's 60 s budget: S2-R30-2, SF-16);
# network errors and 5xx/429 are retried inside the budget, a 4xx is final.
_guide_wait() {
    local sid="$1" task_id="$2" timeout fmt="$4" body per remaining deadline cap="${PTC_GUIDE_WAIT_CAP:-25}" last=""
    timeout=$(_guide_seconds "$3")
    [[ -z "$timeout" ]] && { log_error "--timeout must be seconds or a duration like 20m (got '$3')"; return 1; }
    deadline=$((SECONDS + timeout))
    body=$(ptc_mktemp)
    while :; do
        remaining=$((deadline - SECONDS))
        (( remaining <= 0 )) && break
        per=$(( remaining < cap ? remaining : cap ))
        SID="$sid" TID="$task_id" PER="$per" python3 -c 'import json,os
d={"task_id":os.environ["TID"],"timeout_s":int(os.environ["PER"])}
if os.environ["SID"]: d["session_id"]=os.environ["SID"]
print(json.dumps(d))' > "$body"
        if ! GUIDE_RETRIES=0 GUIDE_MAX_TIME=$((per + 30)) _guide_call POST guide/wait "$body" 2>"$body.err"; then
            case "$GUIDE_HTTP_CODE" in
                000|429|5*)
                    [[ "$fmt" == "text" ]] && log_warning "guide wait: transient failure (HTTP $GUIDE_HTTP_CODE); retrying"
                    remaining=$((deadline - SECONDS)); local pause="${PTC_GUIDE_WAIT_RETRY_S:-5}"; if (( remaining > 0 )); then ptc_sleep $(( remaining < pause ? remaining : pause )); fi
                    continue ;;
                *) cat "$body.err" >&2; return 1 ;;
            esac
        fi
        last="$GUIDE_RESPONSE"
        if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d.get("status")=="waiting" or not d.get("verdict") else 1)' "$last" 2>/dev/null; then
            [[ "$fmt" == "text" ]] && log_info "Still waiting for PTC's verdict on $task_id ($((timeout - deadline + SECONDS))s of ${timeout}s)"
            _ptc_py pushes "$last" >&2 || true  # L11 (SF-31): a push told on a still-waiting answer is printed, not lost
            continue
        fi
        _ptc_py sess task "$(_guide_session_file)" "$last" "$sid" 2>/dev/null || true
        # Eran 2026-10-05 background wait: an agent reads this output later, so it names the task it waited on.
        [[ "$fmt" == "text" ]] && echo "PTC's verdict on task $task_id:"
        _ptc_py render wait "$last" "$fmt" "$VERSION"; return $?
    done
    if [[ "$fmt" == "json" ]]; then
        if [[ -n "$last" ]]; then cat "$last"; else printf '{"status":"waiting","task_id":"%s","waited_s":%s}\n' "$task_id" "$timeout"; fi
    else
        echo "Still waiting after ${timeout}s: PTC has no verdict for $task_id yet. Run 'guide wait $task_id' again."
    fi
    return 3
}

# guide check (G8): POST /guide/check {session_id, commit_sha}. Exit 0 pass, 1 fail, 2 cannot evaluate. The session
# may be done (the check gates every later push), so a missing local cache asks PTC with include_done=1.
# Session order (P3D-4): --session-id / PTC_GUIDE_SESSION_ID, then guide.session_id of the project's config (-c, else
# <project-dir>/.ptc-config.yml: in a suite this is the PRODUCT's session, the one its action runs report to), then the
# local cache, then the repository's session by origin (a suite root: PTC checks every product).
_guide_check() {
    local sha="$1" fmt="$2" cfg="${3:-}" sid body code
    if [[ -z "${PTC_ORG_TOKEN:-}" ]]; then
        _guide_check_refusal "$fmt" "no_token" "PTC_ORG_TOKEN is not set (the organization agent token; in CI the PTC_API_TOKEN secret)"
        return 2
    fi
    [[ -z "$sha" ]] && sha="${CI_COMMIT_SHA:-${GITHUB_SHA:-}}"
    [[ -z "$sha" ]] && sha=$(git -C "$PTC_PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)
    sid="${PTC_GUIDE_SESSION_ID:-}"
    [[ -z "$cfg" && -f "$PTC_PROJECT_DIR/.ptc-config.yml" ]] && cfg="$PTC_PROJECT_DIR/.ptc-config.yml"
    [[ -z "$sid" && -n "$cfg" ]] && sid=$(ptc_config_guide_field "$cfg" session_id)
    [[ -z "$sid" && -f "$(_guide_session_file)" ]] && sid=$(_ptc_py field "$(_guide_session_file)" session_id 2>/dev/null)
    if [[ -z "$sid" ]]; then
        local origin q
        origin=$(git -C "$PTC_PROJECT_DIR" remote get-url origin 2>/dev/null || true)
        if [[ -n "$origin" ]]; then
            q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$origin")
            _guide_call GET "guide/sessions?repo_url=${q}&include_done=1" 2>/dev/null && \
                sid=$(_ptc_py field "$GUIDE_RESPONSE" session_id 2>/dev/null)
        fi
    fi
    # L4 (POL-116): no commit (a working tree without git, `ptc sync`): the run key PTC_GUIDE_RUN_KEY (fp:<fingerprint>) names the run
    local key=""
    [[ -z "$sha" ]] && key="${PTC_GUIDE_RUN_KEY:-}"
    if [[ -z "$sid" || ( -z "$sha" && -z "$key" ) ]]; then
        _guide_check_refusal "$fmt" "no_session" "no guide session or commit to check: pass --session-id and --commit, or run inside the repository"
        return 2
    fi
    body=$(ptc_mktemp)
    SID="$sid" SHA="$sha" KEY="$key" python3 -c 'import json,os;d={"session_id":os.environ["SID"]};d.update({"commit_sha":os.environ["SHA"]} if os.environ["SHA"] else {"run_key":os.environ["KEY"]});print(json.dumps(d))' > "$body"
    if ! _guide_call POST guide/check "$body" 2>"$body.err"; then
        code="$GUIDE_HTTP_CODE"
        if [[ -s "$GUIDE_RESPONSE" ]] && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if isinstance(d.get("error"),dict) else 1)' "$GUIDE_RESPONSE" 2>/dev/null; then
            if [[ "$fmt" == "json" ]]; then cat "$GUIDE_RESPONSE"; else
                python3 -c 'import json,sys;e=json.load(open(sys.argv[1]))["error"];print("guide check cannot evaluate (%s): %s" % (e.get("code"), e.get("message")))' "$GUIDE_RESPONSE"
            fi
        else
            _guide_check_refusal "$fmt" "ptc_unreachable" "PTC answered HTTP ${code:-000} for POST /guide/check"
        fi
        return 2
    fi
    if [[ "$fmt" == "json" ]]; then cat "$GUIDE_RESPONSE"; echo; else
        python3 - "$GUIDE_RESPONSE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("guide check: %s (round %s, %s reasons)" % (d.get("verdict"), d.get("round"), d.get("reasons_total", 0)))
for r in d.get("reasons") or []:
    print("  [%s] %s" % (r.get("code"), r.get("message")))
PY
    fi
    python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get("verdict")=="pass" else 1)' "$GUIDE_RESPONSE" && return 0
    return 1
}

# guide mr-description (P4 T5, R4; Eran 2026-09-29): the GitLab twin of the action's findings comment is the translations
# merge request's DESCRIPTION, set by the recipe's own push (`-o merge_request.description=...`); no API call, no second
# token. PTC composes the text (the check's `comment`: findings, carried-string notes, next action, guide page); when
# PTC's project setting turns the comment off, or PTC gave no answer, the description is a fixed neutral text. Prints ONE
# line on stdout, escaped for a push option: a value cannot hold a literal newline, and GitLab turns every `\n` into one
# (a plain gsub, no other unescaping), so a backslash-n already in the text gets a zero-width space after its backslash
# and newlines become `\n`. The CI-time limit note (PTC_LIMIT_NOTE_FILE, CI-16) leads the text when the run wrote one.
# Capped at PTC_MR_DESCRIPTION_MAX bytes. The findings also go to stderr, so every job log
# carries them, including runs that push nothing. Never fails: a missing or unreadable file gives the neutral text.
_guide_mr_description() {
    local json="$1"
    PTC_MR_BRANCH="${PTC_MR_BRANCH:-ptc/translations}" python3 - "$json" <<'PY' || echo "Translations delivered by PTC."
import json, os, sys
NEUTRAL = ("Translations delivered by PTC. PTC updates this merge request when a CI run changes a translation. "
           "The translations reach your base branch when this merge request is merged, by you or by auto-merge.")
branch = os.environ["PTC_MR_BRANCH"]
limit = int(os.environ.get("PTC_MR_DESCRIPTION_MAX") or 60000)
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
c = d.get("comment") or {}
body = c.get("body") or ""
if body:
    sys.stderr.write("PTC agent-guide findings for this commit:\n%s\n" % body)
elif d.get("error"):
    sys.stderr.write("PTC agent-guide check did not answer: %s\n" % (d["error"].get("message") or d["error"].get("code")))
if c.get("enabled") and body:
    text = body + ("\n\nAuto-merge: select \"Set to auto-merge\" on this merge request "
                   "(https://docs.gitlab.com/user/project/merge_requests/auto_merge/#auto-merge-a-merge-request).\n"
                   "Fetch the translations branch: `git fetch origin %s`" % branch)
else:
    if body:
        sys.stderr.write("PTC findings in the merge request description: off for this project (PTC project setting)\n")
    text = NEUTRAL
# S2-R3 (CI-16): the preflight's CI-time limit note (PTC_LIMIT_NOTE_FILE, written by the run when the balance cannot
# cover the census) leads the description, as the GitHub pull request body carries it; independent of the findings
# setting, since it is about this delivery, not about the guide.
try:
    note = open(os.environ["PTC_LIMIT_NOTE_FILE"]).read().strip() if os.environ.get("PTC_LIMIT_NOTE_FILE") else ""
except Exception:
    note = ""
if note:
    text = note + "\n\n" + text
esc = lambda s: s.replace("\r", "").replace("\\n", "\\\u200bn").replace("\n", "\\n")
out = esc(text)
if len(out.encode()) > limit:
    tail = esc("\n- ... (cut to fit the merge request; the full list is on the project's guide page)")
    room, t = limit - len(tail.encode()), text
    while len(esc(t).encode()) > room:
        t = t[: len(t) - max(1, (len(esc(t).encode()) - room) // 4)]
    out = esc(t) + tail
print(out)
PY
    return 0
}

_guide_check_refusal() {
    local fmt="$1" code="$2" message="$3"
    if [[ "$fmt" == "json" ]]; then
        CODE="$code" MSG="$message" python3 -c 'import json,os;print(json.dumps({"verdict":"error","error":{"code":os.environ["CODE"],"message":os.environ["MSG"]}}))'
    else
        echo "guide check cannot evaluate ($code): $message" >&2
    fi
}

show_guide_help() {
    cat <<HELP
Usage: $SCRIPT_NAME guide <command> [options]

  start  [--project-id ID] [--repo-url URL] [--branch B] open (or resume) the guide session; creates the project without --project-id
         [--organization-id ID]                           the organization to create it in, when your token acts in several
                                                          (PTC then lists them: ask the human which one)
  next                                                    the next task
  submit TASK_ID [--file evidence.json]                   submit evidence (stdin when no --file)
  skip   TASK_ID --reason TEXT                            skip a task (a human decision)
  status                                                  stage, readiness, task list
  upload-sources [TASK_ID] [-c CONFIG]                    API channel (L12): upload the source files PTC does not hold at
                                                          their current sha256 (the upload doors of sync, translate=false:
                                                          nothing is translated, no free delivery is used; a file held at
                                                          the same sha256 is skipped) and print what was uploaded. With
                                                          TASK_ID (source_upload) it then submits the task; without, it is
                                                          a rerun at any point of setup (e.g. after a source fix). In CI it
                                                          uploads nothing (the job uploads).
  wait   TASK_ID [--timeout 20m]                          block until PTC has a verdict for the task (e.g. the CI run
                                                          landed); prints it like submit. Run it as a background command
                                                          only when your harness wakes you on its end; otherwise run it in
                                                          the foreground and read its output.
  check  [--commit SHA]                                   CI gate (G8): PTC's verdict for this commit's ptc-action run against
                                                          the last accepted round. Never opens tasks. Exit 0 pass, 1 fail,
                                                          2 cannot evaluate (no session, no run for the commit, stale files,
                                                          PTC unreachable); every refusal prints PTC's code and message.
                                                          It reports missing information only and never withholds a delivery.
  delivery-commit --commit SHA [--branch B] [--source-commit SHA] [--out R.json]
  delivery-commit --workspace-fingerprint FP --written-manifest FILE   (ptc sync: no commit, no branch; the files written)
                                                          CI, after the pull-request step: report the translations-branch
                                                          commit and its delivered files' sha256, so PTC observes its
                                                          delivery on the branch (PTC_API_TOKEN); a trusted report is the
                                                          delivery proof (PTC closes it). --out keeps PTC's answer
                                                          (delivery_proof, the recomputed check). Never fails the caller.
  action-run [--project-id ID] [--file PATH]... [--out R.json]
                                                          report this checkout (scan, config, source files) to PTC; CI runs
                                                          it on every push, an agent before the workflow is committed (T9).
                                                          Prints the run_key the guide's tasks ask for. Every file a guide
                                                          task named (and each --file) rides with its sha256 and content
                                                          and counts in the workspace fingerprint (SF-22: proof without git)
  mr-description --file CHECK.json                        GitLab CI: print the translations merge request's description as
                                                          ONE push-option line (PTC's findings, or a neutral text when the
                                                          project setting is off); the findings also go to stderr (the job
                                                          log). The recipe pushes it with -o merge_request.description.
                                                          Never fails.

Options: --json (raw JSON), --session-id ID, --api-url URL, -d DIR
Auth: PTC_ORG_TOKEN (your agent token). The session id is cached in .ptc/session.json.
Exit codes: 0 accepted/next, 2 rejected, 3 needs_more (or: wait timed out, still waiting; next: PTC waits on a step it names), 4 CLI below PTC's
minimum version, 1 error.
HELP
}

# S2-R2 item 6: the config file's `api_url:` is honoured when neither --api-url nor PTC_API_URL changed the default
# (the same precedence the translate path applies).
_config_api_url_fallback() {
    local cfg="$1" url=""
    if [[ "$PTC_API_URL" != "https://app.ptc.wpml.org/api/v1/" || ! -f "$cfg" ]]; then
        return 0
    fi
    url=$(grep '^api_url:' "$cfg" 2>/dev/null | head -n1 | sed 's/^api_url: *//; s/ *$//; s/^["'"'"']//; s/["'"'"']$//') || true
    if [[ -n "$url" ]]; then
        case "$url" in */) PTC_API_URL="$url" ;; *) PTC_API_URL="$url/" ;; esac
        log_debug "Loaded api_url from config: $PTC_API_URL"
    fi
    return 0
}

# -> the sha256 of a file's bytes.
_ptc_file_sha() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# L12 (SF-33; Eran 2026-10-08, AGD-1, AGD-4): on the API channel the census source files reach PTC before the description
# task, through the doors `ptc sync` uses (register, then process with translate=false: stored, never translated, no free
# delivery used). With TASK_ID (the `source_upload` task): PTC's payload lists every census source path with the sha256
# of the upload PTC holds; a file held at the same sha256 is not sent again; then the task is submitted. Without TASK_ID
# (a rerun at any point of setup, e.g. after a source_fixes edit; lead ruling, POL-116 + AGD-4): every configured source
# file whose sha256 differs from what PTC was last known to hold (.ptc/uploads.tsv: PTC's payload and this CLI's own
# uploads) is uploaded the same way; nothing is submitted. PTC skips bytes it already holds either way. Prints what it
# uploaded (count, bytes); PTC's stored copy is the proof, never this list.
_guide_upload_sources() {
    local task_id="$1" fmt="$2" cfg="${3:-}" sid="" plan="" todo="" self rc=0 held=0 gone=""
    if _guide_in_ci; then
        echo "In CI the job uploads the source files; nothing uploaded here."
        return 0
    fi
    [[ -z "$cfg" ]] && cfg="$PTC_PROJECT_DIR/.ptc-config.yml"
    [[ -f "$cfg" ]] || { log_error "guide upload-sources needs the project's .ptc-config.yml (not found: $cfg)"; return 1; }
    cfg="$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")"
    local ledger="$PTC_PROJECT_DIR/$PTC_GUIDE_DIR/uploads.tsv"
    mkdir -p "$PTC_PROJECT_DIR/$PTC_GUIDE_DIR"
    [[ -f "$PTC_PROJECT_DIR/$PTC_GUIDE_DIR/.gitignore" ]] || echo '*' > "$PTC_PROJECT_DIR/$PTC_GUIDE_DIR/.gitignore"
    touch "$ledger"
    if [[ -n "$task_id" ]]; then
        [[ -z "${PTC_GUIDE_SESSION_ID:-}" ]] && sid=$(_ptc_py sess task-session "$(_guide_session_file)" "$task_id" 2>/dev/null)
        [[ -z "$sid" ]] && sid=$(_guide_session_id)
        [[ -z "$sid" ]] && { log_error "No guide session: run '$SCRIPT_NAME guide start --project-id ID' or pass --session-id."; return 1; }
        _guide_call GET "guide/next?session_id=${sid}" || return 1
        plan=$(ptc_mktemp)
        # -> "UP<TAB>path" to send, "HELD<TAB>path" held at this sha256, "GONE<TAB>path" not on disk; the ledger takes PTC's word.
        TID="$task_id" ROOT="$PTC_PROJECT_DIR" python3 - "$GUIDE_RESPONSE" "$ledger" > "$plan" <<'PY' || { log_error "PTC's answer does not list $task_id as the current task: run '$SCRIPT_NAME guide next' (or rerun without a task id)"; return 1; }
import hashlib, json, os, sys
task = (json.load(open(sys.argv[1])) or {}).get("task") or {}
if task.get("id") != os.environ["TID"]:
    sys.exit(1)
files = (task.get("payload") or {}).get("files") or []
ledger = dict(l.rstrip("\n").split("\t", 1) for l in open(sys.argv[2]) if "\t" in l)
for f in files:
    ledger.pop(f["path"], None)
    if f.get("held_sha256"):
        ledger[f["path"]] = f["held_sha256"]
with open(sys.argv[2], "w") as fh:
    fh.writelines(f"{p}\t{h}\n" for p, h in sorted(ledger.items()))
for f in files:
    path = os.path.join(os.environ["ROOT"], f["path"])
    if not os.path.isfile(path):
        print("GONE\t" + f["path"]); continue
    sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
    print(("HELD\t" if sha == (f.get("held_sha256") or "") else "UP\t") + f["path"])
PY
        todo=$(sed -n 's/^UP\t//p' "$plan")
        held=$(grep -c '^HELD' "$plan" || true); gone=$(sed -n 's/^GONE\t//p' "$plan")
        [[ -n "$gone" ]] && log_warning "Not on disk, not uploaded: $(echo "$gone" | tr '\n' ' ')"
    fi
    local log skipped; log=$(ptc_mktemp); skipped=$(ptc_mktemp); : > "$log"; : > "$skipped"
    if [[ -z "$task_id" || -n "$todo" ]]; then
        self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
        export PTC_API_TOKEN="${PTC_API_TOKEN:-${PTC_ORG_TOKEN:-}}"
        local only=(); [[ -n "$task_id" ]] && only=(PTC_UPLOAD_ONLY="$todo")
        ( cd "$PTC_PROJECT_DIR" && env ${only[@]+"${only[@]}"} PTC_UPLOAD_HELD="$ledger" PTC_UPLOAD_SKIPPED="$skipped" PTC_UPLOAD_LOG="$log" \
            PTC_GUIDE_PROJECT_ID="${PTC_GUIDE_PROJECT_ID:-$(_ptc_py field "$(_guide_session_file)" project_id 2>/dev/null)}" \
            bash "$self" --config-file "$cfg" --action upload --api-url "$PTC_API_URL" ) >&2 || rc=$?
    fi
    [[ -z "$task_id" ]] && held=$(wc -l < "$skipped" | tr -d ' ')
    # The ledger learns what this run stored.
    PTC_ROOT="$PTC_PROJECT_DIR" python3 - "$log" "$ledger" <<'PY' || true
import hashlib, os, sys
ledger = dict(l.rstrip("\n").split("\t", 1) for l in open(sys.argv[2]) if "\t" in l)
for line in open(sys.argv[1]):
    path = line.split("\t", 1)[0]
    if path:
        ledger[path] = hashlib.sha256(open(os.path.join(os.environ["PTC_ROOT"], path), "rb").read()).hexdigest()
with open(sys.argv[2], "w") as fh:
    fh.writelines(f"{p}\t{h}\n" for p, h in sorted(ledger.items()))
PY
    local count bytes; count=$(wc -l < "$log" | tr -d ' '); bytes=$(awk -F'\t' '{s+=$2} END {print s+0}' "$log")
    echo "Uploaded $count source file(s), $bytes bytes, to PTC (nothing translated); $held already held at the same sha256."
    sed 's/^/  /' "$log" | awk -F'\t' '{print $1" ("$2" bytes)"}'
    [[ $rc -ne 0 ]] && log_error "Some source files were not uploaded (see above); PTC names what it still lacks in its answer."
    if [[ -z "$task_id" ]]; then
        [[ $count -gt 0 ]] && echo "Run 'ptc guide action-run' again, then resubmit the task that asked for these bytes."
        return $rc
    fi
    local evidence; evidence=$(ptc_mktemp)
    printf '{"uploaded": %s, "bytes": %s}\n' "$count" "$bytes" > "$evidence"
    local body; body=$(ptc_mktemp)
    SID="$sid" TID="$task_id" python3 -c 'import json,os,sys;print(json.dumps({"session_id":os.environ["SID"],"task_id":os.environ["TID"],"evidence":json.load(open(sys.argv[1]))}))' "$evidence" > "$body"
    _guide_call POST "guide/submit" "$body" || return 1
    _ptc_py render submit "$GUIDE_RESPONSE" "$fmt" "$VERSION"
}

cmd_guide() {
    local sub="${1:-}"; shift || true
    if [[ "$sub" == "action-run" ]]; then
        cmd_guide_action_run "$@"; return $?
    fi
    if [[ "$sub" == "delivery-commit" ]]; then
        cmd_guide_delivery_commit "$@"; return $?
    fi
    local json=false task_id="" file="" reason="" project_id="" organization_id="" repo_url="" branch="" wait_timeout="20m" commit_sha="" cfg=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) json=true; shift ;;
            --file) file="$2"; shift 2 ;;
            --validate-file) shift 2 ;;  # S2-R14: an older recipe's validate file is ignored
            --reason) reason="$2"; shift 2 ;;
            --session-id) PTC_GUIDE_SESSION_ID="$2"; shift 2 ;;
            --project-id) project_id="$2"; shift 2 ;;
            --organization-id) organization_id="$2"; shift 2 ;;
            --repo-url) repo_url="$2"; shift 2 ;;
            --branch) branch="$2"; shift 2 ;;
            --timeout) wait_timeout="$2"; shift 2 ;;
            --commit) commit_sha="$2"; shift 2 ;;
            -c|--config-file) cfg="$2"; shift 2 ;;
            --api-url) PTC_API_URL="$2"; shift 2 ;;
            -d|--project-dir) PTC_PROJECT_DIR="$2"; shift 2 ;;
            -h|--help) show_guide_help; return 0 ;;
            -*) log_error "Unknown option: $1"; return 1 ;;
            *) task_id="$1"; shift ;;
        esac
    done
    _config_api_url_fallback "${cfg:-$PTC_PROJECT_DIR/.ptc-config.yml}"
    local fmt=text; [[ "$json" == "true" ]] && fmt=json
    # T18 (lab p4r): initialised, so `--session-id` (which skips the task-session lookup below) never reads an unset
    # variable under `set -u`.
    local body sid=""
    body=$(ptc_mktemp)
    case "$sub" in
        start)
            [[ -z "$repo_url" ]] && repo_url=$(git -C "$PTC_PROJECT_DIR" remote get-url origin 2>/dev/null || true)
            [[ -z "$branch" ]] && branch=$(git -C "$PTC_PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
            # L13 (SF-37, AGD-1 "Rejoin silently"): one source of truth, the config's `guide:` block (.ptc-config.yml, which
            # `ptc sync` reads too); .ptc/session.json is only its cache, read when the config has no block yet. PTC
            # rejoins the session it names (no question, no new project); --project-id naming another project is refused.
            local cfg_file="${cfg:-$PTC_PROJECT_DIR/.ptc-config.yml}" known_sid known_pid
            known_sid=$(ptc_config_guide_field "$cfg_file" session_id); known_pid=$(ptc_config_project_id "$cfg_file")
            if [[ -z "$known_sid" && -f "$(_guide_session_file)" ]]; then
                known_sid=$(_ptc_py field "$(_guide_session_file)" session_id 2>/dev/null || true)
                known_pid=$(_ptc_py field "$(_guide_session_file)" project_id 2>/dev/null || true)
            fi
            if [[ -n "$project_id" && -n "$known_pid" && "$project_id" != "$known_pid" ]]; then
                log_error "This directory's config names PTC project $known_pid (guide.project_id in $cfg_file), and ptc sync delivers to it; --project-id $project_id would split the guide and the sync across two projects. Drop --project-id, or remove the config's guide: block first."
                return 1
            fi
            if [[ -z "$project_id" ]]; then
                # No project yet: create it in the organization. The CI secret is the organization agent token (ruling b).
                local pbody; pbody=$(ptc_mktemp)
                NAME="$(basename "$(git -C "$PTC_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$PTC_PROJECT_DIR" && pwd))")" URL="$repo_url" BR="$branch" \
                    ORG="$organization_id" SID="$known_sid" PID="$known_pid" python3 -c 'import json,os;d={"name":os.environ["NAME"],"repo_url":os.environ["URL"],"default_branch":os.environ["BR"]};o=os.environ["ORG"];d.update({"organization_id":int(o) if o.isdigit() else o} if o else {});n=lambda v:int(v) if v.isdigit() else v;d.update({"session_id":n(os.environ["SID"])} if os.environ["SID"] else {});d.update({"project_id":n(os.environ["PID"])} if os.environ["PID"] else {});print(json.dumps(d))' > "$pbody"
                _guide_call POST projects "$pbody" || return 1
                # SF-18 (L8): a token acting in several organizations gets PTC's "which organization" answer (no project_id);
                # it is printed as a list with the --organization-id remedy, never a traceback.
                project_id=$(_ptc_py project-answer "$GUIDE_RESPONSE") || return 1
            fi
            _ptc_py body "$(PID="$project_id" URL="$repo_url" BR="$branch" python3 -c 'import json,os;print(json.dumps({"project_id":int(os.environ["PID"]) if os.environ["PID"].isdigit() else os.environ["PID"],"repo_url":os.environ["URL"],"branch":os.environ["BR"]}))')" > "$body"
            _guide_call POST guide/sessions "$body" || return 1
            mkdir -p "$PTC_PROJECT_DIR/$PTC_GUIDE_DIR"
            # The session cache and scan output are local working files, never part of the customer's commit.
            [[ -f "$PTC_PROJECT_DIR/$PTC_GUIDE_DIR/.gitignore" ]] || echo '*' > "$PTC_PROJECT_DIR/$PTC_GUIDE_DIR/.gitignore"
            python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));json.dump({"session_id":d.get("session_id"),"project_id":sys.argv[2]},open(sys.argv[3],"w"))' \
                "$GUIDE_RESPONSE" "$project_id" "$(_guide_session_file)"
            _ptc_py render start "$GUIDE_RESPONSE" "$fmt" "$VERSION"; return $?
            ;;
        next|status)
            sid=$(_guide_session_id)
            [[ -z "$sid" ]] && { log_error "No guide session: run '$SCRIPT_NAME guide start --project-id ID' or pass --session-id."; return 1; }
            _guide_call GET "guide/${sub}?session_id=${sid}" || return 1
            if [[ "$sub" == "next" ]]; then
                _guide_next_walk "$sid" "$fmt"; return $?
            fi
            _ptc_py render "$sub" "$GUIDE_RESPONSE" "$fmt" "$VERSION"; return $?
            ;;
        submit|skip)
            [[ -z "$task_id" ]] && { log_error "guide $sub needs a TASK_ID"; return 1; }
            # A suite has one session per product: the task goes to the session that handed it out.
            [[ -z "${PTC_GUIDE_SESSION_ID:-}" ]] && sid=$(_ptc_py sess task-session "$(_guide_session_file)" "$task_id" 2>/dev/null)
            [[ -z "$sid" ]] && sid=$(_guide_session_id)
            [[ -z "$sid" ]] && { log_error "No guide session: run '$SCRIPT_NAME guide start --project-id ID' or pass --session-id."; return 1; }
            local evidence
            evidence=$(ptc_mktemp)
            if [[ "$sub" == "submit" ]]; then
                if [[ -n "$file" ]]; then cat "$file" > "$evidence" || return 1; else cat > "$evidence"; fi
            else
                [[ -z "$reason" ]] && { log_error "guide skip needs --reason"; return 1; }
            fi
            SID="$sid" TID="$task_id" REASON="$reason" KIND="$sub" python3 - "$evidence" > "$body" <<'PY' || { log_error "The evidence is not valid JSON"; return 1; }
import json, os, sys
d = {"session_id": os.environ["SID"], "task_id": os.environ["TID"]}
if os.environ["KIND"] == "submit":
    d["evidence"] = json.load(open(sys.argv[1]))
else:
    d["reason"] = os.environ["REASON"]
print(json.dumps(d))
PY
            _guide_call POST "guide/${sub}" "$body" || return 1
            _ptc_py sess task "$(_guide_session_file)" "$GUIDE_RESPONSE" "$sid" 2>/dev/null || true
            _ptc_py render "$sub" "$GUIDE_RESPONSE" "$fmt" "$VERSION"; return $?
            ;;
        wait)
            [[ -z "$task_id" ]] && { log_error "guide wait needs a TASK_ID"; return 1; }
            [[ -z "${PTC_GUIDE_SESSION_ID:-}" ]] && sid=$(_ptc_py sess task-session "$(_guide_session_file)" "$task_id" 2>/dev/null)
            [[ -z "$sid" ]] && sid=$(_guide_session_id)
            _guide_wait "$sid" "$task_id" "$wait_timeout" "$fmt"; return $?
            ;;
        check)
            _guide_check "$commit_sha" "$fmt" "$cfg"; return $?
            ;;
        upload-sources)
            _guide_upload_sources "$task_id" "$fmt" "$cfg"; return $?
            ;;
        mr-description)
            _guide_mr_description "$file"; return $?
            ;;
        ""|-h|--help|help) show_guide_help; return 0 ;;
        *) log_error "Unknown guide command: $sub"; show_guide_help; return 1 ;;
    esac
}

# Posted by ptc-action on every run (PTC_API_TOKEN: the organization agent token): the scan, the parsed config,
# the commit, and a sample of the source files (<= PTC_FILES_SAMPLE_LIMIT bytes, plus every source file the commit changed: S2-R21-2).
# Never fails the caller's translation: the action ignores its exit code.
# The CI platform's identity token for PTC (audience "ptc"): the run's provenance proof (P1). Printed on stdout,
# empty when this CI offers none - PTC then records the run as unverified provenance.
#   explicit / lab : PTC_CI_ID_TOKEN (the lab CI hook mints it, HS256)
#   GitLab         : PTC_ID_TOKEN    (job keyword  id_tokens: { PTC_ID_TOKEN: { aud: ptc } })
#   GitHub Actions : requested from ACTIONS_ID_TOKEN_REQUEST_URL (workflow needs  permissions: id-token: write)
# L3-1 (POL-116): this run is a CI run when CI says so: an identity token (the variables _guide_ci_id_token reads), or the
# commit / CI markers GitHub Actions and GitLab set (the ones the action-run already reads for the commit). Anything else is
# the agent's own machine: the run asks for provenance agent_local.
_guide_in_ci() {
    [[ -n "${PTC_CI_ID_TOKEN:-}${PTC_ID_TOKEN:-}${ACTIONS_ID_TOKEN_REQUEST_URL:-}${GITHUB_ACTIONS:-}${GITLAB_CI:-}${GITHUB_SHA:-}${CI_COMMIT_SHA:-}" ]]
}

_guide_ci_id_token() {
    if [[ -n "${PTC_CI_ID_TOKEN:-}" ]]; then printf '%s' "$PTC_CI_ID_TOKEN"; return 0; fi
    if [[ -n "${PTC_ID_TOKEN:-}" ]]; then printf '%s' "$PTC_ID_TOKEN"; return 0; fi
    if [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
        local resp sep="?"
        [[ "$ACTIONS_ID_TOKEN_REQUEST_URL" == *\?* ]] && sep="&"
        resp=$(PTC_GUIDE_PROJECT_ID="" ptc_curl -sS --max-time 30 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "${ACTIONS_ID_TOKEN_REQUEST_URL}${sep}audience=${PTC_ID_TOKEN_AUDIENCE:-ptc}" 2>/dev/null) || return 0
        printf '%s' "$resp" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("value") or "", end="")
except Exception:
    pass' 2>/dev/null || true
    fi
    return 0
}

cmd_guide_action_run_impl() {
    local cfg="$1" project_id="${2:-}" out="${3:-}"
    # P4 T9: an agent reports its working tree with the agent token it already has (PTC_ORG_TOKEN), before CI.
    local token="${PTC_API_TOKEN:-${PTC_ORG_TOKEN:-}}"
    [[ -z "$token" ]] && { log_error "PTC_API_TOKEN (CI) or PTC_ORG_TOKEN (agent) is not set"; return 1; }
    local scan cfgjson body sha branch
    scan=$(ptc_mktemp); cfgjson=$(ptc_mktemp); body=$(ptc_mktemp)
    local scan_args=(--json -d "$PTC_PROJECT_DIR")
    [[ -n "$cfg" && -f "$cfg" ]] && scan_args+=(-c "$cfg")
    cmd_scan "${scan_args[@]}" > "$scan" || return 1
    GUIDE_RUN_FINGERPRINT=$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("repo") or {}).get("workspace_fingerprint") or "")' "$scan" 2>/dev/null || true)
    # E2: an agent token needs the project named on the call. S2-R3B C-1: without a config and without --project-id
    # this used to exit silently (errexit on the assignment); now it says what is missing and how to give it.
    local pid_from_cfg=""
    [[ -n "$cfg" ]] && pid_from_cfg=$(ptc_config_project_id "$cfg") || true
    [[ -z "${PTC_GUIDE_PROJECT_ID:-}" ]] && PTC_GUIDE_PROJECT_ID="${project_id:-$pid_from_cfg}" || true
    if [[ -z "${PTC_GUIDE_PROJECT_ID:-}" ]]; then
        log_warning "No PTC project named: an agent token needs --project-id N, or -c/--config-file with a .ptc-config.yml carrying guide.project_id ('ptc guide start' writes it). A legacy project token needs neither."
    fi
    if [[ -n "$cfg" && -f "$cfg" ]]; then
        _ptc_py config "$PTC_PROJECT_DIR" "$cfg" json > "$cfgjson" || true
    else
        echo '{"config":null}' > "$cfgjson"
    fi
    sha="${GITHUB_SHA:-${CI_COMMIT_SHA:-$(git -C "$PTC_PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)}}"
    branch="${GITHUB_REF_NAME:-${CI_COMMIT_REF_NAME:-$(git -C "$PTC_PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}}"
    # D13: the paths this commit changed against the default branch (merge base), for PTC's scope check.
    local changed; changed=$(ptc_mktemp)
    _guide_changed_files > "$changed" 2>/dev/null || : > "$changed"
    # The identity token travels by environment, never argv (it is a bearer credential for its lifetime).
    local id_token agent_local=0; id_token=$(_guide_ci_id_token)
    if ! _guide_in_ci; then
        # L3-1 (POL-116): the agent's own machine. PTC records the run agent_local on an API session (setup_mode api),
        # unverified elsewhere; its content (fingerprint, files_sha of the bytes on disk) is what PTC proves things on.
        agent_local=1
        log_info "Not in CI: reporting this working tree as an agent-local run (workspace fingerprint + file digests)."
    elif [[ -z "$id_token" ]]; then
        log_warning "No CI identity token: PTC records this run as unverified provenance. GitHub: add 'permissions: id-token: write' to the workflow; GitLab: add 'id_tokens: { PTC_ID_TOKEN: { aud: ptc } }' to the job."
    fi
    # SF-22 (L8): the files guide tasks named (.ptc/session.json, recorded by guide next/submit) and each --file.
    local named; named="${PTC_ACTION_RUN_FILES:-}$(_ptc_py sess named-files "$(_guide_session_file)" 2>/dev/null || true)"
    PTC_NAMED_FILES="$named" PTC_AGENT_LOCAL="$agent_local" PTC_CI_ID_TOKEN_VALUE="$id_token" _ptc_py action-body "$scan" "$cfgjson" "$project_id" "$sha" "$branch" "$PTC_PROJECT_DIR" "${PTC_FILES_SAMPLE_LIMIT:-204800}" "$changed" > "$body" || return 1
    # SF-22 (L8): the fingerprint the run carries (the named files included) is the key `ptc sync` reports and checks by.
    GUIDE_RUN_FINGERPRINT=$(_ptc_py field "$body" workspace_fingerprint 2>/dev/null || true)
    local resp code
    resp=$(ptc_mktemp)
    # S2-F2 C-2: a 5xx / no answer / 429 with Retry-After is retried; when it gives up the step prints the last HTTP code.
    _guide_request "guide/action_runs" -sS -o "$resp" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        --data-binary "@$body" "${PTC_API_URL%/}/guide/action_runs" || true  # S2-R3B C-1: a final non-2xx is reported below, not an errexit
    code="$GUIDE_HTTP_CODE"
    if [[ "$code" == 2* ]]; then
        local prov; prov=$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("provenance") or "", end="")
except Exception:
    pass' "$resp" 2>/dev/null || true)
        log_info "Reported this run to PTC (guide action run${prov:+, provenance: $prov})."
        # SF-23 (L8): the run key the guide's tasks ask for ({run_key}); `ptc guide action-run` prints it (sync keeps its stdout).
        GUIDE_RUN_KEY=$(_ptc_py field "$resp" run_key 2>/dev/null || true)
        [[ -n "$out" ]] && cp "$resp" "$out"
        _ptc_py pushes "$resp" >&2 || true  # L11 (SF-31): e.g. the subscribe push of a refused push
        return 0
    fi
    if _guide_transient_code "$code"; then
        log_warning "Could not reach PTC to report this run (HTTP $code after ${PTC_TRANSIENT_MAX_RETRIES} retries): the run is not reported."
    elif [[ -z "${PTC_GUIDE_PROJECT_ID:-}" && "$code" == 4* ]]; then
        # S2-R3B C-1: the likeliest cause is named, with the remedy, instead of a bare HTTP code.
        log_error "PTC answered HTTP $code for guide/action_runs: the run is not reported. No project was named: pass --project-id N or a .ptc-config.yml with guide.project_id (-c FILE)."
    else
        log_warning "PTC answered HTTP $code for guide/action_runs: the run is not reported (the guide may be off for this organization)."
    fi
    return 1
}

cmd_guide_action_run() {
    local cfg="" project_id="" out=""
    PTC_ACTION_RUN_FILES=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --out) out="$2"; shift 2 ;;
            --file) PTC_ACTION_RUN_FILES+="$2"$'\n'; shift 2 ;;
            -c|--config-file) cfg="$2"; shift 2 ;;
            --project-id) project_id="$2"; shift 2 ;;
            --api-url) PTC_API_URL="$2"; shift 2 ;;
            -d|--project-dir) PTC_PROJECT_DIR="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    [[ -z "$cfg" && -f "$PTC_PROJECT_DIR/.ptc-config.yml" ]] && cfg="$PTC_PROJECT_DIR/.ptc-config.yml"
    GUIDE_RUN_KEY=""
    cmd_guide_action_run_impl "$cfg" "$project_id" "$out" || return $?
    [[ -n "$GUIDE_RUN_KEY" ]] && printf 'run_key: %s\n' "$GUIDE_RUN_KEY"
    return 0
}

# P4 T14 (R3): posted by ptc-action / the GitLab recipe after the pull-request step. PTC matches the reported files with
# its own hand-overs; only then is its delivery "on the translations branch". Never fails the caller's job.
cmd_guide_delivery_commit() {
    local cfg="" project_id="" commit="" branch="" source="" out="" stopped="" fingerprint="" written=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            # L3-2 (POL-116): `ptc sync`'s branch-less report (no --commit, no --branch).
            --workspace-fingerprint) fingerprint="$2"; shift 2 ;;
            --written-manifest) written="$2"; shift 2 ;;
            # S2-R14: `ptc validate` is gone; an older workflow's --validate / --validate-file is accepted and ignored so
            # the report (the delivery proof) is still sent.
            --validate) shift ;;
            --validate-file) shift 2 ;;
            --out) out="$2"; shift 2 ;;
            # S2-R3B F-2 (CI-16): the run stopped at its monitor bound while PTC was still translating; reported with the
            # commit it did make, or alone (no --commit) when nothing finished inside the bound.
            --stopped-reason) stopped="$2"; shift 2 ;;
            --commit) commit="$2"; shift 2 ;;
            --branch) branch="$2"; shift 2 ;;
            --source-commit) source="$2"; shift 2 ;;
            -c|--config-file) cfg="$2"; shift 2 ;;
            --project-id) project_id="$2"; shift 2 ;;
            --api-url) PTC_API_URL="$2"; shift 2 ;;
            -d|--project-dir) PTC_PROJECT_DIR="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    local token="${PTC_API_TOKEN:-}"
    [[ -z "$token" ]] && { log_error "PTC_API_TOKEN is not set"; return 1; }
    if [[ -n "$stopped" && "$stopped" != "monitor_bound" ]]; then
        log_error "--stopped-reason takes monitor_bound (got '$stopped')"; return 1
    fi
    [[ -z "$commit" && -z "$stopped" && -z "$fingerprint" ]] && { log_error "guide delivery-commit needs --commit SHA (the translations-branch commit), or --workspace-fingerprint FP (a report without a commit)"; return 1; }
    [[ -z "$cfg" && -f "$PTC_PROJECT_DIR/.ptc-config.yml" ]] && cfg="$PTC_PROJECT_DIR/.ptc-config.yml"
    [[ -z "$source" ]] && source="${GITHUB_SHA:-${CI_COMMIT_SHA:-}}"
    local cfgjson body resp code
    cfgjson=$(ptc_mktemp); body=$(ptc_mktemp); resp=$(ptc_mktemp)
    if [[ -n "$cfg" && -f "$cfg" ]]; then
        _ptc_py config "$PTC_PROJECT_DIR" "$cfg" json > "$cfgjson" || echo '{"config":null}' > "$cfgjson"
    else
        echo '{"config":null}' > "$cfgjson"
    fi
    local id_token agent_local=0; id_token=$(_guide_ci_id_token)
    _guide_in_ci || agent_local=1
    PTC_DC_FINGERPRINT="$fingerprint" PTC_DC_WRITTEN="$written" PTC_AGENT_LOCAL="$agent_local" PTC_CI_ID_TOKEN_VALUE="$id_token" _ptc_py delivery-body "$cfgjson" "$project_id" "$commit" "$branch" "$source" "$PTC_PROJECT_DIR" "$stopped" > "$body" || return 1
    # S2-F2 C-2 (AGD-8: this report is the delivery proof): a 5xx / no answer / 429 with Retry-After is retried; when it
    # gives up the step prints the last HTTP code.
    _guide_request "guide/delivery_commits" -sS -o "$resp" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        --data-binary "@$body" "${PTC_API_URL%/}/guide/delivery_commits" || true  # S2-R3B C-1: a final non-2xx is reported below, not an errexit
    code="$GUIDE_HTTP_CODE"
    if [[ "$code" == 2* ]]; then
        [[ -n "$out" ]] && cp "$resp" "$out"
        # L11 (SF-31): the report that confirmed a delivery carries the switch-to-CI suggestion (told once) and the
        # subscribe push; printed in full.
        _ptc_py pushes "$resp" >&2 || true
        [[ -n "$stopped" ]] && log_info "Reported to PTC: this run stopped at its monitor bound while PTC was still translating; the delivery arrives from a later run (retry the job once PTC finishes)."
        if [[ -z "$commit" && -n "$fingerprint" ]]; then
            python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print("Reported the %s files this run wrote to PTC (no branch, workspace %s): %s of them are PTC deliveries." % (d.get("reported"), sys.argv[2][:12], d.get("matched")))
except Exception:
    pass' "$resp" "$fingerprint" >&2 || true
            return 0
        fi
        [[ -z "$commit" ]] && return 0
        python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print("Reported the translations-branch commit %s to PTC: %s of %s delivered files are PTC deliveries." % (sys.argv[2][:12], d.get("matched"), d.get("reported")))
    p=d.get("delivery_proof") or {}
    if p.get("effect"):
        print("delivery proof: %s%s" % (p["effect"], (" - " + p["why"]) if p.get("why") else ""))
except Exception:
    pass' "$resp" "$commit" >&2 || true
        return 0
    fi
    if _guide_transient_code "$code"; then
        log_warning "Could not reach PTC to report the translations-branch commit (HTTP $code after ${PTC_TRANSIENT_MAX_RETRIES} retries): the delivery is not reported; PTC will not count it until a later run reports it."
    else
        log_warning "PTC answered HTTP $code for guide/delivery_commits: the translations-branch commit is not reported (the guide may be off for this organization)."
    fi
    return 1
}

# L3-2 (POL-116, API-33): `ptc sync` = the CI job (the GitLab recipe / ptc-action), run on the agent's machine:
#   1. guide action-run (the working tree's content: fingerprint, files_sha, agent_local outside CI);
#   2. guide check --json, as the job runs it (it reports missing information; it never withholds the translation);
#   3. the full translate workflow (upload -> process -> monitor/download) writing the configured outputs;
#   4. guide delivery-commit with NO branch and no commit: the workspace fingerprint + the sha256 of exactly the files step 3
#      wrote. --dry-run reports the run and the plan (step 3 dry) and moves no bytes (no step 4).
# Exit codes and final lines are the job's: 0 delivered, 5 rejected / unreachable files, 6 parked, 7 still translating
# at the monitor bound, any other non-zero the translate run's own. --json prints the summary on stdout (logs on stderr).
show_sync_help() {
    cat <<HELP
Usage: $SCRIPT_NAME sync [--project-id ID] [-d DIR] [-c CONFIG] [--dry-run] [--json] [--api-url URL]

The CI job, run locally: report the run (guide action-run), PTC's check, translate (writes the configured outputs),
then report the written files to PTC (guide delivery-commit, no branch). Token: PTC_API_TOKEN or PTC_ORG_TOKEN.
  --project-id ID   the PTC project (default: guide.project_id of the config)
  -d DIR            the product directory (suite products); the config is DIR/.ptc-config.yml unless -c names one
  --dry-run         report the run and the plan; upload, download and the delivery report are skipped
  --json            print {run_id, uploaded, delivered, parked, rejected, delivery_commit} on stdout
Exit codes: 0 all delivered, 5 PTC rejected or could not be reached for some files, 6 some files wait in PTC (parked:
over-limit approval or out of credit), 7 still translating at the monitor bound; the rest was delivered in each case.
HELP
}

cmd_sync() {
    local cfg="" project_id="" dry=false json=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --project-id) project_id="$2"; shift 2 ;;
            -d|--project-dir) PTC_PROJECT_DIR="$2"; shift 2 ;;
            -c|--config-file) cfg="$2"; shift 2 ;;
            --api-url) PTC_API_URL="$2"; shift 2 ;;
            -n|--dry-run) dry=true; shift ;;
            --json) json=true; shift ;;
            -h|--help) show_sync_help; return 0 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done
    PTC_PROJECT_DIR=$(cd "$PTC_PROJECT_DIR" 2>/dev/null && pwd) || { log_error "ptc sync: no such directory"; return 1; }
    [[ -z "$cfg" ]] && cfg="$PTC_PROJECT_DIR/.ptc-config.yml"
    [[ -f "$cfg" ]] || { log_error "ptc sync needs the project's .ptc-config.yml (not found: $cfg); 'ptc init' writes one"; return 1; }
    cfg="$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")"
    export PTC_API_TOKEN="${PTC_API_TOKEN:-${PTC_ORG_TOKEN:-}}"
    [[ -z "$PTC_API_TOKEN" ]] && { log_error "PTC_API_TOKEN or PTC_ORG_TOKEN is not set"; return 1; }
    _config_api_url_fallback "$cfg"
    [[ -n "$project_id" ]] && export PTC_PROJECT_ID="$project_id" PTC_GUIDE_PROJECT_ID="$project_id"
    local runresp check manifest summary dcresp
    runresp=$(ptc_mktemp); check=$(ptc_mktemp); manifest=$(ptc_mktemp); summary=$(ptc_mktemp); dcresp=$(ptc_mktemp)
    : > "$summary"; : > "$dcresp"

    # 1. the run (never fails the sync, as in the job)
    GUIDE_RUN_FINGERPRINT=""
    cmd_guide_action_run_impl "$cfg" "$project_id" "$runresp" || true
    local fingerprint="$GUIDE_RUN_FINGERPRINT"
    # 2. the check, exactly as the job runs it; its findings go to the log
    #    L4 (POL-116): without git the check names the run by its key (fp:<workspace fingerprint>)
    ( PTC_GUIDE_RUN_KEY="${fingerprint:+fp:$fingerprint}" PTC_ORG_TOKEN="${PTC_ORG_TOKEN:-$PTC_API_TOKEN}" cmd_guide check --json --config-file "$cfg" --api-url "$PTC_API_URL" -d "$PTC_PROJECT_DIR" > "$check" ) 2>&1 | cat >&2 || true
    _guide_mr_description "$check" >/dev/null || true
    # 3. translate: the same CLI, the job's arguments, run in the project directory
    local self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" rc=0
    local args=(--config-file "$cfg" --written-manifest "$manifest" --api-url "$PTC_API_URL")
    [[ "$dry" == "true" ]] && args+=(--dry-run)
    ( cd "$PTC_PROJECT_DIR" && PTC_RUN_SUMMARY="$summary" bash "$self" "${args[@]}" ) >&2 || rc=$?
    # 4. the branch-less delivery report (only for a real run that got as far as delivering)
    local source=""
    source=$(git -C "$PTC_PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)
    [[ "$source" =~ ^[0-9a-f]{40}$ ]] || source=""
    local reported=false
    if [[ "$dry" != "true" ]] && [[ $rc -eq 0 || $rc -eq 5 || $rc -eq 6 || $rc -eq 7 ]]; then
        local dc_args=(-c "$cfg" --api-url "$PTC_API_URL" -d "$PTC_PROJECT_DIR" --out "$dcresp")
        [[ -n "$project_id" ]] && dc_args+=(--project-id "$project_id")
        [[ -n "$source" ]] && dc_args+=(--source-commit "$source")
        [[ $rc -eq 7 ]] && dc_args+=(--stopped-reason monitor_bound)
        if [[ -s "$manifest" && -n "$fingerprint" ]]; then
            cmd_guide_delivery_commit "${dc_args[@]}" --workspace-fingerprint "$fingerprint" --written-manifest "$manifest" && reported=true
        elif [[ $rc -eq 7 ]]; then
            cmd_guide_delivery_commit "${dc_args[@]}" && reported=true
        fi
    fi
    # The job's final lines (stdout; stderr under --json so stdout stays one JSON document).
    local line=""
    case $rc in
        5) line="PTC rejected some files or could not be reached for them (see 'Rejected by PTC' / 'Could not reach PTC' above); the rest was delivered." ;;
        6) line="Some files wait in PTC - parked for an over-limit approval, or paused out-of-credit (see the lists above); the rest was delivered. Approve in PTC or top up the credit, then re-run." ;;
        7) line="The translation is still running in PTC (see 'Still translating in PTC' above); the finished files were delivered. Retry this job once PTC finishes, or check progress / download manually with the commands printed there." ;;
    esac
    if [[ -n "$line" ]]; then
        if [[ "$json" == "true" ]]; then echo "$line" >&2; else echo "$line"; fi
    fi
    if [[ "$json" == "true" ]]; then
        DRY="$dry" REPORTED="$reported" python3 - "$runresp" "$summary" "$manifest" "$dcresp" <<'PY' || true
import json, os, sys
def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return None
run, summ, dc = load(sys.argv[1]) or {}, load(sys.argv[2]) or {}, load(sys.argv[4])
written = [e for e in open(sys.argv[3], "rb").read().split(b"\0") if e]
out = {"run_id": run.get("run_id"), "uploaded": summ.get("uploaded", 0), "delivered": len(written),
       "parked": summ.get("parked", 0), "rejected": summ.get("rejected", 0),
       "delivery_commit": dc if os.environ["REPORTED"] == "true" else None}
if os.environ["DRY"] == "true":
    out.update(dry_run=True, planned=out["uploaded"], uploaded=0)
print(json.dumps(out, sort_keys=True))
PY
    fi
    return $rc
}

main() {
    # `init` is a subcommand, not a flag: it scaffolds a config and must run
    # before the translate-pipeline validation (which requires a source locale
    # and patterns/config that do not exist yet), so it short-circuits here.
    if [[ "${1:-}" == "init" ]]; then
        shift
        cmd_init "$@"
        exit $?
    fi
    # Agent-guide commands: no source locale / patterns needed.
    case "${1:-}" in
        guide)  shift; cmd_guide "$@";  exit $? ;;
        scan)   shift; cmd_scan "$@";   exit $? ;;
        config) shift; cmd_config "$@"; exit $? ;;
        describe) shift; cmd_describe "$@"; exit $? ;;
        lint)     shift; cmd_lint "$@";     exit $? ;;
        estimate) shift; cmd_estimate "$@"; exit $? ;;
        audit)    shift; cmd_audit "$@";    exit $? ;;
        glossary) shift; cmd_glossary "$@"; exit $? ;;
        sync)     shift; cmd_sync "$@";     exit $? ;;
    esac

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
            --written-manifest)
                PTC_WRITTEN_MANIFEST="$2"
                ensure_written_manifest
                shift 2
                ;;
            --written-manifest=*)
                PTC_WRITTEN_MANIFEST="${1#*=}"
                ensure_written_manifest
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
                PTC_MONITOR_MAX_ATTEMPTS_SET=true
                shift 2
                ;;
            --monitor-max-attempts=*)
                PTC_MONITOR_MAX_ATTEMPTS="${1#*=}"
                PTC_MONITOR_MAX_ATTEMPTS_SET=true
                shift
                ;;
            --monitor-max-minutes)
                PTC_MONITOR_MAX_MINUTES="$2"
                PTC_MONITOR_MAX_MINUTES_SET=true
                shift 2
                ;;
            --monitor-max-minutes=*)
                PTC_MONITOR_MAX_MINUTES="${1#*=}"
                PTC_MONITOR_MAX_MINUTES_SET=true
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

    local rc=0
    process_files || rc=$?
    if [[ $rc -ne 0 ]]; then
        # 5 = partial: only PTC-rejected files are missing; the completed translations were written (E20).
        if [[ $rc -eq 5 ]]; then
            log_error "Some files were rejected by PTC or could not reach it (listed above); the completed translations were written"
            exit 5
        fi
        # 6 = partial (S2-R15, CI-16): some files wait for an over-limit approval; the completed translations were written.
        if [[ $rc -eq 6 ]]; then
            log_error "Some files wait for an over-limit approval in PTC; the completed translations were written"
            exit 6
        fi
        # 7 = stopped (S2-R3B F-2, CI-16): the translation is still running in PTC at the monitor bound; the completed
        # translations were written and the options (retry the job, check progress, download manually) are printed above.
        if [[ $rc -eq 7 ]]; then
            log_error "The translation is still running in PTC; the run stopped at its monitor bound and the completed translations were written (options above)"
            exit 7
        fi
        log_error "Error processing files"
        exit 1
    fi
    
    log_success "Processing completed successfully"
}

# Check if script is run directly, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
