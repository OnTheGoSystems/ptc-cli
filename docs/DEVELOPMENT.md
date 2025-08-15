# PTC CLI Developer Guide

## Project Structure

```
ptc-cli-bash/
├── ptc-cli.sh                    # Main executable script
├── README.md                     # Main documentation
├── config/                       # Configurations
│   └── examples/                # Configuration examples
│       ├── react-app.config     # For React applications
│       └── java-app.config      # For Java applications
├── tests/                        # Testing
│   ├── test-runner.sh           # Main test runner
│   └── fixtures/                # Test data (created automatically)
└── docs/                         # Documentation
    └── DEVELOPMENT.md           # This guide
```

## Script Architecture

### Main Components

1. **Argument parsing**: Command line processing with support for long and short options
2. **Validation**: Input data and environment checking
3. **File search**: Search system with globbing and pattern support
4. **Processing**: Main logic for working with found files
5. **Logging**: Color output with different levels

### Design Principles

- **Fail Fast**: Stop on first error
- **Strict mode**: `set -euo pipefail`
- **Idempotency**: Repeated runs give same result
- **Transparency**: Detailed logging of all operations
- **Modularity**: Separation into functions with clear responsibilities

## Development

### Environment Setup

```bash
# Clone project
git clone <repository-url>
cd ptc-cli-bash

# Set execution permissions
chmod +x ptc-cli.sh
chmod +x tests/test-runner.sh
```

### Running Tests

```bash
# Run all tests
./tests/test-runner.sh

# Test specific functionality
./ptc-cli.sh -s en -p '{lang}-copy.json' --dry-run --verbose
```

### Debugging

Enable verbose mode for debugging:

```bash
./ptc-cli.sh -s en -p '{lang}/**/*.json' --verbose --dry-run
```

For additional bash debugging you can use:

```bash
bash -x ./ptc-cli.sh -s en -p '{lang}-copy.json' --dry-run
```

## Adding New Features

### 1. Adding new option

1. Add variable in "Default variables" section
2. Add handling in `main()` function in argument parsing section
3. Add validation in `validate_args()` function
4. Update `show_help()`
5. Add tests

Example of adding `--timeout` option:

```bash
# In variables section
TIMEOUT=300

# In argument parsing
-t|--timeout)
    TIMEOUT="$2"
    shift 2
    ;;

# In validation
if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    log_error "Timeout must be a number: $TIMEOUT"
    return 1
fi
```

### 2. Adding new pattern type

Modify `find_files_by_pattern()` function to support new patterns.

### 3. Adding new processing logic

Main processing logic is in `process_single_file()` function. Add your logic there.

## Coding Standards

### Bash Style

- Use `readonly` for constants
- Always use `local` for function variables
- Quote variables: `"$variable"`
- Use `[[ ]]` instead of `[ ]` for conditions
- Functions should return 0 on success, non-0 on error

### Naming

- Constants: `UPPER_SNAKE_CASE`
- Variables: `lower_snake_case`
- Functions: `lower_snake_case`
- Private functions: `_prefixed_with_underscore`

### Logging

Use appropriate logging functions:

```bash
log_info "General information"
log_success "Successful operation"
log_warning "Warning"
log_error "Error"
log_debug "Debug information"
```

## Testing

### Test Structure

Tests are in `tests/test-runner.sh` and follow the pattern:

```bash
test_function_name() {
    # Test logic
    return 0  # success
    return 1  # failure
}

run_test "Test description" test_function_name
```

### Adding New Test

1. Create test function in `test-runner.sh`
2. Add `run_test` call in `main()` function
3. If needed, add test data in `setup_fixtures()`

### Test Data

Test files are automatically created in `setup_fixtures()` and removed in `cleanup_fixtures()`.

## CI/CD Integration

### Environment Variables

Script supports configuration via environment variables:

- `PTC_SOURCE_LOCALE`
- `PTC_PATTERNS`
- `PTC_PROJECT_DIR`
- `PTC_VERBOSE`
- `PTC_DRY_RUN`

### Exit Codes

- `0`: Successful execution
- `1`: Validation error or no files found
- `2`: File processing error

### Logs

In CI environments, color codes are automatically disabled when necessary.

## Security

### Input Validation

- All user input is validated
- File paths are checked for existence
- Prevents execution of arbitrary commands

### Temporary Files

If temporary files are created, they should:
- Be created in a secure location
- Be removed in `cleanup()` function
- Have restricted access permissions

## Performance

### Optimizations

- Use `mapfile` instead of loops for reading command output
- Minimize number of external command calls
- Cache results of repeated operations

### Limitations

- For very large projects (>10000 files) consider using `parallel`
- Add timeouts for long-running operations

## Troubleshooting

### Common Issues

1. **Files not found**: Check patterns and paths
2. **Permission denied**: Ensure file permissions
3. **Bash version**: Requires Bash 3.2+ (compatible with macOS default)

### Debugging

```bash
# Enable bash debugging
set -x

# Check bash version
bash --version

# Check file permissions
ls -la ptc-cli.sh
```

## Extensions

### Plugins

To extend functionality you can add plugin system:

1. Create `plugins/` directory
2. Add plugin loading mechanism
3. Define plugin API

### Configuration Files

System already supports configuration files. To add new formats modify configuration loading logic.

## Releases

### Versioning

Uses semantic versioning (semver):
- `MAJOR.MINOR.PATCH`
- Update version in `VERSION` constant

### Release Process

1. Update version in script
2. Update CHANGELOG
3. Create git tag
4. Test on all supported platforms