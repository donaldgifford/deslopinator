# deslopinator — task runner
#
# Wraps the Makefile for ergonomics. Every `make <target>` continues
# to work directly; this file is purely a convenience surface.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

allowed_licenses := "Apache-2.0,MIT,BSD-2-Clause,BSD-3-Clause,ISC,MPL-2.0"

# Default: list recipes
_default:
    @just --list --unsorted

# ─── Dev ────────────────────────────────────────────────────────────

# Format code (gofmt + goimports)
[group('dev')]
fmt:
    @make fmt

# Remove build artifacts
[group('dev')]
clean:
    @make clean

# ─── Build ──────────────────────────────────────────────────────────

# Build the deslopinator binary into build/bin/deslopinator
[group('build')]
build:
    @make build

# Run the freshly-built binary
[group('build')]
run:
    @make run

# ─── Test ───────────────────────────────────────────────────────────

# Run all tests with -race
[group('test')]
test:
    @make test

# Run tests for a single package: just test-pkg ./internal/engine
[group('test')]
test-pkg pkg:
    go test -v -race {{ pkg }}

# Run tests with coverage profile written to coverage.out
[group('test')]
test-coverage:
    @make test-coverage

# Open the HTML coverage report
[group('test')]
test-report:
    @make test-report

# ─── Lint ───────────────────────────────────────────────────────────

# Run golangci-lint
[group('lint')]
lint:
    @make lint

# Run golangci-lint with --fix
[group('lint')]
lint-fix:
    @make lint-fix

# ─── License compliance ─────────────────────────────────────────────

# Check dependency licenses against the allow list
[group('license')]
license-check:
    go-licenses check ./... --allowed_licenses={{ allowed_licenses }}

# Generate CSV report of all dependency licenses
[group('license')]
license-report:
    go-licenses report ./... --template=.github/licenses-csv.tpl

# ─── Release ────────────────────────────────────────────────────────

# Validate the goreleaser config
[group('release')]
release-check:
    goreleaser check

# Snapshot release locally (no publish, no sign)
[group('release')]
release-local:
    goreleaser release --snapshot --clean --skip=publish --skip=sign

# Tag and push a new release: just release v0.1.0
[group('release')]
release tag:
    git tag -a {{ tag }} -m "Release {{ tag }}"
    git push origin {{ tag }}

# ─── Composite gates ────────────────────────────────────────────────

# Pre-commit gate: lint + test
[group('gate')]
check: lint test
    @echo "✓ Pre-commit checks passed"

# Full CI gate: lint + test + build + license-check
[group('gate')]
ci: lint test build license-check
    @echo "✓ CI pipeline complete"
