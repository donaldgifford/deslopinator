---
id: ADR-0001
title: "Cobra CLI framework with cobra-cli scaffolding"
status: Proposed
author: Donald Gifford
created: 2026-05-07
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0001. Cobra CLI framework with cobra-cli scaffolding

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
- [Consequences](#consequences)
  - [Positive](#positive)
  - [Negative](#negative)
  - [Neutral](#neutral)
- [Alternatives Considered](#alternatives-considered)
- [References](#references)
<!--toc:end-->

## Status

Proposed

## Context

RFC-0001 specifies a CLI shape with multiple subcommands (`scan`, `next`, `resolve`,
`status`, `migrate`, `init`) plus per-subcommand flags, persistent flags
(`--config`, `--path`, `--profile`), and skill-file generation that synthesizes
help output as the source of truth. The agent execution loop depends on stable
help text, structured exit codes, and machine-readable output (`--format json`).

The `flag` package in the standard library does not natively support
subcommands, command grouping, persistent flags across a command tree, shell
completion generation, or the `Run/RunE` lifecycle hooks the agent integration
needs. Building these on top of `flag` is feasible but is a meaningful chunk of
undifferentiated code that we would have to maintain ourselves — the same
class of "extra code with no benefit" that ADR-0002 (stdlib-first policy)
explicitly carves out as justified third-party adoption.

`mise.toml` already pins `github.com/spf13/cobra-cli` as a project tool, and the
`go-development` skill set assumes Cobra. Internal Go tooling (`webhookd`,
`mcpgen`, `naos`) standardizes on Cobra, so operator/agent contributors moving
between repos see the same command tree shape.

## Decision

Adopt `github.com/spf13/cobra` as the CLI framework and use `cobra-cli` for
scaffolding new commands. Use `github.com/spf13/viper` for configuration
binding (file + env + flag precedence) only where Cobra alone is insufficient;
do not introduce viper for simple flag-only commands.

Apply the following cobra-cli conventions:

- **Layout.** Commands live under `cmd/deslopinator/cmd/` with one file per
  subcommand (`root.go`, `scan.go`, `next.go`, `resolve.go`, `status.go`,
  `migrate.go`). `cmd/deslopinator/main.go` contains only `func main() { cmd.Execute() }`.
- **Construction style.** Each subcommand is built by a `newXCmd()` constructor
  that returns `*cobra.Command`. No package-level command vars and no `init()`
  registration — `root.go` wires children explicitly. This makes commands
  testable with isolated state and avoids the global mutability that the
  default `cobra-cli add` template produces.
- **`RunE` over `Run`.** All command bodies return `error`; Cobra surfaces the
  error and we get a non-zero exit code without manual `os.Exit` calls.
- **Persistent flags on root only.** `--config`, `--path`, `--profile`,
  `--format`, `--verbose` live on the root command. Subcommands declare only
  their own flags.
- **No service code in `cmd/`.** Command files parse flags, construct an
  `engine.Runner` from the public API (`pkg/api`), and call it. All business
  logic lives under `internal/engine/` (private) or `pkg/api/` (public —
  see ADR-0003).
- **Help is the source of truth.** Skill-file generation (RFC §"Agent
  integration", Phase 5) reads `cmd.Long`, `cmd.Example`, and flag descriptions
  to synthesize `SKILL.md` and `AGENTS.md`. Treat help text as a contract.

Shell completion is generated via Cobra's built-in `completion` subcommand and
shipped with goreleaser archives.

## Consequences

### Positive

- Subcommand tree, persistent flags, and shell completion come for free —
  the parts we'd otherwise reimplement on top of `flag`.
- Help text doubles as agent skill-file content; no parallel doc to drift.
- Constructor-based commands are unit-testable in isolation (`bytes.Buffer` for
  stdout/stderr, no global state mutation).
- Aligns with internal Go tooling conventions, lowering context switch cost
  for contributors.

### Negative

- Two non-stdlib dependencies (`cobra`, eventually `viper` if needed). Both are
  Apache-2.0 and well-maintained, but they pull in transitive deps that
  `license-check` and `govulncheck` will need to clear.
- `cobra-cli add` generates code in a style we don't want (package-level vars,
  `init()` registration). Contributors must follow our constructor convention
  rather than blindly running the generator. Documented in CLAUDE.md.

### Neutral

- We commit to Cobra's release cadence and breaking-change discipline. v1.x
  has been stable for years; risk is low but non-zero.
- viper, if added, brings opinions about config file locations and env var
  prefixes. We bound viper to config loading only and keep flag handling in
  Cobra.

## Alternatives Considered

**`flag` (stdlib) + hand-rolled subcommand dispatch.** Rejected. The agent
integration depends on persistent flags, structured help, and completion. The
amount of code required to recreate these is non-trivial and offers no
benefit beyond avoiding a dependency.

**`urfave/cli`.** Rejected. Smaller ecosystem footprint than Cobra, no internal
precedent, and command-tree composition is more awkward for the multi-level
subcommand layout RFC-0001 implies (`deslopinator review provider list` etc.
in later phases).

**`kong` (alecthomas).** Rejected. Tag-based command definition is elegant but
makes runtime command construction (e.g., dynamic plugin-provided commands in
RFC Phase 4) harder. We prefer explicit constructors.

**`cli` from go-kit / hand-built using `pflag` directly.** Rejected — `pflag`
solves only the flag-parsing slice of the problem; we'd still need to build
the command tree on top.

## References

- RFC-0001 §"Agent integration" — the CLI surface this ADR scaffolds for.
- DESIGN-0002 — concrete command structure and flag layout.
- ADR-0002 — stdlib-first policy this decision is consistent with.
- ADR-0003 — public API boundary that `cmd/` consumes.
- [Cobra User Guide](https://github.com/spf13/cobra/blob/main/site/content/user_guide.md)
- [cobra-cli](https://github.com/spf13/cobra-cli) — scaffolding tool pinned in `mise.toml`.
