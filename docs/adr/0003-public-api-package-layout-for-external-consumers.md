---
id: ADR-0003
title: "Public API package layout for external consumers"
status: Proposed
author: Donald Gifford
created: 2026-05-07
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0003. Public API package layout for external consumers

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
  - [Public surface](#public-surface)
  - [Private surface](#private-surface)
  - [Stability contract](#stability-contract)
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

RFC-0001 specifies `internal/` for the engine, scoring, and queue logic and
`pkg/api/` for "public types for plugin authors." Beyond plugin authors, a
parallel **deslopinator-operator** repo (kubebuilder-generated Kubernetes
operator) needs to import a subset of this codebase to:

- Construct `ScanRequest` / `ScanResult` types in its CRD reconciliation loop.
- Trigger scans programmatically against the engine (or against a sidecar that
  embeds the engine) without shelling out to `deslopinator scan`.
- Read state file artifacts (`StateV1`) produced by the CLI to surface findings
  via the operator's status subresource.
- Consume `Finding`, `Score`, `Resolution`, `ReviewProvider`, and related
  types so the operator's CRD spec maps cleanly onto engine concepts.

Go's import rules make this concrete: anything under `internal/` is
unimportable from outside `github.com/donaldgifford/deslopinator/...`. The
operator lives at `github.com/donaldgifford/deslopinator-operator` (or similar),
which is *outside* that prefix and therefore **cannot import** any
`internal/` package. Whatever the operator needs must live under `pkg/`.

We need to draw the boundary deliberately rather than discovering it
incrementally — promoting types from `internal/` to `pkg/` later is a
breaking change for everyone already using `internal/`, and demoting types
from `pkg/` to `internal/` is a breaking change for the operator. Cost of
getting this wrong is high; cost of getting it right up front is moderate.

## Decision

Adopt the following package layout. The line between public and private is
drawn at **types and read-only operations** (public) versus **algorithms,
state mutation, and orchestration** (private).

### Public surface

Under `pkg/`:

```
pkg/
├── api/                    # Core domain types — the operator imports this.
│   ├── doc.go              # Package documentation; stability contract.
│   ├── finding.go          # Finding, FindingID, Severity, Tier, Dimension.
│   ├── score.go            # Score, StrictScore, LenientScore, ScoreSnapshot,
│   │                       # ScoreHistory.
│   ├── resolution.go       # Resolution, ResolutionStatus, Attestation.
│   ├── state.go            # StateV1 (read-only struct), SchemaVersion const.
│   ├── scan.go             # ScanRequest, ScanResult, ScanOptions.
│   ├── review.go           # ReviewRequest, ReviewResponse, Dimension,
│   │                       # ProviderCapabilities — the *types* the
│   │                       # ReviewProvider interface uses, not the interface
│   │                       # itself (see below).
│   ├── queue.go            # WorkItem, Phase, QueueSnapshot.
│   ├── config.go           # Config types decoded from .deslopinator.hcl
│   │                       # (ADR-0006). Profile, BackendConfig, etc.
│   └── errors.go           # Sentinel errors operator code may need to match.
│
├── llm/                    # Vendor-agnostic LLM transport (ADR-0004).
│   ├── backend.go          # Backend interface, GenerateRequest, Response,
│   │                       # Capabilities. Operators inject custom backends
│   │                       # here (e.g., private endpoint, mock for tests).
│   └── doc.go              # Stability contract notes specific to Backend.
│
├── provider/               # ReviewProvider interface only. Concrete impls
│   │                       # stay in internal/review/provider/. Wraps a
│   │                       # pkg/llm.Backend.
│   └── provider.go         # ReviewProvider interface, Capabilities helpers.
│
├── logger/                 # slog factory (ADR-0005). Mirrors
│   └── logger.go           #   server-price-tracker/pkg/logger.
│                           #   New(level, format) *slog.Logger
│
├── observability/          # OTEL + Langfuse setup (ADR-0005).
│   ├── observability.go    # Init(ctx, Config) (Shutdown, error).
│   ├── config.go           # Config — otel + langfuse sub-configs.
│   └── langfuse/           # Langfuse Client interface + 3 impls
│       ├── client.go       #   (HTTPClient, NoopClient, BufferedClient).
│       ├── http.go
│       ├── noop.go
│       └── buffered.go
│
└── client/                 # In-process Go client to drive the engine.
    ├── client.go           # Client struct, New(opts), Scan, Next, Resolve,
    │                       # LoadState — operator-facing surface.
    └── options.go          # Functional options: WithLogger, WithBackend,
                            # WithReviewProvider, WithObservability, etc.
```

The operator typically imports:

- `pkg/api` everywhere for types (finding, score, state, work-item).
- `pkg/client` to drive scans in-process from the reconciler.
- `pkg/logger` to share its slog handler with deslopinator.
- `pkg/observability` to coordinate OTEL/Langfuse setup (typically
  the operator initializes both and passes them in via
  `client.WithLogger`/`client.WithObservability`).
- `pkg/llm` only when injecting a custom Backend (private LLM endpoint,
  air-gapped environment, deterministic test fixture).
- `pkg/provider` only when injecting a custom ReviewProvider — rare;
  typically only the underlying Backend varies.

### Private surface

Under `internal/`:

```
internal/
├── engine/                 # Detector orchestration, worker pool, queue impl.
│   ├── detector/           # Detector interface, concrete detectors.
│   ├── scoring/            # Score computation, anti-gaming policy.
│   ├── state/              # State load/save, migrations (StateV1 → V2 → ...).
│   ├── queue/              # Phase-gated queue construction and ranking.
│   └── parallel/           # Worker pool, fan-out/fan-in.
├── lang/                   # Language plugins.
├── llm/                    # Concrete pkg/llm.Backend impls (ADR-0004).
│   ├── anthropic/          #   Anthropic Messages API over net/http.
│   ├── openaicompat/       #   OpenAI-compatible /v1/chat/completions
│   │                       #   (covers OpenAI, Azure, OpenRouter, Together,
│   │                       #   Groq, vLLM gateways via base_url config).
│   ├── ollama/             #   Local/remote Ollama /api/chat.
│   └── stub/               #   Deterministic test fixture; no network.
├── review/                 # ReviewProvider impls — wrap an llm.Backend.
│   ├── provider/llm/       #   Default impl that composes Backend + prompts.
│   └── prompt/             #   Versioned prompt templates per dimension.
├── attestation/            # Resolution signing.
├── config/                 # HCL2 decoding glue (ADR-0006); produces
│                           #   pkg/api.Config from .deslopinator.hcl.
└── agent/                  # Skill-file synthesis.
```

The rule: **`pkg/` defines the contract; `internal/` implements it.**

### Stability contract

`pkg/api` follows semver via the `github.com/donaldgifford/deslopinator`
module version. We commit to the following discipline:

1. **No type changes in patch releases.** Adding fields to public structs
   is a minor-version change because Go struct equality and reflective
   serialization can break. Use functional options or builder patterns when
   parameter sets are likely to grow.
2. **Interfaces in `pkg/provider`, `pkg/llm`, and
   `pkg/observability/langfuse` are append-only within a major version.**
   Adding a method to `ReviewProvider`, `Backend`, or
   `langfuse.Client` would break out-of-tree implementers. New
   capabilities go through `Capabilities()` first, then graduate to a
   new interface (`ReviewProviderV2` embedding `ReviewProvider`) if needed.
3. **`StateV1` is frozen.** New schema versions get new types
   (`StateV2`, `StateV3`) in `pkg/api`, with conversion helpers. The
   `SchemaVersion` constant moves; the existing struct does not change.
4. **Errors in `pkg/api/errors.go` are sentinel values for `errors.Is`.**
   We do not add `Unwrap()` methods or rename them.
5. **The CLI is *not* part of the API.** Flag names, output formatting, and
   exit codes can change between minor releases. Operator integration uses
   `pkg/client`, not `os/exec`.

The deslopinator-operator repo gets a CI job that runs against the *current*
`pkg/api` and the *previous minor*'s `pkg/api` to catch breaks before release.

## Consequences

### Positive

- The operator can be authored against a stable Go API instead of parsing
  CLI output. Status subresources, CRD validation, and reconciliation
  loops get to use real types.
- Plugin authors (RFC §"Pluggable subjective review providers") have a
  documented public surface that is intentionally narrower than "everything
  under engine."
- Clear rule for reviewers: if a PR moves something from `internal/` to
  `pkg/`, it needs an ADR amendment or a follow-up ADR. Keeps the boundary
  from drifting.

### Negative

- We have to think carefully about what goes public *up front* — the cost
  of moving a type out of `internal/` later is a breaking change for any
  consumer that started using it.
- Two parallel client surfaces (CLI and Go client). They must stay in sync
  semantically, even though only the Go client is the API contract. Tests
  enforce this — see DESIGN-0003.
- A doc.go-driven stability contract is only as strong as our review
  discipline. We mitigate with the cross-repo CI check above.

### Neutral

- The operator may end up importing the engine as a library and running
  scans in-process, or it may keep them in a sidecar. ADR-0003 covers both
  by exposing `pkg/client` — the operator's deployment topology is its own
  decision.

## Alternatives Considered

**Put everything under `pkg/`; `internal/` is empty.** Rejected. The whole
point of `internal/` is to keep refactor freedom over the algorithms. Without
it, every detector signature, every scoring tweak, every worker-pool
parameter is part of the public API and we cannot evolve them without
breaking consumers.

**Put everything under `internal/`; operator vendors the source.** Rejected.
Vendoring across repo boundaries is brittle, doesn't survive `go mod tidy`,
and means the operator drifts from CLI behavior. Modern Go expects modules
to expose a real `pkg/` surface.

**Single `pkg/deslopinator` package with everything flat.** Rejected. The
public surface has clearly-separable concerns (types, provider interface,
client). Splitting them into sub-packages keeps imports precise — the
operator probably imports `pkg/api` everywhere but `pkg/provider` only in
its review-injection seam.

**Generate `pkg/api` from a protobuf or OpenAPI schema.** Rejected for v1.
We're a Go-native tool talking to Go-native operators; adding a code-gen
toolchain costs more than it saves. Revisit if/when we need a non-Go
language to consume the API (e.g., a Python operator), at which point a
schema is the right answer.

## References

- RFC-0001 §"High-level architecture" — the `internal/` vs `pkg/api` split
  this ADR formalizes.
- DESIGN-0003 — concrete shape of `pkg/api`, `pkg/provider`, `pkg/client`.
- ADR-0002 — stdlib-first policy, which extends to anything we expose
  through `pkg/`.
- [Go Modules Reference: internal packages](https://go.dev/ref/mod#internal).
- [SemVer](https://semver.org/) — the contract `pkg/api` upholds.
