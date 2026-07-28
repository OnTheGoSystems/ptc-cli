#!/bin/bash

# Tests for `ptc init` — the detect_config scaffolder.
#
# These source ptc-cli.sh and stub curl, so they exercise the real detection,
# YAML rendering and .ptcignore/CI logic without touching the network. They
# cover the three contract branches from ci18-7268: a detected layout written to
# .ptc-config.yml, a kind:"any" commented template, and the 422 rejection path.

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI_UNDER_TEST="$(dirname "$TEST_DIR")/ptc-cli.sh"

# shellcheck disable=SC1090
source "$CLI_UNDER_TEST"   # main() is guarded by a BASH_SOURCE check

set +e   # let individual assertions fail without aborting the run

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
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc (missing '$needle')"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$desc (unexpectedly found '$needle')"
    else
        pass "$desc"
    fi
}

# --- curl stub -------------------------------------------------------------
# detect_config answers with body immediately followed by the 3-digit status
# code, exactly as `curl -w "%{http_code}"` produces and the real code splits
# with ${response: -3} / ${response%???}.
MOCK_DETECT_CODE="200"
MOCK_DETECT_BODY=""
# curl runs inside $( ), so what it saw is recorded to files to survive the
# subshell (same reason the status suite counts calls through a file).
MOCK_URL_FILE=""
MOCK_ARGS_FILE=""

curl() {
    [[ -n "$MOCK_ARGS_FILE" ]] && printf '%s\n' "$@" >> "$MOCK_ARGS_FILE"
    local url=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -X|-H|-w|-o|-F|-d|-D) shift 2 ;;
            -s|-i|-L|-fsSL) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    [[ -n "$MOCK_URL_FILE" ]] && printf '%s' "$url" > "$MOCK_URL_FILE"
    case "$url" in
        *detect_config*) printf '%s%s' "$MOCK_DETECT_BODY" "$MOCK_DETECT_CODE" ;;
        *) printf '%s' '000' ;;
    esac
}

# Realistic wire fixtures (compact JSON, as Rails renders it).
RAILS_BODY='{"kind":"rails","source_locale":"en","files":[{"file":"config/locales/en.yml","output":"config/locales/{{lang}}.yml"}],"available_locales":["fr","de"]}'
WORDPRESS_BODY='{"kind":"wordpress","source_locale":"en","files":[{"file":"languages/plugin.pot","output":"languages/plugin-{{lang}}.po","additional_translation_files":[{"type":"mo","path":"languages/plugin-{{lang}}.mo"},{"type":"json","path":"languages/plugin-{{lang}}-wp.json"}]}],"available_locales":["fr"]}'
ANY_BODY='{"kind":"any","source_locale":"en","files":[]}'

# --- JSON array reader -----------------------------------------------------
test_json_array_elements() {
    echo "--- _json_array_elements"

    local out
    out=$(_json_array_elements "$RAILS_BODY" "files")
    assert_eq "files[] yields one object" \
        "$out" '{"file":"config/locales/en.yml","output":"config/locales/{{lang}}.yml"}'

    out=$(_json_array_elements "$RAILS_BODY" "available_locales")
    assert_eq "available_locales yields two lines" "$(_count_lines "$out")" "2"

    out=$(_json_array_elements "$WORDPRESS_BODY" "files")
    assert_contains "nested object survives as one element" "$out" '"additional_translation_files"'
    assert_eq "nested array does not split the parent object" "$(_count_lines "$out")" "1"

    out=$(_json_array_elements "$ANY_BODY" "files")
    assert_eq "empty array yields nothing" "$out" ""

    out=$(_json_array_elements "$RAILS_BODY" "nonexistent")
    assert_eq "absent key yields nothing" "$out" ""
}

# --- payload building & escaping -------------------------------------------
test_build_payload() {
    echo "--- build_detect_payload / _json_escape"

    local out
    out=$(printf 'Gemfile\nconfig/locales/en.yml\n' | build_detect_payload)
    assert_eq "paths become a file_paths array" \
        "$out" '{"file_paths":["Gemfile","config/locales/en.yml"]}'

    out=$(printf 'a"b.json\n' | build_detect_payload)
    assert_eq "double quotes in a path are escaped" \
        "$out" '{"file_paths":["a\"b.json"]}'

    out=$(printf '' | build_detect_payload)
    assert_eq "empty input yields an empty array" "$out" '{"file_paths":[]}'
}

# --- YAML rendering: detected layouts --------------------------------------
test_render_detected() {
    echo "--- render_ptc_config (detected)"

    local out
    out=$(render_ptc_config "$RAILS_BODY")
    assert_contains "rails: source_locale" "$out" "source_locale: en"
    assert_contains "rails: file mapping" "$out" "  - file: config/locales/en.yml"
    assert_contains "rails: output template" "$out" "    output: config/locales/{{lang}}.yml"
    assert_contains "rails: detected kind comment" "$out" "Detected project kind: rails"
    assert_not_contains "rails: no commented files block" "$out" "# files:"

    out=$(render_ptc_config "$WORDPRESS_BODY")
    assert_contains "wp: additional_translation_files header" "$out" "    additional_translation_files:"
    assert_contains "wp: mo entry type" "$out" "      - type: mo"
    assert_contains "wp: mo entry path" "$out" "        path: languages/plugin-{{lang}}.mo"
    assert_contains "wp: json entry type" "$out" "      - type: json"
}

# --- YAML rendering: template fallback (never hard-fail) -------------------
test_render_template() {
    echo "--- render_ptc_config (kind:any / empty)"

    local out
    out=$(render_ptc_config "$ANY_BODY")
    assert_contains "any: could-not-detect notice" "$out" "could not auto-detect"
    assert_contains "any: reports kind" "$out" "(kind: any)"
    assert_contains "any: commented files block" "$out" "# files:"
    assert_contains "any: still sets source_locale" "$out" "source_locale: en"

    # A recognised kind with an empty files[] also falls back to the template.
    out=$(render_ptc_config '{"kind":"rails","source_locale":"fr","files":[]}')
    assert_contains "empty files[]: template with kept locale" "$out" "source_locale: fr"
    assert_contains "empty files[]: commented block" "$out" "# files:"
}

# --- .ptcignore filtering --------------------------------------------------
test_ptcignore() {
    echo "--- filter_ptcignore / _path_matches_ignore"

    local dir out
    dir=$(mktemp -d)
    printf 'node_modules/\n*.log\nvendor\nbuild/output.txt\n# a comment\n\n' > "$dir/.ptcignore"
    out=$(printf '%s\n' \
        "src/en.json" \
        "node_modules/pkg/index.js" \
        "app.log" \
        "logs/app.log" \
        "vendor/autoload.php" \
        "build/output.txt" \
        "build/keep.txt" | filter_ptcignore "$dir")
    assert_eq "only unignored paths remain" "$out" "$(printf '%s\n%s' 'src/en.json' 'build/keep.txt')"
    rm -rf "$dir"

    # No .ptcignore -> pass-through.
    dir=$(mktemp -d)
    out=$(printf 'a.json\nb.json\n' | filter_ptcignore "$dir")
    assert_eq "no .ptcignore is a pass-through" "$out" "$(printf 'a.json\nb.json')"
    rm -rf "$dir"

    # Only-comments .ptcignore must not trip set -u (empty patterns array).
    dir=$(mktemp -d)
    printf '# just a comment\n\n' > "$dir/.ptcignore"
    out=$(printf 'a.json\n' | filter_ptcignore "$dir")
    assert_eq "comment-only .ptcignore is a pass-through" "$out" "a.json"
    rm -rf "$dir"
}

# --- CI provider detection -------------------------------------------------
test_ci_provider() {
    echo "--- detect_ci_provider"

    local dir
    dir=$(mktemp -d); mkdir -p "$dir/.github"
    assert_eq "GitHub via .github/ dir" "$(detect_ci_provider "$dir")" "github"
    rm -rf "$dir"

    dir=$(mktemp -d); touch "$dir/.gitlab-ci.yml"
    assert_eq "GitLab via .gitlab-ci.yml" "$(detect_ci_provider "$dir")" "gitlab"
    rm -rf "$dir"

    dir=$(mktemp -d)
    assert_eq "unknown when no markers" "$(detect_ci_provider "$dir")" "unknown"
    rm -rf "$dir"
}

# --- HTTP status handling in call_detect_config / cmd_init -----------------
test_call_detect_config() {
    echo "--- call_detect_config split"

    PTC_API_TOKEN="test-token"
    PTC_API_URL="https://example.invalid/api/v1/"

    MOCK_DETECT_BODY="$RAILS_BODY"; MOCK_DETECT_CODE="200"
    local response
    response=$(call_detect_config '{"file_paths":["Gemfile"]}')
    assert_eq "http_code is the trailing 3 chars" "${response: -3}" "200"
    assert_eq "body is everything before the code" "${response%???}" "$RAILS_BODY"
}

# --- End-to-end cmd_init ---------------------------------------------------
test_cmd_init_writes_config() {
    echo "--- cmd_init writes config (200)"

    PTC_API_TOKEN="test-token"
    MOCK_DETECT_BODY="$RAILS_BODY"; MOCK_DETECT_CODE="200"

    local dir
    dir=$(mktemp -d)
    printf '{}' > "$dir/en.yml"   # a file so the scan is non-empty

    cmd_init --project-dir "$dir" --api-token test-token --yes >/dev/null 2>&1 </dev/null
    local rc=$?
    assert_eq "cmd_init succeeds" "$rc" "0"

    if [[ -f "$dir/.ptc-config.yml" ]]; then
        pass "cmd_init created .ptc-config.yml"
        local written
        written=$(cat "$dir/.ptc-config.yml")
        assert_contains "written config has the mapping" "$written" "  - file: config/locales/en.yml"
    else
        fail "cmd_init created .ptc-config.yml"
    fi
    rm -rf "$dir"
}

test_cmd_init_refuses_overwrite() {
    echo "--- cmd_init refuses to clobber without --force"

    PTC_API_TOKEN="test-token"
    MOCK_DETECT_BODY="$RAILS_BODY"; MOCK_DETECT_CODE="200"

    local dir
    dir=$(mktemp -d)
    printf 'PRE-EXISTING\n' > "$dir/.ptc-config.yml"
    printf '{}' > "$dir/en.yml"

    cmd_init --project-dir "$dir" --api-token test-token --yes >/dev/null 2>&1 </dev/null
    local rc=$?
    assert_eq "returns non-zero on existing config" "$rc" "1"
    assert_eq "leaves the existing file untouched" "$(cat "$dir/.ptc-config.yml")" "PRE-EXISTING"

    # With --force it overwrites.
    cmd_init --project-dir "$dir" --api-token test-token --yes --force >/dev/null 2>&1 </dev/null
    rc=$?
    assert_eq "--force succeeds" "$rc" "0"
    assert_not_contains "--force replaced the content" "$(cat "$dir/.ptc-config.yml")" "PRE-EXISTING"
    rm -rf "$dir"
}

test_cmd_init_422() {
    echo "--- cmd_init 422 path"

    PTC_API_TOKEN="test-token"
    MOCK_DETECT_BODY='{"success":false,"code":422}'; MOCK_DETECT_CODE="422"

    local dir
    dir=$(mktemp -d)
    printf '{}' > "$dir/en.yml"

    cmd_init --project-dir "$dir" --api-token test-token --yes >/dev/null 2>&1 </dev/null
    local rc=$?
    assert_eq "422 returns non-zero" "$rc" "1"
    if [[ -f "$dir/.ptc-config.yml" ]]; then
        fail "422 must not write a config"
    else
        pass "422 must not write a config"
    fi
    rm -rf "$dir"
}

test_cmd_init_404_gate() {
    echo "--- cmd_init 404 gating path"

    PTC_API_TOKEN="test-token"
    MOCK_DETECT_BODY='not found'; MOCK_DETECT_CODE="404"

    local dir out
    dir=$(mktemp -d)
    printf '{}' > "$dir/en.yml"

    out=$(cmd_init --project-dir "$dir" --api-token test-token --yes 2>&1 </dev/null)
    local rc=$?
    assert_eq "404 returns non-zero" "$rc" "1"
    assert_contains "404 explains the QA gating" "$out" "not available on this server"
    rm -rf "$dir"
}

test_cmd_init_no_token() {
    echo "--- cmd_init works without a token (ci18-7276)"

    local saved="$PTC_API_TOKEN"
    MOCK_DETECT_BODY="$RAILS_BODY"; MOCK_DETECT_CODE="200"
    PTC_API_TOKEN=""   # no --api-token and no inherited env token

    local dir args
    dir=$(mktemp -d)
    printf '{}' > "$dir/en.yml"
    args=$(mktemp)
    MOCK_ARGS_FILE="$args" cmd_init --project-dir "$dir" --yes >/dev/null 2>&1 </dev/null
    local rc=$?
    assert_eq "detect_config is anonymous, so init succeeds with no token" "$rc" "0"
    assert_eq "the config is written" "$([[ -f "$dir/.ptc-config.yml" ]] && echo yes)" "yes"
    # detect_config must not carry an empty Bearer credential.
    if grep -q "Authorization: Bearer *$" "$args" 2>/dev/null; then
        fail "no empty Authorization header is sent without a token"
    else
        pass "no empty Authorization header is sent without a token"
    fi

    MOCK_ARGS_FILE=""
    rm -rf "$dir" "$args"
    PTC_API_TOKEN="$saved"
}

# F1: an inherited PTC_API_TOKEN (env-first) is used when no --api-token is given.
test_cmd_init_env_token() {
    echo "--- cmd_init uses the ambient PTC_API_TOKEN"

    local saved="$PTC_API_TOKEN"
    MOCK_DETECT_BODY="$RAILS_BODY"; MOCK_DETECT_CODE="200"
    PTC_API_TOKEN="env-token"   # as if inherited from the environment

    local dir
    dir=$(mktemp -d)
    printf '{}' > "$dir/en.yml"
    cmd_init --project-dir "$dir" --yes >/dev/null 2>&1 </dev/null
    local rc=$?
    assert_eq "succeeds using the inherited env token" "$rc" "0"
    rm -rf "$dir"
    PTC_API_TOKEN="$saved"
}

# F1 (regression): the startup line must NOT wipe an inherited PTC_API_TOKEN,
# or the translate pipeline authenticates with an empty Bearer token. Sourced in
# a fresh shell so the real startup sequence runs with the env var set.
test_env_token_survives_startup() {
    echo "--- inherited PTC_API_TOKEN survives startup (translate pipeline)"

    local got
    got=$(PTC_API_TOKEN="env-tok" bash -c "source '$CLI_UNDER_TEST' >/dev/null 2>&1; printf '%s' \"\$PTC_API_TOKEN\"")
    assert_eq "env token is retained after sourcing" "$got" "env-tok"
}

# ci18-7254: the GitHub snippet runs through ptc-action rather than a
# hand-rolled curl of the CLI. GitLab cannot - see render_ci_gitlab - so it
# gets the equivalent job inline. Guards against a regression back to a
# floating tag / old version / a GitLab job with no runner image, and against
# reintroducing a component address no customer instance can resolve.
test_ci_snippets_use_action() {
    echo "--- CI snippets: action on GitHub, inline job on GitLab"

    local gh gl block
    gh=$(render_ci_github)
    gl=$(render_ci_gitlab)
    block=$(print_ci_block "$(mktemp -d)")

    assert_contains "github uses the action" "$gh" "uses: OnTheGoSystems/ptc-action@v1"
    assert_contains "github checkout is v7" "$gh" "actions/checkout@v7"
    assert_contains "github passes the config file" "$gh" "config-file: .ptc-config.yml"
    assert_not_contains "github does not curl the raw CLI" "$gh" "raw.githubusercontent"
    assert_not_contains "github does not pin an old checkout" "$gh" "checkout@v4"

    # GitLab gets the job inline: a `component:` address resolves only against
    # the customer's own GitLab instance, so ours can never be reached from
    # gitlab.com or a self-hosted server. Inline keeps every guarantee the
    # component had - runner image, loop-safe rules, stable branch - and drops
    # the one thing that could not work.
    assert_not_contains "gitlab does not use an unreachable component" "$gl" "component:"
    assert_contains "gitlab pins the CLI to this version's tag" "$gl" "ptc-cli/v${VERSION}/ptc-cli.sh"
    assert_not_contains "gitlab does not float the CLI on main" "$gl" "ptc-cli/main/ptc-cli.sh"
    assert_contains "gitlab brings its own runner image" "$gl" "image: alpine:"
    assert_contains "gitlab installs bash for the CLI" "$gl" "apk add --no-cache bash"
    # [skip ci] is the only skip token GitLab actually honours - [skip
    # translations] is a GitHub-side convention and means nothing here.
    assert_contains "gitlab guards the loop with a real skip token" "$gl" '[skip ci]'
    assert_not_contains "gitlab does not rely on a token GitLab ignores" "$gl" '[skip translations]'
    assert_contains "gitlab only runs on the default branch" "$gl" 'CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
    assert_contains "gitlab reuses one stable MR branch" "$gl" "HEAD:ptc/translations"
    assert_contains "gitlab opens the MR via push options" "$gl" "merge_request.create"
    # CI_JOB_TOKEN may not push unless a maintainer opts in (GitLab 18.4+, off
    # by default), so the recipe must accept a write_repository token instead.
    assert_contains "gitlab allows a push token override" "$gl" 'PTC_GIT_PUSH_TOKEN:-$CI_JOB_TOKEN'

    # The standalone path is still offered, so the CLI does not depend on the action.
    assert_contains "standalone CLI usage is still shown" "$block" "./ptc-cli.sh --config-file .ptc-config.yml"
}

# §6: the api_token: config key is deprecated. It must be ignored (never loaded
# into PTC_API_TOKEN) and must produce a warning. parse_config_file runs in the
# current shell (NOT a subshell) so the "not loaded" assertion can actually
# observe a would-be mutation of PTC_API_TOKEN.
test_config_api_token_deprecated() {
    echo "--- config api_token is deprecated: ignored + warned"

    local saved="$PTC_API_TOKEN" saved_locale="$PTC_SOURCE_LOCALE"
    PTC_API_TOKEN=""
    local dir cfg errfile
    dir=$(mktemp -d); cfg="$dir/c.yml"; errfile=$(mktemp)
    printf 'source_locale: en\napi_token: from-config\nfiles:\n  - file: en.json\n    output: {{lang}}.json\n' > "$cfg"
    parse_config_file "$cfg" >/dev/null 2>"$errfile"
    assert_eq "config api_token is NOT loaded" "$PTC_API_TOKEN" ""
    assert_contains "a deprecation warning is emitted" "$(cat "$errfile")" "deprecated 'api_token:'"
    rm -rf "$dir"; rm -f "$errfile"
    PTC_API_TOKEN="$saved"; PTC_SOURCE_LOCALE="$saved_locale"
}

# F2: a .ptcignore whose alphabetically-last path is ignored must not abort the
# scan under set -euo pipefail.
test_ptcignore_last_path_ignored() {
    echo "--- filter_ptcignore last-path-ignored does not fail the pipeline"

    local dir rc out
    dir=$(mktemp -d)
    printf '*.log\n' > "$dir/.ptcignore"
    # Run the exact pipeline shape cmd_init uses, under set -e, last path ignored.
    out=$( set -euo pipefail; printf 'keep.json\nzzz.log\n' | filter_ptcignore "$dir" )
    rc=$?
    assert_eq "pipeline survives (exit 0)" "$rc" "0"
    assert_eq "ignored last path is dropped" "$out" "keep.json"
    rm -rf "$dir"
}

# F6: a --api-url without a trailing slash must still hit a well-formed endpoint.
test_cmd_init_url_normalization() {
    echo "--- cmd_init normalizes --api-url trailing slash"

    local saved_url="$PTC_API_URL"
    MOCK_DETECT_BODY="$RAILS_BODY"; MOCK_DETECT_CODE="200"
    PTC_API_TOKEN="test-token"
    MOCK_URL_FILE=$(mktemp)

    local dir
    dir=$(mktemp -d)
    printf '{}' > "$dir/en.yml"
    cmd_init --project-dir "$dir" --api-token test-token \
             --api-url "https://qa.example/api/v1" --yes >/dev/null 2>&1 </dev/null

    local hit
    hit=$(cat "$MOCK_URL_FILE")
    assert_eq "endpoint is well-formed" "$hit" "https://qa.example/api/v1/detect_config"
    rm -rf "$dir"; rm -f "$MOCK_URL_FILE"
    MOCK_URL_FILE=""
    PTC_API_URL="$saved_url"
}

# §5: every API request carries a versioned User-Agent (via the ptc_curl wrapper).
test_user_agent_header() {
    echo "--- requests send a versioned User-Agent"

    PTC_API_TOKEN="test-token"
    MOCK_DETECT_BODY="$RAILS_BODY"; MOCK_DETECT_CODE="200"
    MOCK_ARGS_FILE=$(mktemp)

    local dir
    dir=$(mktemp -d)
    printf '{}' > "$dir/en.yml"
    cmd_init --project-dir "$dir" --api-token test-token --yes >/dev/null 2>&1 </dev/null

    local args
    args=$(cat "$MOCK_ARGS_FILE")
    assert_contains "User-Agent header is present" "$args" "User-Agent: ptc-cli/"
    assert_contains "User-Agent carries the version" "$args" "User-Agent: $PTC_USER_AGENT"
    rm -rf "$dir"; rm -f "$MOCK_ARGS_FILE"
    MOCK_ARGS_FILE=""
}

main() {
    echo "PTC CLI - init (detect_config) tests"
    echo

    test_json_array_elements
    test_build_payload
    test_render_detected
    test_render_template
    test_ptcignore
    test_ci_provider
    test_call_detect_config
    test_cmd_init_writes_config
    test_cmd_init_refuses_overwrite
    test_cmd_init_422
    test_cmd_init_404_gate
    test_cmd_init_no_token
    test_cmd_init_env_token
    test_env_token_survives_startup
    test_ci_snippets_use_action
    test_config_api_token_deprecated
    test_ptcignore_last_path_ignored
    test_cmd_init_url_normalization
    test_user_agent_header

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
