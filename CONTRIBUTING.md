# Contributing to PSLiongard

Thank you for your interest in contributing. Please read this guide before submitting issues or pull requests.

## Reporting issues

Open a GitHub issue with:
- A clear description of the problem
- PowerShell version (`$PSVersionTable`) and OS
- Steps to reproduce
- Expected vs. actual behaviour

## Submitting a pull request

1. Fork the repository and create a branch from `main`.
2. Make your changes, following the conventions below.
3. Run `task lint` and `task validate` locally and confirm both pass.
4. Open a pull request against `main` with a clear description of the change.
5. Sign off each commit with your name and email.

```bash
git commit -s -m "your commit message"
```

A maintainer from `@github-maint` will review your PR. All PRs require at least one approval before merging.

## Code conventions

- One function per file in `Public/` or `Private/`; filename must match function name.
- All exported functions use the `Liongard` noun prefix (e.g. `Get-LiongardAgent`).
- New public functions must be added to `FunctionsToExport` in `PSLiongard.psd1`.
- New scripts in `Scripts/` must begin with `Import-Module "$PSScriptRoot\..\PSLiongard.psd1" -Force`.
- PSScriptAnalyzer must pass with no errors or warnings (`task lint`).

## Development setup

```bash
# macOS / Linux
brew install go-task
task install:deps

# Windows
winget install Task.Task
task install:deps
```

Re-run with `task install:deps --force` to reinstall dependencies already present.

```bash
# Lint
task lint

# Validate module loads
task validate
```

See [README.md](README.md) for full usage documentation.
