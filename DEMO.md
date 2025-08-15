# PTC CLI Demo

## Creating Test Project

```bash
# Create structure for demonstration
mkdir -p demo-project/locales/en demo-project/locales/ru demo-project/i18n

# Create translation files
echo '{"hello": "Hello", "goodbye": "Goodbye"}' > demo-project/en-copy.json
echo '{"hello": "Привет", "goodbye": "До свидания"}' > demo-project/ru-copy.json

echo '{"common": {"yes": "Yes", "no": "No"}}' > demo-project/locales/en/common.json
echo '{"common": {"yes": "Да", "no": "Нет"}}' > demo-project/locales/ru/common.json

echo 'app.title=My Application' > demo-project/i18n/en-app.properties
echo 'app.title=Мое приложение' > demo-project/i18n/ru-app.properties
```

## Usage Examples

### 1. Search files with language in name

```bash
./ptc-cli.sh -s en -p '{lang}-copy.json' -d demo-project --verbose --dry-run
```

**Result:**
```
[INFO] Starting ptc-cli.sh v1.0.0
[INFO] Dry run mode enabled
[INFO] Starting file search for source locale: en
[SUCCESS] Found 1 file(s) for pattern: en-copy.json
[INFO] Total found 1 file(s)
[INFO] [DRY RUN] Processing file: demo-project/en-copy.json
[SUCCESS] Processing completed successfully
```

### 2. Search files in language directories

```bash
./ptc-cli.sh -s en -p 'locales/{lang}/common.json' -d demo-project --verbose --dry-run
```

**Result:**
```
[INFO] Starting ptc-cli.sh v1.0.0
[INFO] Dry run mode enabled
[INFO] Starting file search for source locale: en
[SUCCESS] Found 1 file(s) for pattern: locales/en/common.json
[INFO] Total found 1 file(s)
[INFO] [DRY RUN] Processing file: demo-project/locales/en/common.json
[SUCCESS] Processing completed successfully
```

### 3. Multiple patterns

```bash
./ptc-cli.sh -s en -p '{lang}-copy.json,locales/{lang}/common.json,i18n/{lang}-app.properties' -d demo-project --verbose --dry-run
```

**Result:**
```
[INFO] Starting ptc-cli.sh v1.0.0
[INFO] Dry run mode enabled
[INFO] Starting file search for source locale: en
[SUCCESS] Found 1 file(s) for pattern: en-copy.json
[SUCCESS] Found 1 file(s) for pattern: locales/en/common.json
[SUCCESS] Found 1 file(s) for pattern: i18n/en-app.properties
[INFO] Total found 3 file(s)
[INFO] [DRY RUN] Processing file: demo-project/en-copy.json
[INFO] [DRY RUN] Processing file: demo-project/locales/en/common.json
[INFO] [DRY RUN] Processing file: demo-project/i18n/en-app.properties
[SUCCESS] Processing completed successfully
```

### 4. Real execution (without --dry-run)

```bash
./ptc-cli.sh -s en -p '{lang}-copy.json' -d demo-project --verbose
```

**Result:**
```
[INFO] Starting ptc-cli.sh v1.0.0
[INFO] Starting file search for source locale: en
[SUCCESS] Found 1 file(s) for pattern: en-copy.json
[INFO] Total found 1 file(s)
[INFO] Processing file: demo-project/en-copy.json
[SUCCESS] Processing completed successfully
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Process Translation Files
on: [push, pull_request]

jobs:
  process-translations:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Process translation files
        run: |
          chmod +x ptc-cli.sh
          ./ptc-cli.sh --source-locale en --patterns '{lang}-copy.json' --verbose
```

### Project Usage

1. **Copy `ptc-cli.sh` to your project**
2. **Make it executable**: `chmod +x ptc-cli.sh`
3. **Configure CI/CD pipeline** with needed patterns
4. **Add to your workflow** processing of found files

## Extending Functionality

In the `process_single_file()` function you can add your own logic:

- Sending files to translation server
- JSON structure validation
- Check for missing keys
- Generate reports
- Synchronization with external systems

## Configuration via Config Files

Use files in `config/examples/` directory as basis for your configurations.

Example for React application:
```bash
# config/my-app.config
SOURCE_LOCALE=en
PATTERNS='public/locales/{lang}/common.json,public/locales/{lang}/translation.json'
PROJECT_DIR=.
VERBOSE=true
```

## Debugging

For debugging use:

```bash
# Verbose output
./ptc-cli.sh -s en -p '{lang}-copy.json' --verbose

# Bash debugging
bash -x ./ptc-cli.sh -s en -p '{lang}-copy.json' --dry-run
```