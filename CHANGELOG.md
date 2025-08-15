# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2024-01-XX

### Added
- Initial version of PTC CLI
- Support for file search by patterns with `{lang}` substitution
- Processing of multiple patterns separated by commas
- Strict error handling for CI environments
- Color logging with levels (INFO, SUCCESS, WARNING, ERROR, DEBUG)
- Dry run mode (--dry-run)
- Verbose mode (--verbose)
- Configuration files and examples
- Automated tests
- Developer documentation
- CI/CD integration examples (GitHub Actions, GitLab CI, Jenkins)

### Supported Patterns
- `{lang}-copy.json` - files with language prefix
- `{lang}/**/*.json` - files in language subdirectories
- `locales/{lang}/messages.json` - files in structured directories
- Any custom patterns with `{lang}` substitution

### Command Line Options
- `-s, --source-locale` - source language (required)
- `-p, --patterns` - file patterns (required)
- `-d, --project-dir` - project directory
- `-v, --verbose` - verbose output
- `-n, --dry-run` - dry run mode
- `-h, --help` - help
- `--version` - version