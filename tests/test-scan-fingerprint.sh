#!/bin/bash
# L2 (POL-116): `ptc scan --json` always reports repo.workspace_fingerprint, the run key of a working tree without a
# commit: sha256 over the sorted "<path>\n<sha256 of the file bytes>\n" list of every source file in every resource set.
# Deterministic, no network.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=${KEEP_WORK:-$(mktemp -d)}; [[ -z "${KEEP_WORK:-}" ]] && trap 'rm -rf "$WORK"' EXIT

field() {  # field <scan.json> <python expression over d>
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1" 2>/dev/null
}

# A working tree with two resource sets (Rails YAML + i18next JSON, non-ASCII content) and no .git.
T="$WORK/tree"; mkdir -p "$T/config/locales" "$T/src/locales/en" "$T/src/locales/de"
printf 'en:\n  hello: "Grüße"\n  bye: "Tschüss ✓"\n' > "$T/config/locales/en.yml"
printf 'de:\n  hello: "Hallo"\n' > "$T/config/locales/de.yml"
printf '{"save": "Save", "title": "Café"}\n' > "$T/src/locales/en/common.json"
printf '{"save": "Speichern"}\n' > "$T/src/locales/de/common.json"

echo "=== ptc scan --json without .git ==="
"$CLI" scan --json -d "$T" > "$WORK/a.json" 2>/dev/null
"$CLI" scan --json -d "$T" > "$WORK/b.json" 2>/dev/null
fp_a=$(field "$WORK/a.json" "d['repo'].get('workspace_fingerprint')")
fp_b=$(field "$WORK/b.json" "d['repo'].get('workspace_fingerprint')")
[[ "$fp_a" =~ ^[0-9a-f]{64}$ ]] && pass "workspace_fingerprint is a 64-hex sha256 without .git" || fail "no fingerprint without .git: '$fp_a'"
[[ "$(field "$WORK/a.json" "d['repo']['head_sha']")" == "None" ]] && pass "head_sha is null without git" || fail "head_sha: $(field "$WORK/a.json" "d['repo']['head_sha']")"
[[ -n "$fp_a" && "$fp_a" == "$fp_b" ]] && pass "the same tree scanned twice gives the same fingerprint" || fail "unstable: '$fp_a' vs '$fp_b'"

# The definition, recomputed independently from the scan's own source-file list.
expected=$(python3 - "$WORK/a.json" "$T" <<'PY'
import hashlib, json, os, sys
d = json.load(open(sys.argv[1])); root = sys.argv[2]
paths = {f["path"] for s in d["resource_sets"] for f in s["source_files"]}
lines = sorted("%s\n%s\n" % (p, hashlib.sha256(open(os.path.join(root, p), "rb").read()).hexdigest()) for p in paths)
print(len(paths), hashlib.sha256("".join(lines).encode()).hexdigest())
PY
)
[[ "${expected#* }" == "$fp_a" && "${expected%% *}" -ge 2 ]] && pass "the fingerprint is sha256 over the sorted (path, sha256) list of the ${expected%% *} source files" || fail "definition: expected '$expected' got '$fp_a'"

printf 'en:\n  hello: "Grüße"\n  bye: "Tschüss ✓!"\n' > "$T/config/locales/en.yml"
"$CLI" scan --json -d "$T" > "$WORK/c.json" 2>/dev/null
fp_c=$(field "$WORK/c.json" "d['repo'].get('workspace_fingerprint')")
[[ "$fp_c" =~ ^[0-9a-f]{64}$ && "$fp_c" != "$fp_a" ]] && pass "one changed byte in a source file changes the fingerprint" || fail "byte change: '$fp_a' -> '$fp_c'"
printf 'de:\n  hello: "Hallo!"\n' > "$T/config/locales/de.yml"
"$CLI" scan --json -d "$T" > "$WORK/d.json" 2>/dev/null
[[ "$(field "$WORK/d.json" "d['repo'].get('workspace_fingerprint')")" == "$fp_c" ]] && pass "a change outside the source files (a translation) leaves it unchanged" || fail "translation change moved the fingerprint"

echo "=== ptc scan --json with .git ==="
git -C "$T" init -q && git -C "$T" add -A && git -C "$T" -c user.email=t@example.com -c user.name=t commit -qm init
"$CLI" scan --json -d "$T" > "$WORK/e.json" 2>/dev/null
[[ "$(field "$WORK/e.json" "d['repo']['head_sha']")" =~ ^[0-9a-f]{40}$ ]] && pass "head_sha is the commit with git" || fail "head_sha with git: $(field "$WORK/e.json" "d['repo']['head_sha']")"
[[ "$(field "$WORK/e.json" "d['repo'].get('workspace_fingerprint')")" == "$fp_c" ]] && pass "the fingerprint is present with git and equals the same tree's without it" || fail "with git: $(field "$WORK/e.json" "d['repo'].get('workspace_fingerprint')") vs $fp_c"

echo ""
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
