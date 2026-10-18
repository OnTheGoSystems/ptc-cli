# Changelog

## Unreleased

- GAP-G24 (wpml-core MR !939: `sitepress.pot` regenerated without the add-ons silently lost 235-343 strings): `ptc scan
  --json` adds `usages_unmatched`, `{text domain => {calls: [{msgid, msgctxt, path, line, text}], total, truncated}}`: every
  gettext call whose (msgctxt, msgid) is in no census template of its text domain (`""` = no or a variable domain), so PTC's
  template freshness check sees strings missing from every template; dynamic literals and calls that do not close on their
  line are not listed; at most 500 calls per domain (`truncated: true`, `total` counts all). Empty when the repository has no
  gettext template.
- GAP-G12 (WPML lab run 6; CLI-16, AGD-4): `ptc guide action-run` sends EVERY configured source file to PTC. Sitepress has
  41 source files; the report carried 36 (`PTC_FILES_SAMPLE_LIMIT`, 204800 bytes, was a budget for the whole run), so PTC
  quoted 36 ("PARTIAL quote ... no content reached PTC") and fell back to the local estimate. The limit now bounds one
  request: the report carries the first batch, and every further batch (at most the same bytes, in file order; a file over
  the limit alone, never in the report) goes to `PATCH guide/action_runs/RUN/files_sample` as `{path: {content, sha}}`. The
  job log says `Sent every source file to PTC: the report and N batch(es) ...`, or warns per batch PTC did not take, naming
  its files (the run stays reported, exit code unchanged).
- GAP-G11 (WPML lab run 6; CLI-21, POL-4): `ptc scan` takes an English source catalogue named `.po` (no language in its
  name, header `Language` empty / `en` / `en_US`, every msgstr empty) as the source of a `po` resource set, like a `.pot`,
  when no `.pot` claims its directory or domain; its languages come from the `.po` / `.mo` siblings as before. Run 6 listed
  no set for wpml-cms-nav and wpml-sticky-links (`locale/orig/<domain>.po` beside `locale/<domain>-de_DE.mo`), so PTC set up
  3 products of 5. A `.po` with translations is unchanged. The census adds `runtime.gettext_domains` (`{domain, calls,
  files}` per text domain) so PTC can name a domain no catalogue covers, and `ptc audit strings --runtime` counts a
  source `.po` as its domain's catalogue.
- GAP-F5 (CLI-20; the CLI side of GAP-F4): `guide wait` and `guide status` print PTC's `waiting` text (what PTC still
  works on before the next task, e.g. "PTC is grouping the strings of N file(s) in the background ...") as one line,
  `PTC: <text>`; only `--json` showed it. `guide next` keeps its own "PTC is waiting:" line. Exit codes unchanged.
- GAP-F3 (WPML lab run 4; CLI-19, POL-4): `ptc guide wait` that reaches its `--timeout` asks PTC once more
  (`timeout_s` 0) and prints the task's stored verdict: `PTC's stored verdict on task TASK: needs_more`, its reasons
  (at most 20, then `and N more reasons (M in all)`; PTC's own capped list is printed whole) and PTC's hint. It printed
  only "no verdict yet", and the agent had to query the task by hand for the not-proved paths. Exit code unchanged (3).
- GAP-G6 (WPML lab run 4; CLI-16, POL-116): `ptc guide action-run` resolves the project it asks for its paths
  (`GET guide/run_paths`) from `PTC_GUIDE_PROJECT_ID` / `PTC_PROJECT_ID`, then `--project-id`, then the config's
  `guide.project_id` (the id every handed-out config carries, the one a CI checkout has), then `.ptc/session.json`,
  and prints one line in the job log: `guide run paths: project N (<source>), K path(s) served by PTC, M named in all.`
  A PTC that gives no list (its HTTP code, no answer) or a run with no project is a warning on that line; it was
  silent, and the first sign was PTC's "<path> was not reported by the CI run".
- GAP-G5 (WPML lab run 4; POL-4, POL-11): `ptc describe apply` never writes a `translators:` note inside a string.
  Run 4 put two notes on the line above a call concatenated into a multi-line single-quoted PHP string, i.e. inside
  the literal, where the String Translation page would have shown them as text; notes above a `? __(` / `: __(`
  continuation or above a JSX element line were not extracted (or became JSX text). The note now goes where the
  extractors read it (`wp i18n make-pot`, `@wordpress/babel-plugin-makepot`): on its own line above the call's line
  when that line starts in PHP code, or (JS/TS) starts with the call; `<?php /* */ ?>` above a PHP template line;
  otherwise directly before the call on its line (`return /* translators: … */ __(`). Only a gettext call in code whose
  msgid is the description's key counts: a msgid that only appears in a string, heredoc or comment, or inside a longer
  msgid, is skipped with the reason. After placing, each file is checked: a note that would not be a comment, or a PHP
  file that `php -l` (when installed) no longer parses, means the file is not written and its notes are skipped with
  the reason.
- GAP-F15-R (Eran 2026-10-15; CI-7, CLI-8, POL-4): a file PTC served with strings it did not translate (status `failed`,
  or `completed` with untranslated strings in the status answer's `strings` counts) is written and listed delivered (✓)
  as before GAP-F15, and the run's exit is unaffected (0 when nothing else is wrong). Failed strings never error a
  delivery: PTC notifies its own team to investigate. The "Partly translated in PTC" list and its exit 5 are gone.
- GAP-G2 (WPML lab run 3): `ptc scan --json` lists every `.gitignore` of the checkout (`gitignore`: path, pattern lines
  with their line numbers), so PTC checks the outputs of the configs it generates by the rule `ptc config validate`
  applies and hands out the `.gitignore` exceptions with them; `config validate` keeps its own check.
- GAP-CI-2 (CI-16; WPML lab run 2): inside GitLab CI the monitor bound is always capped at the job's limit
  (`CI_JOB_TIMEOUT` is the effective one, a runner's maximum included); without it, `PTC_CI_JOB_TIMEOUT_SECONDS` or
  GitLab's 60-minute default, and an unreadable `CI_JOB_STARTED_AT` counts from the CLI's start. The monitor line counts
  files done in PTC (`<done> of <sent> file(s) done in PTC (status check <n>)`) instead of the check budget, and PTC's
  `reviewing` state reads `V` and "translated in PTC; its review holds the delivery until it finishes" (it read U).
- LR2-F6: `ptc describe apply` writes PTC's description as the `translators:` note byte for byte; it no longer drops
  paths or cuts the note at 200 characters with "..." (WPML lab run 2: most notes came out garbled). PTC composes the
  note within the comment rule; a description naming a path, a source file, a function or a `snake_case` identifier is
  skipped with the reason.
- LR2-F7: `ptc guide action-run --file PATH` reads PATH relative to the run directory (`-d`), the base of a suite
  product's task paths, and reports it under its repository-root path; a missing, outside or oversized `--file` stops the
  run with the reason (it was dropped in silence). A path a task named is looked up from the repository root, then
  under the run directory.
- LR2-F12: `ptc guide upload-sources -d <product>` keyed its ledger by the product directory twice
  (`wpml-cms-nav/wpml-cms-nav/...`, a traceback, then success); the ledger is keyed by the repository-root path, a rerun
  skips the files PTC holds, and a failure to record the upload exits non-zero.
- The Python helper is read from stdin: as one `-c` argument it reached Linux's 128 KiB per-argument limit.

## 1.5.1

- WF-11: a source file the commit changed is no longer sent in full beyond the sample cap; the run report carries
  its digest (`files_sha`) and PTC reads its stored upload by that sha. A changed non-source file (a code file a
  source fix edits) is sent with its bytes, up to 1 MB each and 2 MB together; one left out is named on stderr.
- WF-20: a file PTC reports completed while its download is still being prepared is listed as "completed in PTC;
  the download is still being prepared", never as "(completed)" among the files still translating.

## 1.5.0

- An upload PTC answers with `code: suite_setup_pending` (the project's suite is still being set up: stored, not
  translated) is reported, not waited for: the run prints PTC's message, a line saying the translation starts by
  itself once every project of the suite is set up, and the files held; it does not poll them and exits `0` when
  every file was held. Files started in the same run are monitored as before.
