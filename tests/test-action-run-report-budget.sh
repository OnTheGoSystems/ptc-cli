#!/bin/bash
# PL-2 (WPML lab runs 20-21: once the branch differed from its merge base in hundreds of files, `ptc guide action-run` was
# refused "payload too large" at any PTC_FILES_SAMPLE_LIMIT; the agent had to find the knob itself). The report measures
# itself: over its budget (PTC_REPORT_BUDGET_BYTES, 4.5 MB by default) the named and changed files' bytes go to the
# PATCH guide/action_runs/:id/files_sample batches, files_sha still names every path; a scan too large alone for one report
# (PTC_REPORT_LIMIT_BYTES, PTC's 5 MB) is not sent: the cause and the `-d <product dir>` remedy. Runs against the mock.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d)
MOCK_PID=""
cleanup() { [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT

PORT=19769
python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && { echo "port $PORT busy"; exit 1; }
BODIES="$WORK/bodies"; mkdir -p "$BODIES"
PTC_MOCK_PORT=$PORT PTC_MOCK_BODY_DIR="$BODIES" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
API="http://127.0.0.1:$PORT/api/v1/"
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN
      -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u PTC_REPORT_BUDGET_BYTES -u PTC_REPORT_LIMIT_BYTES)

# A repository with one product (plugin/, a composer.json): two source files of 3000 bytes (one batch each at a 5000-byte
# PTC_FILES_SAMPLE_LIMIT) and two named code files of 30000 bytes each (--file).
T="$WORK/tree"; mkdir -p "$T/plugin/locales" "$T/plugin/app"
git -C "$T" init -q
echo '{"name": "acme/plugin"}' > "$T/plugin/composer.json"
mk() { python3 -c "import sys; open(sys.argv[1], 'w').write('{\"k\": \"' + sys.argv[3] * (int(sys.argv[2]) - 10) + '\"}\n')" "$@"; }
mk "$T/plugin/locales/a.en.json" 3000 x; mk "$T/plugin/locales/b.en.json" 3000 y
mk "$T/plugin/app/x.php" 30000 p; mk "$T/plugin/app/y.php" 30000 q
{
    echo "source_locale: en"; echo "files:"
    for f in a b; do printf '  - file: plugin/locales/%s.en.json\n    output: plugin/locales/%s.{{lang}}.json\n' "$f" "$f"; done
    echo "guide:"; echo "  project_id: 42"
} > "$T/.ptc-config.yml"

run() {  # $1: label; the rest: env assignments. Fresh body dir per run.
    local label="$1"; shift
    rm -f "$BODIES"/*
    "${NOCI[@]}" "$@" PTC_FILES_SAMPLE_LIMIT=5000 PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" \
        --file plugin/app/x.php --file plugin/app/y.php >"$WORK/$label.out" 2>&1
    echo $? > "$WORK/$label.rc"
}

check() {  # $1: label, $2: the python checks
    python3 - "$BODIES" "$T" "$@" > "$WORK/checks.txt" <<'PY'
import hashlib, json, os, sys
bodies, tree, label, mode = sys.argv[1:5]
rp = os.path.join(bodies, "guide_action_runs.json")
report = json.load(open(rp))["body"] if os.path.exists(rp) else None
bp = os.path.join(bodies, "files_sample_batches.jsonl")
batches = [json.loads(l)["body"] for l in open(bp)] if os.path.exists(bp) else []
named = {p: open(os.path.join(tree, p), encoding="utf-8").read() for p in ("plugin/app/x.php", "plugin/app/y.php")}
def check(ok, what):
    print(("PASS " if ok else "FAIL ") + f"{label}: {what}")
in_batches = {p: e for b in batches for p, e in b["files_sample"].items()}
if mode == "guard":
    check(report is not None, "the report reached the mock")
    report = report or {"files_sample": {}, "files_sha": {}}
    check(sorted(report["files_sample"]) == ["plugin/app/x.php", "plugin/app/y.php", "plugin/locales/a.en.json"],
          f"under the default budget the report carries the named files and the first batch, as before: {sorted(report['files_sample'])}")
    check(sorted(in_batches) == ["plugin/locales/b.en.json"], f"only the further source batch follows: {sorted(in_batches)}")
    check("files_sample_pending" not in report and not any("last" in b for b in batches), "no pending mark, no last mark (today's report)")
elif mode == "budget":
    check(report is not None, "the report reached the mock")
    report = report or {"files_sample": {}, "files_sha": {}}
    size = len(json.dumps(report, sort_keys=True).encode("utf-8"))
    check(size <= 40000, f"the report body is under the 40000-byte budget: {size} bytes")
    check(not set(named) & set(report["files_sample"]), f"the report carries no named bytes: {sorted(report['files_sample'])}")
    for p, data in named.items():
        e = in_batches.get(p)
        check(e is not None and e["content"] == data, f"{p}: its bytes travel in a files_sample batch")
        sha = hashlib.sha256(data.encode("utf-8")).hexdigest()
        check(report["files_sha"].get(p) == sha and (e or {}).get("sha") == sha, f"{p}: files_sha names it, at the sha of the batch content")
    check(all(len(b["files_sample"]) == 1 for b in batches if set(b["files_sample"]) & set(named)),
          "a named file over PTC_FILES_SAMPLE_LIMIT goes alone in its batch")
    check(sorted(set(report["files_sample"]) | set(in_batches)) == sorted(["plugin/locales/a.en.json", "plugin/locales/b.en.json", *named]),
          f"every source and named file reaches PTC: {sorted(set(report['files_sample']) | set(in_batches))}")
    check(report.get("files_sample_pending") is True, "the report says copies follow it (files_sample_pending: true)")
    check(bool(batches) and batches[-1].get("last") is True and not any("last" in b for b in batches[:-1]),
          f"only the last batch is marked last: {[b.get('last') for b in batches]}")
elif mode == "scan":
    check(report is None, "no report is sent")
    check(not batches, "no batch is sent")
PY
    while IFS= read -r line; do
        case "$line" in PASS*) pass "${line#PASS }" ;; FAIL*) fail "${line#FAIL }" ;; esac
    done < "$WORK/checks.txt"
}

# Guard: a small repository's report is today's (named bytes in the report, the source batches after it).
run guard
[[ $(cat "$WORK/guard.rc") -eq 0 ]] && pass "guard: the run is reported (exit 0)" || fail "guard: exit $(cat "$WORK/guard.rc"): $(tail -3 "$WORK/guard.out")"
check guard guard

# Over the budget: the named bytes go to the batches, the report stays under it.
run budget PTC_REPORT_BUDGET_BYTES=40000
[[ $(cat "$WORK/budget.rc") -eq 0 ]] && pass "budget: the run is reported (exit 0)" || fail "budget: exit $(cat "$WORK/budget.rc"): $(tail -3 "$WORK/budget.out")"
check budget budget

# The scan alone over PTC's limit for one report: nothing is sent; the cause and the product-dir remedy.
run scan PTC_REPORT_BUDGET_BYTES=500 PTC_REPORT_LIMIT_BYTES=1000
[[ $(cat "$WORK/scan.rc") -ne 0 ]] && pass "scan: exit non-zero" || fail "scan: exit 0"
grep -q "the repository scan alone is .* too large for one run report" "$WORK/scan.out" && pass "scan: the cause is printed" \
    || fail "scan: no cause line: $(tail -3 "$WORK/scan.out")"
grep -qF "ptc guide action-run -d plugin" "$WORK/scan.out" && pass "scan: the remedy names the product directory" \
    || fail "scan: no -d plugin remedy: $(tail -3 "$WORK/scan.out")"
check scan scan

echo
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
