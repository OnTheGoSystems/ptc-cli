# PTC CLI - Private Translation Cloud CLI

> **Source of truth: `cli/` in `ci18n/private-translation-cloud`.**
> This directory is where the CLI is developed and gated (`cli-tests` in
> `.gitlab-ci/component-tests.yml`). It is published to
> <https://github.com/OnTheGoSystems/ptc-cli> by the release job on tags
> matching `cli/vX.Y.Z` (cut by hand on `release`); the GitHub repository is a publish target, not a place
> to commit. Customer pipelines keep fetching the published copy by tag.

Bash script for processing translation files through PTC (Private Translation Cloud) API with support for various project configurations.

[Sample repositories](https://github.com/OnTheGoSystems/ptc-cli/wiki/Sample-repositories)

## Features

- 🔍 Flexible file search using globbing or explicit file configuration
- 🛡️ Strict error handling for CI environments
- 📝 Detailed logging with color highlighting
- ⚡ Optimized for CI/CD usage
- ✅ Preflight check: validates the token and reports balance before uploading
- 🔄 Step-based processing (Preflight → Upload → Process → Monitor → Download)
- 🎯 Isolated action support (upload, status, download)
- 📊 Compact progress monitoring with status indicators
- 🗂️ YAML configuration file support
- 📋 Additional translation files support (mo, php, json, etc.)

## Quick Start

### Scaffold a config with `ptc init` (Recommended)

Don't hand-write `.ptc-config.yml` — let the CLI detect it. `ptc init` scans your
checkout (respecting `.gitignore` and an optional `.ptcignore`), sends the file
**paths only** (never file contents) to the PTC `detect_config` endpoint, shows
you what it found, and writes a ready-to-use config plus a CI snippet.

```bash
# Detect and scaffold (prompts before writing)
./ptc-cli.sh init

# Preview without touching disk
./ptc-cli.sh init --dry-run --verbose

# Non-interactive (CI), overwrite an existing config
./ptc-cli.sh init --yes --force
```

`init` needs no API token — `detect_config` is anonymous. A token is required
only later, to upload and translate. If the project layout isn't recognised,
`init` writes a commented template you can fill in — it never hard-fails. Ignore
extra paths by listing gitignore-style patterns in a `.ptcignore` file at the
repo root.

### Using a hand-written Configuration File

```bash
# Create config file
cat > .ptc-config.yml << 'EOF'
source_locale: en

files:
  - file: src/locales/en.json
    output: src/locales/{{lang}}.json
  
  - file: languages/plugin.pot
    output: languages/plugin-{{lang}}.po
    additional_translation_files:
      - type: mo
        path: languages/plugin-{{lang}}.mo
      - type: po
        path: languages/plugin-{{lang}}.po
EOF

# Process translations (the token is read from the PTC_API_TOKEN env var)
export PTC_API_TOKEN=your-token
./ptc-cli.sh --config-file .ptc-config.yml
```

### Using Patterns

Convenient for processing multiple files when the file or path to it contains a language code. In this case, you cannot transfer additional translation files (e.g. `mo`, `po`) or configure the output_file_path for each.

```bash
# Make script executable
chmod +x ptc-cli.sh

# Find files for English language by pattern
./ptc-cli.sh --source-locale en --patterns 'sample-{{lang}}.json'

# Find files in subdirectories
./ptc-cli.sh --source-locale en --patterns '{{lang}}/**/*.json' --api-url=https://app.ptc.wpml.org/api/v1/

# Multiple patterns
./ptc-cli.sh -s en -p 'sample-{{lang}}.json,{{lang}}-*.properties'
```

## Usage

### Main Options

**File Selection:**
- `-c, --config-file FILE` - YAML configuration file (recommended)
- `-p, --patterns PATTERNS` - File patterns separated by commas

**Basic Parameters:**
- `-s, --source-locale LOCALE` - Source language (required unless in config)
- `-t, --file-tag-name TAG` - File tag name/branch name (default: auto-detect from git)
- `-d, --project-dir DIR` - Project directory (default: current)

**API Configuration:**
- `--api-url URL` - PTC API base URL (default: https://app.ptc.wpml.org/api/v1/)
- `--api-token TOKEN` - API token override (prefer the `PTC_API_TOKEN` env var)
- `--monitor-interval SECONDS` - Status check interval (default: 5)
- `--monitor-max-attempts COUNT` - Maximum monitoring attempts (default: 100)

**Control Options:**
- `--action ACTION` - Perform isolated action: upload, status, download
- `-v, --verbose` - Verbose output
- `-n, --dry-run` - Show what would be done without executing
- `-h, --help` - Show help
- `--version` - Show version

**Writing option values.** Every option above takes its value as a separate
argument (`--file-tag-name my-branch`). The `--flag=value` form works only for
`--api-url`, `--api-token`, `--monitor-interval`, `--monitor-max-attempts` and
`--action`; anywhere else it is reported as an unknown option. (`init` accepts
`=` for `--api-url`, `--api-token` and `--project-dir`.)

### Authentication

Provide your API token through the `PTC_API_TOKEN` environment variable:

```bash
export PTC_API_TOKEN=your-token
./ptc-cli.sh --config-file .ptc-config.yml
```

In CI, set it as a masked secret named `PTC_API_TOKEN` (see the CI examples
below). The `--api-token` flag still works as an override, but keeping the token
in the environment avoids leaking it into shell history and process listings.

> **Deprecated:** the `api_token:` config-file key is no longer read — a token in
> a committed file is a leak. If present, the CLI warns and ignores it.

### Preflight

Every run (except `--dry-run`) starts with a preflight check that validates the
API token and reports the account state in one line:

```
[SUCCESS] Preflight OK: source=en, plan=trial, balance=4200 trial words
```

It stops the run immediately, before any upload, only when PTC has definitively
said the run cannot work: the token is missing, the token is rejected, or the
subscription is inactive. Anything else — an unreachable API, a source locale
that disagrees with the PTC project, a zero word balance — produces a warning
and the run continues, so a brief API hiccup cannot fail a build that would
otherwise have succeeded.

## Configuration File Format

The YAML configuration file supports full project setup:

```yaml
# Basic settings
source_locale: en
file_tag_name: main
api_url: https://app.ptc.wpml.org/api/v1/
# NOTE: the api_token: key is deprecated and ignored. Never store a token in a
# committed file — provide it via the PTC_API_TOKEN environment variable.

# Monitoring settings (optional)
monitor_interval: 5
monitor_max_attempts: 100
monitor_max_minutes: 45   # wall-clock bound from the first upload; reached with files still translating -> exit 7

# Files to translate
files:
  # React app localization files
  - file: src/locales/en.json
    output: src/locales/{{lang}}.json
    additional_translation_files:
      - type: mo
        path: dist/locales/{{lang}}.mo
      - type: php
        path: includes/lang-{{lang}}.php
  
  # Admin panel translations  
  - file: admin/locales/en.json
    output: admin/locales/{{lang}}.json
  
  # WordPress plugin translations
  - file: languages/plugin.pot
    output: languages/plugin-{{lang}}.po
    additional_translation_files:
      - type: mo
        path: languages/plugin-{{lang}}.mo
      - type: json
        path: languages/plugin-{{lang}}-wp.json
```

### Usage Examples

**With Configuration File:**
```bash
# Basic usage with config
./ptc-cli.sh --config-file config.yml

# Dry run to see what would happen
./ptc-cli.sh -c config.yml --dry-run --verbose

# Override specific settings (short flags take a separate argument, not --flag=value)
./ptc-cli.sh -c config.yml --file-tag-name feature-branch

# Isolated actions
./ptc-cli.sh -c config.yml --action upload                   # Only upload files
./ptc-cli.sh -c config.yml --action status --verbose         # Check translation status
./ptc-cli.sh -c config.yml --action download                 # Download completed translations
```

**With params:**
```bash
# Basic usage
./ptc-cli.sh -s en -p 'sample-{{lang}}.json'

# Search in specific directory
./ptc-cli.sh -s de -p '{{lang}}/**/*.json' -d /path/to/project

# Dry run with verbose output
./ptc-cli.sh -s en -p '{{lang}}/*.json' --verbose --dry-run

# Multiple patterns
./ptc-cli.sh -s en -p 'i18n/{{lang}}/app.json,locales/{{lang}}/*.properties'

# WordPress WPSite example
./ptc-cli.sh -s en -p 'languages/wpsite.pot' -t main

# Isolated actions with patterns
./ptc-cli.sh -s en -p 'sample-{{lang}}.json' --action upload
./ptc-cli.sh -s en -p 'sample-{{lang}}.json' --action status --verbose
./ptc-cli.sh -s en -p 'sample-{{lang}}.json' --action download
```

## Agent guide commands (1.2.3)

These commands serve PTC's agent guide: an AI coding agent (or a person) is led
through connecting a repository to PTC one verified task at a time. They need
**python3 (>= 3.6)** on PATH; the translate pipeline itself still needs only
bash + curl.

### `ptc guide` — protocol transport

```bash
export PTC_ORG_TOKEN=...          # your agent token (PTC's agent token page, /dashboard/agent-tokens)
./ptc-cli.sh guide start --project-id 123   # opens/resumes the session, caches it in .ptc/session.json
./ptc-cli.sh guide start --organization-id 7 # no project yet: creates it in organization 7 (when your token acts in several,
                                            # PTC lists them: ask the human which one)
./ptc-cli.sh guide next                     # the next task (add --json for the raw envelope)
./ptc-cli.sh guide submit gt_abc --file .ptc/scan.json   # evidence from a file ...
echo '{"languages":["de"]}' | ./ptc-cli.sh guide submit gt_def   # ... or stdin
./ptc-cli.sh guide skip gt_ghi --reason "the owner decided to skip this"
./ptc-cli.sh guide status
./ptc-cli.sh guide wait gt_jkl --timeout 20m   # background only if your harness wakes you on its end, else foreground; ends when PTC has a verdict
```

Exit codes: `0` next task / accepted / skipped, `2` rejected, `3` needs more
(`guide next` too, when PTC answers `waiting` instead of a task: it prints `PTC is waiting:` and the step PTC names,
e.g. `ptc guide action-run`; "All guide tasks are done." only on PTC's explicit `done`),
`4` this CLI is older than PTC's `cli.min_version` (the upgrade command is
printed), `1` error. `guide wait` exits `3` when `--timeout` (default `20m`;
`90s`, `1h` or plain seconds) passes without a verdict; it long-polls
`POST /guide/wait` in requests of at most 25 s (PTC's own cap, below the gateway's 60 s) and retries network errors,
429 and 5xx inside the budget. Agents run it as a background command when their
harness wakes them on its end, otherwise in the foreground, and read its output: it names the task (`PTC's verdict on task gt_jkl:`)
and prints the verdict, its reasons and the next task exactly as `submit` does. Every other guide call, and the
`action-run` / `delivery-commit` reports (the latter also carries
`--stopped-reason monitor_bound`, with or without `--commit`, when the translate
run stopped at its monitor bound: exit `7`, see Exit codes), retry a 5xx, no answer (000) or a 429
that carries `Retry-After` 3 times with backoff (`PTC_TRANSIENT_BASE_DELAY`,
default 5 s, doubling; `Retry-After` wins when sent), then fail with "Could not
reach PTC" and the last HTTP code; a 4xx is final at once. `--session-id` (or `PTC_GUIDE_SESSION_ID`) overrides the
cached session; `--api-url` points at another PTC instance.

Every API call the CLI makes — guide or translate — sends
`User-Agent: ptc-cli/<version>` and `X-PTC-CLI-Version: <version>`.

`guide check [--commit SHA] [--json]` (1.3.0) is the CI gate of a finished
guide: PTC compares the ptc-action run of the commit (default `CI_COMMIT_SHA`,
`GITHUB_SHA`, then `HEAD`) with the last accepted round and answers `pass` or
`fail` with one reason per line (`under_specified_string` with its file:line and
key, `setup_incomplete`), plus notes that never fail it
(`carried_string`: a new string with no code usage yet). It reports missing
information only (1.4.0: no `translation_missing`; whether a translation was
delivered is PTC's own bookkeeping) and every reason names the next step
(`ptc guide next --session-id N` / MCP `guide_next`). It never opens tasks.
`guide mr-description --file CHECK.json` (1.4.0) prints the GitLab
translations merge request's description as ONE push-option line: PTC's findings
(or a fixed neutral text when the project setting turns the findings off, or PTC
gave no answer), which the recipe's push sets with
`-o merge_request.description` - no API call and no second token. The findings
also go to stderr, so every job log carries them. GitLab sets the description
only on a push that changes the branch: a run with nothing new to deliver leaves
the previous description in place (the job log still shows the current
findings). Exit `0` pass, `1` fail, `2` PTC cannot evaluate (no session,
no run for the commit yet, stale files, PTC unreachable, no token); every `2`
prints the refusal's code and message. The session may be `done`: without a
cached session the CLI asks `GET /guide/sessions?include_done=1` by origin URL.
The action runs it with `guide-check: true` and exposes the verdict as its
`guide-check` output (`guide-check-fail: true` fails the job on fail / error).

### `ptc scan` — repository census

```bash
./ptc-cli.sh scan            # readable summary
./ptc-cli.sh scan --json     # schema 2, the evidence for the guide's repo_census task
```

Deterministic and offline. Finds translation resource sets (Rails YAML under
`locale`/`i18n` paths, gettext `.pot`/`.po`, i18next-style JSON under
`locales/`-like directories, plus the `files:` of a `.ptc-config.yml`), counts
entries, placeholders, plural groups, contexts and comments per source file,
lists the languages already present, and maps each key to the code lines that
use it (`t('k')`, `t('.lazy')` in Rails views, `I18n.t("k")`, `t("ns:k")`,
`__()`/`_e()`/`_x()`/`_n()`/`esc_html__()`... keyed by msgid). Files come from
`git ls-files` (so `.gitignore` is honoured); `vendor/`, `node_modules/` and
test/fixture/sample directories are not counted as product resources.

`repo.workspace_fingerprint` (always present, with or without git): the sha256 over the
sorted list of `"<path>\n<sha256 of the file bytes>\n"` for every source file in every
resource set (paths relative to the scan root, forward slashes). It is stable across runs
and changes when one byte of a source file changes; PTC keys a run from a working tree
without a commit by it (POL-116). Without git `repo.head_sha` is `null`. Still schema 2
(the field is additive).

Schema 2 keeps every schema-1 field and adds the census v2 facts (cheap,
deterministic heuristics; counts are lower-bound estimates):

| Key | Content |
|---|---|
| `other_string_sources` | `[{kind, files, occurrences, samples:[{path,line,text}] (max 5)}]` for strings outside the resource files. `kind`: `templates` (hard-coded text nodes in ERB/HAML/PHP/Twig/Vue/JSX, `t()`/`__()` calls excluded), `html`, `js_literals` (sentence-like string literals), `emails` (mailer / e-mail template paths), `pdf` (PDF files, PDF template paths), `seo_meta` (`<title>`, description/OpenGraph/Twitter meta, `content_for :title`) |
| `partition` | `[{source_pattern, audience, rule}]` per resource set; `audience`: `client` / `staff_only` (admin, backoffice, staff, internal paths) / `vendor` (third_party, libraries, external) / `developer_only` (docs, examples, scripts, tools, debug). A proposal for the human to confirm. |
| `existing_translations` | `languages_on_disk`; `by_set:[{source_pattern, languages, files:[{lang, path, entries, translated}]}]` (`translated` for gettext); `duplicates:[{source_pattern, language, variants}]` (the bare code beside its default region, e.g. `de` + `de_DE`); `non_loading:[{path, reason}]` (WordPress: a `.po` without its `.mo`, a catalogue named for another text domain) |
| `runtime` | `text_domains` (`Text Domain:` headers), `domain_paths`, `load_textdomain` (`load_*_textdomain` calls with the domain and remaining arguments), `i18n_init` (i18next/Vue-I18n init, `config.i18n.*`, `I18n.load_path`/`default_locale`, `wp_set_script_translations`) |

### `ptc config validate`

```bash
./ptc-cli.sh config validate          # text report, exit 0 valid / 2 invalid
./ptc-cli.sh config validate --json   # {valid, errors, warnings, config, files:[{file, output, matches, outputs:{lang: path}}], ignored_outputs}
```

Checks the v1 structure (the same checks the translate run applies), that each
`file:` resolves to at least one file, that each `output:` has a `{{lang}}`
slot, and that language codes are known; reports the output path per language.
1.2.8: each output, instantiated with its first target language, is run through
`git check-ignore`; an output the repository's `.gitignore` ignores is an error
(the rule is cited) and is listed in `ignored_outputs`, because translations
written there could never be committed.
Languages come from the optional `guide:` key, else from the translations found
on disk:

```yaml
guide:
  session_id: gs_abc
  project_id: 123
  languages: [de, fr]
```

### `ptc describe apply` — write PTC's string descriptions into the repository

```bash
./ptc-cli.sh describe apply --file descriptions.json [--dry-run] [--into-template] [--json]
```

Input: `{"descriptions":[{"file", "key", "context"?, "description", "usage"?: {"path", "line"}}]}`
(or the bare list), as PTC's write-back task hands it out.

- **gettext (default):** a `translators:` comment at the call site — the line
  above `usage.path:usage.line` with the call's indentation (`/* translators: … */`
  in PHP/JS/C-like files, `# translators: …` in Python/Ruby, `{# … #}` in Twig),
  or inside the tag on an inline `<?php … ?>` template line. `xgettext
  --add-comments=translators:` and `wp i18n make-pot` extract it into the
  template's `#.` line, so regenerating the template carries it. Without
  `usage`, the call site comes from `ptc scan`'s usage map. A usage line that
  does not hold the msgid (±3 lines) is skipped with the reason; a changed
  description replaces the old `translators:` line.
- **`--into-template`:** the old fallback: a `#.` line in the `.po`/`.pot` entry
  (lost when the build regenerates the template).
- **Chrome-i18n JSON:** the message's `description` sibling. Other formats
  (Rails YAML, flat i18next JSON) have no slot PTC reads and are skipped.

Re-applying is idempotent. Exit `0` every description written or already
present, `2` some skipped (listed with reasons), `1` bad input.

### `ptc lint source` — deterministic source-string checks

```bash
./ptc-cli.sh lint source [--json] [--file PATH]... [--template languages/x.pot --template-cmd "wp i18n make-pot . languages/x.pot"]
```

Reads the source files `scan` finds (or the `--file`s) and reports FAIL/WARN
findings `{check, level, file, key, text, detail}`: `spelling_variant_mix`
(US and UK spellings in one corpus), `quote_class_mix` (straight and curly
apostrophes), `ellipsis_mix`, `leftover_markup` (unbalanced tags, FAIL),
`inline_markup`, `html_entity`, `edge_whitespace`, `double_space`,
`url_in_string`, `feature_name_in_sentence` (CamelCase or Title Case names
mid-sentence), and with `--template`/`--template-cmd` `template_regeneration`:
the command regenerates the template as the build does, the entry sets are
compared (FAIL on any lost msgid, WARN on additions) and the committed file is
restored. Exit `0` no FAIL, `2` any FAIL, `1` error.

### `ptc glossary fmt|validate` — glossary CSV for PTC's import

```bash
./ptc-cli.sh glossary validate glossary.csv --remote [--project-id N] [--json]   # PTC's own validator
./ptc-cli.sh glossary validate glossary.csv [--source en] [--json]                # offline pre-check
./ptc-cli.sh glossary fmt glossary.csv [--write]
```

`--remote` sends the file (CSV, or PTC's YAML by its `.yaml`/`.yml` name) to
`POST /api/v1/guide/glossary/validate` and prints PTC's validator report: the
one validator the guide's glossary tasks and the dashboard import preview run
(POL-7), so its verdict is the one that counts. It needs `PTC_ORG_TOKEN` and
the project id (`--project-id`, `PTC_PROJECT_ID` / `guide.project_id`, or the
guide session's). Its classes: FAIL `structure`, `self_contradiction`,
`case_contradiction`, `wrong_script`; WARN `dropped_language`, `duplicate`, `case_variant`,
`overlap`, `inverse_contradiction`, `keep_vs_translate`, `lint`,
`deleted_term`, `conflict_existing`. Without `--remote` the command is an
offline pre-check (`"validator": "local-precheck"` in its JSON) of the
checks below; PTC re-runs its own on import and on guide submit.

The file is PTC's glossary import shape: a header row of language codes (the
source language, default the first column, plus targets), one term per row.
`validate` reports `structure` (unknown or repeated codes, rows wider/narrower
than the header, missing source column or term: FAIL), `self_contradiction`
(the same term, exact source, translated differently for a language: FAIL),
`case_contradiction` (terms that differ only in case, translated differently
for a language: FAIL; PTC asks which one), `case_variant` (terms that differ
only in case, translated alike, are distinct terms: WARN),
`duplicate` (identical repeat: WARN) and `wrong_script` (a cell in another
non-Latin script than its language uses: FAIL; Latin text in a non-Latin
column that differs from the source: WARN; cells equal to the source term are
kept names and pass). Exit `0` no FAIL, `2` any FAIL, `1` error. `fmt` prints
(or `--write`s) the canonical form: UTF-8 without BOM, trimmed NFC cells, blank
rows dropped.

### `ptc audit strings` — i18n readiness audit (1.2.6)

```bash
./ptc-cli.sh audit strings [--json] [--runtime] [-d DIR]
```

Finds code that cannot translate well, by recipe per framework (detected from
the census: `ptc scan` frameworks, runtime text domains, `package.json`,
`Gemfile`). Deterministic line rules, python3 stdlib only.

| Class | WordPress / PHP | JS / React | Rails |
|---|---|---|---|
| `hardcoded_string` | `echo`/`print` literal, HTML text outside `<?php` | JSX text, `placeholder`/`title`/`alt`/`aria-label`/`label` literals | view text, `link_to`/`button_to`/`submit`/`label_tag` literals |
| `concatenation` | `__()` result `.`-joined with a variable | `t() +` / `+ t()`, template literal around `t()` | `"…" + t()` / `t() + "…"` |
| `i18n_call_misuse` | variable text domain, concatenated or variable msgid | | |
| `plural` | `$n == 1 ? __() : __()` outside `_n()` | | `pluralize()` |
| `locale_format` | `date('…')` with a literal format | `.toFixed(n)` | `.strftime('…')` in views |

JSON schema 1: `{schema: 1, framework: [...], findings: [{class, file, line,
excerpt, rule, fix_hint, text?}], truncated, counts: {by_class}, coverage:
{files_scanned, files_skipped}}` — `text` is the user-visible literal of a
`hardcoded_string` finding (PTC checks it against the uploaded source strings).
At most 500 findings (`truncated: true` beyond), excerpts at most 4 KB. The
scan's exclusions apply (vendor, node_modules, build/dist, `.ptcignore`), plus
minified files and test/fixture paths.

`--runtime` adds `runtime: {script_translations, text_domains, findings,
counts}` (WordPress): a `wp_set_script_translations` handle with no jed
catalogue `<domain>-<locale>-<handle|md5>.json` (`script_catalogue_name`), a
text domain without a `<domain>.pot` / `<domain>-<locale>.po`
(`textdomain_catalogue_name`), a catalogue whose domain nothing loads
(`unreferenced_catalogue`), and a `.mo` / jed `.json` older than its `.po`
(`stale_compiled_catalogue`, compared by file mtime — run it on a fresh build,
not a fresh clone). Exit `0` (findings or not), `2` no recognised framework,
`1` error.

### `ptc guide action-run`

`ptc guide action-run [--project-id ID] [--file PATH]... [--out R.json]` prints `run_key: <key>` on stdout (the commit
sha, or `fp:<workspace fingerprint>` without git): the key the guide's proof-taking tasks ask for. Every file a guide
task named (the paths of its payload's `proposals` / `readiness_manual`, recorded in `.ptc/session.json` when the CLI
fetched the task) and each `--file PATH` rides with its sha256 in `files_sha` and its bytes in `files_sample` (at most
100 files of 1 MB each, inside the repository), and the workspace fingerprint covers them too, so on a plain directory
(no git) an edit to a code file is provable and the run after it has a new key (SF-22). A path git already reported
from the commit keeps the commit's digest.

Used by ptc-action (and the GitLab recipe) after each run, with the one CI
secret `PTC_API_TOKEN` (your agent token, from PTC's agent token page `/dashboard/agent-tokens`;
a legacy project token still works). With an agent token every `/api/v1` call of the
translate pipeline and of `guide action-run` sends `X-PTC-Project-Id` from the config's `guide.project_id`
(or `PTC_PROJECT_ID`). It
posts the scan, the parsed config, the commit sha and branch, the source files'
content (up to 200 KB, `PTC_FILES_SAMPLE_LIMIT` in bytes, plus every source file the commit
changed), `ignored_outputs` (the checkout's
`ptc config validate --json` list of git-ignored outputs: PTC's `commit_config` refuses
the commit on this list, never on the agent's submitted one), `files_sha` (sha256 of every
committed `.ptc-config.yml`, `.github/workflows/*.yml` and `.gitlab-ci.yml`,
read from `HEAD`, keyed by repository-root paths and covering the whole
repository even when run from a product's `project-dir`; 1.2.8: plus every path
the commit changed — the `changed_files` and the HEAD commit's own diff — at most
200 keys, so PTC can check a source edit the agent reports), `delivered_files_sha`
(1.2.7: sha256 of every committed delivered translation file — a file matching a
config entry's `output:` pattern with a language in `{{lang}}` — keyed the same
way, at most 500; PTC compares them with the files it delivered to refuse a git
edit of a delivered file), `repo_prefix` (that
directory relative to the repository root; scan and upload paths stay relative
to it) and `ci_id_token` to `/guide/action_runs`. PTC ignores it when
the guide is off for the organization.

`ci_id_token` is the CI platform's identity token with audience `ptc` — PTC's
proof that CI, not the agent, ran this commit. Where it comes from:

| CI | Setup | Read from |
|---|---|---|
| GitHub Actions | `permissions: id-token: write` in the workflow | requested from `ACTIONS_ID_TOKEN_REQUEST_URL` (audience `ptc`) |
| GitLab CI | `id_tokens: { PTC_ID_TOKEN: { aud: ptc } }` on the job | `PTC_ID_TOKEN` |
| anything else / the lab | mint it yourself | `PTC_CI_ID_TOKEN` |

Without one the run is still reported and PTC records it as *unverified
provenance* (the command warns). The lab's push hook mints an HS256 token with
`tools/mint-lab-ci-token.py` (claims documented in that file).

**From the agent's machine (POL-116).** Outside CI — no identity-token variable
above and no `GITHUB_ACTIONS` / `GITLAB_CI` / `GITHUB_SHA` / `CI_COMMIT_SHA` — the
run asks for `provenance_request: agent_local` (PTC records it so on a session
whose delivery channel is the API, `unverified` elsewhere) and carries the
working tree's content: `workspace_fingerprint` (`ptc scan`'s), `files_sha` plus
the sha256 of every census source file as its bytes on disk at run time (in CI
too; at most 1500 sources), and `ignored_outputs`. Without git no commit sha is
sent: PTC keys the run by the fingerprint (`fp:<fingerprint>`). `--out FILE`
keeps PTC's answer (`run_id`, `run_key`, `provenance`).

### `ptc sync` — the CI job, run locally

```bash
PTC_ORG_TOKEN=... ptc sync [--project-id ID] [-d DIR] [-c CONFIG] [--dry-run] [--json]
```

Runs what the GitLab recipe / ptc-action job runs, in its order, on the agent's
machine: (1) `ptc guide action-run` (above), (2) `ptc guide check --json` (the
findings go to the log; it never withholds the translation), (3) the full
translate workflow writing the configured outputs, (4) `ptc guide
delivery-commit` with no branch and no commit: `workspace_fingerprint`, the
source commit when git has one, and the sha256 of exactly the files step 3
wrote (read from disk), which PTC matches to its hand-overs as it matches a
translations-branch report. Token: `PTC_API_TOKEN`, else `PTC_ORG_TOKEN`; `-d`
names a suite product's directory (its `.ptc-config.yml` unless `-c` names one).

Exit codes and final lines are the job's: `0` all delivered; `5` PTC rejected
or could not be reached for some files; `6` some files wait in PTC (parked for
an over-limit approval, or paused out of credit); `7` still translating at the
monitor bound. In each of these the rest is delivered and reported. Any other
non-zero is the translate run's own, and no report is sent.

`--json` prints one object on stdout (logs and the final line go to stderr):
`{"run_id", "uploaded", "delivered", "parked", "rejected", "delivery_commit"}`
— `delivered` counts the files written, `delivery_commit` is PTC's answer to
the report (null when none was sent). `--dry-run` reports the run and PTC's
check, plans the translation without calling PTC and sends no report: nothing
is uploaded or written (`--json` adds `"dry_run": true` and `"planned"`).
Without git the check names the sync's run by its run key (`run_key:
fp:<workspace fingerprint>`, from `PTC_GUIDE_RUN_KEY`); the exit code is
unaffected.

## Processing Workflow

The script supports two modes of operation:

### Full Workflow (Default)
The script follows a step-based approach:

1. **📤 Upload Step**: All files are uploaded to the PTC API
2. **⚙️ Processing Step**: Translation processing is triggered for all files  
3. **👀 Monitoring Step**: Translation status is monitored with compact progress display
4. **📥 Download Step**: Completed translations are downloaded and unpacked

### Isolated Actions
For more granular control, you can perform specific steps in isolation:

#### `--action upload`
Only uploads files to PTC without starting translation processing.
```bash
./ptc-cli.sh -c config.yml --action upload
```

#### `--action status`
Checks the translation status of files without downloading.
```bash
./ptc-cli.sh -c config.yml --action status --verbose
```

#### `--action download`
Downloads completed translations without checking or uploading.
```bash
./ptc-cli.sh -c config.yml --action download
```

**Use Cases for Isolated Actions:**
- **CI/CD pipelines**: Upload files in one job, check status and download in another
- **Manual workflows**: Upload files, review translations externally, then download
- **Debugging**: Check specific status or retry downloads without re-uploading

### Progress Indicators

During monitoring, you'll see compact status indicators (Each letter for one file):

- `UU 12/30` - Unknown status (12 attempts out of 30 total)
- `QQ 23/30` - Queued for processing
- `PP 25/30` - Processing in progress
- `CQ 27/30` - Some completed, some queued
- `CC 28/30` - All completed

**Status Characters:**
- 🟢 `C` - Completed
- 🔵 `Q` - Queued
- 🔵 `P` - Processing
- 🔴 `F` - Failed
- 🟡 `U` - Unknown

### Exit codes

The exit code is the CI-facing verdict, so it reports what actually happened rather than whether the script reached the end.

| Code | Meaning |
|------|---------|
| `0` | Every file completed. For `--action status`, every file is either ready or still translating. |
| `1` | Something did not complete: a file failed, no files were found, the API rejected a request, or the arguments were invalid. |
| `5` | Partial: PTC rejected some source files (a processing 4xx such as HTTP 422, a file left `draft` for 3 checks — `PTC_DRAFT_TERMINAL_ROUNDS` — or status `rejected`), and every other file completed and was written. The summary lists them under "Rejected by PTC". A file whose processing request never got a PTC answer (HTTP 5xx or no response, e.g. a proxy or tunnel in between) is retried 3 times with backoff (5 s, 10 s, 20 s; `PTC_TRANSIENT_BASE_DELAY` sets the first wait) and, if it still fails, is listed under "Could not reach PTC" instead: it was not rejected, a re-run translates it. It also exits `5`. So does a file whose status could not be read (no answer, 404, 5xx, a body that is not JSON) on every poll since some time until the monitor bound (S2-R19-1): it is listed under "Could not reach PTC" with since when and the last HTTP code, its state unknown — not "still translating". ptc-action and the GitLab recipe still deliver the written translations, then fail the job with "PTC rejected some files or could not be reached for them" (S2-R19-3). |
| `6` | Partial: PTC paused some files out-of-credit (status `out_of_credit`: the organization's credit does not cover them; they are listed under "Paused out-of-credit in PTC" and resume when the organization tops up or upgrades — when nothing completed the run exits `1` instead), or parked some files behind an over-limit approval (the run costs more than the organization's translation approval limit; status `awaiting_approval`, or `approval_expired` once the 24 h request lapsed), and every other file completed and was written. The summary lists them under "Parked for an over-limit approval in PTC" with the remedy: approve the request in PTC (emailed to the organization's administrators) or raise the approval limit; the next run picks them up once the approval is given. ptc-action and the GitLab recipe still deliver the written translations and report the delivery commit, then fail the job. A run with other failed or unfinished files exits `1`. |
| `7` | Stopped (S2-R3B, CI-16): the translation is still running in PTC when the run reaches its bound — the wall clock (`monitor_max_minutes`, default 45 minutes from the first upload; `--monitor-max-minutes`, `PTC_MONITOR_MAX_MINUTES`; flag > environment > config) or the attempts cap (`monitor_max_attempts`) — and nothing failed. Only files PTC answered for count as still translating; files PTC could not be asked about are listed separately under "Could not reach PTC" (S2-R19-1). Every completed file was written. The summary lists the files still translating with PTC's state for each under "Still translating in PTC", then the options: (a) retry the CI job once PTC finishes (or push the next commit), (b) check progress with the exact `--action status` command (and the project page, when the config names `guide.project_id`), (c) download manually with the exact `--action download` command and commit. ptc-action and the GitLab recipe deliver what finished, tell PTC the run stopped (`guide delivery-commit --stopped-reason monitor_bound`, with the commit or alone) and fail the job with "translation still running in PTC". |
| `129` / `130` / `143` | Stopped by SIGHUP / SIGINT / SIGTERM (cleanup runs, then the CLI exits; `timeout` and CI cancels stop it). |

**A partial run is a failure.** If ten files are submitted and one is rejected or parked, the exit code is `5` (rejected) or `6` (parked); `7` when the rest is still translating at the bound; `1` only when nothing distinguishes the failure (a file failed). The summary lines above it list what completed, what failed and what was left unfinished, so the log says which is which.

**A bound is not a failure of the translation.** The run is bounded twice, below the CI job's own limit (the generated GitLab job sets `timeout: 3h`, the GitHub workflow `timeout-minutes: 180`): `monitor_max_minutes` (45 by default, from the first upload) and `monitor_max_attempts` (max(100, 20 x files) polls at `monitor_interval`). Either one reached with files still translating ends the run with exit `7` and the options above; the finished files are on disk. Raise `monitor_max_minutes` (keeping it below the job limit) for projects whose first translation needs longer.

`--action status` is the exception worth knowing: a translation still in progress is a legitimate answer and exits `0`. Only a terminal failure, or a status that could not be read at all, exits `1`.

## CI/CD Usage

### Pinning the CLI version

Pipelines download the script from a **pinned release tag**, not a moving branch,
so a push to `main` can never change what your build runs:

```bash
curl -fsSL https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/v1.4.0/ptc-cli.sh -o ptc-cli.sh
```

Use an exact release tag such as `v1.4.0` to pin, or the floating `v1` tag to
pick up backward-compatible updates automatically: `v1` always equals the newest
published CLI — the release job moves it onto every new `vX.Y.Z` and fails if the
two differ. `ptc init` scaffolds the
pinned URL for you, at the version of the CLI that printed it.

**Verify the download** against the SHA256 checksum published on the
[release page](https://github.com/OnTheGoSystems/ptc-cli/releases):

```bash
# macOS
shasum -a 256 ptc-cli.sh
# Linux
sha256sum ptc-cli.sh
```

Each request the CLI makes carries a `User-Agent: ptc-cli/<version>` header, so
the server can attribute traffic to a specific release.

### GitHub Actions

Add PTC_API_TOKEN to the repository secrets (Settings -> Secrets and variables -> Actions -> New repository secret).
Ensure to turn on the "Allow GitHub Actions to create and approve pull requests" permission in the repository settings (Settings -> Actions -> General -> Workflow permissions).

This is what `ptc init` writes for you. It runs the CLI through
[`ptc-action`](https://github.com/OnTheGoSystems/ptc-action), which vendors a
pinned copy of this script, so there is nothing to download at job time:

```yaml
name: PTC Translations
on:
  push:
    branches: [main]
  workflow_dispatch: {}

permissions:
  contents: write
  pull-requests: write
  id-token: write   # identity token: proves to PTC's agent guide that this CI ran the commit

jobs:
  translate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 2   # HEAD's parent: lets the run name the files its commit changed (agent guide)
      - uses: OnTheGoSystems/ptc-action@v1
        with:
          api-token: ${{ secrets.PTC_API_TOKEN }}
          config-file: .ptc-config.yml
          create-pr: true
```

Sample `.ptc-config.yml` file:

```yaml
source_locale: en
file_tag_name: main

files:
  - file: src/locales/en.json
    output: src/locales/{{lang}}.json
```

### GitLab CI

There is no GitLab component to include: `include: component:` is resolved by
your own GitLab instance, so a component published anywhere else is unreachable.
`ptc init` prints this self-contained job instead:

```yaml
ptc-translate:
  stage: deploy
  image: alpine:3.22
  # A first translation of a large project outlives GitLab's default 1 h job limit (CI-16). 3 h covers it; the CLI stops
  # on its own at a 45-minute bound (monitor_max_minutes in .ptc-config.yml), delivers what finished and exits 7.
  timeout: 3h
  # The preflight writes the CI-time limit note here (balance short of the census); the merge request description
  # below carries it, as a GitHub pull request body does.
  variables:
    PTC_LIMIT_NOTE_FILE: /tmp/ptc-limit-note
  # The job's identity token proves to PTC that this CI ran the commit (agent guide provenance).
  id_tokens:
    PTC_ID_TOKEN:
      aud: ptc
  # Loop-safe twice over: the job only runs on a push to the default branch (the
  # translation push targets ptc/translations, so it cannot retrigger this job),
  # and rules: below refuses a commit marked [skip translations].
  rules:
    # The second condition is what keeps this loop-safe, and it has to live
    # here: GitLab evaluates rules: against the commit message, whereas
    # `[skip ci]` in the message would suppress the pipeline of the merge
    # request itself - leaving the translations untested and, with "Pipelines
    # must succeed" enabled, unmergeable.
    - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_MESSAGE !~ /\[skip translations\]/'
  before_script:
    # jq is never invoked by the CLI. unzip is - it unpacks the downloaded
    # translations; alpine already provides it as a busybox applet, so it is
    # named here only to keep the job working if the image is ever changed.
    # git is needed by the push step below, not by the CLI.
    - apk add --no-cache bash curl git unzip python3
  script:
    # Downloaded OUTSIDE the checkout: anything this job writes into the working
    # tree is a file the commit below could sweep into the merge request, and
    # the CLI is 100+ KB of it.
    # A CI/CD variable PTC_CLI_URL pins another copy of the CLI (curl accepts
    # file://, e.g. file://$CI_PROJECT_DIR/cli/ptc-cli.sh for the repository's own).
    - curl -fsSL "${PTC_CLI_URL:-https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/v1.4.0/ptc-cli.sh}" -o /tmp/ptc-cli.sh
    - chmod +x /tmp/ptc-cli.sh
    - rm -f /tmp/ptc-written /tmp/ptc-limit-note
    # Report the run to PTC's agent guide (scan, config digests, identity token); never fails the job.
    - /tmp/ptc-cli.sh guide action-run --config-file .ptc-config.yml || true
    # Check first (agent guide): PTC reports missing information for this commit; it never withholds the translation.
    - PTC_ORG_TOKEN="${PTC_ORG_TOKEN:-$PTC_API_TOKEN}" /tmp/ptc-cli.sh guide check --json --config-file .ptc-config.yml > /tmp/ptc-check.json || true
    # The merge request's description carries PTC's findings (set by the push below; the project setting in PTC turns
    # them off). They are printed here too, so every job log shows them, also when there is nothing new to push.
    - ptc_mr_description="$(/tmp/ptc-cli.sh guide mr-description --file /tmp/ptc-check.json)"
    # Exit 5 = partial: PTC rejected some files or could not be reached for them, and
    # every other file was written.
    # Exit 6 = partial: some files wait in PTC (an over-limit approval, or paused
    # out-of-credit) and every other file was written. Exit 7 = the translation is still running in PTC at the
    # CLI's monitor bound and every finished file was written. Deliver those below,
    # then fail the job at the end with the reason.
    - ptc_rc=0
    - /tmp/ptc-cli.sh --config-file .ptc-config.yml --written-manifest /tmp/ptc-written || ptc_rc=$?
    - if [ "$ptc_rc" -ne 0 ] && [ "$ptc_rc" -ne 5 ] && [ "$ptc_rc" -ne 6 ] && [ "$ptc_rc" -ne 7 ]; then exit "$ptc_rc"; fi
    # Exit 7: the delivery-commit report below tells PTC the run stopped while it was still translating.
    - ptc_stopped=""; if [ "$ptc_rc" -eq 7 ]; then ptc_stopped="--stopped-reason monitor_bound"; fi
    # Pushing needs a token that may write to the repository. CI_JOB_TOKEN can,
    # but ONLY if a maintainer turns on Settings > CI/CD > Job token permissions
    # > "Allow Git push requests to the repository" (GitLab 18.4+, off by
    # default). Otherwise set PTC_GIT_PUSH_TOKEN to a project access token with
    # the write_repository scope, as a masked CI/CD variable.
    # Staged from the manifest, so the merge request carries the translations and
    # nothing else - not this job's downloads, not whatever an earlier step in
    # your pipeline left in the working directory.
    #
    # `|| true` is not cosmetic: if a translation lands on a path your
    # .gitignore covers, git exits 1 while still staging everything else, and
    # GitLab would abort the job on that exit code alone.
    #
    # Staging comes BEFORE the check, and the check reads the index: on the
    # first run the translations are new files, and a plain `git diff` only
    # looks at tracked ones - it would report "nothing changed", skip the push,
    # and leave a green job that produced no merge request.
    - |
      git config user.email "ci@ptc"
      git config user.name "PTC Translate"
      git checkout -B ptc/translations
      git add --pathspec-from-file=/tmp/ptc-written --pathspec-file-nul || true
      if ! git diff --cached --quiet; then
        git commit -m "chore(i18n): update translations via PTC [skip translations]"
        ptc_mr_description="$(/tmp/ptc-cli.sh guide mr-description --file /tmp/ptc-check.json)"
        git push -o merge_request.create \
                 -o merge_request.target="$CI_DEFAULT_BRANCH" \
                 -o merge_request.title="Update translations from PTC" \
                 -o merge_request.description="$ptc_mr_description" \
                 -f "https://gitlab-ci-token:${PTC_GIT_PUSH_TOKEN:-$CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" HEAD:ptc/translations
        # PTC observes its delivery on the translations branch (P4 T14): the commit and its delivered files'
        # sha256 (S2-R14: a trusted report of PTC's delivery on the translations branch is the delivery proof).
        /tmp/ptc-cli.sh guide delivery-commit --commit "$(git rev-parse HEAD)" --branch ptc/translations --source-commit "$CI_COMMIT_SHA" --config-file .ptc-config.yml $ptc_stopped || true
      elif [ -n "$ptc_stopped" ]; then
        # Nothing finished inside the bound: PTC still hears that this run stopped, so the guide says "re-run the job".
        /tmp/ptc-cli.sh guide delivery-commit $ptc_stopped --source-commit "$CI_COMMIT_SHA" --config-file .ptc-config.yml || true
      fi
    - if [ "$ptc_rc" -eq 5 ]; then echo "PTC rejected some files or could not be reached for them (see 'Rejected by PTC' / 'Could not reach PTC' above); the rest was delivered."; exit 5; fi
    - if [ "$ptc_rc" -eq 6 ]; then echo "Some files wait in PTC - parked for an over-limit approval, or paused out-of-credit (see the lists above); the rest was delivered. Approve in PTC or top up the credit, then re-run."; exit 6; fi
    - if [ "$ptc_rc" -eq 7 ]; then echo "The translation is still running in PTC (see 'Still translating in PTC' above); the finished files were delivered. Retry this job once PTC finishes, or check progress / download manually with the commands printed there."; exit 7; fi
```

Store `PTC_API_TOKEN` as a **masked** CI/CD variable. The push needs a token
that may write to the repository: `CI_JOB_TOKEN` can, but only if a maintainer
enables Settings -> CI/CD -> Job token permissions -> "Allow Git push requests
to the repository" (GitLab 18.4+, off by default). Otherwise set
`PTC_GIT_PUSH_TOKEN` to a project access token with the `write_repository`
scope, also masked.

Loop-safe twice over: the job runs only on a push to the default branch, and the
translation push targets `ptc/translations`, which cannot re-trigger it.

### Additional Translation Files

When using YAML configuration, you can specify additional files to be generated (useful for WordPress):

```yaml
files:
  - file: languages/plugin.pot
    output: languages/plugin-{{lang}}.po
    additional_translation_files:
      - type: mo
        path: languages/plugin-{{lang}}.mo
      - type: json
        path: languages/plugin-{{lang}}.json
      - type: php
        path: includes/lang-{{lang}}.php
```

### Troubleshooting

**Common Issues:**

1. **HTTP 401 Unauthorized**
   ```text
   [ERROR] Failed to upload file: example.json (HTTP 401)
   ```
   - Check your API token
   - Verify token has correct permissions

2. **HTTP 403 Forbidden**
   ```text
   [ERROR] Failed to upload file: example.json (HTTP 403)
   ```
   - Check your API token
   - Check your Subscription
   - Verify token has correct permissions

3. **Files not found**
   ```text
   [ERROR] No files found for pattern: {{lang}}.json
   ```
   - Check file paths in config
   - Verify source locale matches your files
   - Use `--verbose` to see search details

4. **Translation timeout**
   ```text
   [WARNING] Timed out files: 1
   ```
   - Increase `--monitor-max-attempts`
   - Check translation status manually with provided curl command

## Development

See [DEVELOPMENT.md](docs/DEVELOPMENT.md) for development and testing instructions.

## License

MIT License
