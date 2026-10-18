#!/bin/bash
# covers: WF-16
# status: fixed
# source: tasks/translation-guide/review/wpml-manual/RUN-LOG.md stops 30/32/35 (3 suite jobs green, no ptc/translations-* branch, no MR)
# title: a suite GitLab job (script starts with `cd <product dir>`) stages, commits and pushes the translations it wrote
# The job's own delivery block (rendered by render_ci_gitlab, the guide's template byte for byte) runs against a real CLI
# run on the mock, in a temp repository: once from the product directory (the suite job: Guide::Tasks::CommitConfig
# suite_gitlab_yaml inserts `- cd <dir>`), once from the repository root (the single-product job). A manifest whose
# paths cannot be staged must fail the job loudly, never leave it green without a merge request.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.bash"
start_mock M 19887

# The `- |` delivery block of the job, de-indented (git config ... fi).
render_gitlab_recipe | python3 -c '
import sys
lines = sys.stdin.read().split("\n")
start = next(i for i, l in enumerate(lines) if l == "    - |")
out = []
for l in lines[start + 1:]:
    if not l.startswith("      "):
        break
    out.append(l[6:])
print("\n".join(out))' > "$WORK/delivery.sh"
grep -q 'pathspec-from-file=/tmp/ptc-written' "$WORK/delivery.sh" || { fail "no manifest staging in the delivery block"; finish; exit 1; }

STUB="$WORK/ptc-cli-stub.sh"   # the job's /tmp/ptc-cli.sh after the run: mr-description / delivery-commit only
printf '#!/bin/sh\necho "stub $*" >> "%s/stub.log"\n' "$WORK" > "$STUB"; chmod +x "$STUB"

# run_job NAME CWD_SUFFIX: a fresh repo with product dir prod/, the real CLI run (cwd = repo/CWD_SUFFIX), then the block.
run_job() {
    local name="$1" sub="$2" repo="$WORK/$1" man="$WORK/$1.written"
    mkdir -p "$repo/prod/config/locales"
    printf 'en:\n  a: "Hello a"\n' > "$repo/prod/config/locales/a.en.yml"
    printf 'source_locale: en\nfiles:\n  - file: config/locales/a.en.yml\n    output: config/locales/a.{{lang}}.yml\n' > "$repo/prod/.ptc-config.yml"
    git -C "$repo" init -q -b main && git -C "$repo" -c user.email=t@t -c user.name=t add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
    if [[ "$sub" == "." ]]; then  # the single-product job: the config at the repository root
        mv "$repo/prod/.ptc-config.yml" "$repo/.ptc-config.yml"; sed -i 's#config/locales#prod/config/locales#g' "$repo/.ptc-config.yml"
        git -C "$repo" -c user.email=t@t -c user.name=t commit -qam root-config
    fi
    : > "$man"
    (cd "$repo/$sub" && PTC_API_TOKEN=t "$CLI" --config-file .ptc-config.yml --api-url "$API_M" --monitor-interval 1 --written-manifest "$man") >"$WORK/$name.cli.out" 2>&1
    sed -e "s#/tmp/ptc-written#$man#g" -e "s#/tmp/ptc-cli.sh#$STUB#g" -e "s#/tmp/ptc-check.json#$WORK/check.json#g" "$WORK/delivery.sh" > "$WORK/$name.block.sh"
    (cd "$repo/$sub" && git() { if [ "$1" = push ]; then echo "PUSHED"; return 0; fi; command git "$@"; } \
        && export -f git && CI_DEFAULT_BRANCH=main CI_COMMIT_SHA=abc CI_SERVER_HOST=h CI_PROJECT_PATH=p ptc_stopped="" bash "$WORK/$name.block.sh") >"$WORK/$name.job.out" 2>&1
    echo $? > "$WORK/$name.rc"
}

run_job suite prod
[[ -s "$WORK/suite.written" ]] && pass "suite: the CLI run wrote and recorded translations" || fail "suite: empty manifest: $(tail -5 "$WORK/suite.cli.out")"
committed=$(git -C "$WORK/suite" log -1 --name-only --format= ptc/translations 2>/dev/null)
grep -q '^prod/config/locales/a\.de\.yml$' <<<"$committed" && pass "suite job (cwd = product dir): the translations are committed on ptc/translations" \
    || fail "suite job committed nothing (rc $(cat "$WORK/suite.rc")): $(head -c 600 "$WORK/suite.job.out")"
grep -q PUSHED "$WORK/suite.job.out" && pass "suite job pushes (merge request)" || fail "suite job did not push"
grep -q 'delivery-commit --commit' "$WORK/stub.log" 2>/dev/null && pass "suite job reports the delivery commit" || fail "no delivery-commit report"

: > "$WORK/stub.log"
run_job single .
committed=$(git -C "$WORK/single" log -1 --name-only --format= ptc/translations 2>/dev/null)
grep -q '^prod/config/locales/a\.de\.yml$' <<<"$committed" && pass "single-product job (cwd = repository root): committed" \
    || fail "single job committed nothing: $(head -c 600 "$WORK/single.job.out")"

# The loud guard: a manifest naming written files that end up unstaged (here product-relative paths) fails the job.
G="$WORK/guard"; mkdir -p "$G/prod"; git -C "$G" init -q -b main; echo x > "$G/prod/keep"; git -C "$G" add -A; git -C "$G" -c user.email=t@t -c user.name=t commit -qm init
echo 'de: {}' > "$G/prod/written.de.yml"; printf 'written.de.yml\0' > "$WORK/guard.written"
sed -e "s#/tmp/ptc-written#$WORK/guard.written#g" -e "s#/tmp/ptc-cli.sh#$STUB#g" -e "s#/tmp/ptc-check.json#$WORK/check.json#g" "$WORK/delivery.sh" > "$WORK/guard.block.sh"
(cd "$G" && CI_DEFAULT_BRANCH=main CI_COMMIT_SHA=abc ptc_stopped="" bash "$WORK/guard.block.sh") >"$WORK/guard.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -qiE "not staged|nothing was staged" "$WORK/guard.out" && pass "written files left unstaged fail the job loudly (rc $rc)" \
    || fail "unstaged written files left the job green (rc $rc): $(cat "$WORK/guard.out")"
finish
