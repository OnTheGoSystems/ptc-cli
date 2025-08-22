# PTC CLI - Private Translation Cloud CLI

Bash script for processing translation files through PTC (Private Translation Cloud) API with support for various project configurations.

## Features

- 🔍 Flexible file search using globbing or explicit file configuration
- 🛡️ Strict error handling for CI environments
- 📝 Detailed logging with color highlighting
- 🧪 Dry run mode
- ⚡ Optimized for CI/CD usage
- 🔄 Step-based processing (Upload → Process → Monitor → Download)
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

# Or set environment variable
export PTC_API_TOKEN=your-secret-token
./ptc-cli.sh --config-file .ptc-config.yml
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
- `-v, --verbose` - Verbose output
- `-n, --dry-run` - Show what would be done without executing
- `-h, --help` - Show help
- `--version` - Show version

### Pattern Examples

| Pattern | Description | Finds |
|---------|-------------|-------|
| `sample-{{lang}}.json` | Files with language extension | `sample-en.json`, `sample-de.json`, `sample-fr.json` |
| `{{lang}}/**/*.json` | All JSON files in language folders | `en/**/*.json`, `de/**/*.json` |
| `locales/{{lang}}/messages.json` | Specific file in language folder | `locales/en/messages.json` |
| `i18n/{{lang}}/*.properties` | Properties files | `i18n/en/app.properties` |
| `languages/wpsite.pot` | WordPress plugin template | `languages/wpsite.pot` |
| `languages/**/plugin.pot` | WordPress plugin templates | `languages/plugins/wpsite.pot` |

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
```

## Processing Workflow

The script follows a step-based approach:

1. **📤 Upload Step**: All files are uploaded to the PTC API
2. **⚙️ Processing Step**: Translation processing is triggered for all files
3. **👀 Monitoring Step**: Translation status is monitored with compact progress display
4. **📥 Download Step**: Completed translations are downloaded and unpacked

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

### Jenkins

```groovy
pipeline {
    agent any
    environment {
        PTC_API_TOKEN = credentials('ptc-api-token')
    }
    stages {
        stage('Process Translations') {
            steps {
                sh '''
                    chmod +x ptc-cli.sh
                    ./ptc-cli.sh --config-file config.yml --api-token="$PTC_API_TOKEN" --verbose
                '''
            }
        }
    }
}
```

## Requirements

- Bash 3.2+ (compatible with macOS default bash)
- Standard Unix utilities: `find`, `grep`, `sed`, `curl`
- Network access to PTC API
- Read permissions for project files
- Valid PTC API token for actual processing

## Project Structure

```
ptc-cli-bash/
├── ptc-cli.sh           # Main script
├── README.md            # Documentation
├── config/              # Configuration examples
│   └── examples/        # Configuration examples for different projects
│       ├── react-app.config      # React application example
│       ├── java-app.config       # Java application example
│       ├── wordpress-wpsite.config # WordPress plugin example
│       └── full-config.yml       # Complete YAML configuration example
├── tests/               # Tests
│   ├── test-runner.sh   # Test runner
│   └── fixtures/        # Test data
└── docs/                # Additional documentation
    ├── DEVELOPMENT.md   # Developer guide
    ├── DEMO.md          # Demo walkthrough
    └── CHANGELOG.md     # Version history
```

## API Integration

### Authentication

The script supports Bearer token authentication. **For security, always use environment variables or command-line parameters instead of storing tokens in config files:**

```bash
# ✅ SECURE: Via environment variable (recommended)
export PTC_API_TOKEN=your-secret-token
./ptc-cli.sh --config-file config.yml

# ✅ SECURE: Via command line parameter
./ptc-cli.sh --config-file config.yml --api-token="$PTC_API_TOKEN"

# ❌ INSECURE: Never store tokens in config files committed to repository!
# api_token: your-secret-token  # DON'T DO THIS!
```

**Security Best Practices:**
- Use CI/CD secrets management (GitHub Secrets, GitLab Variables, etc.)
- Store tokens in environment variables
- Use local config files (ignored by git) for development
- Never commit API tokens to version control

**For Local Development:**
```bash
# Create a local config with your token (ignored by git)
cp config/examples/config.local.yml.example config.local.yml
# Edit config.local.yml with your real API token
./ptc-cli.sh --config-file config.local.yml
```

### API Endpoints

The script uses the following PTC API endpoints:

- `POST /source_files` - Upload files for translation
- `PUT /source_files/process` - Trigger translation processing
- `GET /source_files/translation_status` - Check translation status
- `GET /source_files/download_translations` - Download completed translations

### Additional Translation Files

When using YAML configuration, you can specify additional files to be generated:

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

These are sent to the API as JSON array: `[{"type":"mo","path":"languages/plugin-{{lang}}.mo"},{"type":"json","path":"languages/plugin-{{lang}}.json"},{"type":"php","path":"includes/lang-{{lang}}.php"}]`

## Error Handling

The script uses strict bash mode (`set -euo pipefail`) and properly handles errors:

- **Exit code 0**: Successful execution
- **Exit code 1**: Argument validation error or no files found
- **Exit code 2**: File processing error

### Troubleshooting

**Common Issues:**

1. **HTTP 401 Unauthorized**
   ```bash
   [ERROR] Failed to upload file: example.json (HTTP 401)
   ```
   - Check your API token
   - Verify token has correct permissions

2. **HTTP 404 Not Found**
   ```bash
   [ERROR] Failed to upload file: example.json (HTTP 404)
   ```
   - Check your API URL
   - Verify the endpoint exists

3. **Files not found**
   ```bash
   [ERROR] No files found for pattern: {{lang}}.json
   ```
   - Check file paths in config
   - Verify source locale matches your files
   - Use `--verbose` to see search details

4. **Translation timeout**
   ```bash
   [WARNING] Timed out files: 1
   ```
   - Increase `--monitor-max-attempts`
   - Check translation status manually with provided curl command

## Logging

The script supports color logging:

- 🔵 **INFO**: General information
- 🟢 **SUCCESS**: Successful operations
- 🟡 **WARNING**: Warnings
- 🔴 **ERROR**: Errors
- 🔵 **DEBUG**: Debug information (only with --verbose)

## Development

See [DEVELOPMENT.md](docs/DEVELOPMENT.md) for development and testing instructions.

## License

MIT License