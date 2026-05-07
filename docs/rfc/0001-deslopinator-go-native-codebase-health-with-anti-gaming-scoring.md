---
id: RFC-0001
title: "Deslopinator: Go-native codebase health with anti-gaming scoring"
status: Draft
author: Donald Gifford
created: 2026-05-07
---

<!-- markdownlint-disable-file MD025 MD041 -->

# RFC 0001: Deslopinator: Go-native codebase health with anti-gaming scoring

**Status:** Draft **Author:** Donald Gifford **Date:** 2026-05-07

<!--toc:start-->

- [RFC 0001: Deslopinator: Go-native codebase health with anti-gaming scoring](#rfc-0001-deslopinator-go-native-codebase-health-with-anti-gaming-scoring)
  - [Summary](#summary)
  - [Problem Statement](#problem-statement)
  - [Proposed Solution](#proposed-solution)
  - [Design](#design)
    - [High-level architecture](#high-level-architecture)
    - [Concurrency model](#concurrency-model)
    - [State schema with explicit migrations](#state-schema-with-explicit-migrations)
    - [Subjective review provider interface](#subjective-review-provider-interface)
    - [Scoring honesty: what we adopt, what we tighten](#scoring-honesty-what-we-adopt-what-we-tighten)
    - [Agent integration](#agent-integration)
  - [Alternatives Considered](#alternatives-considered)
  - [Implementation Phases](#implementation-phases)
    - [Phase 1: Rename + scaffold](#phase-1-rename-scaffold)
    - [Phase 2: Scoring + state + queue](#phase-2-scoring-state-queue)
    - [Phase 3: Subjective review provider abstraction](#phase-3-subjective-review-provider-abstraction)
    - [Phase 4: Multi-language plugins](#phase-4-multi-language-plugins)
    - [Phase 5: Agent skill synthesis + production hardening](#phase-5-agent-skill-synthesis-production-hardening)
  - [Risks and Mitigations](#risks-and-mitigations)
  - [Success Criteria](#success-criteria)
  - [References](#references)
  <!--toc:end-->

## Summary

Rename `deslop` to **deslopinator** and re-scope it from a Go-only static
analyzer into a multi-language, agent-first codebase health tool that leverages
Go's native concurrency and single-binary distribution. Core differentiator from
prior art (notably `peteromallet/desloppify`) is a tighter execution model —
true within-run parallelism via worker pools, a versioned state schema with
explicit migrations, swappable subjective-review providers, and an OSI-approved
license — while adopting desloppify's most valuable design idea: an anti-gaming
scoring model that gives agents a north-star they cannot dismiss their way to
perfection on.

> "Listen, and understand. That slop has no pity, no remorse, no unused-import
> detector. And it absolutely will not stop, ever, until your CI is dead."

## Problem Statement

Vibe-coded and agent-generated codebases accumulate a specific class of debt
that traditional linters miss: dead abstractions, near-duplicate functions,
naming drift, mixed error-handling conventions, and "looks-correct-but-isn't"
type sprawl. The detection layer is solvable; the harder problems are scoring
honesty and agent integration.

Existing tools fall into three buckets, none of which fit our needs:

1. **Traditional linters** (golangci-lint, ruff, eslint) — mechanical, no
   subjective review, no scoring, no cross-session state, no agent integration.
2. **AI-assisted reviewers** (Copilot, CodeRabbit) — opaque, per-PR, no
   persistent state, no resistance to gaming, no plugin model.
3. **`peteromallet/desloppify`** — closest match to what we want conceptually.
   Strong scoring philosophy, real plugin architecture, but Python-only,
   source-available (OSNL) rather than OSS, "29 languages" claim masks 17 stub
   plugins, and the within-run scan is single-process.

The internal context matters: we already maintain a Go-heavy platform stack
(`webhookd`, `mcpgen`, `wiz-go-sdk`, agent platform, docz, `naos`). A static
analysis tool we control end-to-end — that ships as a single binary, fits our
existing operator/CLI patterns, and is licensed permissively enough to ship
inside customer-facing tooling — is more valuable than adopting an upstream we
can't shape.

The bet underlying this RFC is that the _interesting_ work is not the detectors;
it is the **scoring honesty model and the agent execution queue**. Detectors are
table stakes — `golangci-lint`, `staticcheck`, `revive`, ruff, `clippy`,
tree-sitter queries — and we will compose them rather than reinvent them where
sensible. The scoring layer is where we win or lose.

## Proposed Solution

Build `deslopinator` as a Go-native CLI with the following shape:

**Single binary, native concurrency.** One static binary produced by
`goreleaser` across linux/darwin/amd64/arm64. Within-run parallelism via a
configurable worker pool over the file set, with a fan-out/fan-in pattern for
detector phases. No "install with `[full]` extras to make it work" footgun — the
default install is the complete tool.

**SSA + `dave/dst`-grounded Go analysis.** For Go targets, leverage the existing
`deslop` SSA+dst foundation for semantic detectors (unused functions, dead
branches, near-duplicate bodies via normalized SSA hashing, mutable global
state). For non-Go targets, treat tree-sitter as the universal substrate and
shell out to native linters where they exist.

**Anti-gaming scoring, ported and tightened.** Adopt desloppify's strict-score
model (open + wontfix both count as debt, attestation required on resolution,
subjective scores re-checked against suspicious-target alignment) and tighten
it: add provider-attestation signing on subjective reviews, require a non-empty
resolution note for _any_ status transition (not just `wontfix`), and persist
score history so trend lines are auditable.

**Pluggable subjective review providers.** First-class interface for the
LLM-driven review layer: Claude API, Copilot CLI (subprocess), local
`mlx_vlm.server` Qwen3 models, OpenRouter, or a no-op stub for environments
without LLM access. Desloppify hardcodes a single review path; we make it a
boundary.

**Agent execution queue with phase enforcement.** `deslopinator next` returns
exactly one work item from a triaged queue, with phase gating (initial reviews →
communicate score → plan → triage → execute). The queue is the agent's only
input — they don't reason over the full backlog, they consume the queue and
report back via `resolve`.

**OSI-approved license.** Apache 2.0. We are not in the source-available
business; the platform value is in the agent integration and our own deployment,
not in license-tier rent extraction.

## Design

### High-level architecture

```
deslopinator/
├── cmd/deslopinator/         # CLI entry point (cobra)
├── internal/
│   ├── engine/               # Language-agnostic core
│   │   ├── detector/         # Generic algorithms (dupes, gods, naming, ...)
│   │   ├── scoring/          # Strict + lenient score, anti-gaming policy
│   │   ├── state/            # Versioned state schema + migrations
│   │   ├── queue/            # Execution queue, phase gating, ranking
│   │   └── parallel/         # Worker pool, fan-out/fan-in primitives
│   ├── lang/                 # Language plugins
│   │   ├── golang/           # SSA+dst-based, deepest plugin
│   │   ├── python/           # tree-sitter + ruff adapter
│   │   ├── typescript/       # tree-sitter + tsc adapter
│   │   ├── rust/             # tree-sitter + clippy adapter
│   │   └── ...
│   ├── review/               # Subjective review provider interface
│   │   ├── provider/         # Claude, Copilot, MLX, stub
│   │   └── prompt/           # Per-dimension prompts, versioned
│   ├── attestation/          # Resolution signing, score history
│   └── agent/                # Agent skill files, prompt synthesis
└── pkg/
    └── api/                  # Public types for plugin authors
```

Boundary rule (lifted from desloppify, enforced via `internal/`): `lang/` may
import from `engine/`, never the reverse. This keeps the scoring/queue logic
language-agnostic and makes adding a language a strictly additive operation.

### Concurrency model

The detection phase is the obvious concurrency win Go gives us that desloppify
doesn't have. Sketch:

```go
type Detector interface {
    Name() string
    Tier() int
    Run(ctx context.Context, units <-chan AnalysisUnit) <-chan Finding
}

func RunPhase(ctx context.Context, dets []Detector, units []AnalysisUnit) ([]Finding, error) {
    // Fan-out units to workers, fan-in findings.
    // Worker count: min(GOMAXPROCS, cfg.MaxWorkers, len(units))
    // Each detector consumes its own copy of the unit stream — bounded by ring
    // buffer to keep memory predictable on large repos.
}
```

Detector independence is the property that makes this safe — the union-find
clustering in `dupes`, for example, is a serial reduce step _after_ the parallel
pairwise scoring. We model this explicitly: detectors declare whether they are
pure-parallel, parallel-then-reduce, or strict-serial.

This connects directly to the parallelism story we already worked out for the
Renovate operator (RFC-0001 / DESIGN-0001) — sharding work across worker pods to
amortize startup cost. Same pattern, different layer: there it was Indexed Jobs
across pods, here it is goroutines across cores.

### State schema with explicit migrations

Desloppify's `dupes.py` cache validation (defensive `isinstance` ladders on its
own state file) is a smell — it suggests the schema isn't versioned tightly
enough to trust. We do this differently:

```go
type StateV1 struct {
    SchemaVersion int                  `json:"schema_version"` // 1
    ScanPath      string               `json:"scan_path"`
    Findings      map[FindingID]Finding `json:"findings"`
    Scores        ScoreSnapshot         `json:"scores"`
    Resolutions   []Resolution          `json:"resolutions"`
}
```

Migrations are explicit upgrade functions (`migrateV1ToV2`, etc.), gated by
`SchemaVersion`. State files older than the binary refuse to load with a clear
error pointing at a migration command. No defensive parsing of our own output.

### Subjective review provider interface

```go
type ReviewProvider interface {
    Name() string
    Review(ctx context.Context, req ReviewRequest) (ReviewResponse, error)
    Capabilities() ProviderCapabilities // streaming, batch, tool-use, etc.
}

type ReviewRequest struct {
    Dimension  Dimension      // naming_quality, abstraction_fitness, ...
    Scope      ReviewScope    // file, package, repo
    Context    []SourceFile
    PriorScore *float64       // for re-review consistency checks
}
```

Providers ship in-tree under `internal/review/provider/`. Out-of-tree providers
are a deliberate non-goal for v1 — keeping it in-tree means we control the
prompt-versioning and attestation chain. We can revisit a provider plugin API if
there is real demand.

### Scoring honesty: what we adopt, what we tighten

| Mechanism                  | Desloppify                  | Deslopinator                                       |
| -------------------------- | --------------------------- | -------------------------------------------------- |
| Open findings → debt       | ✅ lenient + strict         | ✅                                                 |
| Wontfix → strict debt only | ✅                          | ✅                                                 |
| Attestation on resolve     | Required note for `wontfix` | Required note for **all** transitions              |
| Subjective re-review       | Flags target-aligned scores | Flags + signed re-review with provider attestation |
| Score history              | Snapshot per scan           | Append-only signed log, auditable                  |
| Subjective weight          | 75% of total                | 60% (configurable; see Risks)                      |
| Game resistance            | Implicit in design          | Explicit policy doc + test suite                   |

The 75% → 60% subjective weight change is deliberate. Desloppify's bet is that
LLM review is reliable enough to weight that heavily; our internal experience
with Qwen3-35B-A3B local vs. Claude Opus on the server price tracker code review
suggests subjective dimensions vary materially between providers and deserve
more bounded influence. Configurable per-repo.

### Agent integration

`deslopinator` ships skill files at install time for the agents we use
internally: Claude (`.claude/skills/deslopinator/SKILL.md`), Codex
(`.agents/skills/deslopinator/SKILL.md`), and a generic `AGENTS.md` for others.
The skill file content is synthesized from the same source we use for `--help`,
so they cannot drift.

The execution loop the agent runs is:

```
deslopinator scan --path .
deslopinator next                 # one item, with full fix context
# agent does the fix
deslopinator resolve fixed <id> --note "what I actually did"
deslopinator next                 # next item
# ...
deslopinator scan --path .        # verify, catch cascade effects
```

The `--note` requirement on every `resolve` is the central anti-gaming knob.
Empty notes, repeated notes, and notes that don't reference the modified files
are all flagged (lightweight heuristic, not LLM-backed — kept cheap so it runs
every time).

## Alternatives Considered

**Adopt desloppify directly.** Rejected for license, language fit, and shape
control. OSNL's commercial tiers are a real concern if we ever ship deslopinator
inside a product or share it with a partner; even for purely internal use the
license requires us to track our own commercialization status carefully. Python
also doesn't fit our team's deployment patterns — we ship Go binaries, run them
as Kubernetes operators, and integrate with Go-native tooling like `wiz-go-sdk`.

**Fork desloppify and translate to Go.** Rejected as worst-of-both-worlds —
inherits design decisions made for Python's runtime constraints (single-process
scan, dynamic plugin discovery via `__init__.py` side effects, defensive state
parsing) without the Python ecosystem benefits (existing
`tree-sitter-language-pack`, `ruff`, `bandit` as direct imports). A clean-room
Go implementation that _learns from_ desloppify's scoring philosophy is cheaper
than a translation that fights both languages.

**Build only on top of `golangci-lint` plugins.** Rejected because golangci-lint
is the wrong abstraction layer — it is a linter aggregator, not a state machine.
We need persistent state across scans, scoring, queue management, and subjective
review. golangci-lint is one of several detectors we _call into_ from a Go
plugin, not the framework.

**Skip subjective review entirely; mechanical-only scoring.** Rejected because
the actually-interesting debt in agent-generated code is structural and
subjective: bad abstractions, naming drift, error-handling pattern soup. A
mechanical-only score would optimize the wrong thing and quickly hit a ceiling
where agents can dismiss further work as "no findings." The subjective layer is
where the score earns its keep.

## Implementation Phases

Each phase produces a working binary. We do not merge phase N until phase N
ships green on internal repos.

### Phase 1: Rename + scaffold

- Rename module `github.com/donaldgifford/deslop` → `.../deslopinator`.
- Migrate the existing SSA+dst Go detection code into `internal/lang/golang/`.
- Stand up the `cmd/deslopinator` cobra entry point, `engine/` skeleton, and
  versioned state schema (`StateV1`).
- `deslopinator scan` and `deslopinator status` work on Go targets only.
- DESIGN doc to follow this RFC: `DESIGN: Deslopinator engine and worker pool`.

### Phase 2: Scoring + state + queue

- Strict/lenient score implementation with full anti-gaming policy.
- Append-only signed resolution log.
- Execution queue with phase gating and `next`/`resolve` commands.
- ADR: `ADR: Scoring weights and re-review consistency policy`.

### Phase 3: Subjective review provider abstraction

- `ReviewProvider` interface and in-tree implementations: Claude API, stub.
- Versioned per-dimension prompts under `internal/review/prompt/`.
- ADR: `ADR: Subjective review provider boundary and prompt versioning`.

### Phase 4: Multi-language plugins

- Python (tree-sitter + ruff adapter).
- TypeScript (tree-sitter + tsc adapter).
- Rust (tree-sitter + clippy adapter).
- Plugin contract validation harness.

### Phase 5: Agent skill synthesis + production hardening

- Skill file generation from `--help` source-of-truth.
- Goreleaser multi-arch binaries.
- Internal dogfood on `webhookd`, `mcpgen`, `naos`, this repo itself.

## Risks and Mitigations

| Risk                                                                                   | Impact | Likelihood | Mitigation                                                                                                                                |
| -------------------------------------------------------------------------------------- | ------ | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Subjective review dominates score; LLM drift makes scores meaningless across providers | High   | Medium     | Bound subjective weight to 60% configurable; require provider attestation on every review; freeze prompt versions per release             |
| Within-run parallelism introduces detector ordering bugs                               | Medium | Medium     | Detectors declare parallel/reduce/serial mode explicitly; CI runs every detector under `-race` and with deterministic seed                |
| State schema migrations break on real-world repos                                      | High   | Low        | Migrations are forward-only, gated by `SchemaVersion`; binary refuses to load unknown versions; migration command emits diff              |
| "29 languages" trap — we add stubs that pretend to work                                | Medium | Medium     | Plugin contract test suite distinguishes "full" from "tree-sitter-only" tiers; CLI surfaces the tier; README is honest                    |
| Desloppify ships v1 with similar design first; we look like a fork                     | Low    | Medium     | Differentiation is concrete (Go binary, native concurrency, OSS license, provider abstraction); credit desloppify explicitly in docs      |
| Agent gaming we didn't anticipate                                                      | High   | Medium     | Anti-gaming policy lives in a versioned doc with a regression test suite; new gaming vectors get added as test cases, not as code patches |

## Success Criteria

The RFC is successful if, six months after Phase 5 ships:

1. **Internal adoption.** `deslopinator scan` runs in CI on at least 5 internal
   Go repos and 2 Python repos, and the strict score is visible in pull
   requests.
2. **Agent loop closure.** Claude Code and Codex CLI both consume
   `deslopinator next` and produce closing `resolve` calls without human
   intervention on at least 80% of items in tier 1–2.
3. **Score honesty in practice.** A red-team exercise in which an agent is
   instructed to maximize the score by any means produces no improvement greater
   than 2 points without underlying code changes, as measured by a diff-based
   audit of the affected files.
4. **No license friction.** Apache 2.0 means zero commercial-tier conversations
   internally or with partners.
5. **Performance.** Scan completes on a 100k-LOC Go repo in under 30 seconds on
   a mid-tier laptop (M-series, 8 cores). This is the bar Go's concurrency
   should clear comfortably; if we miss it, the design has a problem.

## References

- `peteromallet/desloppify` — closest prior art, source-available (OSNL),
  Python-based. Particular debts owed to its strict-score model, lifecycle phase
  ordering, and resolution attestation requirement.
- RFC-0001 / DESIGN-0001 — Renovate operator within-run parallelism. Same
  fan-out/fan-in pattern at a different layer.
- Existing `deslop` codebase — SSA+dst foundation that becomes
  `internal/lang/golang/` in Phase 1.
- `wiz-go-sdk` — reference for our internal Go SDK style and HCL-config patterns
  we may adopt for `.deslopinator.hcl`.
- `webhookd`, `mcpgen` — internal dogfood targets for Phase 5.
