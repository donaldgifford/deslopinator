---
id: DESIGN-0002
title: "CLI command surface and Cobra structure"
status: Draft
author: Donald Gifford
created: 2026-05-07
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0002: CLI command surface and Cobra structure

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-07

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Command tree](#command-tree)
  - [File layout](#file-layout)
  - [Constructor pattern](#constructor-pattern)
  - [Persistent flags](#persistent-flags)
  - [Per-command flags and behavior](#per-command-flags-and-behavior)
  - [Output formats and exit codes](#output-formats-and-exit-codes)
  - [Configuration loading](#configuration-loading)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Overview

This document specifies the concrete `deslopinator` CLI command tree,
flag layout, output formats, and exit-code semantics. ADR-0001 chose
Cobra; this design fixes the *shape* of the commands so agent integration
(skill files), the operator (which exec's the CLI in some deployment
modes), and CI consumers have a stable contract.

## Goals and Non-Goals

### Goals

- One-to-one mapping between user intent and subcommand. No "magic" flags
  that change a command's mode of operation drastically.
- Every command emits machine-readable output behind `--format json`.
- Help text is structured so the agent skill-file generator (RFC §"Agent
  integration") can consume it directly.
- Predictable exit codes for CI consumers.
- Friendly to `cobra-cli add <name>` for scaffolding new commands, with
  a documented post-scaffold cleanup pass to match our constructor
  convention.

### Non-Goals

- Plugin-discovered subcommands at runtime (RFC defers this to a possible
  Phase 4+ follow-up).
- Interactive TUI mode. Read-eval-print loops are an anti-pattern for
  agent integration; the agent runs `next`/`resolve` in a script-like
  loop instead.
- Backwards-compatibility for any prior `deslop` CLI; this is a
  greenfield surface.

## Background

The agent loop in RFC-0001 §"Agent integration" is:

```
deslopinator scan --path .
deslopinator next                 # one item, with full fix context
deslopinator resolve fixed <id> --note "..."
deslopinator next
deslopinator scan --path .        # verify
```

The skill-file synthesizer reads command help to produce
`.claude/skills/deslopinator/SKILL.md`. If help text is unstructured or
flag names drift, the skill drifts with it. Treat help as a contract.

Cobra gives us subcommands, persistent flags, completion, and structured
help out of the box. ADR-0001 also pinned a constructor-based pattern
(`newScanCmd() *cobra.Command`) over the default `cobra-cli` package-var
style. This design implements that pattern concretely.

## Detailed Design

### Command tree

```
deslopinator
├── scan          Run a scan and produce a state file.
├── next          Return the next work item from the queue.
├── resolve       Mark a finding as fixed, dismissed, or wontfix.
├── status        Summarize current state: scores, queue depth, phase.
├── findings      List or filter findings (read-only over state).
├── score         Print scores from the current state file.
├── state
│   ├── show      Pretty-print the state file.
│   ├── migrate   Run schema migrations against the state file.
│   └── validate  Validate state file integrity / signatures.
├── review
│   ├── list      List configured review providers.
│   └── run       Run a review provider against a finding (debug aid).
├── init          Bootstrap .deslopinator/ in the current repo.
├── completion    Generate shell completion scripts (Cobra builtin).
└── version       Print version, commit, build date.
```

Two-level subcommand groups (`state`, `review`) are reserved for areas
that already need ≥3 verbs. Resist the urge to add a group prematurely
— flat is fine until it isn't.

### File layout

```
cmd/deslopinator/
├── main.go                 // func main() { cmd.Execute() }
└── cmd/
    ├── root.go             // newRootCmd() + Execute()
    ├── scan.go             // newScanCmd()
    ├── next.go             // newNextCmd()
    ├── resolve.go          // newResolveCmd()
    ├── status.go           // newStatusCmd()
    ├── findings.go         // newFindingsCmd()
    ├── score.go            // newScoreCmd()
    ├── state.go            // newStateCmd() + newState{Show,Migrate,Validate}Cmd()
    ├── review.go           // newReviewCmd() + newReview{List,Run}Cmd()
    ├── init.go             // newInitCmd()
    ├── version.go          // newVersionCmd()
    ├── flags.go            // shared flag-binding helpers
    └── output.go           // shared output formatting (text/json)
```

`cmd/deslopinator/cmd/` is unusual but matches Cobra convention; the
extra `cmd/` keeps `main.go` minimal and lets the test suite import the
command constructors without binary-import gymnastics.

### Constructor pattern

```go
// cmd/deslopinator/cmd/scan.go

func newScanCmd(client api.Client, out io.Writer) *cobra.Command {
    var opts scanOptions

    c := &cobra.Command{
        Use:   "scan",
        Short: "Run a scan and produce a state file.",
        Long: `Scan walks the configured path, runs all enabled detectors, and
writes the resulting StateV1 to disk. By default it scans the current
directory and writes to .deslopinator/state.json.`,
        Example: `  deslopinator scan
  deslopinator scan --path ./services --workers 4
  deslopinator scan --no-subjective --format json`,
        RunE: func(cmd *cobra.Command, args []string) error {
            return runScan(cmd.Context(), client, out, opts)
        },
    }

    c.Flags().IntVar(&opts.Workers, "workers", 0,
        "max concurrent detector workers (0 == GOMAXPROCS)")
    c.Flags().DurationVar(&opts.PerDetectorTimeout, "per-detector-timeout",
        60*time.Second, "timeout per detector per analysis unit")
    c.Flags().BoolVar(&opts.NoSubjective, "no-subjective", false,
        "skip the subjective-review phase")
    return c
}
```

Rules:

- No package-level command vars. No `init()`. Children are wired in
  `newRootCmd` via `root.AddCommand(newScanCmd(client, out))`.
- Every command body returns `error`. No `os.Exit` calls in command code.
- Every command takes `(client api.Client, out io.Writer)` (or relevant
  subset) — never reads stdout/stderr from globals. Lets tests use
  `bytes.Buffer`.

### Persistent flags

Defined on the root command only:

| Flag | Default | Purpose |
| --- | --- | --- |
| `--config FILE` | `.deslopinator.hcl` if present | Override config file path (HCL2; ADR-0006). |
| `--path DIR` | auto-detected | Repo root to operate on. Default walks up from CWD to the nearest `.git/` directory; explicit flag or HCL `path` always wins. |
| `--profile NAME` | `default` | Named profile from config. |
| `--format {text,json,jsonl}` | `text` | Output format. Every command supports `text` (human) and `json` (single object); list-shaped commands (`findings`, `score --history`, `next --limit`) additionally support `jsonl` (one record per line). |
| `--state-file FILE` | `.deslopinator/state.json` | Override state file path. |
| `--verbose` / `-v` | `false` | Verbose logging (log/slog level Debug). |
| `--quiet` / `-q` | `false` | Suppress non-error stdout (mutually exclusive with `-v`). |
| `--no-otel` | `false` | Disable OTEL tracing/metrics for this run (ADR-0005). |
| `--no-llm-extension` | `false` | Skip the configured `LLMExtension` (Langfuse / Phoenix / etc.) for this run (ADR-0005). |
| `--no-observability` | `false` | Convenience: equivalent to `--no-otel --no-llm-extension`. |

No global `--log-format`. `--format` controls user output; logs are
always structured slog JSON to stderr when `--verbose` is set, otherwise
human-readable to stderr. Disabling observability with the above flags
short-circuits to no-op providers (zero allocations, no exporter setup).

### Per-command flags and behavior

**`scan`**

- `--workers N` — see DESIGN-0001.
- `--per-detector-timeout DUR` — see DESIGN-0001.
- `--no-subjective` — skip subjective review phase.
- `--detectors NAME[,NAME...]` — run only listed detectors (debug aid).
- `--languages LANG[,LANG...]` — restrict to languages.
- Output: scan summary (counts, score, duration). Exit 0 on completion
  regardless of findings — non-zero only on engine error.

**`next`**

- `--phase {initial,communicate,plan,triage,execute}` — restrict to
  items in a specific phase. Default returns the next phase-gated item.
- `--limit N` — return up to N items (default 1, matching RFC).
- Output: a single `WorkItem` JSON when `--format json`, formatted brief
  when `--format text`. Exit 0 with empty payload if queue is empty;
  exit 0 with payload otherwise.

**`resolve <status> <id>`**

- `<status>` is one of `fixed`, `dismissed`, `wontfix`.
- `--note STRING` — required. Empty notes return exit 2 with
  `ErrEmptyResolutionNote` (see DESIGN-0001).
- `--force` — bypass the heuristic notes-checker (lightweight check that
  the note references the modified files, per RFC §"Agent integration").
  Use sparingly; logged.
- Output: confirmation + new score delta.

**`status`**

- No required args.
- Output: current scores, queue depth per phase, last scan time.

**`findings [QUERY]`**

- Free-form query: `severity:high tier:1 lang:go`.
- `--limit N`, `--offset N` for paging.
- Output: table or JSON list.

**`score`**

- Output: strict + lenient scores. With `--history`, prints score
  trend from the append-only resolution log.

**`state show|migrate|validate`**

- `state migrate` is the only command with a non-trivial side effect.
  Requires `--yes` to actually write; otherwise prints a diff.

**`review list|run`**

- `review run --provider claude --finding ID` is a debug aid that calls
  the provider directly without going through the scorer.

**`init`**

- Creates `.deslopinator.yaml` and `.deslopinator/` with sensible
  defaults. Refuses to overwrite without `--force`.

**`completion {bash|zsh|fish|powershell}`**

- Cobra builtin. Goreleaser packages the outputs into release archives.

### Output formats and exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, including "no findings" and "queue empty". |
| 1 | Engine or runtime error (panic, ctx error, unexpected). |
| 2 | User error (bad flag, missing required value, empty resolution note). |
| 3 | Config error (file unreadable, profile not found). |
| 4 | State schema mismatch — caller should run `state migrate`. |
| 5 | Provider error (subjective review provider failed unrecoverably). |

All commands support `--format json` from day 1 — never deferred to a
later version. JSON output is part of the agent and CI integration
contract: agents read the JSON, scripts parse it. The `text` format is
the default for interactive use; `json` is mandatory for any
machine-driven caller.

- `--format text` (default) — human-readable; subject to UX changes
  between minor versions.
- `--format json` — single JSON object per invocation. Stable wire
  shape within a major version (additive).
- `--format jsonl` — newline-delimited JSON, one record per line. Used
  by list-shaped commands (`findings`, `score --history`,
  `next --limit N`). Same per-record stability as `json`.

Provider errors that produce sentinel `pkg/llm` errors (ADR-0004)
surface as exit 5 with the sentinel name in the JSON `error.code`
field — caller can branch on `ErrBackendRateLimited` vs.
`ErrBackendUnauthorized` etc. without parsing free-form text.

### Configuration loading

Config files are HCL2 (ADR-0006). The precedence chain matches
ADR-0006 §"Discovery and merge order":

1. Hard-coded defaults baked into the binary.
2. `/etc/deslopinator/config.hcl` (system-wide).
3. `$XDG_CONFIG_HOME/deslopinator/config.hcl` (user-global).
4. `./.deslopinator.hcl` (repo-local; overridable with `--config`).
5. `./.deslopinator/profiles/<profile>.hcl` (selected via `--profile`).
6. Env var `DESLOPINATOR_<UPPER_FLAG>` overrides.
7. Explicit CLI flag values.

Decoding uses `github.com/hashicorp/hcl/v2/gohcl` into the typed
`pkg/api.Config` struct. We do **not** layer viper on top — HCL2's
evaluation context already covers env-var interpolation and profile
inheritance, which were the original viper triggers in ADR-0001.

## API / Interface Changes

The CLI consumes `pkg/client.Client` (DESIGN-0003) for everything. No
direct imports of `internal/engine`. This is the rule that lets us
exercise the same code path in operator integration tests.

The CLI itself is **not** part of the API contract (see ADR-0003
§"Stability contract"). Flag names *will* change between minor versions
where it improves UX. Operator integration uses `pkg/client`.

## Data Model

The CLI defines one user-facing data model: `.deslopinator.hcl`
(HCL2; see ADR-0006 for grammar choice and ADR-0004 for backend
selection).

```hcl
version = 1

profile "default" {
  path                  = "."
  workers               = 0           # 0 == GOMAXPROCS
  per_detector_timeout  = "60s"
  languages             = []
  detectors             = []          # empty == all enabled

  review {
    enabled = true
    backend "anthropic" {
      model       = "claude-opus-4-7"
      api_key_env = "ANTHROPIC_API_KEY"
    }
  }

  observability {
    otel {
      enabled  = true
      endpoint = "localhost:4317"
      insecure = true
    }
    # Zero or one LLMExtension block. Vendor selected by block label
    # (ADR-0005). Omit the block to run plain OTEL with no LLM-specific
    # observability.
    llm_extension "langfuse" {
      host           = "https://cloud.langfuse.com"
      public_key_env = "LANGFUSE_PUBLIC_KEY"
      secret_key_env = "LANGFUSE_SECRET_KEY"
      buffered       = true
    }
  }
}

profile "ci" {
  path     = "."
  workers  = 2
  languages = ["go"]

  review        { enabled = false }   # CI runs mechanical-only
  observability {
    otel { enabled = false }
    # No llm_extension block; nothing to disable.
  }
}
```

Schema versioned via top-level `version = 1` (mirrors `StateV1`'s
versioning). Unknown attributes are warnings; unknown blocks are errors.

## Testing Strategy

- **Command-tree unit tests.** Each `newXCmd(...)` test builds the
  command, executes it against a `bytes.Buffer`, and asserts output and
  exit-equivalent error. Lives in `cmd/deslopinator/cmd/<name>_test.go`.
- **End-to-end CLI tests.** `internal/test/e2e/` builds the binary
  (via `go build`) and runs scenarios against fixture repos under
  `testdata/`. Asserts stdout, stderr, exit codes.
- **Help-text regression test.** `cmd/deslopinator/cmd/help_test.go`
  diffs the help output against a golden file. Forces help changes to
  be deliberate, since the agent skill-file generator depends on them.
- **Skill-file synthesis test.** Once Phase 5 lands, a generator test
  runs the synthesizer against the help output and diffs against a
  golden `SKILL.md`.

## Migration / Rollout Plan

This is greenfield; no migration. Rollout sequence within Phase 1:

1. Land `cmd/deslopinator/main.go` + `cmd/deslopinator/cmd/root.go`
   with `version` and `init` subcommands only. Binary builds.
2. Add `scan` (calls into a stub engine that returns an empty result).
   Smoke-tests the wiring through `pkg/client`.
3. Replace stub engine with real DESIGN-0001 engine.
4. Add `next`, `resolve`, `status`, `findings`, `score` against the new
   engine + state file.
5. Add `state` and `review` subcommand groups in Phase 2/3.

## Open Questions

1. **Should `resolve` accept a positional `<status>` or a `--status` flag?**
   **Status: resolved.** Positional: `resolve fixed ID --note "..."`.
   Shell-script-friendly and matches the "verb-object" feel of the
   agent loop.
2. **JSON output requirements.** **Status: resolved.** Day-1
   requirement: every command must support `--format json`. Default
   stays `text`. `--format jsonl` (newline-delimited JSON, useful
   for `xargs`-style pipelines on `findings`) is added as a
   third option in v1 since the format is trivial and consumers
   that need streaming won't accept "wait for v2."
3. **Viper.** **Status: resolved by ADR-0006.** HCL2 carries env-var
   interpolation and profile inheritance natively. Viper stays
   reserved as an escape hatch *only* for a future need that HCL2
   genuinely doesn't cover (e.g., a remote/etcd-backed config service).
   Don't add it speculatively. See ADR-0006 §"Discovery and merge order".
4. **Auto-detection of repo root.** **Status: resolved.** `--path`
   defaults to walking up from CWD to the nearest directory containing
   `.git/`. The CLI flag and the per-profile `path = "..."` HCL
   attribute both override the auto-detected value; explicit always
   wins. Documented in §"Persistent flags".

## References

- RFC-0001 §"Agent integration" — the loop this CLI must support.
- ADR-0001 — Cobra adoption, constructor pattern.
- ADR-0002 — stdlib-first; current approved-deps list.
- ADR-0003 — public API; the CLI consumes `pkg/client`, not internals.
- ADR-0004 — AI provider abstraction; backend block in the HCL config.
- ADR-0005 — observability; `--no-otel` / `--no-langfuse` flags.
- ADR-0006 — HCL2 config; this design's `--config` source format.
- DESIGN-0001 — engine that `scan` invokes.
- DESIGN-0003 — public client surface that the CLI calls.
- [Cobra: command structure](https://github.com/spf13/cobra/blob/main/site/content/user_guide.md).
