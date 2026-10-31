#!/bin/bash

# Org #7184 (CLI-24, AGD-1): the CLI finds the agent token where the token page put it.
#
# The token page hands the token out as an MCP header; the guide then needs this CLI, which read only PTC_API_TOKEN, so
# agents stopped and asked for a token the user had already pasted (one invented PTC_AGENT_TOKEN). Covered here, through
# the doors every token-needing command goes through (preflight_check: the translate pipeline; _guide_call: every
# `ptc guide` sub-command; `ptc sync` itself):
#   - PTC_API_TOKEN, PTC_AGENT_TOKEN, both (PTC_API_TOKEN wins);
#   - none set: the token from the CLI's own credentials file ($XDG_CONFIG_HOME, else ~/.config, /ptc/credentials,
#     PTC_API_TOKEN=<token>), read only at mode 600; at 644 it is refused with one line, the value never printed;
#   - an env name beats the file;
#   - no token anywhere: the error names `ptc auth login` (org #7308), the credentials file, PTC_API_TOKEN, PTC_AGENT_TOKEN and --api-token;
#   - no log line ever carries a token value.
#   - org #7319: a token PTC refuses (HTTP 401) is named by its source; an environment token says it wins over the
#     credentials file and points to `ptc auth login` (CODE=401 makes the curl stub answer 401).
# The CLI never reads an MCP client's configuration (Eran, 27 Oct 2026): a Claude Code ~/.claude.json carrying a PTC
# token is not read. Each case runs in its own bash with a temp HOME and working directory (never this machine's own
# files) and a curl stub that records the bearer it was given to a file. PTC_CLI_UNDER_TEST points it at another copy (the red run).

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_UNDER_TEST="${PTC_CLI_UNDER_TEST:-$(dirname "$TEST_DIR")/ptc-cli.sh}"

test_count=0; passed_count=0; failed_count=0
pass() { echo "[PASS] $*"; passed_count=$((passed_count + 1)); test_count=$((test_count + 1)); }
fail() { echo "[FAIL] $*"; failed_count=$((failed_count + 1)); test_count=$((test_count + 1)); }

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

TOK_API="ptcu_api_$RANDOM$RANDOM"
TOK_AGENT="ptcu_agent_$RANDOM$RANDOM"
TOK_FILE="ptcu_file_$RANDOM$RANDOM"
TOK_MCP="ptcu_mcp_$RANDOM$RANDOM"
ALL_TOKENS=("$TOK_API" "$TOK_AGENT" "$TOK_FILE" "$TOK_MCP")

# run_door CASE DOOR [VAR=value ...] -> output in $WORK_DIR/CASE/out, the bearer curl got in $WORK_DIR/CASE/bearer,
# the door's status in $WORK_DIR/CASE/rc. The case's HOME and cwd are $WORK_DIR/CASE/{home,cwd} (set up beforehand).
run_door() {
    local case_dir="$WORK_DIR/$1" door="$2"; shift 2
    mkdir -p "$case_dir/home" "$case_dir/cwd"; : > "$case_dir/bearer"
    ( cd "$case_dir/cwd" && env -u PTC_API_TOKEN -u PTC_AGENT_TOKEN -u PTC_ORG_TOKEN -u PTC_API_URL \
        -u XDG_CONFIG_HOME HOME="$case_dir/home" PTC_API_URL="http://ptc.test/api/v1/" REC="$case_dir/bearer" "$@" \
        bash -c '
            source "$1"
            PTC_VERBOSE=true
            curl() {
                local prev="" out=""
                for a in "$@"; do
                    if [[ "$prev" == "-H" && "$a" == "Authorization: Bearer "* ]]; then printf "%s" "${a#Authorization: Bearer }" > "$REC"; fi
                    [[ "$prev" == "-o" ]] && out="$a"
                    # #7225: the bearer arrives as a curl config on stdin (-K -), never as an argument.
                    if [[ "$prev" == "-K" && "$a" == "-" ]]; then
                        sed -n "s/^header = \"Authorization: Bearer \(.*\)\"\$/\1/p" | tr -d "\n" > "$REC"
                    fi
                    prev="$a"
                done
                if [[ -n "$out" ]]; then printf "{}" > "$out"; printf "%s" "${CODE:-200}"; else printf "{}%s" "${CODE:-200}"; fi
            }
            case "$2" in
                preflight) preflight_check ;;
                guide) _guide_call GET "guide/status" ;;
            esac
        ' _ "$CLI_UNDER_TEST" "$door" ) > "$case_dir/out" 2>&1
    echo $? > "$case_dir/rc"
}

masked_out() { sed 's/ptcu_[A-Za-z0-9_]*/<token>/g' "$WORK_DIR/$1/out" | tail -"${2:-3}" | tr '\n' ' '; }

assert_bearer() {
    local desc="$1" case_name="$2" want="$3"
    if [[ "$(cat "$WORK_DIR/$case_name/bearer")" == "$want" ]]; then pass "$desc"
    else fail "$desc (the expected token did not reach the API; output: $(masked_out "$case_name"))"; fi
}

assert_out_contains() {
    local desc="$1" case_name="$2" needle="$3"
    if grep -qF -- "$needle" "$WORK_DIR/$case_name/out"; then pass "$desc"
    else fail "$desc (expected '$needle' in: $(masked_out "$case_name" 8))"; fi
}

assert_failed() {
    local desc="$1" case_name="$2"
    if [[ "$(cat "$WORK_DIR/$case_name/rc")" != 0 ]]; then pass "$desc"; else fail "$desc (exit 0)"; fi
}

assert_no_token_logged() {
    local case_name="$1" t
    for t in "${ALL_TOKENS[@]}"; do
        if grep -qF -- "$t" "$WORK_DIR/$case_name/out"; then fail "$case_name: a token value appears in the output"; return; fi
    done
    pass "$case_name: no token value in any log line"
}

echo "=== env names: PTC_API_TOKEN, PTC_AGENT_TOKEN, first set wins ==="
for door in preflight guide; do
    run_door "api-$door" "$door" PTC_API_TOKEN="$TOK_API"
    assert_bearer "$door: PTC_API_TOKEN alone is sent" "api-$door" "$TOK_API"
    assert_no_token_logged "api-$door"

    run_door "agent-$door" "$door" PTC_AGENT_TOKEN="$TOK_AGENT"
    assert_bearer "$door: PTC_AGENT_TOKEN alone is sent" "agent-$door" "$TOK_AGENT"
    assert_out_contains "$door: verbose names the source PTC_AGENT_TOKEN" "agent-$door" "API token from PTC_AGENT_TOKEN"
    assert_no_token_logged "agent-$door"

    run_door "both-$door" "$door" PTC_API_TOKEN="$TOK_API" PTC_AGENT_TOKEN="$TOK_AGENT"
    assert_bearer "$door: both set -> PTC_API_TOKEN wins" "both-$door" "$TOK_API"
done

echo
echo "=== no env name: the CLI's own credentials file (mode 600) ==="
creds() {  # creds CASE MODE [DIR] -> writes PTC_API_TOKEN=$TOK_FILE to DIR/ptc/credentials (DIR: the case's ~/.config)
    local dir="${3:-$WORK_DIR/$1/home/.config}"
    mkdir -p "$dir/ptc"; printf 'PTC_API_TOKEN=%s\n' "$TOK_FILE" > "$dir/ptc/credentials"; chmod "$2" "$dir/ptc/credentials"
}
claude_json() {  # a Claude Code user config carrying a PTC MCP token: never read
    mkdir -p "$(dirname "$1")"
    printf '{"mcpServers": {"ptc": {"type": "http", "url": "http://ptc.test/mcp", "headers": {"Authorization": "Bearer %s"}}}}\n' "$2" > "$1"
}

creds file-preflight 600
run_door file-preflight preflight
assert_bearer "preflight: the token from ~/.config/ptc/credentials (mode 600)" file-preflight "$TOK_FILE"
assert_out_contains "preflight: verbose names the credentials file" file-preflight "API token from $WORK_DIR/file-preflight/home/.config/ptc/credentials"
assert_no_token_logged file-preflight

creds file-guide 600
run_door file-guide guide
assert_bearer "guide: the token from the credentials file" file-guide "$TOK_FILE"
assert_no_token_logged file-guide

creds xdg-guide 600 "$WORK_DIR/xdg-guide/xdg"
run_door xdg-guide guide XDG_CONFIG_HOME="$WORK_DIR/xdg-guide/xdg"
assert_bearer "guide: \$XDG_CONFIG_HOME/ptc/credentials" xdg-guide "$TOK_FILE"

creds loose 644
run_door loose preflight
assert_bearer "preflight: a 644 credentials file is not read" loose ""
assert_out_contains "preflight: the refusal names the mode" loose "its mode is 644"
assert_out_contains "preflight: the refusal names chmod 600" loose "chmod 600 $WORK_DIR/loose/home/.config/ptc/credentials"
assert_failed "preflight: a 644 file only -> fails" loose
assert_no_token_logged loose

creds env-first 600
run_door env-first preflight PTC_AGENT_TOKEN="$TOK_AGENT"
assert_bearer "an env name beats the credentials file" env-first "$TOK_AGENT"

echo
echo "=== an MCP client's configuration is never read ==="
claude_json "$WORK_DIR/mcp-ignored/home/.claude.json" "$TOK_MCP"
run_door mcp-ignored preflight
assert_bearer "preflight: the token in ~/.claude.json is never sent" mcp-ignored ""
assert_failed "preflight: only an MCP config -> fails" mcp-ignored
assert_no_token_logged mcp-ignored

echo
echo "=== no token anywhere: the error names every door ==="
run_door none-preflight preflight
assert_failed "preflight: no token -> fails" none-preflight
assert_out_contains "preflight: names PTC_API_TOKEN and PTC_AGENT_TOKEN" none-preflight "set PTC_API_TOKEN (or PTC_AGENT_TOKEN)"
assert_out_contains "preflight: names --api-token" none-preflight "pass --api-token"
# org #7308: the human saves the token with `ptc auth login`; the error names the command and the file it writes. Org row 7348: in their own terminal, not through the agent. Org row 7352: approved in the browser, no token typed.
assert_out_contains "preflight: names ptc auth login and the credentials file" none-preflight \
    "Ask the human to run \`ptc auth login\` in their own terminal, not through the agent, and approve the sign-in in their browser at http://ptc.test (no token is typed; the CLI saves it to $WORK_DIR/none-preflight/home/.config/ptc/credentials, mode 600)"
run_door none-guide guide
assert_failed "guide: no token -> fails" none-guide
assert_out_contains "guide: names PTC_API_TOKEN and PTC_AGENT_TOKEN" none-guide "PTC_API_TOKEN and PTC_AGENT_TOKEN are not set"
assert_out_contains "guide: names ptc auth login and --api-token" none-guide "/home/.config/ptc/credentials, mode 600), or set PTC_API_TOKEN (or PTC_AGENT_TOKEN), or pass --api-token."

echo
echo "=== a refused token (HTTP 401) names the source it came from (org #7319, CLI-24) ==="
for door in preflight guide; do
    creds "env401-$door" 600
    run_door "env401-$door" "$door" CODE=401 PTC_API_TOKEN="$TOK_API"
    assert_failed "$door: env token refused -> fails" "env401-$door"
    assert_out_contains "$door: 401 names PTC_API_TOKEN and that it beats the credentials file" "env401-$door" \
        "PTC refused the agent token (HTTP 401): it came from the environment variable PTC_API_TOKEN, which wins over the credentials file $WORK_DIR/env401-$door/home/.config/ptc/credentials."
    assert_out_contains "$door: 401 on an env token points to ptc auth login" "env401-$door" "\`ptc auth login\`"
    assert_no_token_logged "env401-$door"

    run_door "agent401-$door" "$door" CODE=401 PTC_AGENT_TOKEN="$TOK_AGENT"
    assert_out_contains "$door: 401 names PTC_AGENT_TOKEN" "agent401-$door" \
        "PTC refused the agent token (HTTP 401): it came from the environment variable PTC_AGENT_TOKEN."
    assert_no_token_logged "agent401-$door"

    creds "file401-$door" 600
    run_door "file401-$door" "$door" CODE=401
    assert_out_contains "$door: 401 names the credentials file" "file401-$door" \
        "PTC refused the agent token (HTTP 401): it came from the credentials file $WORK_DIR/file401-$door/home/.config/ptc/credentials."
    assert_out_contains "$door: 401 on the file points to ptc auth login" "file401-$door" "\`ptc auth login\`"
    assert_no_token_logged "file401-$door"
done

echo
echo "=== ptc sync: the door itself, no token anywhere ==="
mkdir -p "$WORK_DIR/sync/home" "$WORK_DIR/sync/cwd"
printf 'source_locale: en\nfiles:\n  - file: en.json\n    output: "{{lang}}.json"\n' > "$WORK_DIR/sync/cwd/.ptc-config.yml"
( cd "$WORK_DIR/sync/cwd" && env -u PTC_API_TOKEN -u PTC_AGENT_TOKEN -u PTC_ORG_TOKEN -u XDG_CONFIG_HOME HOME="$WORK_DIR/sync/home" \
    PTC_API_URL="http://ptc.test/api/v1/" bash "$CLI_UNDER_TEST" sync ) > "$WORK_DIR/sync/out" 2>&1
echo $? > "$WORK_DIR/sync/rc"
assert_failed "sync: no token -> fails" sync
assert_out_contains "sync: no token -> names PTC_API_TOKEN and PTC_AGENT_TOKEN" sync "PTC_API_TOKEN and PTC_AGENT_TOKEN are not set"

echo
echo "Total: $test_count, passed: $passed_count, failed: $failed_count"
[[ $failed_count -eq 0 ]]
