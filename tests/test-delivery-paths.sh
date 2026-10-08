#!/bin/bash
# E23: where a delivered translation lands. Each archive entry is named after the file's output pattern
# (directories included) and must be written to exactly that path - never collapsed onto its basename in
# the source file's directory, where two languages overwrite each other and the source itself.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
refuse_busy_port() {  # a port that already answers would hide a mock that could not bind (a stale run's server passes the probe)
    local i  # up to ~5 s for a listener in its last moments (the previous suite's mock shutting down) to go quiet
    for i in $(seq 1 20); do
        python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), 0.4).close()" 2>/dev/null || return 0
        sleep 0.25
    done
    echo "port $1 already in use: a stale mock_ptc_api.py? (pgrep -af mock_ptc_api.py)" >&2; exit 1
}
stop_mocks() {  # kill the suite's mocks AND wait until they are gone, so the next suite finds their ports free
    local p i; for p in "$@"; do kill "$p" 2>/dev/null; done
    for p in "$@"; do wait "$p" 2>/dev/null; for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done; done
}
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
PIDS=()
cleanup() { stop_mocks "${PIDS[@]}"; rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {  # start_mock VAR port... -> sets VAR to the API url
    local var="$1" port pid i; shift
    for port in "$@"; do
        refuse_busy_port "$port"
        PTC_MOCK_PORT="$port" PTC_MOCK_LOG="$WORK/journal-$port" python3 "$MOCK" >>"$WORK/mock-$port.log" 2>&1 &
        pid=$!
        for i in $(seq 1 30); do
            if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 0.4).close()" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
                PIDS+=("$pid"); printf -v "$var" 'http://127.0.0.1:%s/api/v1/' "$port"; JOURNAL="$WORK/journal-$port"; return 0
            fi
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.3
        done
        kill "$pid" 2>/dev/null
    done
    echo "mock did not come up"; exit 1
}

run_in() {  # run_in DIR -> runs the CLI there with the config committed in DIR
    ( cd "$1" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API" \
        --monitor-interval 1 --monitor-max-attempts 10 ) >"$WORK/out" 2>&1
}

has_lang() {  # has_lang FILE LANG -> the file exists and carries that language's content
    [[ -f "$1" ]] && grep -q "\[$2\]" "$1"
}

API=""; JOURNAL=""; start_mock API 19287 19297 19307

echo "=== E23: a monorepo product whose source lives in a subdirectory of its output ==="
R="$WORK/mono"; P="$R/woocommerce-multilingual"
mkdir -p "$P/locale/orig"
printf 'msgid "Hello"\nmsgstr ""\n' > "$P/locale/orig/woocommerce-multilingual.pot"
cp "$P/locale/orig/woocommerce-multilingual.pot" "$WORK/pot.orig"
printf 'source_locale: en\nfiles:\n  - file: locale/orig/woocommerce-multilingual.pot\n    output: locale/woocommerce-multilingual-{{lang}}.po\n' > "$P/.ptc-config.yml"
git -C "$R" init -q
run_in "$P"
grep -q "upload woocommerce-multilingual/locale/orig/woocommerce-multilingual.pot -> output woocommerce-multilingual/locale/woocommerce-multilingual-{{lang}}.po" "$JOURNAL" \
    && pass "the upload carries the config's output pattern, anchored at the repository root like file_path" \
    || fail "upload output pattern: $(grep 'upload woocommerce' "$JOURNAL")"
has_lang "$P/locale/woocommerce-multilingual-de.po" de && pass "German lands at locale/woocommerce-multilingual-de.po" || fail "de not written: $(find "$P" -type f ! -path '*/.git/*' | sort)"
has_lang "$P/locale/woocommerce-multilingual-fr.po" fr && pass "French lands at locale/woocommerce-multilingual-fr.po" || fail "fr not written"
cmp -s "$P/locale/orig/woocommerce-multilingual.pot" "$WORK/pot.orig" && pass "the source .pot is untouched" || fail "the source .pot was overwritten"

echo "=== E23: same-basename entries in different directories stay apart ==="
R="$WORK/samebase"
mkdir -p "$R/en"
printf 'msgid "Hello"\nmsgstr ""\n' > "$R/en/messages.po"
cp "$R/en/messages.po" "$WORK/src.orig"
printf 'source_locale: en\nfiles:\n  - file: en/messages.po\n    output: {{lang}}/messages.po\n' > "$R/.ptc-config.yml"
git -C "$R" init -q
run_in "$R"
has_lang "$R/de/messages.po" de && pass "de/messages.po is written" || fail "de/messages.po missing: $(find "$R" -type f ! -path '*/.git/*' | sort)"
has_lang "$R/fr/messages.po" fr && pass "fr/messages.po is written" || fail "fr/messages.po missing"
cmp -s "$R/en/messages.po" "$WORK/src.orig" && pass "the source en/messages.po is untouched" || fail "the source was overwritten"

echo "=== E23: the shape that always worked (output next to the source) still does ==="
R="$WORK/flat"
mkdir -p "$R/languages"
printf 'msgid "Hello"\nmsgstr ""\n' > "$R/languages/disable-comments.pot"
printf 'source_locale: en\nfiles:\n  - file: languages/disable-comments.pot\n    output: languages/disable-comments-{{lang}}.po\n' > "$R/.ptc-config.yml"
git -C "$R" init -q
run_in "$R"
has_lang "$R/languages/disable-comments-de.po" de && has_lang "$R/languages/disable-comments-fr.po" fr \
    && pass "languages/disable-comments-{de,fr}.po are written" || fail "flat shape: $(find "$R" -type f ! -path '*/.git/*' | sort)"

echo "=== E27: every config entry resolves by the same rule (pot/ subdirectory, monorepo product) ==="
# The WPML suite shape from lab round 7: a product directory, catalogues under pot/ subdirectories, and names
# that contain the letters "en" inside a word. A comment or a blank line between file: and output: used to make
# the lookup miss, and the fallback then replaced the first "en" anywhere in the name
# (Front{{lang}}d-ui.pot, deleting-cont{{lang}}t.pot) instead of applying output:.
R="$WORK/wpml"; P="$R/sitepress-multilingual-cms"
mkdir -p "$P/locale/jed/pot" "$P/wpml/languages/pot"
for f in locale/jed/pot/sitepress-wpml-updateTranslationFrontend-ui.pot wpml/languages/pot/wpml-wpml-deleting-content.pot \
         wpml/languages/pot/wpml-wpml-dashboard.pot; do
    printf 'msgid "Hello"\nmsgstr ""\n' > "$P/$f"
done
cat > "$P/.ptc-config.yml" <<'YML'
source_locale: en
languages: [de, fr]
files:
  - file: locale/jed/pot/sitepress-wpml-updateTranslationFrontend-ui.pot
    # jed catalogue of the React UI
    output: locale/jed/pot/sitepress-wpml-updateTranslationFrontend-ui-{{lang}}.po
  - file: wpml/languages/pot/wpml-wpml-deleting-content.pot

    output: wpml/languages/pot/wpml-wpml-deleting-content-{{lang}}.po
  - file: wpml/languages/pot/wpml-wpml-dashboard.pot
    output: wpml/languages/pot/wpml-wpml-dashboard-{{lang}}.po
guide:
  project_id: 1318
YML
git -C "$R" init -q
: > "$JOURNAL"
run_in "$P"; rc=$?
[[ $rc -eq 0 ]] && pass "the run exits 0" || fail "rc=$rc: $(tail -5 "$WORK/out")"
for f in locale/jed/pot/sitepress-wpml-updateTranslationFrontend-ui wpml/languages/pot/wpml-wpml-deleting-content wpml/languages/pot/wpml-wpml-dashboard; do
    grep -qF "upload sitepress-multilingual-cms/$f.pot -> output sitepress-multilingual-cms/$f-{{lang}}.po" "$JOURNAL" \
        && pass "$(basename "$f").pot is sent with its config output" \
        || fail "$(basename "$f").pot upload: $(grep -F "upload sitepress-multilingual-cms/$f.pot" "$JOURNAL")"
    has_lang "$P/$f-de.po" de && has_lang "$P/$f-fr.po" fr && pass "$(basename "$f")-{de,fr}.po are written" \
        || fail "$(basename "$f")-{de,fr}.po missing"
done
stray=$(find "$P" -type f \( -name '*Frontd*' -o -name '*Frontfr*' -o -name '*contd*' -o -name '*contfr*' \) | sort)
[[ -z "$stray" ]] && pass "no file is named by replacing the 'en' inside Frontend/content" || fail "misnamed deliveries: $stray"

echo "=== E27: without an output pattern, only a delimited source-locale token is replaced; no token fails the file ==="
R="$WORK/fallback"
mkdir -p "$R/wpml/languages/pot" "$R/locale" "$R/i18n/en"
printf 'msgid "Hello"\nmsgstr ""\n' > "$R/wpml/languages/pot/wpml-wpml-deleting-content.pot"
printf '{"hello": "Hello"}\n' > "$R/locale/sample-en.json"
printf '{"hello": "Hello"}\n' > "$R/i18n/en/app.json"
git -C "$R" init -q
: > "$JOURNAL"
( cd "$R" && PTC_API_TOKEN=t "$CLI" -s en -p 'wpml/languages/pot/wpml-wpml-deleting-content.pot,locale/sample-{{lang}}.json,i18n/{{lang}}/app.json' \
    --api-url "$API" --monitor-interval 1 --monitor-max-attempts 10 ) >"$WORK/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && pass "the run exits non-zero (rc=$rc)" || fail "a file with no derivable pattern still exited 0"
grep -q "No output pattern for wpml/languages/pot/wpml-wpml-deleting-content.pot" "$WORK/out" \
    && pass "the error names the file that has no pattern" || fail "no clear error: $(grep -i 'error' "$WORK/out" | head -3)"
grep -q "upload wpml/languages/pot/wpml-wpml-deleting-content.pot" "$JOURNAL" \
    && fail "the file was uploaded with a guessed pattern: $(grep 'upload wpml' "$JOURNAL")" || pass "the file is not uploaded with a guessed pattern"
grep -qF "upload locale/sample-en.json -> output locale/sample-{{lang}}.json" "$JOURNAL" \
    && pass "-en. is replaced (sample-{{lang}}.json)" || fail "sample-en.json: $(grep 'upload locale' "$JOURNAL")"
grep -qF "upload i18n/en/app.json -> output i18n/{{lang}}/app.json" "$JOURNAL" \
    && pass "/en/ is replaced (i18n/{{lang}}/app.json)" || fail "i18n/en/app.json: $(grep 'upload i18n' "$JOURNAL")"
has_lang "$R/locale/sample-de.json" de && has_lang "$R/i18n/fr/app.json" fr \
    && pass "the files with a delimited token are still delivered" || fail "delimited files not delivered: $(find "$R" -type f ! -path '*/.git/*' | sort)"

echo "=== S2-R2 item 1 (decision 2, F5): a file in status failed whose download succeeds is delivered, silently ==="
# One failed segment never blocks the rest: PTC writes the failed segments by the format's missing-translation rule
# and serves the archive, so the CLI delivers the file like a completed one. Silent for the user: no failure line,
# exit 0 (the action then opens the pull request; the findings comment is PTC's and does not list the file).
R="$WORK/partial"
mkdir -p "$R/locales"
printf '{"hello": "Hello"}\n' > "$R/locales/en.json"
printf 'source_locale: en\nfiles:\n  - file: locales/en.json\n    output: locales/{{lang}}.json\n' > "$R/.ptc-config.yml"
git -C "$R" init -q
API_HAPPY="$API"
port="${API#http://127.0.0.1:}"; port="${port%%/*}"
API="http://127.0.0.1:$((port + 2))/api/v1/"   # the mock's "failed" scenario: status failed, archive served
run_in "$R"; rc=$?
API="$API_HAPPY"
[[ $rc -eq 0 ]] && pass "a failed-status file with a served archive exits 0" || fail "rc=$rc: $(tail -5 "$WORK/out")"
has_lang "$R/locales/de.json" de && has_lang "$R/locales/fr.json" fr \
    && pass "the failed-status file is delivered like a completed one" || fail "not delivered: $(find "$R" -type f ! -path '*/.git/*' | sort)"
grep -qiE "translation failed|failed files|run incomplete" "$WORK/out" \
    && fail "the delivered file is reported as failed: $(grep -iE 'translation failed|failed files|run incomplete' "$WORK/out")" \
    || pass "the delivered file is not reported as failed"

echo "=== S2-R4: the same failed-status file in pattern mode (--patterns, the e2e CLI-8 mid-poll cell's run) ==="
# The pattern-mode monitor loop (process_files_in_steps) takes its own branch for a terminal status; the e2e cell
# asserts exactly these lines, so they are pinned here where the CLI side runs.
R="$WORK/partial-patterns"
mkdir -p "$R/locales"
printf '{"hello": "Hello"}\n' > "$R/locales/en.json"
git -C "$R" init -q
( cd "$R" && PTC_API_TOKEN=t "$CLI" -s en -p 'locales/en.json' --api-url "http://127.0.0.1:$((port + 2))/api/v1/" \
    --monitor-interval 1 --monitor-max-attempts 10 --verbose ) >"$WORK/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "pattern mode: a failed-status file with a served archive exits 0" || fail "rc=$rc: $(tail -5 "$WORK/out")"
has_lang "$R/locales/de.json" de && pass "pattern mode: the failed-status file is delivered" \
    || fail "not delivered: $(find "$R" -type f ! -path '*/.git/*' | sort)"
grep -qF "✓ locales/en.json" "$WORK/out" && grep -qF "Step-based processing completed successfully" "$WORK/out" \
    && pass "pattern mode: listed as completed" || fail "not listed as completed: $(tail -8 "$WORK/out")"
grep -qF "Translation failed for locales/en.json" "$WORK/out" \
    && fail "pattern mode: reported as failed: $(grep -F 'Translation failed' "$WORK/out")" || pass "pattern mode: no failure line"

echo
echo "Total: $((passed + failed))  Passed: $passed  Failed: $failed"
[[ $failed -eq 0 ]]
