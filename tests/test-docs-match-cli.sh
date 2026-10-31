#!/bin/bash

# Org #7312: the docs show only commands the CLI has.
#
# Every fenced command line in cli/README.md and cli/docs/*.md that runs the CLI
# (`ptc ...`, `ptc-cli.sh ...`, or a path ending in ptc-cli.sh such as
# `.ptc/bin/ptc-cli.sh ...`; also after a `|` or `VAR=value` prefix) is checked
# against the script: its sub-command is one main() dispatches, its second word
# (for commands that take one, e.g. `guide next`) is a case label of the script,
# and each `--flag` it shows is a case label of the script's option parsing.
#
# Deterministic, no network, nothing executed from the docs.
# Usage: bash cli/tests/test-docs-match-cli.sh [PATH/TO/ptc-cli.sh]
# (default: this tree's cli/ptc-cli.sh)

set -uo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$TEST_DIR")"
CLI="${1:-$PROJECT_DIR/ptc-cli.sh}"

if [[ ! -f "$CLI" ]]; then
    echo "FAIL: CLI script not found: $CLI"
    exit 1
fi

DOCS=("$PROJECT_DIR/README.md")
for f in "$PROJECT_DIR"/docs/*.md; do DOCS+=("$f"); done

python3 - "$CLI" "${DOCS[@]}" <<'PY'
import re, shlex, sys

cli_path, docs = sys.argv[1], sys.argv[2:]
src = open(cli_path, encoding="utf-8").read()
version = (re.search(r'^readonly VERSION="([^"]+)"', src, re.M) or [None, "?"])[1]

# main(): the sub-commands it dispatches (`word) shift; cmd_...`) and `init` (handled before the case).
m = re.search(r'^main\(\) \{\n(.*?)^\}', src, re.S | re.M)
if not m:
    print("FAIL: no main() in %s" % cli_path); sys.exit(1)
main_body = m.group(1)
subcommands = set(re.findall(r'^\s*([a-z][a-z-]*)\)\s*shift;\s*cmd_', main_body, re.M))
subcommands |= set(re.findall(r'"\$\{1:-\}" == "([a-z][a-z-]*)"', main_body))
# Sub-commands whose second word is itself a command (`guide next`, `glossary validate`, ...).
TWO_WORD = {"auth", "guide", "config", "describe", "lint", "audit", "glossary"}

def is_case_label(word):
    # `word)`, `word|other)`, `a|word)`, or a `== "word"` / `!= "word"` comparison.
    w = re.escape(word)
    return bool(re.search(r'(^|[\s(|])' + w + r'(=\*)?[)|]', src, re.M)
                or re.search(r'[!=]= "' + w + r'"', src))

cli_start = re.compile(r'^(?:ptc|(?:\S*/)?ptc-cli\.sh)$')

def command_lines(path):
    in_fence = False
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        s = line.strip()
        if s.startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence or not s:
            continue
        for seg in s.split(" | "):
            try:
                words = shlex.split(seg, comments=True)
            except ValueError:
                words = seg.split()
            while words and re.match(r'^[A-Z_][A-Z0-9_]*=', words[0]):
                words = words[1:]          # VAR=value prefixes
            if words and cli_start.match(words[0]):
                yield n, seg, words[1:]

checked, failures = 0, []
for path in docs:
    rel = path.split("/cli/", 1)[-1]
    for n, text, args in command_lines(path):
        checked += 1
        probs = []
        words = [a.strip("[]") for a in args]
        words = [w[:-3] if w.endswith("...") else w for w in words]
        rest = list(words)
        if rest and rest[0] in ("-v", "--verbose") and len(rest) > 1 and not rest[1].startswith("-"):
            rest = rest[1:]
        if rest and not rest[0].startswith("-"):
            sub = rest[0]
            if sub not in subcommands:
                probs.append("sub-command '%s' is not dispatched by main()" % sub)
            elif sub in TWO_WORD:
                if len(rest) < 2 or rest[1].startswith("-"):
                    if sub != "guide" or len(rest) >= 2:
                        probs.append("'%s' needs its second word" % sub)
                else:
                    second = rest[1].split("|")
                    for w in second:
                        if not is_case_label(w):
                            probs.append("'%s %s' is not a case label in the script" % (sub, w))
        for w in words:
            for f in re.findall(r'(?:^|\|)(--[a-z][a-z0-9-]*)', w):
                if not is_case_label(f):
                    probs.append("flag %s is not parsed by the script" % f)
        if probs:
            failures.append("%s:%d: %s\n    -> %s" % (rel, n, text, "; ".join(probs)))

print("CLI: %s (version %s)" % (cli_path, version))
print("sub-commands dispatched by main(): %s" % " ".join(sorted(subcommands)))
print("docs: %s" % " ".join(p.split("/cli/", 1)[-1] for p in docs))
print("command lines checked: %d" % checked)
for f in failures:
    print("FAIL " + f)
if checked == 0:
    print("FAIL: no command line found in the docs"); sys.exit(1)
if failures:
    print("RESULT: %d of %d command lines name something the CLI does not have" % (len(failures), checked)); sys.exit(1)
print("RESULT: PASS (%d command lines, every sub-command and --flag found in the script)" % checked)
PY
