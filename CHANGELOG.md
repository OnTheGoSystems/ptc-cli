# Changelog

## Unreleased

## 1.5.6

- Org #7188 (CLI-27; production live test 27 Oct 2026): every door that takes `--project-id` (`guide action-run`, `glossary validate --remote`, `sync`, `guide delivery-commit`, the guide session doors) resolves the project once: the flag, `PTC_PROJECT_ID` / `PTC_GUIDE_PROJECT_ID`, the config's `guide.project_id`, the local cache `.ptc/session.json` (every successful guide call now refreshes it), then PTC's open session for the checkout's origin; `-v` / `PTC_VERBOSE=true` prints `project <id> from <source>`. The guide doors that take `--session-id` fall back to the cached session; with no token they print the token error instead of "No guide session", and a failed lookup names PTC's HTTP code. The guide's install line puts the CLI at `.ptc/bin/ptc-cli.sh` (git-ignored by `.ptc/.gitignore`), so a later sync needs no reinstall.
- Org #7184 (CLI-24; production live test 27 Oct 2026: agents stopped to ask for a token the user had already pasted into the MCP command): every door that needs the agent token (the translate pipeline, `ptc sync`, every `ptc guide` sub-command, `ptc estimate`) reads it from `--api-token`, `PTC_API_TOKEN`, `PTC_AGENT_TOKEN` (first set wins; the legacy `PTC_ORG_TOKEN` is still accepted, deprecated), then the CLI's own credentials file `${XDG_CONFIG_HOME:-~/.config}/ptc/credentials` (one line `PTC_API_TOKEN=<token>`), read only at mode 600 or stricter: a looser file is refused with one line naming its mode. The token page's snippet writes that file. With no token the error names `PTC_API_TOKEN` / `PTC_AGENT_TOKEN`, `--api-token` and the file. `-v` names the token's source, never its value. The CLI never reads an MCP client's configuration.
- Org #6647: `ptc scan` with a `.ptc-config.yml` that has no `source_locale:` line scans with the `en` default. Before, the read of that line failed on no match under the script's strict mode, so `ptc scan --json` printed nothing and stopped with exit 1.
- RR-2 (Eran 24 Oct, WPML lab run 22: a time-limited CI job is re-run): a re-run of a CI job (GitLab "Retry this job", GitHub "Re-run failed jobs") keeps every file the first job delivered and adds the rest. The resume key is still the pipeline / run id, but a file is skipped only when its outputs are on disk with the sha this run wrote; in a fresh checkout it is downloaded again (PTC keeps the delivery, nothing is translated again), and skipped outputs are listed in `--written-manifest` too, so the job's commit carries every delivered file and the merge request never shrinks to the re-run's files. Before, the retry skipped them without writing them. Exit 7's option (a) names the one click per channel and says the re-run keeps what this run delivered. ptc-action sizes its monitor bound from the estimate as the GitLab job is (about 250 words a minute plus 15 minutes, 45 to 170) when nothing names one. The stopped run's first merge / pull request already says the delivery is not complete, names the files still translating and the one click (limit note: the PR body, the GitLab MR description); with PTC's own sentence in the check it is said once, and ptc-action posts the findings comment on exit 7.

## 1.5.5

- PL-2 (WPML lab runs 20-21: a branch hundreds of files from its merge base was refused "payload too large" at any `PTC_FILES_SAMPLE_LIMIT`): `ptc guide action-run` measures its own run report and keeps it under a budget (4.5 MiB) below PTC's 5 MiB limit on one report. Over the budget, the copies of the named and changed files, then the first source batch, move to the `files_sample` batches that follow the report; `files_sha` still names every path. The report then carries `files_sample_pending: true` and the last batch is marked `last`, so a proof missing one of the moved copies waits for it instead of refusing. The CLI prints `The run report is kept under N bytes: M batch(es) of file copies follow it.`
- PL-2 (same runs): a repository scan too large for one report on its own is not sent; the CLI says so with its size and PTC's limit and names the remedy, `ptc guide action-run -d <product dir>` for each product directory of the scan. A `payload too large` refusal from PTC is never a bare 422: the error states the cause and the same remedy. A failed batch of file copies says PTC holds no copy of those files from this run.
- Token name: every `ptc guide` sub-command, `ptc guide check` and `ptc glossary validate --remote` read `PTC_API_TOKEN`, the name PTC tells customers to use, and still accept `PTC_ORG_TOKEN` when it is not set (as `ptc estimate`, `guide action-run` and `ptc sync` already did). Before, they read only `PTC_ORG_TOKEN` and refused a customer who had set `PTC_API_TOKEN`. Their error messages and help name `PTC_API_TOKEN`.
- ES-3 (WPML lab runs 20-21: the local estimate counted fewer words than PTC quoted): the local estimate (`ptc estimate`) counts a plural entry's `msgid_plural` form as well as its `msgid`, the two source forms PTC bills.
- WB-4 (WPML lab run 22, `source_fixes` gt_2047: three source fixes applied on disk were "not found"): a file named with `--file` (or by the guide task) that the HEAD commit changed and that differs on disk now rides with the bytes on disk and their sha256, so PTC proves an uncommitted edit of it; before, `files_sha` kept the committed blob and the copy was dropped. A config file keeps its committed digest.

## 1.5.4

- SC-3 (WPML lab run 17, wpml-string-translation `scope_cleanup` gt_1658 / `source_upload` gt_1665: `null.pot`, a build artefact committed to the repository yet listed in its own `.gitignore`, was in the census, PTC proposed regenerating it and `source_upload` demanded it): the census no longer lists a tracked file that the repository's `.gitignore` rules ignore (`git ls-files --cached --ignored --exclude-standard`), for templates, catalogues and source files alike; an untracked ignored file stays out as before. Outside a git checkout nothing changes.
- SC-3 (same run, sitepress: PHP source under `classes/*/log/` was never scanned): `log` and `tmp` are runtime directories only at the scanned root; a nested `log/` or `tmp/` directory is source and is listed. The other skipped directories (`.git`, `node_modules`, `vendor`, `coverage`, `dist`, `build`, `.bundle`, `.ptc`) are still skipped at any depth.
- The tracked-but-ignored exclusion is a census rule only: the delivery digest (`delivered_files_sha`) still lists a committed translation file that `.gitignore` matches, so it agrees with the digest read from the commit (`ls-tree`).

## 1.5.3

- CN-1 (WPML lab run 17, sitepress `scope_cleanup` gt_1588: PTC proposed regenerating 15 templates, the agent regenerated 11 with the repository's own generators, every copy came back unchanged, and it declined each with the live call site): the census `usages` count a gettext call as a use of its FIRST string argument wherever that sits. The literal may follow the opening paren on the call line or on one of the next 6 lines, past blank lines and `//`, `#`, `/* */` comments (`__(` / `'text',` / `'domain'`, a JSX `{__(` call, a translators comment inside `_n(`); adjacent literals joined by `.` (PHP) or `+` (JS) are one msgid, and the joined pieces may run up to 20 lines further; a backtick literal without `${` counts; `_n_noop` and `_nx_noop` are recognised. The use is reported at the call's line. A first argument that is not a literal (a variable, a literal glued to a variable, a `${` template) is a use of nothing, so it proves no entry used or unused. msgids compare byte for byte (`'` and `’` stay different). `usages_unmatched` is unchanged: a call that does not close on its line is still never listed.
- PREP-B (AGD-3 row 5a, `scope_cleanup`; Eran 2026-10-22, ruling 5): `ptc guide next` (and the `Next:` block of a verdict) prints a task's source-change proposals, PTC's `payload.items` marked `applies_via: agent`, under "Proposed changes": per item its id, class and file (with the line when there is one), `now:` the current text or the file's role, `change:` the exact command or the proposed text, and `reason:` the reason in full. A task without proposals prints no block.
- PREP-A (the agent guide's readiness score becomes a preparedness profile, no number anywhere): `ptc guide status` and `ptc guide start` print AGD-2's setup number as `setup N%` (PTC's `setup_progress`, falling back to the deprecated `readiness` alias from an older PTC), as do a suite's product rows; `ptc guide status` prints a `Preparedness` block, one aligned line per dimension (scope, completeness, context, placeholders, sentences, terminology, conventions, existing_translations, delivery, durability): its state (`ready`, `needs work`, `not applicable`, `not checked`), PTC's sentence, and `→ <task>` when a guide task addresses it. `ptc guide next` prints the same block when PTC sends the profile (only when it changed since it was last shown). The help names `ptc audit strings` the "string audit" (was "i18n readiness audit") and `guide status` "stage, setup progress, preparedness, task list".
- GAP-G57 (WPML lab run 11, session 75, gt_1031: the agent cut PTC's accepted readiness_audit verdict at 8,000 characters, could not resubmit, and `guide status` did not repeat the reasons): every verdict the CLI receives (`guide submit`, `skip`, `wait`, `upload-sources TASK_ID`, `status TASK_ID`) is written in full to `.ptc/work/s<session>/verdict-<task id>.json` before it is printed, and the output's first line names the file (stderr under `--json`). `ptc guide status TASK_ID` prints PTC's stored verdict on that task with every reason, also after the task closed (cli-client CLI-23). A task never answered writes no file.
- GAP-G52 (WPML lab run 10, MR !3 of a five-product suite: the description said `git fetch origin ptc/translations`, the job had pushed `ptc/translations-wpml-string-translation`): `ptc guide mr-description` names the branch PTC's check names for the session (`comment.branch`; per product in a suite) in its fetch line; `PTC_MR_BRANCH` still overrides it, and a check answer without it keeps `ptc/translations`.
- GAP-G46 (WPML lab run 9, CI job 4217058: every file came back `suite_setup_pending`, nothing was delivered, and the job exited 0 "Processing completed successfully"): a run where EVERY file was held for its suite exits `13`, prints `Nothing delivered (setup_incomplete): <PTC's message>` on its own line, never the success line, and reports the stop to PTC (`guide delivery-commit --stopped-reason setup_incomplete`, which now also accepts that reason). A run with some files delivered is unchanged (cli-client CLI-22).
- GAP-G44 (WPML lab run 9: a second `ptc describe apply` against the same files skipped call sites, `<path>:<line> does not contain the msgid`, because the first apply's notes had moved them below the usage line PTC reported at scan time): a note is placed at the call site even when the reported usage line has moved since the scan. When the msgid's call is not on the reported line ±3, the whole file is searched for it and the match nearest the reported line is used; the `--json` `applied` entry carries `moved_from` (the reported line) and `line` (the line used). A call that already carries the note stays `unchanged`, never duplicated.
- GAP-G40 (WPML lab run 7 stop 18: the files landed at `wpml-cms-nav/locale/`, the line said `unpacked successfully to .../wpml-cms-nav/locale/orig`, and the reader reported a wrong location): after unpacking a file's archive the CLI prints `Translations written: N file(s) under <dir>`, where `<dir>` is the directory the written files share (else their deepest common directory), repository-relative; it never names the source file's directory unless a file was written there.

## 1.5.2

- GAP-G34 (WPML lab run 7 stop 14: a config that moved `wpml-cms-nav.po` from a `.mo` output to a `.po` output plus a `mo` companion shipped PO text under the old `.mo` names): the process call (`PUT source_files/process`) carries the entry's `output_file_path` and its `additional_translation_files[][type]` / `[path]` pairs, the outputs the register call sends, so PTC processes the file on the configured outputs (api-cli API-14).
- GAP-G32 (WPML lab run 7: "195 of 209 delivered files are PTC deliveries", the 14 others shipped translations of languages never ordered): the delivered files `ptc guide action-run` and `ptc guide delivery-commit` report to PTC, and so the delivery count, are only those of the configured `languages` (their `locale_map` locale, or the language and its regional tags when unmapped); other languages' files that match an output pattern are not deliveries.
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
