---
id: ADR-0005
title: "OpenTelemetry observability with optional Langfuse export"
status: Proposed
author: Donald Gifford
created: 2026-05-08
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0005. OpenTelemetry observability with optional Langfuse export

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
  - [OTEL pipeline shape](#otel-pipeline-shape)
  - [LLMExtension interface — Langfuse and anything else](#llmextension-interface--langfuse-and-anything-else)
  - [Disable-via-config behavior](#disable-via-config-behavior)
  - [Public packages](#public-packages)
  - [Public, interface-driven logger](#public-interface-driven-logger)
  - [Spans and metrics we always emit](#spans-and-metrics-we-always-emit)
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

Three concerns drive an observability decision:

1. **The engine has fan-out concurrency.** DESIGN-0001 fans out detector
   work over a worker pool; debugging "why did this scan take 12s when
   the next one took 3s" requires per-detector spans, per-unit timing,
   and worker-pool wait times. Logs alone are insufficient.

2. **AI calls cost money and have non-trivial latency.** ADR-0004's
   `Backend.Generate` calls dominate scan latency once the subjective
   review phase kicks in. We need to track cost (input/output tokens,
   $/Mtok), latency, and prompt fidelity (which prompt version produced
   which output) to evolve the prompt set without flying blind.

3. **The operator runs in production K8s clusters.** ADR-0003's
   deslopinator-operator is the production deployment vector. Any
   cluster operator already has a tracing/metrics pipeline (Tempo,
   Jaeger, Prometheus, Mimir, Datadog, Honeycomb, etc.); we cannot
   force them to adopt a deslopinator-specific stack.

A reference implementation already exists for exactly the right
shape: `server-price-tracker/pkg/observability` initializes OTEL with
OTLP/gRPC exporters for both traces and metrics, exports LLM
generations to Langfuse, and short-circuits to a no-op when
`cfg.Enabled` is false so calling code never branches on
"is observability on?". We adopt that.

OTEL is the obvious lower bound. The interesting decisions are:
(a) which Langfuse client shape to use, (b) how to make disabling
free-of-cost, (c) what gets exposed as a public package vs. kept
internal.

## Decision

Adopt OpenTelemetry as the **only** observability backbone. Default
deployment is plain OTEL (traces + metrics) with no LLM-platform
coupling. Langfuse — and any future LLM-observability platform
(Phoenix, LangSmith, Helicone, etc.) — layers on top via a
**`LLMExtension` interface** that the user opts into via config.
Same shape as ADR-0004's vendor-agnostic `Backend` plus vendor-specific
sub-interfaces: a clean common path with optional richer
provider-specific surfaces.

Both layers can be disabled independently with **zero allocation cost**
at the call site (no-op TracerProvider, no `LLMExtension` configured).

### OTEL pipeline shape

The base OTEL setup is borrowed almost verbatim from
`server-price-tracker/pkg/observability` and is the only piece every
deployment runs:

- **Exporters.** OTLP/gRPC for both traces and metrics, single endpoint
  + insecure-toggle config. Operators run a collector
  (otelcol-contrib) that fans out to whatever backend they use.
- **Sampler.** `AlwaysSample()` at the SDK; collector applies
  tail-sampling. Reasoning: deslopinator runs on demand
  (CI/agent loop), not as a high-QPS service. Sample budgets are not
  the constraint; getting all spans for the run a developer is
  debugging is.
- **Propagators.** W3C TraceContext + Baggage, registered globally.
  Operators reconciling our CR want their span context to flow into
  our scan span.
- **Resource.** `service.name=deslopinator`,
  `service.version=<goreleaser version>`,
  `service.instance.id=<commit sha or hostname>`,
  `deslopinator.profile=<active profile>`.

That's it. Plain OTEL is enough for engine-level observability,
detector latency, and "did the scan complete?" debugging. Langfuse
is layered on for the LLM-specific surface.

### `LLMExtension` interface — Langfuse and anything else

LLM-observability platforms (Langfuse, Phoenix, LangSmith, Helicone)
all integrate by attaching SpanProcessors / metric exporters to a
running OTEL pipeline plus optional vendor-specific operations
(score callbacks, dataset linking, prompt-version metadata). We
expose this as a single interface — implementations live alongside
their config in `pkg/observability/<vendor>/`:

```go
// pkg/observability/extension.go

type LLMExtension interface {
    Name() string
    // Apply attaches the extension's span processors / metric readers
    // to the running OTEL providers. Called once during Init after the
    // base OTEL pipeline is up.
    Apply(tp *sdktrace.TracerProvider, mp *sdkmetric.MeterProvider) error
    // Shutdown drains any extension-specific exporters.
    Shutdown(ctx context.Context) error
}
```

Each LLM platform becomes a vendor-specific package implementing the
interface — and, where it has features beyond span export, exposes a
vendor sub-interface alongside (mirrors ADR-0004's `AnthropicBackend`
pattern):

```go
// pkg/observability/langfuse/langfuse.go (Langfuse implementation)

type Extension struct { /* ... */ }

func New(cfg Config) (*Extension, error) { ... }

// Implements pkg/observability.LLMExtension.
func (e *Extension) Name() string                                            { ... }
func (e *Extension) Apply(tp *sdktrace.TracerProvider,
    mp *sdkmetric.MeterProvider) error                                       { ... }
func (e *Extension) Shutdown(ctx context.Context) error                      { ... }

// Operations is the Langfuse-specific surface for things that don't
// fit OTEL spans cleanly: explicit score callbacks, dataset linking,
// prompt-version registration.
type Operations interface {
    Score(ctx context.Context, traceID string, val ScorePayload) error
    RegisterPromptVersion(ctx context.Context, p PromptVersion) error
    CreateDatasetItem(ctx context.Context, item DatasetItem) error
    CreateDatasetRun(ctx context.Context, run DatasetRun) error
}

// Operations exposes the Langfuse-specific API to callers that need it.
// Most code uses OTEL spans and never touches this.
func (e *Extension) Operations() Operations { ... }
```

Why this works:

- **Default deployment is plain OTEL.** No Langfuse, no LangSmith, no
  third-party coupling. Operators ship traces/metrics to their
  collector and pick the backend they want.
- **Adding a new platform is additive.** A future
  `pkg/observability/phoenix.Extension` lives alongside
  `langfuse.Extension`. Same interface; users swap by config.
- **Vendor-specific affordances stay vendor-specific.** Langfuse
  scoring/datasets live on `langfuse.Operations`, not on the common
  interface — same logic as ADR-0004's vendor sub-interfaces. Code
  that needs them imports `pkg/observability/langfuse` and accepts
  the `Operations` interface; portable code uses OTEL only.
- **The Langfuse SDK problem is moot.** We don't import their Go
  SDK; we implement against their HTTP API and OTEL endpoint
  ourselves. ADR-0002 forbids langfuse-go-sdk specifically.

In-tree, behind the `Extension`, Langfuse export uses the same
three-impl pattern as the reference repo for resilience:

- **`httpclient`** — talks Langfuse HTTP / OTLP endpoint directly
  via stdlib. **No Langfuse Go SDK import.**
- **`noopclient`** — used when no extension is configured (rare;
  most code paths just don't construct an extension).
- **`bufferedclient`** — wraps `httpclient` with an in-memory queue
  and background drain so Langfuse latency never blocks scan
  completion. Drops events on queue overflow with a counter
  metric (`observability.extension.dropped_events_total`).

These are **internal implementation details** of `langfuse.Extension`,
not public contracts. Public surface is `LLMExtension` +
`langfuse.Operations`.

### Disable-via-config behavior

OTEL on/off plus zero-or-one LLM extension:

```hcl
# .deslopinator.hcl
observability {
  otel {
    enabled  = true
    endpoint = "localhost:4317"
    insecure = true
  }

  # Zero or one extension block. Block label selects the vendor.
  llm_extension "langfuse" {
    host           = "https://cloud.langfuse.com"
    public_key_env = "LANGFUSE_PUBLIC_KEY"
    secret_key_env = "LANGFUSE_SECRET_KEY"
    buffered       = true
  }

  # Future alternatives (mutually exclusive with the block above):
  # llm_extension "phoenix"   { ... }
  # llm_extension "langsmith" { ... }
  # llm_extension "helicone"  { ... }
}
```

- `otel.enabled = false` → wire `noop.NewTracerProvider()` and
  `noop.NewMeterProvider()` from the OTEL SDK. All `otel.Tracer(...)`
  calls return no-op spans. **No exporter, no collector connection,
  no goroutines started.**
- No `llm_extension` block → `Init` returns an `LLMExtension` of `nil`.
  Code that needs `Operations` checks for nil and skips
  vendor-specific calls; OTEL spans still emit through the base
  pipeline.

CLI flags `--no-otel` and `--no-llm-extension` override config.
Convenience flag `--no-observability` disables both. Useful in CI
where the runner is short-lived and exporter setup latency would
add to test wall-clock.

The "calling code never branches" property is non-negotiable: detector
code, engine code, and Backend code call `tracer.Start(ctx, ...)`
unconditionally and trust that the no-op fallback costs nothing
when disabled. This matches the reference repo and makes the
observability surface invisible to detector authors.

### Public packages

Adding to ADR-0003's public layout:

```
pkg/
├── logger/                       # Public, interface-driven (see below).
│   ├── logger.go                 //   New(...) *slog.Logger; defaults
│   ├── handler.go                //   slog.Handler is the swap point
│   └── doc.go                    //   stability contract
└── observability/
    ├── observability.go          //   Init(ctx, Config) (Shutdown, *Handles, error)
    ├── config.go                 //   Config types
    ├── extension.go              //   LLMExtension interface
    └── langfuse/                 //   Reference LLMExtension implementation.
        ├── langfuse.go           //     Extension struct, public Operations interface
        ├── config.go
        └── (internal/ subpkg holds httpclient/noopclient/bufferedclient)
```

Why public:

- The operator (ADR-0003) initializes its own observability and wants to
  pass us a configured `*slog.Logger` and a parent OTEL context. Without
  `pkg/logger` and a way to disable our own init, we'd double-init.
- Plugin authors writing custom detectors or `pkg/llm.Backend` impls
  need the OTEL conventions and the `LLMExtension`-aware seam so their
  spans are picked up by whatever extension the user configured.
- Future LLM-observability platforms (Phoenix, LangSmith, Helicone,
  custom internal tooling) are external implementations of
  `LLMExtension`, so the interface lives in `pkg/`.

Stability: same contract as `pkg/api` (ADR-0003 §"Stability contract").
Adding methods to `LLMExtension` or `langfuse.Operations` is a major
version change.

### Public, interface-driven logger

`pkg/logger` is public so consumers (operator, custom integrations) can
swap the logging backend — slog by default, with a path to zap or
zerolog if profiling shows slog is the bottleneck. The Go-idiomatic
way to do this is to **lean on `slog.Handler` as the interface**
rather than introducing a new `Logger` interface alongside it: `*slog.Logger`
is itself the value type the rest of the code accepts, and the swap
point is the handler underneath.

```go
// pkg/logger/logger.go

// New returns a *slog.Logger configured for the given level and format.
//   level: "debug" | "info" | "warn" | "error" (default "info")
//   format: "text" | "json"                    (default "text")
//
// Output goes to os.Stderr. For Kubernetes deployments this is the
// expected target; cluster-side log forwarders (Alloy, Vector, Promtail)
// pick it up and ship to Loki / Elastic / Datadog.
func New(level, format string) *slog.Logger

// NewWithWriter is identical to New but writes to w.
func NewWithWriter(w io.Writer, level, format string) *slog.Logger

// NewWithHandler returns a logger backed by an arbitrary slog.Handler.
// This is the seam to swap the backend implementation:
//
//   import "github.com/agoda-com/opentelemetry-logs-go/exporters/otlp/otlplogs"
//   import "go.uber.org/zap/exp/zapslog"
//
//   handler := zapslog.NewHandler(zapCore)
//   l := logger.NewWithHandler(handler)
//
// We do not vendor zap/zerolog adapters in this repo; consumers wiring
// them in own that integration. ADR-0002 keeps slog as the in-tree
// default.
func NewWithHandler(h slog.Handler) *slog.Logger
```

Why not a custom `Logger` interface:

- `*slog.Logger` is already the de-facto interface in modern Go (Go
  1.21+). Wrapping it with our own narrower interface fragments the
  ecosystem — every library taking a `*slog.Logger` would also need
  to take our wrapper.
- `slog.Handler` is the actual swap point. zap, zerolog, OTEL logs,
  and bespoke handlers all implement `slog.Handler` (directly or via
  small adapters). Code that wants zap performance does
  `logger.NewWithHandler(zapslog.NewHandler(...))` — no API change to
  callers, no dependency on zap from deslopinator itself.
- This matches what `server-price-tracker/pkg/logger` does (returns
  `*slog.Logger` directly) and aligns with stdlib idioms.

Performance escape hatch (deferred until profiling demands it): if
slog overhead measurably hits scan latency on a hot detector path,
swap that path's `Handler` for a zap- or zerolog-backed handler via
`NewWithHandler`. Document the swap with a benchmark that motivates
it. **Don't pre-emptively introduce a custom `Logger` interface** —
the cost of leaning on slog is paid up front but is well-bounded;
introducing our own interface costs us forever.

### Spans and metrics we always emit

Spans:
- `engine.scan` (root span for `Client.Scan`)
- `engine.phase.<name>` (sources, detect, reduce, subjective, score,
  persist, queue)
- `engine.detector.<name>` (per-detector, per-unit)
- `llm.generate` (one per `Backend.Generate` call)
- `provider.review` (one per `ReviewProvider.Review` call, parents
  the `llm.generate` span)

Metrics:
- `engine.scan.duration_seconds` (histogram, attributes: result, profile)
- `engine.findings.total` (counter, attributes: severity, tier, language)
- `llm.tokens.input_total` / `llm.tokens.output_total` (counter,
  attributes: backend, model)
- `llm.cost.usd_total` (counter, attributes: backend, model)
- `langfuse.dropped_events_total` (BufferedClient only)

This is the minimum surface; detectors and backends may add their own.

## Consequences

### Positive

- One pipeline (OTEL + collector) covers both engine performance and
  LLM cost/quality observability. Operators don't run two stacks.
- Langfuse export is on the *path* but not on the *blocker* —
  BufferedClient means a Langfuse outage never stalls a scan.
- Disabling is genuinely free, not "skipped at the call site." Matches
  the reference repo.
- The pattern is portable: future deslopinator features (skill-file
  generation, agent-loop orchestration) get tracing for free by using
  the standard `tracer.Start` + `attribute.String` calls.

### Negative

- OTEL's transitive dependency closure is non-trivial — the OTLP/gRPC
  exporter pulls in `google.golang.org/grpc`, `google.golang.org/protobuf`,
  and a handful of others. License-check has to whitelist those (all
  Apache-2.0/BSD-3, no surprises).
- We commit to maintaining custom Langfuse HTTP code as Langfuse's API
  evolves. Reference repo already does this; we copy the patterns and
  inherit the maintenance pattern with it. Mitigation: contract test
  with `-tags=integration`, similar to the LLM backend contract tests
  in ADR-0004.
- Adding two new packages to `pkg/` widens the public surface and
  the stability contract. Worth it because operators are real
  consumers, not hypothetical.

### Neutral

- We do not adopt OpenInference / OpenTelemetry-LLM-conventions yet
  (the WG is still iterating on attribute names). Instead, our
  `llm.*` span/metric attributes follow the conventions used by
  Langfuse's OTEL integration. We'll align once the WG converges.
- Logs go to slog over stderr in standard Kubernetes fashion;
  cluster-side log forwarders (Alloy → Loki, Vector → Elastic) handle
  shipping. We do not pipe logs through OTEL yet — cost/benefit isn't
  there for a CLI tool that already emits structured stderr.
- slog is the in-tree default. If profiling shows slog overhead
  hurting scan latency on a hot path, swap that path's `slog.Handler`
  for a zap- or zerolog-backed handler via `logger.NewWithHandler` —
  the public API doesn't change. We don't pre-emptively introduce a
  custom `Logger` interface; `slog.Handler` is already the swap
  point.

## Alternatives Considered

**OTEL only, skip the LLMExtension entirely.** Rejected. OTEL spans
for LLM calls don't give us prompt-versioned scoring, dataset
evaluation, or per-model cost attribution out of the box. We do want
those for the scoring honesty audit (RFC §"Success Criteria" #3) —
but we want them as an *opt-in* layer, not a mandatory dependency.
The `LLMExtension` interface is exactly that opt-in: default deployment
is plain OTEL, and Langfuse / Phoenix / LangSmith plug in via config.

**Hard-code Langfuse in `pkg/observability` directly.** Rejected. Locks
us into one LLM-observability vendor and forces every operator
deployment to think about Langfuse credentials even if they're not
using it. The interface costs essentially nothing and gives us swap
freedom — same logic as ADR-0004's `Backend` interface.

**zap or zerolog as the in-tree default instead of slog.** Rejected.
`log/slog` shipped in Go 1.21 with structured handlers, level support,
and OTEL bridge compatibility. ADR-0002 reinforces stdlib-first; the
reference repo also uses slog. The performance escape hatch
(`logger.NewWithHandler` with a zap-backed `slog.Handler`) is there
without making zap the default.

**Custom `Logger` interface alongside `*slog.Logger`.** Rejected.
`*slog.Logger` is already the de-facto interface in modern Go.
Wrapping it forces every consumer that takes a `*slog.Logger` to
choose between our wrapper and the stdlib type, and the
ecosystem fragmentation isn't worth it. `slog.Handler` is the actual
swap point and we lean on it.

**Honeycomb or Datadog SDKs directly.** Rejected. Hard-couples us to
one vendor and bypasses the OTEL collector pattern that makes vendor
choice an operator's concern, not ours.

**Build the OTEL pipeline from scratch with `net/http` exporters.**
Rejected. OTEL SDK is the authoritative implementation; reimplementing
the protobuf wire format and propagator logic for marginal binary-size
savings is the kind of "reinventing the wheel" ADR-0002 explicitly
calls out as not justified.

## References

- `github.com/donaldgifford/server-price-tracker/pkg/observability` —
  the reference implementation we copy-paste patterns from
  (httpclient/noopclient/bufferedclient layout, init shape,
  no-op-on-disabled behavior). We do not import the package.
- `github.com/donaldgifford/server-price-tracker/pkg/logger` — slog
  factory we mirror; `*slog.Logger` is the value type, `slog.Handler`
  is the swap point.
- ADR-0004 — same vendor sub-interface pattern (`AnthropicBackend` etc.)
  we use for `langfuse.Operations`. The two ADRs converge on one
  composition rule: common interface for portability, vendor sub-interface
  for vendor-specific power.
- ADR-0002 — stdlib-first policy. OTEL SDK and OTLP exporters are
  added to the approved list as part of this ADR.
- ADR-0003 — public API layout this ADR extends with `pkg/logger`
  and `pkg/observability`.
- ADR-0004 — AI provider abstraction; observability wraps every
  `Backend.Generate` call.
- ADR-0006 — HCL2 config that drives observability toggles.
- DESIGN-0001 — engine that emits `engine.*` spans/metrics.
- DESIGN-0003 — public API surface; this ADR adds `pkg/logger`
  and `pkg/observability` to it.
- [OTEL Go SDK](https://pkg.go.dev/go.opentelemetry.io/otel).
- [Langfuse API reference](https://api.reference.langfuse.com/).
