#!/bin/bash

# Org #7308 (CLI-24, AGD-1; Eran 28 Oct 2026): the human hands the CLI the agent token with `ptc auth login`.
#
# The token page's snippets no longer write the CLI's credentials file; the agent installs the CLI and asks the human to
# run `ptc auth login`, which reads the token (no echo at a terminal, else one line on stdin), verifies it against PTC
# and saves `PTC_API_TOKEN=<token>`, mode 600, in the CLI's credentials file: `$APPDATA/ptc/credentials` when APPDATA is
# set (Git Bash, MSYS, Cygwin), else `${XDG_CONFIG_HOME:-~/.config}/ptc/credentials`. Covered here:
#   - the stdin form writes the file at mode 600 with the one line, and the token is on no argument list (the curl stub
#     records its argv) and in no output;
#   - the APPDATA branch writes there, and the doors read it (APPDATA's file first when both exist);
#   - a token PTC refuses (401) is not saved, exit non-zero;
#   - with no token anywhere, the doors' error names `ptc auth login`.
# Each case runs with a temp HOME (never this machine's own files) and a curl stub on PATH. PTC_CLI_UNDER_TEST points it
# at another copy (the red run).

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_UNDER_TEST="${PTC_CLI_UNDER_TEST:-$(dirname "$TEST_DIR")/ptc-cli.sh}"

test_count=0; passed_count=0; failed_count=0
pass() { echo "[PASS] $*"; passed_count=$((passed_count + 1)); test_count=$((test_count + 1)); }
fail() { echo "[FAIL] $*"; failed_count=$((failed_count + 1)); test_count=$((test_count + 1)); }

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

GOOD="ptcu_good_$RANDOM$RANDOM"
BAD="ptcu_bad_$RANDOM$RANDOM"

# The curl stub: records its argv (one argument per line) and the bearer it got through --config (stdin), and answers as
# PTC does for an agent token that names no project (org row 7344): GET /api/v1/auth/check answers 200 for the good token
# and 401 otherwise; GET /api/v1/languages is project-scoped and answers every agent token without X-PTC-Project-Id
# 401 {"error":"Name the project (X-PTC-Project-Id) when using an agent token"}; any other path 404.
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/curl" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >> "\$CURL_ARGV"
cfg=""; prev=""
for a in "\$@"; do [[ "\$prev" == "--config" || "\$prev" == "-K" ]] && cfg="\$a"; prev="\$a"; done
bearer=""
if [[ "\$cfg" == "-" ]]; then bearer=\$(sed -n -E 's/^header *= *"Authorization: Bearer (.*)"\$/\1/p'); fi
printf '%s' "\$bearer" > "\$CURL_BEARER"
url=""; for a in "\$@"; do [[ "\$a" == http* ]] && url="\$a"; done
case "\$url" in
    */api/v1/auth/check) if [[ "\$bearer" == "$GOOD" ]]; then printf '200'; else printf '401'; fi ;;
    */api/v1/languages) printf '401' ;;
    *) printf '404' ;;
esac
STUB
chmod +x "$WORK_DIR/bin/curl"

# login CASE TOKEN [VAR=value ...]: `ptc auth login` with TOKEN on stdin; output, rc, argv and bearer under $WORK_DIR/CASE.
login() {
    local case_dir="$WORK_DIR/$1" token="$2"; shift 2
    mkdir -p "$case_dir/home"; : > "$case_dir/argv"; : > "$case_dir/bearer"
    printf '%s\n' "$token" | env -u PTC_API_TOKEN -u PTC_AGENT_TOKEN -u PTC_ORG_TOKEN -u XDG_CONFIG_HOME -u APPDATA \
        HOME="$case_dir/home" PATH="$WORK_DIR/bin:$PATH" PTC_API_URL="http://ptc.test/api/v1/" \
        CURL_ARGV="$case_dir/argv" CURL_BEARER="$case_dir/bearer" "$@" \
        bash "$CLI_UNDER_TEST" auth login > "$case_dir/out" 2>&1
    echo $? > "$case_dir/rc"
}

# resolved CASE [VAR=value ...]: the token the doors resolve (resolve_api_token), compared with GOOD -> "good" / "other".
resolved() {
    local case_dir="$WORK_DIR/$1"; shift
    env -u PTC_API_TOKEN -u PTC_AGENT_TOKEN -u PTC_ORG_TOKEN -u XDG_CONFIG_HOME -u APPDATA HOME="$case_dir/home" "$@" \
        bash -c 'source "$1"; resolve_api_token 2>/dev/null; [[ "${PTC_API_TOKEN:-}" == "$2" ]] && echo good || echo other' \
        _ "$CLI_UNDER_TEST" "$GOOD"
}

masked() { sed 's/ptcu_[A-Za-z0-9_]*/<token>/g' "$1" | tail -"${2:-4}" | tr '\n' ' '; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# --- 1. the stdin form: the file, its mode, its one line; the token on no argv and in no output
login stdin "$GOOD"
file="$WORK_DIR/stdin/home/.config/ptc/credentials"
if [[ "$(cat "$WORK_DIR/stdin/rc")" == 0 ]]; then pass "auth login (stdin) exits 0 for a token PTC accepts"
else fail "auth login (stdin) exits 0 for a token PTC accepts (rc $(cat "$WORK_DIR/stdin/rc"); output: $(masked "$WORK_DIR/stdin/out"))"; fi
if [[ -f "$file" && "$(cat "$file")" == "PTC_API_TOKEN=$GOOD" ]]; then pass "auth login writes PTC_API_TOKEN=<token> to ~/.config/ptc/credentials"
else fail "auth login writes PTC_API_TOKEN=<token> to ~/.config/ptc/credentials (file: $( [[ -f "$file" ]] && echo present || echo absent))"; fi
if [[ "$(mode_of "$file")" == 600 ]]; then pass "the credentials file is mode 600"
else fail "the credentials file is mode 600 (mode: $(mode_of "$file"))"; fi
if [[ "$(cat "$WORK_DIR/stdin/bearer")" == "$GOOD" ]]; then pass "auth login verifies the token with PTC through --config on stdin"
else fail "auth login verifies the token with PTC through --config on stdin (no bearer reached the stub)"; fi
if [[ -s "$WORK_DIR/stdin/argv" ]] && ! grep -qF -- "$GOOD" "$WORK_DIR/stdin/argv"; then pass "the token is on no argument list during the verify call"
else fail "the token is on no argument list during the verify call ($( [[ -s "$WORK_DIR/stdin/argv" ]] && echo 'token in argv' || echo 'no curl call'))"; fi
if ! grep -qF -- "$GOOD" "$WORK_DIR/stdin/out"; then pass "auth login never prints the token"
else fail "auth login never prints the token"; fi
if [[ "$(resolved stdin)" == good ]]; then pass "the doors read the token auth login saved"
else fail "the doors read the token auth login saved"; fi

# --- 2. the APPDATA branch (Git Bash, MSYS, Cygwin)
login appdata "$GOOD" APPDATA="$WORK_DIR/appdata/AppData/Roaming"
afile="$WORK_DIR/appdata/AppData/Roaming/ptc/credentials"
if [[ -f "$afile" && "$(cat "$afile")" == "PTC_API_TOKEN=$GOOD" && ! -e "$WORK_DIR/appdata/home/.config/ptc/credentials" ]]; then
    pass "with APPDATA set, auth login writes \$APPDATA/ptc/credentials"
else fail "with APPDATA set, auth login writes \$APPDATA/ptc/credentials (output: $(masked "$WORK_DIR/appdata/out"))"; fi
if [[ "$(resolved appdata APPDATA="$WORK_DIR/appdata/AppData/Roaming")" == good ]]; then pass "with APPDATA set, the doors read \$APPDATA/ptc/credentials"
else fail "with APPDATA set, the doors read \$APPDATA/ptc/credentials"; fi
mkdir -p "$WORK_DIR/appdata/home/.config/ptc"
( umask 077; printf 'PTC_API_TOKEN=%s\n' "$BAD" > "$WORK_DIR/appdata/home/.config/ptc/credentials" )
if [[ "$(resolved appdata APPDATA="$WORK_DIR/appdata/AppData/Roaming")" == good ]]; then pass "with both files present, APPDATA's is read first"
else fail "with both files present, APPDATA's is read first"; fi

# --- 3. a token PTC refuses is not saved
login refused "$BAD"
if [[ "$(cat "$WORK_DIR/refused/rc")" != 0 && ! -e "$WORK_DIR/refused/home/.config/ptc/credentials" ]]; then
    pass "a token PTC refuses (401) is not saved and auth login exits non-zero"
else fail "a token PTC refuses (401) is not saved and auth login exits non-zero (rc $(cat "$WORK_DIR/refused/rc"); output: $(masked "$WORK_DIR/refused/out"))"; fi
if grep -qF -- "401" "$WORK_DIR/refused/out" && ! grep -qF -- "$BAD" "$WORK_DIR/refused/out"; then pass "the refusal names PTC's answer and never prints the token"
else fail "the refusal names PTC's answer and never prints the token (output: $(masked "$WORK_DIR/refused/out"))"; fi

# --- 4. no token anywhere: the doors name the command
mkdir -p "$WORK_DIR/none/home" "$WORK_DIR/none/cwd"
( cd "$WORK_DIR/none/cwd" && env -u PTC_API_TOKEN -u PTC_AGENT_TOKEN -u PTC_ORG_TOKEN -u XDG_CONFIG_HOME -u APPDATA \
    HOME="$WORK_DIR/none/home" PTC_API_URL="http://ptc.test/api/v1/" \
    bash -c 'source "$1"; curl() { printf "{}200"; }; _guide_call GET "guide/status"' _ "$CLI_UNDER_TEST" ) > "$WORK_DIR/none/out" 2>&1
if grep -qF -- 'ptc auth login' "$WORK_DIR/none/out"; then pass "with no token the error names 'ptc auth login'"
else fail "with no token the error names 'ptc auth login' (output: $(masked "$WORK_DIR/none/out" 3))"; fi
# Org row 7348 (AGD-1; Eran 29 Oct 2026): the human runs it in their own terminal, not through the agent.
if grep -qF -- 'Ask the human to run `ptc auth login` in their own terminal, not through the agent' "$WORK_DIR/none/out"; then
    pass "with no token the error asks for 'ptc auth login' in the human's own terminal"
else fail "with no token the error asks for 'ptc auth login' in the human's own terminal (output: $(masked "$WORK_DIR/none/out" 3))"; fi

echo
echo "Tests: $test_count, passed: $passed_count, failed: $failed_count"
[[ $failed_count -eq 0 ]]
