# CLI reference

For anyone running `ptc-cli.sh` by hand or in a script: usage, options, configuration file, workflow and exit codes.

## Install

From the repository root:

```bash
mkdir -p .ptc/bin && curl -fsSL https://app.ptc.wpml.org/cli/ptc-cli.sh -o .ptc/bin/ptc-cli.sh && chmod +x .ptc/bin/ptc-cli.sh
```

Every `ptc` command in these docs is `.ptc/bin/ptc-cli.sh` run from the
repository root (alias it as `ptc` if you like).

## Usage

```bash
.ptc/bin/ptc-cli.sh auth login                   # you, once: approve the sign-in in your browser; saves your agent token (mode 600)
.ptc/bin/ptc-cli.sh auth login --paste           # or paste the token from the agent token page
.ptc/bin/ptc-cli.sh init                         # detect the project, write .ptc-config.yml and print a CI snippet (prompts first)
.ptc/bin/ptc-cli.sh init --dry-run --verbose     # preview
.ptc/bin/ptc-cli.sh init --yes --force           # non-interactive, overwrite
.ptc/bin/ptc-cli.sh --config-file .ptc-config.yml
.ptc/bin/ptc-cli.sh -s en -p 'sample-{{lang}}.json,{{lang}}-*.properties'   # patterns instead of a config
```

`init` sends file **paths only** to the anonymous `detect_config` endpoint (no
token), respects `.gitignore` and `.ptcignore`, and writes a commented template
for an unrecognised layout. Patterns cannot carry additional files or outputs.

## Options

| Option | Meaning |
|---|---|
| `-c, --config-file FILE` | YAML configuration file (recommended) |
| `-p, --patterns PATTERNS` | File patterns, comma-separated |
| `-s, --source-locale LOCALE` | Source language (required unless in config) |
| `-t, --file-tag-name TAG` | File tag / branch name (default: from git) |
| `-d, --project-dir DIR` | Project directory (default: current) |
| `--api-url URL` | Default `https://app.ptc.wpml.org/api/v1/` |
| `--api-token TOKEN` | Override; prefer `ptc auth login` or `PTC_API_TOKEN` |
| `--monitor-interval SECONDS` | Status check interval (default 5) |
| `--monitor-max-attempts COUNT` | Max monitoring attempts (default: max(100, 20 x the number of files)) |
| `--monitor-max-minutes MIN` | Wall-clock bound for monitoring, from the first upload (default: 45); exit `7` when reached |
| `--written-manifest FILE` | Write the list of files the run wrote, NUL-separated and relative to the repository root (CI stages exactly these) |
| `--action ACTION` | Isolated action: `upload`, `status`, `download` |
| `-v, --verbose` / `-n, --dry-run` | Verbose output / show without executing |
| `-h, --help` / `--version` | Help / version |

Values go as a separate argument (`--file-tag-name my-branch`). `--flag=value`
works only for `--api-url`, `--api-token`, `--monitor-interval`,
`--monitor-max-attempts`, `--monitor-max-minutes`, `--written-manifest` and
`--action` (`init`: `--api-url`, `--api-token`,
`--project-dir`).

**Token.** Your agent token, from PTC's agent token page
(<https://app.ptc.wpml.org/dashboard/agent-tokens>; one per user, minted the
first time you need it, rotated there, never a second one). On your machine you
save it once with `ptc auth login`: at a terminal it prints a link and a code
(and opens the link unless `--no-browser`), you approve the code on PTC signed in
as yourself, and the CLI receives the token (no token is typed); `--paste` (or a
token piped on stdin) takes the token instead, nothing shown. It checks the
token with PTC and saves it, mode 600, to `%APPDATA%\ptc\credentials` when
`APPDATA` is set (Git Bash, MSYS, Cygwin), else
`${XDG_CONFIG_HOME:-~/.config}/ptc/credentials`. Your agent never receives or
types the token. The CLI takes the first of `--api-token`, `PTC_API_TOKEN`,
`PTC_AGENT_TOKEN` (the legacy `PTC_ORG_TOKEN` is still accepted), then that
file. In CI it is a masked secret named `PTC_API_TOKEN`.

**Preflight.** Every run except `--dry-run` first validates the token and
prints the account state in one line. It stops before any upload only when the
token is missing or rejected or the subscription is inactive; anything else
(unreachable API, a source locale that disagrees with the PTC project, a zero
balance) is a warning.

## Configuration file

```yaml
source_locale: en
file_tag_name: main
api_url: https://app.ptc.wpml.org/api/v1/
monitor_interval: 5
monitor_max_attempts: 100   # default: max(100, 20 x the number of files)
monitor_max_minutes: 45   # wall clock from the first upload; reached with files still translating -> exit 7

files:
  - file: src/locales/en.json
    output: src/locales/{{lang}}.json
  - file: languages/plugin.pot
    output: languages/plugin-{{lang}}.po
    additional_translation_files:   # mo, po, json, php
      - type: mo
        path: languages/plugin-{{lang}}.mo
      - type: json
        path: languages/plugin-{{lang}}-wp.json
```

## Workflow

A full run is Preflight → Upload → Process → Monitor → Download. `--action
upload|status|download` runs one step (e.g. upload in one CI job, download in
another). Monitoring prints one letter per file: `C` completed, `Q` queued,
`P` processing, `F` failed, `U` unknown, `$` out of credit, `A` awaiting or
expired approval, `.` pending, `D` draft, `R` rejected, `V` reviewing (e.g.
`CQ 27/30`).

A **suite** project whose setup is unfinished gets `code: suite_setup_pending`:
PTC stores the upload, the CLI does not wait, the next run delivers.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Every file completed (`--action status`: every file ready or still translating; also files held for their suite beside completed ones). |
| `1` | Something did not complete: a file failed, no files found, a request rejected, invalid arguments. |
| `5` | Partial: PTC rejected some files (listed under "Rejected by PTC"), or could not be reached for them after 3 retries (5 s, 10 s, 20 s; `PTC_TRANSIENT_BASE_DELAY`), listed under "Could not reach PTC". Every other file was written. |
| `6` | Partial: some files paused out-of-credit or parked behind an over-limit approval (approve in PTC or raise the limit; the next run picks them up). Every other file was written. |
| `7` | Stopped at the monitor bound (`monitor_max_minutes`, default 45; `--monitor-max-minutes`, `PTC_MONITOR_MAX_MINUTES`; or `monitor_max_attempts`) with files still translating and nothing failed. Finished files are written; the summary prints the exact `--action status` and `--action download` commands. |
| `13` | Nothing delivered: PTC stored every file without translating it because the suite's setup is not finished. |
| `129` / `130` / `143` | Stopped by SIGHUP / SIGINT / SIGTERM. |

A partial run is a failure: ptc-action and the GitLab recipe deliver what was
written, then fail the job with the reason.

## Troubleshooting

| Symptom | Check |
|---|---|
| `[ERROR] Failed to upload file: example.json (HTTP 401)` | The agent token: if it was rotated, run `ptc auth login` again with the current one |
| `[ERROR] Failed to upload file: example.json (HTTP 403)` | The agent token, your subscription, whether you still administer the organization |
| `[WARNING] No files found for pattern: {{lang}}.json` | File paths in the config; the source locale matches your files; rerun with `--verbose` |
| `[WARNING] Still translating in PTC: N` / exit 7 | Wait and run the printed `--action status` / `--action download` commands, or raise `monitor_max_minutes` |
