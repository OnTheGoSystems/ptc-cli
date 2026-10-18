#!/bin/bash
# GAP-G12 (WPML lab run 6: 5 of sitepress' 41 source files never reached PTC, so PTC's estimate quoted 36 and fell back
# to the local estimate): `ptc guide action-run` sends EVERY configured source file. PTC_FILES_SAMPLE_LIMIT bounds one
# request, never the run: the report carries the first batch, each further batch (at most the same budget; a file over it
# alone) goes to PATCH guide/action_runs/:run_id/files_sample, in file order, each entry {content, sha}. Runs against the mock.
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLI="$(dirname "$TEST_DIR")/ptc-cli.sh"
readonly MOCK="$TEST_DIR/mock_ptc_api.py"
passed=0; failed=0
pass() { echo "[PASS] $*"; passed=$((passed + 1)); }
fail() { echo "[FAIL] $*"; failed=$((failed + 1)); }
WORK=$(mktemp -d); BODIES="$WORK/bodies"; mkdir -p "$BODIES"
MOCK_PID=""
cleanup() { [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT

PORT=19767
python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && { echo "port $PORT busy"; exit 1; }
PTC_MOCK_PORT=$PORT PTC_MOCK_BODY_DIR="$BODIES" python3 "$MOCK" >>"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.4).close()" 2>/dev/null && break; sleep 0.3; done
API="http://127.0.0.1:$PORT/api/v1/"
NOCI=(env -u GITHUB_SHA -u GITHUB_REF_NAME -u GITHUB_ACTIONS -u GITLAB_CI -u CI_COMMIT_SHA -u CI_COMMIT_REF_NAME -u PTC_CI_ID_TOKEN -u PTC_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN)

# Five source files, 13.5 KB in all, against a 5000-byte budget: a (3000) | b (3000) | big (9000, over the budget: alone) |
# c (3000) + d (1500). The report carries a; three batches follow: b, big, c+d.
T="$WORK/tree"; mkdir -p "$T/locales"
mk() { python3 -c "import sys; open(sys.argv[1], 'w').write('{\"k\": \"' + 'x' * (int(sys.argv[2]) - 10) + '\"}\n')" "$T/locales/$1.en.json" "$2"; }
mk a 3000; mk b 3000; mk big 9000; mk c 3000; mk d 1500
python3 -c "import sys; open(sys.argv[1], 'w').write('{\"k\": \"Grüße ✓ ' + 'y' * 1400 + '\"}\n')" "$T/locales/d.en.json"
{
    echo "source_locale: en"; echo "files:"
    for f in a b big c d; do printf '  - file: locales/%s.en.json\n    output: locales/%s.{{lang}}.json\n' "$f" "$f"; done
    echo "guide:"; echo "  project_id: 42"
} > "$T/.ptc-config.yml"

"${NOCI[@]}" PTC_FILES_SAMPLE_LIMIT=5000 PTC_ORG_TOKEN=org-token "$CLI" guide action-run --api-url "$API" -d "$T" >"$WORK/ar.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "the run is reported (exit 0)" || fail "action-run exit $rc: $(tail -5 "$WORK/ar.out")"

python3 - "$BODIES" "$T" > "$WORK/checks.txt" <<'PY'
import hashlib, json, os, sys
bodies, tree = sys.argv[1], sys.argv[2]
report = json.load(open(os.path.join(bodies, "guide_action_runs.json")))["body"]
path = os.path.join(bodies, "files_sample_batches.jsonl")
batches = [json.loads(l) for l in open(path)] if os.path.exists(path) else []
want = {f"locales/{f}.en.json": open(os.path.join(tree, f"locales/{f}.en.json"), encoding="utf-8").read() for f in "a b big c d".split()}
def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what)
check(sorted(report["files_sample"]) == ["locales/a.en.json"], f"the report carries the first batch only: {sorted(report['files_sample'])}")
check(len(batches) == 3, f"3 further requests (PATCH .../files_sample), got {len(batches)}")
check([sorted(b["body"]["files_sample"]) for b in batches] == [["locales/b.en.json"], ["locales/big.en.json"], ["locales/c.en.json", "locales/d.en.json"]],
      f"batches in file order, the file over the budget alone: {[sorted(b['body']['files_sample']) for b in batches]}")
check(all(b["run_id"] == 1 for b in batches), "every batch goes to the run PTC named (run_id 1)")
check(all(b["body"].get("project_id") == 42 for b in batches), "every batch names the project (the agent token's door needs it)")
small = [b for b in batches if "locales/big.en.json" not in b["body"]["files_sample"]]
check(all(sum(len(e["content"].encode()) for e in b["body"]["files_sample"].values()) <= 5000 for b in small), "each batch's content is within PTC_FILES_SAMPLE_LIMIT")
got = dict(report["files_sample"])
for b in batches:
    for p, e in b["body"]["files_sample"].items():
        got[p] = e["content"]
        check(e["sha"] == hashlib.sha256(e["content"].encode("utf-8")).hexdigest(), f"{p}: sha is the sha256 of its content")
check(got == want, f"every source file reached the mock with its content: {sorted(got)}")
PY
while IFS= read -r line; do
    case "$line" in PASS*) pass "${line#PASS }" ;; FAIL*) fail "${line#FAIL }" ;; esac
done < "$WORK/checks.txt"
grep -q "Sent every source file to PTC: the report and 3 batch(es)" "$WORK/ar.out" && pass "the job log says every source file was sent" \
    || fail "no 'Sent every source file' line: $(grep -i batch "$WORK/ar.out" | head -3)"

echo
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
