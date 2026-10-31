# Agent commands

For agents (and the people debugging them) that run the CLI commands PTC's guide asks for.

PTC drives your agent one task at a time over the MCP; the commands below are what the agent runs to complete those tasks.

PTC leads the agent through connecting a repository one task at a time, and
checks each result before handing out the next. Every API call sends
`User-Agent: ptc-cli/<version>` and `X-PTC-CLI-Version: <version>`.

## How PTC drives your agent

The MCP server (`ptc-guide`) exposes five tools: `guide_next` (the next task
with its payload), `guide_submit` (submit a task's result), `guide_status`
(where the session stands), `guide_skip` (skip a task with a reason) and
`guide_wait` (wait while PTC finishes a pending task). Your agent runs the CLI
to complete those tasks.

## `guide` — the MCP session from the command line

The human saves the agent token for the CLI once with `ptc auth login`, in
their own terminal: they approve the sign-in in their browser, no token is
typed, and the CLI saves the token mode 600 in its credentials file (`--paste`
takes the token from PTC's agent token page, `/dashboard/agent-tokens`,
instead); the agent never receives or types the token. Every `ptc` command below is `.ptc/bin/ptc-cli.sh` run from the
repository root.

```bash
ptc guide start --project-id 123             # opens/resumes the session, caches it in .ptc/session.json
ptc guide start --organization-id 7          # no project yet: creates it in organization 7
                                             # (token in several organizations: PTC lists them, ask the human)
ptc guide next                               # the next task (--json for the raw response)
ptc guide submit gt_abc --file .ptc/scan.json                     # a task's result from a file ...
echo '{"languages":["de"]}' | ptc guide submit gt_def             # ... or stdin
ptc guide skip gt_ghi --reason "the owner decided to skip this"
ptc guide status
ptc guide wait gt_jkl --timeout 20m          # ends when PTC has a verdict
```

Exit codes: `0` next task / accepted / skipped; `2` rejected; `3` needs more
(also `guide next` when PTC answers `waiting`: it prints `PTC is waiting:` and
the step PTC names, e.g. `ptc guide action-run`; "All guide tasks are done."
only on PTC's explicit `done`); `4` this CLI is older than PTC's
`cli.min_version` (the upgrade command is printed); `1` error.

- `guide wait` exits `3` when `--timeout` (default `20m`; `90s`, `1h` or
  seconds) passes without a verdict. Run it in the background only if your
  harness wakes you when it ends. It prints the verdict, its reasons and the
  next task exactly as `submit` does.
- Other guide calls retry a 5xx, no answer or a 429 with `Retry-After` 3 times
  (`PTC_TRANSIENT_BASE_DELAY`, default 5 s, doubling), then fail with "Could not
  reach PTC". A 4xx is final at once.
- `--session-id` (or `PTC_GUIDE_SESSION_ID`) and `--project-id` are optional:
  without them the session and project come from the config's `guide:` block,
  then the cache `.ptc/session.json` (every successful guide call refreshes it),
  then PTC's open session for the checkout's origin; `-v` prints where the
  project came from. `--api-url` points at another PTC instance.

**`guide check [--commit SHA] [--json]`** — the CI gate of a finished guide.
PTC compares the ptc-action run of the commit (default `CI_COMMIT_SHA`,
`GITHUB_SHA`, then `HEAD`) with the last accepted round and answers `pass` or
`fail`, one reason per line (`under_specified_string` with file:line and key,
`setup_incomplete`), plus notes that never fail it (`carried_string`: a new
string with no code usage yet). It reports missing information only and every
reason names the next step (`ptc guide next --session-id N` / MCP
`guide_next`). It never opens tasks. Exit `0` pass, `1` fail, `2` PTC cannot
evaluate (no session, no run for the commit yet, stale files, PTC unreachable,
no token; the refusal's code and message are printed). Session order:
`--session-id` / `PTC_GUIDE_SESSION_ID`, then `guide.session_id` in
`.ptc-config.yml`, then `.ptc/session.json`, then
`GET /guide/sessions?repo_url=<origin>&include_done=1`. ptc-action runs
it with `guide-check: true` and exposes the verdict as its `guide-check` output
(`guide-check-fail: true` fails the job on fail / error).

**`guide mr-description --file CHECK.json`** prints PTC's findings as the
GitLab merge request description (one push-option line for
`-o merge_request.description`; also to stderr).

## `scan` — inventory of the repository's translatable files

```bash
ptc scan          # readable summary
ptc scan --json   # schema 2, the result PTC expects for its repo_census task
```

Deterministic and offline. Finds translation resource sets (Rails YAML under
`locale`/`i18n` paths, gettext `.pot`/`.po`, i18next-style JSON under
`locales/`-like directories, plus the `files:` of a `.ptc-config.yml`), counts
entries, placeholders, plural groups, contexts and comments per source file,
lists the languages already present, and maps each key to the code lines that
use it. Files come from `git ls-files`; `vendor/`, `node_modules/` and
test/fixture/sample directories are not counted.

`repo.workspace_fingerprint` (always present) is a sha256 over every source
file's path and content; without git `repo.head_sha` is `null`.

Schema 2 adds (heuristics; counts are lower-bound estimates):

| Key | Content |
|---|---|
| `other_string_sources` | strings outside the resource files, by `kind`: `templates`, `html`, `js_literals`, `emails`, `pdf`, `seo_meta` (max 5 samples each) |
| `partition` | per resource set, `audience`: `client` / `staff_only` / `vendor` / `developer_only` — a proposal for the human to confirm |
| `existing_translations` | `languages_on_disk`, `by_set`, `duplicates` (e.g. `de` + `de_DE`), `non_loading` (WordPress: `.po` without `.mo`, catalogue for another text domain) |
| `runtime` | `text_domains`, `domain_paths`, `load_textdomain`, `i18n_init` |

## `config validate`

```bash
ptc config validate          # text report, exit 0 valid / 2 invalid
ptc config validate --json   # {valid, errors, warnings, config, files:[...], ignored_outputs}
```

Checks the config structure, that each `file:` resolves, that each `output:`
has a `{{lang}}` slot and that language codes are known. An output `.gitignore`
ignores is an error (`ignored_outputs`). Languages come from the optional
`guide:` key (`session_id`, `project_id`, `languages: [de, fr]`), else from
translations on disk.

## `describe apply` — write PTC's string descriptions into the repository

```bash
ptc describe apply --file descriptions.json [--dry-run] [--into-template] [--json]
```

Input: `{"descriptions":[{"file", "key", "context"?, "description", "usage"?: {"path", "line"}}]}`
(or the bare list), as PTC's write-back task hands it out.

gettext: a `translators:` comment above the call site (extracted by `xgettext
--add-comments=translators:` and `wp i18n make-pot`); `--into-template` writes
a `#.` line in the `.po`/`.pot` instead. Chrome-i18n JSON: the `description`
sibling. Rails YAML and flat i18next JSON are skipped.

The note is written byte for byte. Re-applying is idempotent. Exit `0` all
written or present, `2` some skipped (listed with reasons), `1` bad input.

## `lint source` — deterministic source-string checks

```bash
ptc lint source [--json] [--file PATH]... [--template languages/x.pot --template-cmd "wp i18n make-pot . languages/x.pot"]
```

FAIL/WARN findings `{check, level, file, key, text, detail}`:
`spelling_variant_mix`, `quote_class_mix`, `ellipsis_mix`, `leftover_markup`
(FAIL), `inline_markup`, `html_entity`, `edge_whitespace`, `double_space`,
`url_in_string`, `feature_name_in_sentence`, and with `--template` /
`--template-cmd` `template_regeneration` (FAIL on any lost msgid, WARN on
additions; the committed file is restored). Exit `0` no FAIL, `2` any FAIL, `1`
error.

## `glossary validate|fmt`

```bash
ptc glossary validate glossary.csv --remote [--project-id N] [--json]   # PTC's own validator
ptc glossary validate glossary.csv [--source en] [--json]                # offline pre-check
ptc glossary fmt glossary.csv [--write]
```

`--remote` sends the file (CSV, or YAML by its `.yaml`/`.yml` name) to
`POST /api/v1/guide/glossary/validate`; its verdict is the one that counts. It
needs the agent token (`ptc auth login`) and the project id (`--project-id`,
`PTC_PROJECT_ID`, the config's `guide.project_id`, the cache
`.ptc/session.json`, or PTC's open session for the checkout). FAIL classes: `structure`,
`self_contradiction`, `case_contradiction`, `wrong_script`; WARN:
`dropped_language`, `duplicate`, `case_variant`, `overlap`,
`inverse_contradiction`, `keep_vs_translate`, `lint`, `deleted_term`,
`conflict_existing`. Without `--remote` it is an offline pre-check
(`"validator": "local-precheck"`). File shape: a header row of language codes
(source first by default), one term per row. Exit `0` no FAIL, `2` any FAIL,
`1` error. `fmt` prints (or `--write`s) the canonical form: UTF-8 without BOM,
trimmed NFC cells, blank rows dropped.

## `audit strings` — is the code ready for translation

```bash
ptc audit strings [--json] [--runtime] [-d DIR]
```

Finds code that cannot translate well, per framework (WordPress/PHP, JS/React,
Rails): `hardcoded_string`, `concatenation`, `i18n_call_misuse`, `plural`,
`locale_format`; at most 500 findings. `--runtime` (WordPress) adds `script_catalogue_name`,
`textdomain_catalogue_name`, `unreferenced_catalogue`,
`stale_compiled_catalogue` (by mtime: run it on a fresh build). Exit `0`
(findings or not), `2` no recognised framework, `1` error.

## `guide action-run`

```bash
ptc guide action-run [--project-id ID] [--file PATH]... [--out R.json]
```

Reports a run to PTC and prints `run_key: <key>` (the commit sha, or
`fp:<workspace fingerprint>` without git): the key PTC's record-keeping
tasks ask for. Files a guide task named and each `--file PATH` (relative to
`-d DIR`; at most 100 files of 1 MB, inside the repository) ride with their
sha256 and bytes. A `--file` that is missing, outside the repository or over
1 MB stops the run. ptc-action and the GitLab recipe call it after each run
with the CI secret `PTC_API_TOKEN` (your agent token). Calls send `X-PTC-Project-Id`
for the project `--project-id` names, else `PTC_PROJECT_ID`, the config's
`guide.project_id`, the cache `.ptc/session.json`, or PTC's open session for the
checkout. PTC ignores the report when the session
is off for the organization.

It sends `ci_id_token`, the CI identity token with audience `ptc`, as proof
that CI ran the commit: GitHub Actions `permissions: id-token: write`; GitLab
`id_tokens: { PTC_ID_TOKEN: { aud: ptc } }`; elsewhere `PTC_CI_ID_TOKEN`.
Without one the run is recorded as *unverified provenance*: PTC could not confirm which commit CI ran. Outside CI the run
asks for `provenance_request: agent_local` and carries the working tree's
content; without git PTC keys it by the fingerprint. `--out FILE` keeps PTC's
answer (`run_id`, `run_key`, `provenance`).

## `sync` — the CI job, run locally

```bash
ptc sync [--project-id ID] [-d DIR] [-c CONFIG] [--dry-run] [--json]
```

Runs the CI job's steps in order: `guide action-run`, `guide check --json`
(findings go to the log; never withholds the translation), the translate
workflow, then `guide delivery-commit` with the sha256 of the files it wrote.
Token: the one `ptc auth login` saved (or `PTC_API_TOKEN`). Exit codes are the job's (`0`,
`5`, `6`, `7`, see [Exit codes](cli.md#exit-codes)); `13` nothing delivered,
the suite's setup is not finished; any other code is the
translation run's own. `--json` prints
`{"run_id", "uploaded", "delivered", "parked", "rejected", "delivery_commit"}`
on stdout. `--dry-run` reports the run and the plan; upload, download and the delivery
report are skipped.
