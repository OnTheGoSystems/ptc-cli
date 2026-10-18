#!/bin/bash
# The defect regression scenario suite, CLI half (the rspec half: backend/spec/guide/scenarios/*.yml, run by
# scenario_runner_spec.rb). Every historical live-run finding has a replayable scenario: cli/tests/scenarios/*.sh, one
# file per finding or group, starting with header lines
#   # covers: <finding IDs, space separated>
#   # status: fixed|open
#   # open: <ID>            (when open)
#   # source: <evidence pointer>
#   # title: <one line>
# A scenario exits 0 when it passes. Status works like rspec pending: an open scenario that FAILS is "pending <ID>" and
# does not fail the run; an open scenario that PASSES fails the run (the finding is fixed: flip its status); a fixed
# scenario must pass.
# The registry backend/spec/guide/scenarios/registry.yml names every finding; each one marked `scenario: cli` must be
# covered by some scenario's `# covers:` line.
#   bash tests/test-guide-scenarios.sh [scenario-file...]   (no argument: every scenario)
set -uo pipefail
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCEN_DIR="$TEST_DIR/scenarios"
readonly REGISTRY="$TEST_DIR/../../backend/spec/guide/scenarios/registry.yml"
LOGS=$(mktemp -d); trap 'rm -rf "$LOGS"' EXIT

header() { sed -n "s/^# $1: *//p" "$2" | head -1; }

npass=0; npending=0; nfail=0; failures=()
files=("$@")
[[ ${#files[@]} -eq 0 ]] && files=("$SCEN_DIR"/[!_]*.sh)
covered=" "
for f in "$SCEN_DIR"/[!_]*.sh; do covered+="$(header covers "$f") "; done

for f in "${files[@]}"; do
    name=$(basename "$f" .sh)
    status=$(header status "$f"); covers=$(header covers "$f"); open=$(header open "$f")
    if [[ -z "$covers" || ( "$status" != "fixed" && "$status" != "open" ) || ( "$status" == "open" && -z "$open" ) ]]; then
        echo "[FAIL] $name: bad header (covers: '$covers', status: '$status', open: '$open')"; nfail=$((nfail + 1)); failures+=("$name"); continue
    fi
    bash "$f" >"$LOGS/$name.log" 2>&1; rc=$?
    if [[ "$status" == "fixed" ]]; then
        if [[ $rc -eq 0 ]]; then echo "[PASS] $name ($covers)"; npass=$((npass + 1))
        else echo "[FAIL] $name ($covers): a fixed finding regressed"; grep -E '^\[FAIL\]' "$LOGS/$name.log" | sed 's/^/    /'; tail -3 "$LOGS/$name.log" | sed 's/^/    | /'
             nfail=$((nfail + 1)); failures+=("$name"); fi
    else
        if [[ $rc -ne 0 ]]; then echo "pending $open ($name: still open)"; grep -E '^\[FAIL\]' "$LOGS/$name.log" | head -3 | sed 's/^/    /'; npending=$((npending + 1))
        else echo "[FAIL] $name: open scenario for $open PASSES - fixed? flip status to fixed"; nfail=$((nfail + 1)); failures+=("$name"); fi
    fi
done

if [[ $# -eq 0 ]]; then
    if [[ -f "$REGISTRY" ]]; then
        missing=()
        while IFS= read -r id; do
            [[ "$covered" == *" $id "* ]] || missing+=("$id")
        done < <(sed -nE 's/^  ([A-Z]+-[0-9]+): *\{ *scenario: *cli[,} ].*/\1/p' "$REGISTRY")
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "[FAIL] registry: scenario: cli findings with no '# covers:' line: ${missing[*]}"; nfail=$((nfail + 1)); failures+=("registry")
        else
            echo "[PASS] registry: every scenario: cli finding is covered"
        fi
    else
        echo "note: $REGISTRY absent - the registry coverage check is skipped"
    fi
fi

echo "scenarios: $npass passed, $npending pending (open), $nfail failed"
[[ $nfail -eq 0 ]]
