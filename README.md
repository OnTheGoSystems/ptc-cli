# PTC CLI - Private Translation Cloud CLI

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
| `1` | Something did not complete: a file failed, a file was still unfinished when monitoring ran out, no files were found, the API rejected a request, or the arguments were invalid. |

**A partial run is a failure.** If ten files are submitted and one fails, the exit code is `1`. The summary lines above it list what completed, what failed and what was left unfinished, so the log says which is which.

**A timeout is a failure too.** Files still translating when `monitor_max_attempts` runs out are reported as unfinished and the run exits `1`. Raise `monitor_max_attempts` / `monitor_interval` (see [Configuration File Format](#configuration-file-format)) for projects that need longer than the default ~8 minutes.

`--action status` is the exception worth knowing: a translation still in progress is a legitimate answer and exits `0`. Only a terminal failure, or a status that could not be read at all, exits `1`.

## CI/CD Usage

### Pinning the CLI version

Pipelines download the script from a **pinned release tag**, not a moving branch,
so a push to `main` can never change what your build runs:

```bash
curl -fsSL https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/v1.0.3/ptc-cli.sh -o ptc-cli.sh
```

Use an exact release tag such as `v1.0.3` to pin, or the floating `v1` tag to
pick up backward-compatible updates automatically. `ptc init` scaffolds the
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

jobs:
  translate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
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
  rules:
    - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
  before_script:
    - apk add --no-cache bash curl git unzip
  script:
    - curl -fsSL https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/v1.0.3/ptc-cli.sh -o ptc-cli.sh
    - chmod +x ptc-cli.sh
    - ./ptc-cli.sh --config-file .ptc-config.yml
    - |
      if ! git diff --quiet; then
        git config user.email "ci@ptc"
        git config user.name "PTC Translate"
        git checkout -B ptc/translations
        git add -A
        git commit -m "chore(i18n): update translations via PTC [skip ci]"
        git push -o merge_request.create \
                 -o merge_request.target="$CI_DEFAULT_BRANCH" \
                 -o merge_request.title="Update translations from PTC" \
                 -f "https://gitlab-ci-token:${PTC_GIT_PUSH_TOKEN:-$CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" HEAD:ptc/translations
      fi
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
