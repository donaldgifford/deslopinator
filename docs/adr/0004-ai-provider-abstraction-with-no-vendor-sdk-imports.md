---
id: ADR-0004
title: "AI provider abstraction with no vendor SDK imports"
status: Proposed
author: Donald Gifford
created: 2026-05-08
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0004. AI provider abstraction with no vendor SDK imports

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
  - [Two-layer interface](#two-layer-interface)
  - [No vendor SDK imports](#no-vendor-sdk-imports)
  - [Vendor-specific sub-interfaces](#vendor-specific-sub-interfaces)
  - [No fallback; sentinel errors only](#no-fallback-sentinel-errors-only)
  - [Streaming](#streaming)
  - [Configuration and selection](#configuration-and-selection)
  - [Capability negotiation](#capability-negotiation)
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

RFC-0001 §"Pluggable subjective review providers" specifies an interface
boundary for the LLM-driven review layer that supports Claude API, Copilot
CLI subprocess, local `mlx_vlm.server` Qwen3 models, OpenRouter, and a
no-op stub. The original framing in the RFC named one interface
(`ReviewProvider`) and assumed in-tree implementations would each take
care of their own HTTP transport and JSON shape.

Two things have evolved since:

1. **More vendors, same problem.** Production users will want
   Anthropic Claude, OpenAI-compatible endpoints (OpenAI, Azure OpenAI,
   OpenRouter, Together, Groq, vLLM gateways), and local Ollama at
   minimum. Pulling in `github.com/anthropics/anthropic-sdk-go`,
   `github.com/sashabaranov/go-openai`, and `github.com/ollama/ollama`
   each carries its own transitive dependency closure, types, error
   model, and release cadence. ADR-0002's stdlib-first policy explicitly
   discourages this kind of accretion.

2. **Reference implementation exists.** A sibling repo
   (`github.com/donaldgifford/server-price-tracker`) already runs the
   pattern we want here: `pkg/extract.LLMBackend` is the vendor
   abstraction, all three backends (Anthropic, OpenAI-compatible,
   Ollama) build raw HTTP requests using `net/http` + `encoding/json`,
   and a higher-level `pkg/judge` composes on top of `LLMBackend` for
   its domain-specific use case. Zero direct SDK imports across the
   whole stack. Production-tested.

A separate but related decision: the boundary needs to be at the right
level. RFC-0001's `ReviewProvider` is *semantic* (review a finding for
a dimension); what we actually need is *also* a transport-level boundary
so an operator deploying deslopinator with a private LLM endpoint, or a
test harness wanting deterministic LLM responses, can swap one without
having to reimplement the deslopinator-specific review logic.

## Decision

Adopt the two-layer interface pattern from `server-price-tracker`. Forbid
direct AI vendor SDK imports anywhere in this repo. All three primary
backends (Anthropic, OpenAI-compatible, Ollama) ship in-tree and talk
HTTP via stdlib.

### Two-layer interface

**Layer 1 — `pkg/llm.Backend`: vendor-agnostic transport.** Mirrors
`server-price-tracker`'s `pkg/extract.LLMBackend`. Operators or test
harnesses inject a custom `Backend` here when they need a different
transport (private endpoint, mock server, replay fixture).

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
    Tools       []Tool        // optional, see Capabilities
    Stream      bool          // reserved; v1 Backend impls return non-streaming
}

type GenerateResponse struct {
    Content   string
    ToolCalls []ToolCall
    Usage     Usage
    Model     string
    Latency   time.Duration
}
```

**Layer 2 — `pkg/provider.ReviewProvider`: deslopinator-specific
review.** Mirrors `server-price-tracker`'s `pkg/judge.Judge`. Wraps a
`Backend`, adds prompt rendering, dimension-specific framing, JSON
verdict parsing, and provider attestation (RFC §"Scoring honesty"). The
operator-injected case here is rare — typically it's only the underlying
Backend that varies.

```go
// pkg/provider/provider.go (already declared in DESIGN-0003;
// this ADR clarifies that internal/review wraps a pkg/llm.Backend)

type ReviewProvider interface {
    Name() string
    Review(ctx context.Context, req api.ReviewRequest) (api.ReviewResponse, error)
    Capabilities() api.ProviderCapabilities
}
```

The default `ReviewProvider` impl (in `internal/review/provider/llm/`)
takes a `llm.Backend` and the prompt set as construction-time
dependencies. The two boundaries compose; the operator can choose which
one to override.

### No vendor SDK imports

The following imports are **forbidden** anywhere in `deslopinator`:

- `github.com/anthropics/anthropic-sdk-go`
- `github.com/sashabaranov/go-openai`
- `github.com/ollama/ollama` (and any sub-package thereof)
- `github.com/openai/openai-go`
- Any vendor's official Go SDK or "client library" for an LLM service.

Backends speak HTTP directly using `net/http` + `encoding/json`:

```
internal/llm/
├── anthropic/        // talks /v1/messages on api.anthropic.com
├── openaicompat/     // talks /v1/chat/completions; baseURL configurable
│                     //   (OpenAI, Azure, OpenRouter, Together, Groq, vLLM)
├── ollama/           // talks /api/chat on a local or remote Ollama
└── stub/             // deterministic fixture for tests; no network
```

Each backend is a struct that implements `pkg/llm.Backend`. Construction
takes an `*http.Client` (so callers can inject timeouts, retries, or a
test transport), a base URL, an API key (where applicable), and a model
name. A small shared helper handles request signing and error mapping;
no shared base struct.

Why this works in stdlib:
- LLM HTTP APIs are unspecified-but-stable JSON-over-HTTPS. Anthropic,
  OpenAI, and Ollama all publish OpenAPI specs or stable schemas; the
  delta against `encoding/json` struct tags is small.
- Rate-limiting headers (`x-ratelimit-*`, `retry-after`) parse cleanly.

Test backends (`stub/`) load canned responses from `testdata/` so
detector tests don't hit the network and provider tests are
deterministic.

### Vendor-specific sub-interfaces

Vendors expose features that don't fit the common `Backend` shape —
Anthropic prompt caching and content blocks, OpenAI structured outputs
and Responses API, Ollama keep-alive and model-list management. Forcing
all of these into one interface either bloats the contract or buries
features behind opaque options.

Solution: **vendor-specific sub-interfaces**, exactly the same pattern
as ADR-0005's `LLMExtension` for observability. Each vendor adapter
exposes one canonical sub-interface alongside its `Backend`
implementation. Callers that want vendor-specific features type-assert
or accept the sub-interface directly.

```go
// pkg/llm/anthropic/anthropic.go (public — vendor-specific sub-interface)

type AnthropicBackend interface {
    llm.Backend
    PromptCacheControl(ctx context.Context, blocks []CacheBlock) error
    // Anthropic-specific affordances. Additive within a major version
    // (same stability rule as llm.Backend).
}

// pkg/llm/openai/openai.go

type OpenAIBackend interface {
    llm.Backend
    StructuredOutput(ctx context.Context, schema json.RawMessage) (...)
    // OpenAI-specific affordances.
}

// pkg/llm/ollama/ollama.go

type OllamaBackend interface {
    llm.Backend
    ListModels(ctx context.Context) ([]Model, error)
    Pull(ctx context.Context, model string) error
}
```

Notes:
- Sub-interfaces live in `pkg/llm/<vendor>/`. The concrete impl
  (`internal/llm/<vendor>/`) implements both `llm.Backend` and the
  vendor sub-interface.
- We start with **one** vendor adapter (Anthropic) wired through the
  full sub-interface pattern. OpenAI and Ollama get sub-interfaces
  populated as features are needed, not pre-emptively.
- Sub-interfaces are append-only within a major version (same stability
  rule as `llm.Backend`).
- Code that wants vendor-portable behavior types against `llm.Backend`.
  Code that needs vendor-specific behavior accepts the sub-interface
  directly. The detector and review layers stay vendor-portable.
- HCL config drives both backend selection and which sub-interface
  features are enabled. See ADR-0006 §"Approved dependency".

This keeps the common path narrow without losing vendor-specific
power-user features. Same shape as ADR-0005's `LLMExtension`.

### No fallback; sentinel errors only

If the configured backend fails — quota, network, schema drift, anything
— deslopinator returns a typed sentinel error and stops. **No automatic
fallback to a different vendor.** A scan that runs against Claude with
no review output is a different artifact than a scan that ran against
Ollama as a substitute, and silently swapping would corrupt the
audit/scoring history (RFC-0001 §"Scoring honesty"). If the user wants
fallback semantics, they configure that at the orchestration layer
(operator, CI workflow, retry harness).

Sentinel errors expose enough signal to act on:

```go
// pkg/llm/errors.go

var (
    // ErrBackendUnavailable: transport-level failure (DNS, connection
    // refused, TLS, timeout reaching the endpoint).
    ErrBackendUnavailable = errors.New("llm: backend unavailable")

    // ErrBackendUnauthorized: 401/403 — credentials wrong or missing.
    ErrBackendUnauthorized = errors.New("llm: backend unauthorized")

    // ErrBackendRateLimited: 429 or vendor-specific rate-limit signal.
    // Wraps the parsed retry-after duration where available.
    ErrBackendRateLimited = errors.New("llm: backend rate limited")

    // ErrBackendQuotaExceeded: provider-specific quota/billing rejection
    // distinct from rate limits (e.g., Anthropic spend cap reached).
    ErrBackendQuotaExceeded = errors.New("llm: backend quota exceeded")

    // ErrBackendBadRequest: 4xx that isn't rate-limit or auth — bad
    // model name, invalid params, content-policy violation. Often
    // permanent; retrying without changing the request won't help.
    ErrBackendBadRequest = errors.New("llm: backend bad request")

    // ErrBackendBadResponse: 2xx with a body we can't parse, or 5xx with
    // no useful retry signal. Schema drift indicator.
    ErrBackendBadResponse = errors.New("llm: backend bad response")

    // ErrBackendCapabilityMissing: caller asked for tools/streaming/
    // JSON mode against a backend that declared SupportsX = false.
    // Returned at construction or at first call.
    ErrBackendCapabilityMissing = errors.New("llm: backend capability missing")
)
```

Each sentinel is wrapped (`fmt.Errorf("anthropic: %w: status=%d body=...", ErrBackendUnauthorized, resp.StatusCode)`)
so `errors.Is` matches and the operator/CI surfaces the underlying
detail. Backends additionally expose a typed wrapper carrying the HTTP
status code, vendor error code, and `retry-after` for callers that need
structured access via `errors.As`:

```go
type BackendError struct {
    Sentinel    error          // one of the sentinels above
    Backend     string         // "anthropic", "openai", ...
    StatusCode  int
    VendorCode  string         // vendor-specific error code, if any
    RetryAfter  time.Duration  // 0 if not provided
    RawBody     string         // truncated; not for parsing
}

func (e *BackendError) Error() string  { ... }
func (e *BackendError) Unwrap() error  { return e.Sentinel }
```

The promoted operator-facing surface in `pkg/api/errors.go`
(DESIGN-0003) re-exports these sentinels for `errors.Is` chains
without forcing the operator to import `pkg/llm` for error matching.

### Streaming

Verified as of 2026-05-07: vendor LLM streaming is still SSE for
Anthropic Messages API and OpenAI Chat Completions / Responses API.
Ollama `/api/chat` streams **NDJSON** (newline-delimited JSON over
HTTP chunked transfer), not SSE. MCP's transport reshape from
"HTTP+SSE" to "Streamable HTTP" (2025-06-18 spec) is unrelated to
vendor LLM streaming and still rides on SSE under the hood for the
single-endpoint path.

Concrete plan:

- `Backend.Generate` is non-streaming in v1. The `Stream bool` field
  on `GenerateRequest` is **reserved** but not honored by v1 backends.
- Streaming graduates to a sibling method when a real consumer needs
  it (most likely the agent execution loop, where token-by-token
  output is useful for the `next` command's "communicate score"
  phase). When that happens, the interface becomes:

  ```go
  type StreamingBackend interface {
      Backend
      GenerateStream(ctx context.Context, req GenerateRequest) (Stream, error)
  }

  type Stream interface {
      // Recv returns the next chunk or io.EOF when complete.
      Recv() (Chunk, error)
      Close() error
  }
  ```

- Per-vendor streaming format is tracked in the vendor adapter itself,
  not bubbled up: SSE for Anthropic/OpenAI, NDJSON for Ollama, future
  vendors as needed. The common `Stream` interface hides the wire
  format from callers.
- Capability negotiation surfaces streaming support via
  `Capabilities().SupportsStreaming` so the review layer can pick
  per-dimension (e.g., streaming for "communicate", batched for
  "scoring honesty audit").

Tracking the vendor streaming format per provider is required for
the broader `Backend` interface to remain swappable. Each vendor
adapter unit-tests its parser against fixture streams under
`testdata/streams/<vendor>/`.

### Configuration and selection

Backend selection is driven by HCL config (ADR-0006):

```hcl
# .deslopinator.hcl
review {
  enabled = true

  backend "anthropic" {
    model       = "claude-opus-4-7"
    api_key_env = "ANTHROPIC_API_KEY"
  }

  # OR: openai-compatible (covers OpenAI, Azure, OpenRouter, Together, etc.)
  # backend "openaicompat" {
  #   base_url    = "https://openrouter.ai/api/v1"
  #   model       = "anthropic/claude-opus-4-7"
  #   api_key_env = "OPENROUTER_API_KEY"
  # }

  # OR: local ollama
  # backend "ollama" {
  #   base_url = "http://localhost:11434"
  #   model    = "qwen3-coder:35b"
  # }
}
```

Exactly one backend block per profile. Cross-backend fallback (e.g.,
"try claude, fall back to ollama on quota") is a future ADR — start
simple.

### Capability negotiation

Backends declare what they support via `Capabilities()`:

```go
type Capabilities struct {
    SupportsTools      bool
    SupportsJSONMode   bool   // strict JSON output mode
    SupportsStreaming  bool   // reserved
    MaxContextTokens   int
    InputCostPerMTok   float64  // optional, for budget tracking
    OutputCostPerMTok  float64  // optional, for budget tracking
}
```

`ReviewProvider` checks capabilities at construction; mismatches
(e.g., asking for tool use against an Ollama model that doesn't support
it) are construction-time errors, not runtime surprises.

## Consequences

### Positive

- One audit path for AI vendor calls — every outbound request goes
  through `pkg/llm.Backend.Generate`. Trivial to wrap with OTEL spans
  (ADR-0005) and Langfuse logging.
- Adding a new vendor is ~150 lines of HTTP + JSON, not a new SDK
  dependency. Pull request small enough to review thoroughly.
- License-check stays clean: no transitive deps from vendor SDKs (some
  of which pull in absurd things like proto runtimes for unused
  features).
- Tests are deterministic by default — `stub/` backend with
  `testdata/` fixtures.
- Operator and test harnesses can inject `Backend` without
  understanding deslopinator's review semantics.

### Negative

- We have to track API drift across three vendors. Mitigation: each
  backend has its own contract test that, on `-tags=integration`,
  hits the real API with a tiny prompt and asserts the response shape
  parses. Run nightly, not on every PR. Catches breaking schema
  changes in days, not months.
- Streaming support is deferred. If we add it later, the interface
  change is additive (`Stream bool` already in `GenerateRequest`)
  but every backend has to implement SSE parsing.
- Some vendor features (e.g., Anthropic's prompt caching, OpenAI's
  structured outputs) need to be modeled in our common types or
  exposed via backend-specific options. Currently TBD per backend
  in implementation; not blocking for v1 of the review layer.

### Neutral

- The `OpenAI-compatible` lane covers a lot of ground but isn't
  identical across providers (rate-limit header names, error shapes,
  exact tool-call format). Each adapter gets its own
  `internal/llm/openaicompat/<vendor>/` sub-adapter only when needed;
  start with one shared implementation.
- We don't gain SDK-level ergonomics (typed message builders,
  retry/backoff helpers, observability hooks). Most of these we'd
  override anyway because we have our own observability stack
  (ADR-0005).

## Alternatives Considered

**Adopt LangChain Go (`tmc/langchaingo`).** Rejected. Adds a heavy
abstraction layer with its own opinions about chains, agents, memory,
etc. — none of which we need. Doesn't actually solve the
no-vendor-SDK problem because it depends on the vendor SDKs underneath.

**Adopt one vendor SDK (Anthropic) and HTTP-only the rest.** Rejected
as inconsistent. The argument for the SDK is "ergonomics"; the same
ergonomics argument applies to the other two. Either we accept the
audit/license/transitive-dep cost three times, or we reject it three
times. Three times rejected.

**Build everything against an OpenAI-compatible interface only;
require Anthropic and Ollama users to front their endpoints with a
proxy that translates.** Rejected. Forces users to deploy infrastructure.
Anthropic's native API is materially different (system prompt
handling, content blocks, tool result format) and translation
proxies are lossy. We accept the cost of three native adapters.

**Skip vendor abstraction; one backend hard-coded.** Rejected. The
RFC's whole "subjective review providers" model assumes pluggability,
and the success criterion of "internal teams use deslopinator" assumes
each team can use the LLM stack they already pay for.

## References

- RFC-0001 §"Pluggable subjective review providers" — the boundary
  this ADR formalizes and refines (now two layers).
- ADR-0002 — stdlib-first policy this decision reinforces.
- ADR-0003 — public API layout; `pkg/llm` and `pkg/provider` are
  added to that layout (see DESIGN-0003 amendment).
- ADR-0005 — observability stack that wraps `Backend.Generate`.
- ADR-0006 — HCL2 config that selects the backend.
- DESIGN-0003 — public API surface, including Backend interface
  details.
- `github.com/donaldgifford/server-price-tracker/pkg/extract` —
  reference implementation for the Backend pattern. Direct
  copy-paste of vendor adapters is acceptable (LLMBackend interface,
  Anthropic/OpenAI/Ollama HTTP clients) — we are not importing the
  package, just reusing the pattern.
- `github.com/donaldgifford/server-price-tracker/pkg/judge` —
  reference for composing a domain interface on top of `Backend`.
