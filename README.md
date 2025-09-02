# PTC CLI - Private Translation Cloud CLI

Bash script for processing translation files through PTC (Private Translation Cloud) API with support for various project configurations.

[Sample repositories](https://github.com/OnTheGoSystems/ptc-cli/wiki/Sample-repositories)

## Features

- 🔍 Flexible file search using globbing or explicit file configuration
- 🛡️ Strict error handling for CI environments
- 📝 Detailed logging with color highlighting
- ⚡ Optimized for CI/CD usage
- 🔄 Step-based processing (Upload → Process → Monitor → Download)
- 🎯 Isolated action support (upload, status, download)
- 📊 Compact progress monitoring with status indicators
- 🗂️ YAML configuration file support
- 📋 Additional translation files support (mo, php, json, etc.)

## Quick Start

### Using Configuration File (Recommended)

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

# Process translations with token from command line
./ptc-cli.sh --config-file .ptc-config.yml --api-token="$PTC_API_TOKEN"
```

### Using Patterns

Convenient for processing multiple files when the file or path to it contains a language code. In this case, you cannot transfer additional translation files (e.g. `mo`, `po`) or configure the output_file_path for each.

```bash
# Make script executable
chmod +x ptc-cli.sh

# Find files for English language by pattern
./ptc-cli.sh --source-locale en --patterns 'sample-{{lang}}.json' --api-token=your-token

# Find files in subdirectories
./ptc-cli.sh --source-locale en --patterns '{{lang}}/**/*.json' --api-url=https://app.ptc.wpml.org/api/v1/

# Multiple patterns
./ptc-cli.sh -s en -p 'sample-{{lang}}.json,{{lang}}-*.properties' --api-token=your-token
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
- `--api-token TOKEN` - API authentication token
- `--monitor-interval SECONDS` - Status check interval (default: 5)
- `--monitor-max-attempts COUNT` - Maximum monitoring attempts (default: 100)

**Control Options:**
- `--action ACTION` - Perform isolated action: upload, status, download
- `-v, --verbose` - Verbose output
- `-n, --dry-run` - Show what would be done without executing
- `-h, --help` - Show help
- `--version` - Show version

## Configuration File Format

The YAML configuration file supports full project setup:

```yaml
# Basic settings
source_locale: en
file_tag_name: main
api_url: https://app.ptc.wpml.org/api/v1/
# api_token: NEVER store API tokens in config files committed to repository!
# Use --api-token parameter or PTC_API_TOKEN environment variable instead

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

# Override specific settings
./ptc-cli.sh -c config.yml --api-token=different-token --file-tag-name=feature-branch

# Isolated actions
./ptc-cli.sh -c config.yml --action upload                   # Only upload files
./ptc-cli.sh -c config.yml --action status --verbose         # Check translation status
./ptc-cli.sh -c config.yml --action download                 # Download completed translations
```

**With params:**
```bash
# Basic usage
./ptc-cli.sh -s en -p 'sample-{{lang}}.json' --api-token=your-token

# Search in specific directory
./ptc-cli.sh -s de -p '{{lang}}/**/*.json' -d /path/to/project

# Dry run with verbose output
./ptc-cli.sh -s en -p '{{lang}}/*.json' --verbose --dry-run --api-token=your-token

# Multiple patterns
./ptc-cli.sh -s en -p 'i18n/{{lang}}/app.json,locales/{{lang}}/*.properties' --api-token=your-token

# WordPress WPSite example
./ptc-cli.sh -s en -p 'languages/wpsite.pot' -t main --api-token=your-token

# Isolated actions with patterns
./ptc-cli.sh -s en -p 'sample-{{lang}}.json' --action upload --api-token=your-token
./ptc-cli.sh -s en -p 'sample-{{lang}}.json' --action status --verbose --api-token=your-token
./ptc-cli.sh -s en -p 'sample-{{lang}}.json' --action download --api-token=your-token
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

## CI/CD Usage

### GitHub Actions

Add PTC_API_TOKEN to the repository secrets (Settings -> Secrets and variables -> Actions -> New repository secret).
Ensure to turn on the "Allow GitHub Actions to create and approve pull requests" permission in the repository settings (Settings -> Actions -> General -> Workflow permissions).

```yaml
name: Process Translation Files
on:
  workflow_dispatch: # Manual trigger

jobs:
  process-translations:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
      
      - name: Setup PTC CLI
        run: |
          curl -fsSL https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/refs/heads/main/ptc-cli.sh -o ptc-cli.sh
          chmod +x ptc-cli.sh
      
      - name: Process translations with PTC CLI
        env:
          PTC_API_TOKEN: ${{ secrets.PTC_API_TOKEN }}
        run: |
          ./ptc-cli.sh \
            --config-file .ptc/config.yml \
            --api-token ${{ secrets.PTC_API_TOKEN }} \
            --verbose
      
      - name: Clean up temporary files
        run: |
          rm -f ptc-cli.sh
      
      - name: Create Pull Request with translations
        if: success()
        uses: peter-evans/create-pull-request@v5
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          commit-message: "🌐 Update translations via PTC CLI"
          title: "🌐 Update translations from PTC"
          body: |
            ## 🌐 Translation Update
            
            This PR contains new translations processed by PTC CLI.
            
            **Triggered by:** ${{ github.event_name }}
            **Branch:** ${{ github.ref_name }}
            **Commit:** ${{ github.sha }}
            
            ---
            *Auto-generated by GitHub Actions*
          delete-branch: true
```

Sample `.ptc/config.yml` file:

```yaml
source_locale: en
file_tag_name: main

files:
  - file: src/locales/en.json
    output: src/locales/{{lang}}.json
```

### GitLab CI

```yaml
process_translations:
  stage: deploy
  script:
    - chmod +x ptc-cli.sh
    - ./ptc-cli.sh -c config.yml --api-token="$PTC_API_TOKEN" -v
  variables:
    PTC_API_TOKEN: "$CI_PTC_API_TOKEN"
  only:
    - merge_requests
    - main
```

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
   ```bash
   [ERROR] Failed to upload file: example.json (HTTP 401)
   ```
   - Check your API token
   - Verify token has correct permissions

2. **HTTP 403 Forbidden**
   ```bash
   [ERROR] Failed to upload file: example.json (HTTP 403)
   ```
   - Check your API token
   - Check your Subscription
   - Verify token has correct permissions

3. **Files not found**
   ```bash
   [ERROR] No files found for pattern: {{lang}}.json
   ```
   - Check file paths in config
   - Verify source locale matches your files
   - Use `--verbose` to see search details

5. **Translation timeout**
   ```bash
   [WARNING] Timed out files: 1
   ```
   - Increase `--monitor-max-attempts`
   - Check translation status manually with provided curl command

## Development

See [DEVELOPMENT.md](docs/DEVELOPMENT.md) for development and testing instructions.

## License

MIT License
