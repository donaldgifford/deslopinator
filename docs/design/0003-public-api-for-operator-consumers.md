---
id: DESIGN-0003
title: "Public API for operator consumers"
status: Draft
author: Donald Gifford
created: 2026-05-07
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0003: Public API for operator consumers

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
  - [pkg/api — domain types](#pkgapi--domain-types)
    - [Finding](#finding)
    - [Score](#score)
    - [Resolution](#resolution)
    - [State](#state)
    - [Scan](#scan)
    - [Review](#review)
    - [Queue](#queue)
    - [Errors](#errors)
  - [pkg/llm — vendor-agnostic LLM transport](#pkgllm--vendor-agnostic-llm-transport)
  - [pkg/provider — review provider boundary](#pkgprovider--review-provider-boundary)
  - [pkg/logger — slog factory](#pkglogger--slog-factory)
  - [pkg/observability — OTEL + Langfuse setup](#pkgobservability--otel--langfuse-setup)
  - [pkg/client — engine driver](#pkgclient--engine-driver)
  - [Operator integration patterns](#operator-integration-patterns)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Overview

This document specifies the concrete shape of `pkg/api`, `pkg/provider`,
and `pkg/client` — the three packages the **deslopinator-operator**
(kubebuilder-generated) imports. ADR-0003 fixed *what* lives where and
*why*; this design fixes the field names, method signatures, and the
operator-side usage patterns those packages are optimized for.

## Goals and Non-Goals

### Goals

- A complete, reviewable public-API surface that an external consumer
  (operator) can build CRDs, reconcilers, and status subresources
  against.
- Field names and types compatible with kubebuilder's CRD generation
  conventions where the operator is likely to embed them
  (e.g., `metav1.Time`-friendly timestamps, JSON-tag-clean structs).
- Functional-options constructors so additive changes don't break callers.
- Explicit pointer-vs-value rules: nilable optional, value if always set.

### Non-Goals

- The operator's CRD spec itself (lives in the deslopinator-operator
  repo).
- Wire-format stability with the CLI's `--format json` output. JSON shape
  alignment is desirable but not contractual; the operator uses Go types
  via `pkg/client`, not JSON parsing.
- A REST/gRPC server. The engine runs in-process for v1; remote-engine
  support is a future ADR.

## Background

ADR-0003 §"Stability contract" set the rules:

1. No type changes in patch releases.
2. Interfaces in `pkg/provider` are append-only within a major version.
3. `StateV1` is frozen.
4. Sentinel errors don't change shape.
5. CLI is not part of the API.

The operator's reconciliation loop will look approximately like:

```go
import (
    deslopapi "github.com/donaldgifford/deslopinator/pkg/api"
    deslopclient "github.com/donaldgifford/deslopinator/pkg/client"
)

func (r *ScanReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var cr deslopv1.Scan
    if err := r.Get(ctx, req.NamespacedName, &cr); err != nil { ... }

    client, err := deslopclient.New(deslopclient.WithStatePath(cr.Spec.StatePath))
    if err != nil { ... }

    result, err := client.Scan(ctx, deslopapi.ScanRequest{
        Path:      cr.Spec.RepoPath,
        Languages: cr.Spec.Languages,
    })
    if err != nil { ... }

    cr.Status.Score = deslopv1.ScoreFromAPI(result.Score)
    cr.Status.LastScanTime = metav1.Now()
    return ctrl.Result{}, r.Status().Update(ctx, &cr)
}
```

Everything in that snippet must compile against `pkg/api` and `pkg/client`
and against nothing else from this repo.

## Detailed Design

### pkg/api — domain types

```go
// pkg/api/doc.go
//
// Package api defines the public domain types of deslopinator. These types
// are stable per ADR-0003: additive within a minor version, frozen within
// a patch version, and any breaking change requires a major version bump.
//
// The deslopinator-operator and other external consumers import this
// package directly. The CLI surface (deslopinator scan, etc.) is NOT part
// of the API contract.
package api
```

#### Finding

```go
// pkg/api/finding.go

type FindingID string  // stable across scans for the same code location

type Severity string
const (
    SeverityInfo     Severity = "info"
    SeverityWarning  Severity = "warning"
    SeverityError    Severity = "error"
    SeverityCritical Severity = "critical"
)

type Tier int  // 1 = highest priority, 5 = lowest

type Dimension string
const (
    DimensionMechanical        Dimension = "mechanical"
    DimensionNamingQuality     Dimension = "naming_quality"
    DimensionAbstractionFitness Dimension = "abstraction_fitness"
    DimensionErrorHandling     Dimension = "error_handling"
    DimensionTestQuality       Dimension = "test_quality"
)

type Language string
const (
    LanguageGo         Language = "go"
    LanguagePython     Language = "python"
    LanguageTypeScript Language = "typescript"
    LanguageRust       Language = "rust"
)

type Finding struct {
    ID           FindingID `json:"id"`
    DetectorName string    `json:"detector_name"`
    Severity     Severity  `json:"severity"`
    Tier         Tier      `json:"tier"`
    Dimension    Dimension `json:"dimension"`
    Language     Language  `json:"language"`
    Path         string    `json:"path"`
    Line         int       `json:"line"`
    Column       int       `json:"column,omitempty"`
    Message      string    `json:"message"`
    Excerpt      string    `json:"excerpt,omitempty"`
    Suggestion   string    `json:"suggestion,omitempty"`
}

type FindingCounts struct {
    Total      int `json:"total"`
    BySeverity map[Severity]int `json:"by_severity"`
    ByTier     map[Tier]int     `json:"by_tier"`
    ByLanguage map[Language]int `json:"by_language"`
}
```

JSON tags use snake_case. They're stable; renaming is a major version
bump. Optional fields use `omitempty` and pointer-or-zero semantics
documented per-field.

#### Score

```go
// pkg/api/score.go

type Score struct {
    StrictScore  float64 `json:"strict_score"`  // 0..100
    LenientScore float64 `json:"lenient_score"` // 0..100
}

type ScoreSnapshot struct {
    Score
    ComputedAt time.Time `json:"computed_at"`
    Detectors  []string  `json:"detectors"`
    Provider   string    `json:"provider,omitempty"`
}

type ScoreHistory struct {
    Snapshots []ScoreSnapshot `json:"snapshots"`
}
```

#### Resolution

```go
// pkg/api/resolution.go

type ResolutionStatus string
const (
    StatusOpen      ResolutionStatus = "open"
    StatusFixed     ResolutionStatus = "fixed"
    StatusDismissed ResolutionStatus = "dismissed"
    StatusWontFix   ResolutionStatus = "wontfix"
)

type Resolution struct {
    FindingID    FindingID         `json:"finding_id"`
    Status       ResolutionStatus  `json:"status"`
    Note         string            `json:"note"`
    ResolvedBy   string            `json:"resolved_by"` // git user or agent id
    ResolvedAt   time.Time         `json:"resolved_at"`
    Attestation  *Attestation      `json:"attestation,omitempty"`
}

type Attestation struct {
    Provider  string `json:"provider"`
    Signature []byte `json:"signature"`
    KeyID     string `json:"key_id"`
}
```

#### State

```go
// pkg/api/state.go

const SchemaVersionV1 = 1

type StateV1 struct {
    SchemaVersion int                    `json:"schema_version"`
    ScanPath      string                 `json:"scan_path"`
    Findings      map[FindingID]Finding  `json:"findings"`
    Score         ScoreSnapshot          `json:"score"`
    Resolutions   []Resolution           `json:"resolutions"`
    CreatedAt     time.Time              `json:"created_at"`
    UpdatedAt     time.Time              `json:"updated_at"`
}
```

`StateV1` is frozen (ADR-0003 stability rule 3). When we ship a v2,
new code lives in `pkg/api/state_v2.go` with conversion helpers
`MigrateV1ToV2(StateV1) StateV2`.

#### Scan

```go
// pkg/api/scan.go (also referenced from DESIGN-0001)

type ScanRequest struct {
    Path      string
    Languages []Language
    Detectors []string
    Profile   string
    Options   ScanOptions
}

type ScanOptions struct {
    MaxWorkers          int
    PerDetectorTimeout  time.Duration
    DisableSubjective   bool
    StatePath           string
}

type ScanResult struct {
    StatePath string
    Score     ScoreSnapshot
    Counts    FindingCounts
    Duration  time.Duration
}
```

#### Review

```go
// pkg/api/review.go

type ReviewScope string
const (
    ScopeFile    ReviewScope = "file"
    ScopePackage ReviewScope = "package"
    ScopeRepo    ReviewScope = "repo"
)

type ReviewRequest struct {
    Dimension  Dimension
    Scope      ReviewScope
    Context    []SourceFile
    PriorScore *float64  // nil on first review
}

type ReviewResponse struct {
    Score     float64  // 0..100
    Rationale string
    Provider  string
    PromptID  string   // versioned prompt identity, for audit
}

type ProviderCapabilities struct {
    SupportsBatch     bool
    SupportsStreaming bool
    MaxContextBytes   int
}

type SourceFile struct {
    Path  string
    Bytes []byte
}
```

#### Queue

```go
// pkg/api/queue.go

type Phase string
const (
    PhaseInitial     Phase = "initial"
    PhaseCommunicate Phase = "communicate"
    PhasePlan        Phase = "plan"
    PhaseTriage      Phase = "triage"
    PhaseExecute     Phase = "execute"
)

type WorkItem struct {
    Finding    Finding
    Phase      Phase
    Rank       float64  // higher == more urgent
    Rationale  string   // why this is the next item
}

type QueueSnapshot struct {
    Phase  Phase
    Depths map[Phase]int
    Items  []WorkItem
}
```

#### Errors

```go
// pkg/api/errors.go

var (
    ErrStateSchemaMismatch  = errors.New("deslopinator: state schema mismatch")
    ErrPhaseGateUnsatisfied = errors.New("deslopinator: phase gate unsatisfied")
    ErrEmptyResolutionNote  = errors.New("deslopinator: resolution note required")
    ErrUnknownFinding       = errors.New("deslopinator: unknown finding id")
    ErrProviderUnavailable  = errors.New("deslopinator: review provider unavailable")
)
```

Operator code matches with `errors.Is(err, deslopapi.ErrStateSchemaMismatch)`.

### pkg/llm — vendor-agnostic LLM transport

ADR-0004 fixes that we never import an AI vendor SDK. `pkg/llm.Backend`
is the lower of two boundaries: a transport-level interface that
mirrors `server-price-tracker/pkg/extract.LLMBackend`. Anthropic,
OpenAI-compatible, and Ollama backends all live in
`internal/llm/<vendor>/` and speak HTTP via `net/http` + `encoding/json`.
The operator (or a test harness) can inject a custom `Backend` here
when it needs a different transport — most commonly a private LLM
endpoint or a deterministic mock.

```go
// pkg/llm/backend.go

type Backend interface {
    Name() string
    Generate(ctx context.Context, req GenerateRequest) (GenerateResponse, error)
    Capabilities() Capabilities
}

type GenerateRequest struct {
    Model       string
    Messages    []Message
    System      string
    Temperature float64
    MaxTokens   int
    Tools       []Tool        // optional, capability-gated
    Stream      bool          // reserved; v1 backends return non-streaming
}

type Message struct {
    Role    Role         // RoleSystem, RoleUser, RoleAssistant, RoleTool
    Content string
    Name    string       // optional, used by tool messages
}

type Role string

type Tool struct {
    Name        string
    Description string
    Schema      json.RawMessage  // JSON Schema for parameters
}

type ToolCall struct {
    ID        string
    Name      string
    Arguments json.RawMessage
}

type GenerateResponse struct {
    Content   string
    ToolCalls []ToolCall
    Usage     Usage
    Model     string         // echo of the model that actually served the call
    Latency   time.Duration
    Raw       json.RawMessage // optional pass-through of vendor response
}

type Usage struct {
    InputTokens  int
    OutputTokens int
    CostUSD      float64  // computed from Capabilities().*CostPerMTok if known
}

type Capabilities struct {
    SupportsTools     bool
    SupportsJSONMode  bool
    SupportsStreaming bool
    MaxContextTokens  int
    InputCostPerMTok  float64  // 0 if unknown
    OutputCostPerMTok float64  // 0 if unknown
}
```

The interface is small by design. Adding a method is a major version
bump (ADR-0003 stability rule 2, extended).

### pkg/provider — review provider boundary

The upper boundary. `ReviewProvider` is deslopinator-specific (it
knows about dimensions, prompt versions, and provider attestation);
the canonical implementation in `internal/review/provider/llm/` wraps
a `pkg/llm.Backend` to do the actual model call. Operators rarely
inject here — typically only the underlying `Backend` varies.

```go
// pkg/provider/provider.go

type ReviewProvider interface {
    Name() string
    Review(ctx context.Context, req api.ReviewRequest) (api.ReviewResponse, error)
    Capabilities() api.ProviderCapabilities
}
```

Composition rule: `internal/review/provider/llm.New(backend, prompts, opts)`
returns a `ReviewProvider`. The operator's typical injection pattern is
`client.WithBackend(myBackend)`, not `client.WithReviewProvider(myProvider)`.

### pkg/logger — slog factory

```go
// pkg/logger/logger.go

// New returns a *slog.Logger configured for the given level and format.
// level: "debug" | "info" | "warn" | "error" (defaults to "info" on unknown).
// format: "json" | "text" (defaults to "text").
func New(level, format string) *slog.Logger { ... }

// NewWithWriter is identical to New but writes to w instead of os.Stderr.
func NewWithWriter(w io.Writer, level, format string) *slog.Logger { ... }
```

Mirrors `server-price-tracker/pkg/logger`. Stdlib-only (`log/slog`).
Operators that already have a configured slog handler should pass it
in via `client.WithLogger(theirLogger)` and skip this package.

### pkg/observability — OTEL + Langfuse setup

ADR-0005 specifies OTEL as the only observability backbone, with
optional LLM-platform layering (Langfuse, Phoenix, etc.) via a single
`LLMExtension` interface. Public surface:

```go
// pkg/observability/observability.go

type Config struct {
    OTel      OTelConfig
    Resource  ResourceAttributes      // service.name, version, instance
    Extension LLMExtension            // optional; nil == plain OTEL only
}

type OTelConfig struct {
    Enabled  bool
    Endpoint string  // e.g., "localhost:4317"
    Insecure bool
}

// Init wires global TracerProvider, MeterProvider, and propagators
// according to cfg. If cfg.Extension is non-nil, it is Apply()'d after
// the base pipeline is up. When cfg.OTel.Enabled is false, installs
// no-op providers and the returned Shutdown is a no-op.
func Init(ctx context.Context, cfg Config) (Shutdown, error)

type Shutdown func(context.Context) error
```

```go
// pkg/observability/extension.go

// LLMExtension is the seam for layering an LLM-observability platform
// (Langfuse, Phoenix, LangSmith, Helicone, custom) on top of the base
// OTEL pipeline. Same composition pattern as ADR-0004's vendor
// sub-interfaces: Backend is portable, AnthropicBackend is vendor-specific;
// LLMExtension is portable, langfuse.Operations is vendor-specific.
type LLMExtension interface {
    Name() string
    Apply(tp *sdktrace.TracerProvider, mp *sdkmetric.MeterProvider) error
    Shutdown(ctx context.Context) error
}
```

The reference implementation (`pkg/observability/langfuse`) provides
both the `LLMExtension` impl and a Langfuse-specific `Operations`
sub-interface for things that don't fit OTEL spans cleanly:

```go
// pkg/observability/langfuse/langfuse.go

type Extension struct { /* ... */ }

func New(cfg Config) (*Extension, error)

// Implements pkg/observability.LLMExtension.
func (e *Extension) Name() string                                     { ... }
func (e *Extension) Apply(tp *sdktrace.TracerProvider,
    mp *sdkmetric.MeterProvider) error                                { ... }
func (e *Extension) Shutdown(ctx context.Context) error               { ... }

// Operations exposes Langfuse-specific affordances. Most code uses
// OTEL spans and never imports this — only callers that need
// scoring callbacks or dataset linking accept the interface.
type Operations interface {
    Score(ctx context.Context, traceID string, val ScorePayload) error
    RegisterPromptVersion(ctx context.Context, p PromptVersion) error
    CreateDatasetItem(ctx context.Context, item DatasetItem) error
    CreateDatasetRun(ctx context.Context, run DatasetRun) error
}

// Operations returns the Langfuse-specific surface.
func (e *Extension) Operations() Operations { ... }

type Config struct {
    Host          string
    PublicKey     string
    SecretKey     string
    Buffered      bool
    BufferSize    int  // queue depth when Buffered (default 1024)
}
```

Future LLM-observability platforms become parallel packages
(`pkg/observability/phoenix`, `pkg/observability/langsmith`, ...) each
implementing `LLMExtension`. Adding a method to `LLMExtension` or to
`langfuse.Operations` is a major version bump.

### pkg/client — engine driver

```go
// pkg/client/options.go

type Option func(*config)

type config struct {
    statePath          string
    profile            string
    backend            llm.Backend                  // override pkg/llm.Backend
    reviewProvider     provider.ReviewProvider      // override the upper layer
    workers            int
    perDetectorTimeout time.Duration
    logger             *slog.Logger
    extension          observability.LLMExtension   // pre-built LLMExtension
    skipObservability  bool                         // operator owns OTEL init
}

func WithStatePath(path string) Option                                { ... }
func WithProfile(name string) Option                                  { ... }
func WithBackend(b llm.Backend) Option                                { ... }
func WithReviewProvider(p provider.ReviewProvider) Option             { ... }
func WithMaxWorkers(n int) Option                                     { ... }
func WithLogger(l *slog.Logger) Option                                { ... }
func WithLLMExtension(ext observability.LLMExtension) Option          { ... }
func SkipObservabilityInit() Option                                   { ... }  // operator owns it
```

`SkipObservabilityInit` is the seam the operator uses when it already
called `observability.Init(ctx, ...)` itself and doesn't want
deslopinator to double-init. The operator is then responsible for
passing a `*slog.Logger` and, if it wants LLM-specific observability,
constructing an `LLMExtension` (e.g., `langfuse.New(...)`) and passing
it via `WithLLMExtension`.

```go
// pkg/client/client.go

type Client struct {
    cfg config
    eng *engine.Engine // internal/engine — unexported handle
}

func New(opts ...Option) (*Client, error) { ... }

// Scan runs a full scan and writes the resulting state file.
func (c *Client) Scan(ctx context.Context, req api.ScanRequest) (*api.ScanResult, error) { ... }

// Next returns the next phase-gated work item, or nil if the queue is empty.
func (c *Client) Next(ctx context.Context) (*api.WorkItem, error) { ... }

// Resolve marks a finding with the given status.
func (c *Client) Resolve(ctx context.Context, req ResolveRequest) (*ResolveResult, error) { ... }

// LoadState loads StateV1 from the configured state path. Returns
// ErrStateSchemaMismatch if the file's schema is newer than this binary.
func (c *Client) LoadState(ctx context.Context) (*api.StateV1, error) { ... }

// Score returns the latest score snapshot from state, without scanning.
func (c *Client) Score(ctx context.Context) (*api.ScoreSnapshot, error) { ... }

type ResolveRequest struct {
    ID     api.FindingID
    Status api.ResolutionStatus
    Note   string  // required; empty returns ErrEmptyResolutionNote
    Force  bool    // bypass note heuristic
}

type ResolveResult struct {
    NewScore api.ScoreSnapshot
    Delta    api.Score  // diff from prior snapshot
}
```

`Client.eng` is unexported and lives in `internal/engine`; the operator
cannot reach in. This is the single point where `pkg/` calls into
`internal/`, and the only place we have to defend.

### Operator integration patterns

Three patterns the operator can use, in order of recommendation:

**1. In-process scan (recommended for v1).**

Operator imports `pkg/client`, calls `client.Scan(ctx, req)` in the
reconciler. State file lives on a PVC mounted at
`/var/lib/deslopinator/<namespace>/<name>`. Operator typically owns
its own observability stack and constructs the client like this:

```go
import (
    deslopapi      "github.com/donaldgifford/deslopinator/pkg/api"
    deslopclient   "github.com/donaldgifford/deslopinator/pkg/client"
    deslopobs      "github.com/donaldgifford/deslopinator/pkg/observability"
    deslopfuse     "github.com/donaldgifford/deslopinator/pkg/observability/langfuse"
)

// In the operator's main.go or controller setup:
ext, _ := deslopfuse.New(deslopfuse.Config{
    Host:      opCfg.LangfuseHost,
    PublicKey: os.Getenv("LANGFUSE_PUBLIC_KEY"),
    SecretKey: os.Getenv("LANGFUSE_SECRET_KEY"),
    Buffered:  true,
})

shutdown, err := deslopobs.Init(ctx, deslopobs.Config{
    OTel:      opCfg.OTel,
    Resource:  opCfg.Resource,
    Extension: ext,             // nil to run plain OTEL
})
defer shutdown(ctx)

c, err := deslopclient.New(
    deslopclient.SkipObservabilityInit(),  // operator already initialized
    deslopclient.WithLogger(opLogger),
    deslopclient.WithStatePath(crStatePath),
)
```

Custom LLM endpoint (e.g., a private Anthropic-compatible gateway in
the cluster):

```go
backend := myllm.NewAnthropicCompatBackend(myllm.Config{
    BaseURL: "https://llm-gateway.svc.cluster.local",
    Model:   "claude-opus-4-7",
    APIKey:  os.Getenv("LLM_GATEWAY_KEY"),
})

c, _ := deslopclient.New(
    deslopclient.WithBackend(backend),
    // ... other opts
)
```

`myllm.NewAnthropicCompatBackend` is operator-side code that
implements `pkg/llm.Backend` against the operator's preferred
transport. Same shape as deslopinator's in-tree backends.

**2. Sidecar with shared volume.**

Operator pod has a sidecar running `deslopinator scan` triggered via
file-based signaling. Used when the operator wants language-plugin
isolation (e.g., Python plugin requires Python runtime in the
container). Operator still imports `pkg/api` for the type-safe state
file parsing.

**3. Remote engine (future).**

Reserved for a future ADR. Would add `pkg/client` overloads
`NewRemote(addr string, opts...)` calling a gRPC service. Out of scope
for v1.

## API / Interface Changes

This DESIGN *is* the API. Every type, field, method signature, and JSON
tag listed above is the contract. Reviewer pass should treat this
section like a code review.

## Data Model

`StateV1` is the on-disk schema, defined above. Stored at
`<statePath>/state.json` (default `.deslopinator/state.json`). Atomic
writes via temp-file-and-rename. No locks; concurrent writes from two
processes is undefined and we will document the assumption that one
deslopinator owns one state directory.

## Testing Strategy

- **API stability test.** `pkg/api/api_stability_test.go` uses
  reflection to enumerate exported fields and methods, dumps a hash to
  a golden file. Any change to public types fails CI; reviewers must
  intentionally regenerate the golden, signaling a deliberate API change.
- **Cross-version test.** `internal/test/apicompat/` builds against the
  *previous* tagged minor's `pkg/api` (via `go mod download`) and
  asserts the operator-typical usage pattern still compiles.
- **Operator integration test.** A nightly job in the
  deslopinator-operator repo runs against the latest deslopinator
  release. Failures here block deslopinator releases.
- **CLI/client parity test.** `internal/test/parity/` runs the same
  operations through the CLI (`os/exec`) and through `pkg/client`,
  diffs the resulting state files. Catches drift between the two
  surfaces.

## Migration / Rollout Plan

1. Land `pkg/api/` types behind `internal/engine`'s use. Engine starts
   importing `pkg/api` instead of defining its own. No external consumer
   yet.
2. Land `pkg/llm.Backend` and `pkg/provider.ReviewProvider` interfaces.
   Stub backend (`internal/llm/stub`) satisfies `Backend`. Default
   in-tree review provider (`internal/review/provider/llm`) wraps
   `Backend`.
3. Land `pkg/logger` and `pkg/observability` (incl. `langfuse`).
   `internal/llm/*` and `internal/review/provider/llm` use them.
4. Land Anthropic, OpenAI-compatible, and Ollama backends in
   `internal/llm/{anthropic,openaicompat,ollama}/`. Contract tests
   gated behind `-tags=integration`.
5. Land `pkg/client.New` with stub implementations. CLI rewires to
   call through `Client`.
6. Land real `Client.Scan/Next/Resolve` once DESIGN-0001 engine is in.
7. Tag `v0.1.0`. Operator repo can begin importing.
8. After 2 minor releases, declare API frozen for v1. Major version
   bumps require an ADR amendment.

## Open Questions

1. **`Finding.Excerpt` size limit.** **Status: resolved with tracking.**
   Default cap: 2 KB per finding. Configurable per-profile via
   `excerpt_max_bytes` in `.deslopinator.hcl`. Hard upper bound enforced
   by the engine: 64 KB per finding regardless of config (prevents
   pathological state-file growth and worker-pool memory pressure).
   Track perf data: emit `engine.findings.excerpt_bytes` histogram
   metric (ADR-0005). Tune the default downward if the p95 stays well
   below 2 KB or upward if real findings get truncated frequently.
   We will not commit to a comprehensive performance suite, but the
   metric gives us *some* data to reference when boundaries change.
2. **`WorkItem.Rationale`: text vs structured code.** **Status: resolved.**
   Start with `Rationale string` (free-form). Add a `Code string` field
   (sentinel-style; e.g., `tier1.high_severity`,
   `phase_gate.communicate_score_first`) in a minor release once the
   set of rationale codes stabilizes. The selection between which
   field a `WorkItem` populates is config-driven (per-profile flag in
   `.deslopinator.hcl`) — same interface-driven pattern as ADR-0004's
   sub-providers and ADR-0005's `LLMExtension`. Operator UIs that want
   structured codes opt in; agent prompts that want prose stay on text.
3. **Error wrapping in `pkg/client`.** **Status: resolved.** Use
   sentinel errors throughout (`pkg/api/errors.go`,
   `pkg/llm/errors.go` re-exported per ADR-0004). All wrapping uses
   `fmt.Errorf("...: %w", sentinel)` so `errors.Is` traverses the
   chain. `BackendError` (ADR-0004) implements `Unwrap()` returning
   the sentinel. `internal/test/parity/error_chain_test.go` enforces
   this — every public-API error path is asserted to match the
   expected sentinel via `errors.Is` from the operator-typical seam.
4. **Should `pkg/client` expose `WatchState(ctx) <-chan StateV1`?**
   **Status: open — track for v0.2.** The operator's reconciler is
   event-driven; a watch API would let it skip polling. Defer until
   the operator's first revision in deslopinator-operator can tell us
   whether file-mtime polling is acceptable or if we genuinely need
   `inotify`/`fsnotify` semantics. Worth revisiting after operator
   integration testing surfaces real reconcile-loop characteristics.
5. **kubebuilder `zz_generated_deepcopy` compatibility.** **Status: resolved.**
   The operator wraps `pkg/api` types with its own
   kubebuilder-annotated types and runs `controller-gen` against
   *those*. We do **not** modify or vendor kubebuilder-generated code
   in this repo, and `pkg/api` stays kubebuilder-agnostic (no
   `+kubebuilder:object:generate=true` markers, no
   `zz_generated_deepcopy.go`). The operator imports `pkg/api` types,
   wraps them, and generates DeepCopy on the wrappers. This keeps the
   import direction one-way and the API surface lean.

## References

- RFC-0001 §"High-level architecture", §"Subjective review provider
  interface", §"State schema with explicit migrations".
- ADR-0001 — CLI uses `pkg/client`, doesn't reach into `internal/`.
- ADR-0002 — stdlib-first; influences which types we expose
  (e.g., `time.Time` rather than a custom timestamp).
- ADR-0003 — public/private boundary and stability contract.
- ADR-0004 — AI provider abstraction; `pkg/llm.Backend` two-layer model.
- ADR-0005 — observability stack; `pkg/logger`, `pkg/observability`.
- ADR-0006 — HCL2 config; `pkg/api/config.go` types.
- DESIGN-0001 — engine that `pkg/client` drives.
- DESIGN-0002 — CLI surface that consumes `pkg/client`.
- `github.com/donaldgifford/server-price-tracker/pkg/{extract,judge,
  logger,observability}` — pattern reference for `pkg/llm`,
  `pkg/provider`, `pkg/logger`, `pkg/observability`. Direct
  copy-paste of structural patterns is acceptable; we do not import.
- [kubebuilder book — types and DeepCopy](https://book.kubebuilder.io/cronjob-tutorial/api-design.html).
