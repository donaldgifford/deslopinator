---
id: IMPL-0001
title: "Initial deslopinator implementation phasing"
status: Draft
author: Donald Gifford
created: 2026-05-08
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0001: Initial deslopinator implementation phasing

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-08

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Phase Dependency Graph](#phase-dependency-graph)
- [Implementation Phases](#implementation-phases)
  - [Phase 0: Repository foundation and public types](#phase-0-repository-foundation-and-public-types)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 1: HCL2 configuration system](#phase-1-hcl2-configuration-system)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 2: Observability foundation](#phase-2-observability-foundation)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 3: LLM transport layer](#phase-3-llm-transport-layer)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 4: Engine core](#phase-4-engine-core)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 5: Review provider and attestation](#phase-5-review-provider-and-attestation)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 6: Public client and CLI scaffolding](#phase-6-public-client-and-cli-scaffolding)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
  - [Phase 7: Core CLI commands](#phase-7-core-cli-commands)
    - [Tasks](#tasks-7)
    - [Success Criteria](#success-criteria-7)
  - [Phase 8: Additional backends and Go language plugin](#phase-8-additional-backends-and-go-language-plugin)
    - [Tasks](#tasks-8)
    - [Success Criteria](#success-criteria-8)
  - [Phase 9: Stability tests and v0.1.0 release](#phase-9-stability-tests-and-v010-release)
    - [Tasks](#tasks-9)
    - [Success Criteria](#success-criteria-9)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [O-1. Legacy deslop codebase: where is it, what does it look like, and what gets ported? — OPEN](#o-1-legacy-deslop-codebase-where-is-it-what-does-it-look-like-and-what-gets-ported--open)
  - [O-2. Skill-file synthesis: stub in Phase 9 or full RFC Phase 5 deferral? — RESOLVED](#o-2-skill-file-synthesis-stub-in-phase-9-or-full-rfc-phase-5-deferral--resolved)
  - [O-3. Phase 4 detector tier split: when does near_duplicates land? — RESOLVED](#o-3-phase-4-detector-tier-split-when-does-nearduplicates-land--resolved)
  - [O-4. State file location relative to repo root vs cwd — RESOLVED](#o-4-state-file-location-relative-to-repo-root-vs-cwd--resolved)
  - [O-5. Anthropic prompt-caching capability — public sub-interface or hidden? — RESOLVED](#o-5-anthropic-prompt-caching-capability--public-sub-interface-or-hidden--resolved)
  - [O-6. Per-detector configuration — does .deslopinator.hcl need a detector "name" { ... } block in v0.1.0? — RESOLVED](#o-6-per-detector-configuration--does-deslopinatorhcl-need-a-detector-name----block-in-v010--resolved)
  - [O-7. Performance benchmark fixture: vendored or fetched? — RESOLVED](#o-7-performance-benchmark-fixture-vendored-or-fetched--resolved)
  - [O-8. Cgroup GOMAXPROCS verification (DESIGN-0001 Q2) — Phase 4 or Phase 9? — RESOLVED](#o-8-cgroup-gomaxprocs-verification-design-0001-q2--phase-4-or-phase-9--resolved)
- [References](#references)
<!--toc:end-->

## Objective

Implement the deslopinator scaffold described by RFC-0001 (Phase 1) up
through a publicly tagged `v0.1.0` release that the deslopinator-operator
repo can begin importing. This impl plan consolidates and sequences the
rollout sections from DESIGN-0001 (engine), DESIGN-0002 (CLI), and
DESIGN-0003 (public API) into a single phased work plan with explicit
dependencies, tasks, and success criteria.

**Implements:** RFC-0001, DESIGN-0001, DESIGN-0002, DESIGN-0003.
**Honors:** ADR-0001 through ADR-0006.

## Scope

### In Scope

- Greenfield Go module structure under `pkg/` and `internal/`.
- HCL2 configuration system end-to-end (decoder, schema, validation).
- OTEL observability with the `LLMExtension` interface and a Langfuse
  reference implementation.
- Vendor-agnostic `pkg/llm.Backend` interface plus the Anthropic
  backend as the first concrete implementation. OpenAI-compatible and
  Ollama backends ship in Phase 8.
- `internal/engine` worker pool, detector contract, state file
  (StateV1), scoring, and phase-gated work queue.
- `pkg/client` driver and the full Cobra-based CLI surface.
- A first Go-language detector set written greenfield against
  `golang.org/x/tools/go/{ssa,packages}` and `github.com/dave/dst`.
- `v0.1.0` release with goreleaser-built multi-arch binaries.

### Out of Scope

- Multi-language plugins beyond Go (Python, TypeScript, Rust — RFC
  Phase 4).
- Agent skill-file synthesis from `--help` output (RFC Phase 5).
- Remote engine over gRPC (DESIGN-0003 §"Operator integration patterns"
  pattern 3 — future ADR).
- Streaming `Backend.GenerateStream` (ADR-0004 §"Streaming" — graduates
  when a real consumer needs it).
- The deslopinator-operator repo itself.

## Phase Dependency Graph

```
Phase 0 ─┬─► Phase 1 ─┬─► Phase 2 ─┬─► Phase 3 ─┬─► Phase 4 ─┬─► Phase 5 ─┐
         │            │            │            │            │            │
         │            │            │            │            ├────────────┘
         │            │            │            │            │
         │            │            │            │            ▼
         │            │            │            │       Phase 6 ─► Phase 7 ─► Phase 8 ─► Phase 9
         │            │            │            │
         └─ types ────┘            └─ traces ───┘
            (every phase imports pkg/api)
```

Phases 0–5 build the engine bottom-up from public types to a working
`Engine.Run`. Phases 6–7 build the operator-facing surface and the
CLI on top. Phase 8 adds the remaining vendor backends and the first
real detector. Phase 9 hardens and ships.

A phase is complete when **all** its tasks are checked off **and** all
its success criteria are met. Don't proceed to the next phase with a
phase only "mostly done" — the dependency graph means partial work
ripples.

## Implementation Phases

---

### Phase 0: Repository foundation and public types

Establish the Go module structure, public type surface, and zero-logic
scaffolding the rest of the implementation depends on. No behavior is
visible yet; this phase exists to make later phases mergeable without
moving directories around.

#### Tasks

- [ ] Create `pkg/api/` directory with `doc.go` carrying the stability
      contract from ADR-0003.
- [ ] Add `pkg/api/finding.go`: `FindingID`, `Severity`, `Tier`,
      `Dimension`, `Language`, `Finding`, `FindingCounts` (DESIGN-0003).
- [ ] Add `pkg/api/score.go`: `Score`, `ScoreSnapshot`, `ScoreHistory`.
- [ ] Add `pkg/api/resolution.go`: `ResolutionStatus`, `Resolution`,
      `Attestation`.
- [ ] Add `pkg/api/state.go`: `StateV1`, `SchemaVersionV1` constant.
- [ ] Add `pkg/api/scan.go`: `AnalysisUnit`, `ScanRequest`,
      `ScanOptions`, `ScanResult`.
- [ ] Add `pkg/api/review.go`: `ReviewScope`, `ReviewRequest`,
      `ReviewResponse`, `ProviderCapabilities`, `SourceFile`.
- [ ] Add `pkg/api/queue.go`: `Phase`, `WorkItem`, `QueueSnapshot`.
- [ ] Add `pkg/api/errors.go`: 5 sentinel errors (DESIGN-0001).
- [ ] Add `pkg/api/config.go`: `Config`, `Profile`, `BackendConfig`,
      `ObservabilityConfig`, `OTelConfig`, `LLMExtensionConfig`,
      `ReviewConfig` (ADR-0006). Types only; decoding lands in Phase 1.
- [ ] Create `pkg/logger/logger.go`: `New`, `NewWithWriter`,
      `NewWithHandler` (ADR-0005).
- [ ] Create `pkg/logger/doc.go`: stability contract; document
      `slog.Handler` as the swap point.
- [ ] Replace stub `cmd/deslopinator/main.go` with a minimal
      `func main() { os.Exit(cmd.Execute()) }` — `cmd` package empty
      placeholder OK for now.
- [ ] Create empty placeholder packages so `go build ./...` resolves:
      `pkg/{llm,provider,client,observability}/doc.go`.
- [ ] Add Apache-2.0 license header to all new `.go` files (matches
      `goheader` linter rule from `.golangci.yml`).
- [ ] Update CLAUDE.md "Current state" line to reflect that Phase 0
      has landed.
- [ ] Add unit-test stubs for each `pkg/api` file (validate JSON
      round-tripping for the structs that have JSON tags).

#### Success Criteria

- `go build ./...` and `go vet ./...` pass with zero errors or warnings.
- `make lint` passes.
- `pkg/api` types can be JSON-encoded and decoded by `encoding/json`
  without info loss (round-trip test).
- `pkg/logger.New("info", "json")` returns a working `*slog.Logger`
  that emits structured JSON to stderr.
- All packages under `pkg/` have a `doc.go` referencing the relevant
  ADR(s).
- Module path verified: `go list -m` returns
  `github.com/donaldgifford/deslopinator`.

---

### Phase 1: HCL2 configuration system

Land the configuration loader so every later phase can be configured
from `.deslopinator.hcl` rather than hard-coded values. This phase
makes the engine, observability, and backend choices declarable.

#### Tasks

- [ ] Add `github.com/hashicorp/hcl/v2` and `.../hcl/v2/gohcl` to
      `go.mod`.
- [ ] Create `internal/config/decoder.go`: load + decode HCL2 file into
      `pkg/api.Config`.
- [ ] Implement discovery + merge order from ADR-0006 §"Discovery and
      merge order": defaults → `/etc/deslopinator/config.hcl` →
      `$XDG_CONFIG_HOME/deslopinator/config.hcl` → `./.deslopinator.hcl`
      → `./.deslopinator/profiles/<profile>.hcl` → env → flags.
- [ ] Implement env-var override for `DESLOPINATOR_<UPPER_FLAG>`.
- [ ] Implement schema version check: reject `version != 1` with
      `pkg/api.ErrStateSchemaMismatch`-style error pointing at a
      future migration command.
- [ ] Add unknown-attribute warnings (continue) vs unknown-block
      errors (fail).
- [ ] Implement env interpolation for HCL `*_env` attributes
      (e.g., `api_key_env = "ANTHROPIC_API_KEY"` resolves at decode
      time using `os.LookupEnv`).
- [ ] Auto-detect repo root: walk up from CWD to nearest `.git/` if
      `--path` and `path = "..."` are both unset (DESIGN-0002 Q4
      resolution).
- [ ] Write a fully-commented sample `.deslopinator.hcl` matching the
      example in DESIGN-0002 §"Data Model"; embed via `//go:embed` for
      `deslopinator init`.
- [ ] Table-driven tests for the decoder using `t.TempDir()` HCL
      fixtures: valid file, missing file, schema-version mismatch,
      env interpolation, profile inheritance, unknown attributes,
      unknown blocks.
- [ ] Test coverage for the discovery chain ordering using a tempdir
      with files at each level.

#### Success Criteria

- `internal/config.Load(ctx, path)` returns a fully-populated
  `pkg/api.Config` for the sample HCL file.
- Env var precedence works: `DESLOPINATOR_PATH=/foo deslopinator-test`
  overrides the HCL `path` attribute.
- `version = 2` config files fail to load with a clear error.
- Auto-detect repo root finds the right `.git/` ancestor in a nested
  directory test.
- Decoder unit tests run with `-race` and pass.
- `go test ./internal/config/...` coverage ≥ 85%.

---

### Phase 2: Observability foundation

Stand up OTEL + the `LLMExtension` interface plus a Langfuse reference
implementation. Every phase from here on emits spans/metrics through
this layer.

#### Tasks

- [ ] Add OTEL deps to `go.mod`: `go.opentelemetry.io/otel`,
      `go.opentelemetry.io/otel/sdk`,
      `go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc`,
      `go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc`,
      `go.opentelemetry.io/otel/propagation`.
- [ ] Verify all OTEL transitive deps land in license-allow-list
      (Apache-2.0/BSD-3 expected); update `make license-check`
      golden if needed.
- [ ] Create `pkg/observability/observability.go`: `Config`,
      `OTelConfig`, `ResourceAttributes`, `Init`, `Shutdown`.
- [ ] Create `pkg/observability/extension.go`: `LLMExtension` interface
      (ADR-0005).
- [ ] Wire base OTEL pipeline: OTLP/gRPC trace + metric exporters,
      `AlwaysSample()`, W3C TraceContext + Baggage propagators,
      resource with `service.name=deslopinator`, version, instance,
      profile.
- [ ] Implement `Init` to short-circuit to `noop.NewTracerProvider()`
      and `noop.NewMeterProvider()` when `cfg.OTel.Enabled = false` —
      no exporter setup, no goroutines started.
- [ ] Create `pkg/observability/langfuse/langfuse.go`: `Extension`
      struct, `Config`, `New`, `Operations` interface,
      `(*Extension).Operations()`.
- [ ] Create `internal/observability/langfuse/httpclient.go`: stdlib
      `net/http` + `encoding/json` Langfuse client.
- [ ] Create `internal/observability/langfuse/noopclient.go`: every
      method returns nil.
- [ ] Create `internal/observability/langfuse/bufferedclient.go`:
      in-memory queue + background drain goroutine, drops on overflow
      with `observability.extension.dropped_events_total` counter.
- [ ] Wire `Extension.Apply` to attach Langfuse SpanProcessors and
      metric readers to the running OTEL providers.
- [ ] Add benchmark proving disabled path is allocation-free
      (`testing.B` with `b.ReportAllocs()`).
- [ ] Document `--no-otel` / `--no-llm-extension` / `--no-observability`
      semantics in package docs.
- [ ] Integration test against a local OTEL collector
      (`-tags=integration` + collector container in test setup).

#### Success Criteria

- `pkg/observability.Init(ctx, cfg)` with `cfg.OTel.Enabled = true`
  returns a working tracer + meter, OTLP/gRPC connects to a local
  collector, spans flow.
- `Init` with `cfg.OTel.Enabled = false` allocates zero bytes (verified
  by benchmark) and returns a no-op `Shutdown`.
- `langfuse.New` plus `Init` with `Extension: ext` produces a
  TracerProvider whose spans are exported to a stub Langfuse server.
- `BufferedClient` drops events on queue overflow without blocking the
  caller; counter metric increments.
- `pkg/logger.New` + observability Init compose correctly: logs go to
  stderr, traces go to OTLP, no double-init.
- Coverage ≥ 80% for `pkg/observability/...`.

---

### Phase 3: LLM transport layer

Implement the vendor-agnostic `Backend` interface with one concrete
backend (Anthropic). OpenAI-compatible and Ollama backends ship in
Phase 8 — the interface and stub backend land here so Phase 5 can
develop against them.

#### Tasks

- [ ] Create `pkg/llm/backend.go`: `Backend` interface,
      `GenerateRequest`, `GenerateResponse`, `Message`, `Role`,
      `Tool`, `ToolCall`, `Usage`, `Capabilities` (ADR-0004).
- [ ] Create `pkg/llm/errors.go`: 8 sentinel errors
      (`ErrBackendUnavailable`, `ErrBackendUnauthorized`,
      `ErrBackendRateLimited`, `ErrBackendQuotaExceeded`,
      `ErrBackendBadRequest`, `ErrBackendBadResponse`,
      `ErrBackendCapabilityMissing`, `ErrCapabilityNotImplemented`) and
      `BackendError` wrapper with `Unwrap()`.
      `ErrCapabilityNotImplemented` is the marker for vendor
      sub-interface methods declared but reserved — see Phase 3
      `AnthropicBackend.PromptCacheControl` task below.
- [ ] Re-export sentinel errors from `pkg/api/errors.go` so operators
      match via `errors.Is(err, deslopapi.ErrBackendRateLimited)`
      without importing `pkg/llm`.
- [ ] Create `pkg/llm/anthropic/anthropic.go`: `AnthropicBackend`
      sub-interface (extends `llm.Backend` with prompt-cache
      affordances). Method `PromptCacheControl(...)` is **declared in
      v0.1.0 but reserved** — concrete impl returns
      `ErrCapabilityNotImplemented`. Per O-5 resolution: full caching
      lands in v0.2.0 once review-phase observability tells us
      expected savings.
- [ ] Create `pkg/llm/openai/openai.go`: `OpenAIBackend` sub-interface
      signature (impl in Phase 8).
- [ ] Create `pkg/llm/ollama/ollama.go`: `OllamaBackend` sub-interface
      signature (impl in Phase 8).
- [ ] Create `internal/llm/stub/stub.go`: deterministic fixture
      backend that loads canned responses from `testdata/`.
- [ ] Create `internal/llm/anthropic/`: full HTTP impl against
      `POST /v1/messages` on `api.anthropic.com`.
  - [ ] Request encoder (system, messages, tools, tool_choice).
  - [ ] Response decoder (content blocks, tool_use blocks, usage).
  - [ ] HTTP status → sentinel error mapping (401→`ErrBackendUnauthorized`,
        429→`ErrBackendRateLimited` with `retry-after`, 5xx→
        `ErrBackendUnavailable`, etc.).
  - [ ] `BackendError` populated with vendor error code, raw body
        (truncated to 1KB), retry-after.
  - [ ] Capabilities: `SupportsTools=true`, `SupportsJSONMode=true`,
        `MaxContextTokens` per-model table, cost-per-Mtok per-model
        table (kept current per release).
- [ ] OTEL spans wrap each `Backend.Generate` call with attributes
      `llm.backend`, `llm.model`, `llm.tokens.input`,
      `llm.tokens.output`, `llm.cost.usd`.
- [ ] Construction-time capability check: caller asks for tools
      against a non-tool backend → `ErrBackendCapabilityMissing` from
      `New(...)`, not from first `Generate`.
- [ ] Per-vendor unit tests with `httptest.Server` fixtures.
- [ ] Per-vendor contract test gated by `-tags=integration` + real
      API key — runs nightly in CI, hits real API with a tiny prompt,
      asserts response shape parses.

#### Success Criteria

- `internal/llm/anthropic.Backend.Generate` round-trips a 50-token
  prompt against the real Anthropic API in a contract test.
- Stub backend loads `testdata/anthropic_simple_response.json` and
  returns it deterministically.
- HTTP 429 with `retry-after: 5` returns
  `&BackendError{Sentinel: ErrBackendRateLimited, RetryAfter: 5*time.Second}`,
  and `errors.Is(err, ErrBackendRateLimited)` matches.
- Capability mismatch (tools on non-tool model) returns
  `ErrBackendCapabilityMissing` at `New(...)`.
- `BackendError.RawBody` truncated to ≤ 1024 bytes.
- OTEL spans for `llm.generate` show up in the local collector with
  the documented attributes.
- Coverage ≥ 80% for `pkg/llm/...` and `internal/llm/anthropic/...`.

---

### Phase 4: Engine core

Build the language-agnostic engine: worker pool, detector contract,
state persistence, scoring, queue. One trivial detector lands here as
a smoke test; the real Go detector arrives in Phase 8.

#### Tasks

- [ ] Add `golang.org/x/sync` to `go.mod` (errgroup, semaphore).
- [ ] Create `internal/engine/parallel/pool.go`: `Pool` struct,
      `RunDetector` method using `errgroup.Group` (DESIGN-0001).
- [ ] Implement deterministic output: per-unit sequence number,
      sort findings by `(unit.Path, finding.Line, finding.DetectorName)`
      before returning.
- [ ] Implement worker sizing: `min(GOMAXPROCS, cfg.MaxWorkers, len(units))`.
- [ ] Create `internal/engine/detector/detector.go`: `Detector` interface,
      `Tier` enum, `Reducer` interface (DESIGN-0001).
- [ ] Create `internal/engine/state/state.go`: load/save `pkg/api.StateV1`
      with atomic write (temp-file-and-rename).
- [ ] State path resolution rule (per O-4 resolution): default state
      path is `<repo-root>/.deslopinator/state.json`. If repo-root
      auto-detect failed (no `.git/` found), the CLI errors out with
      `ErrConfigError` and exit code 3, asking for explicit `--path`
      or `--state-file`. The `pkg/client` Go API requires explicit
      `WithStatePath(...)` — no implicit fallback. Operator (which
      runs in pods with no `.git/`) provides the path from its CR
      spec.
- [ ] Implement state schema version check on load: refuse newer
      versions with `ErrStateSchemaMismatch`.
- [ ] Stub migration framework (`migrateV1ToV2`) with one no-op
      migration to validate the framework — real migrations come when
      `StateV2` exists.
- [ ] Create `internal/engine/scoring/scoring.go`: strict + lenient
      score per RFC §"Scoring honesty". Anti-gaming policy applied
      per RFC table.
- [ ] Create `internal/engine/queue/queue.go`: phase-gated work queue
      construction, ranking by tier and severity.
- [ ] Create `internal/engine/engine.go`: `Engine` struct, `Run`
      method executing phases 0–6 (sources → detect → reduce →
      subjective → score → persist → queue).
- [ ] Per-phase OTEL span wrapping: `engine.scan`,
      `engine.phase.<name>`, `engine.detector.<name>` (ADR-0005).
- [ ] Per-detector timeout from `ScanOptions.PerDetectorTimeout`
      (default 60s); timeout produces a synthetic
      `engine.detector_timeout` finding rather than aborting.
- [ ] Per-detector panic recovery → `Severity: Error` finding;
      scan continues.
- [ ] `errors.Join` collects per-detector errors for the phase return
      while preserving partial findings (DESIGN-0001 Q3 resolution).
- [ ] One Tier-1 (`TierPureParallel`) trivial detector under
      `internal/engine/detector/empty_files/`: flags zero-byte source
      files. Smoke-tests the per-unit fan-out path.
- [ ] One Tier-2 (`TierParallelReduce`) smoke detector under
      `internal/engine/detector/exact_dupes/`: hashes file bytes,
      reduces by joining identical-hash unit groups into a single
      cluster finding. Validates the parallel-then-reduce code path
      before the real `near_duplicates` Go detector lands in Phase 8
      (per O-3 resolution).
- [ ] Determinism property test: random unit orderings produce
      identical `ScoreSnapshot`.
- [ ] Worker pool race test with `-race` + deterministic seed.
- [ ] `goleak.VerifyNone(t)` cancellation test.
- [ ] Engine integration test against a fixture repo under
      `testdata/`; assert `StateV1` matches a golden file modulo
      timestamps.
- [ ] Vendor a small (~10k-LOC) Go fixture repo under
      `testdata/fixtures/small_go_repo/` for the per-PR Phase 4
      benchmark (per O-7 resolution). Pin to a specific upstream
      tag/SHA, document in the fixture's README. The full 100k-LOC
      benchmark is fetched at test time in Phase 9.
- [ ] Cgroup `GOMAXPROCS` contract test under
      `internal/engine/parallel/cgroup_test.go` gated by
      `-tags=integration` (per O-8 resolution): spin up a Kind cluster
      via `sigs.k8s.io/kind` test harness, deploy a pod with a CPU
      limit, exec the test binary, assert `runtime.GOMAXPROCS(0)`
      returns the limited value. Re-run as a release gate in Phase 9.
- [ ] Excerpt size enforcement: cap per-finding excerpt at
      `excerpt_max_bytes` (default 2KB, hard upper bound 64KB)
      per DESIGN-0003 Q1 resolution.
- [ ] Emit `engine.findings.excerpt_bytes` histogram metric.

#### Success Criteria

- `Engine.Run` against a fixture repo produces a `StateV1` with
  findings from the empty-files detector.
- Determinism property test passes for 100 random orderings.
- `-race` + worker pool test passes.
- `goleak.VerifyNone(t)` passes after a cancelled scan.
- Per-detector timeout produces `engine.detector_timeout` finding,
  scan completes with the rest of detectors' results.
- p95 scan latency on a 10k-LOC fixture < 5s on M-series 8-core
  laptop (intermediate target; the 30s/100k-LOC criterion lives
  in Phase 9).
- Engine emits all documented OTEL spans/metrics in the local
  collector.
- Coverage ≥ 80% for `internal/engine/...`.

---

### Phase 5: Review provider and attestation

Add the subjective review layer that wraps a `Backend` for prompt-driven
scoring. Resolution attestation lands here so RFC §"Scoring honesty"
properties hold.

#### Tasks

- [ ] Create `pkg/provider/provider.go`: `ReviewProvider` interface
      (ADR-0004 / DESIGN-0003).
- [ ] Create `internal/review/prompt/`: versioned per-dimension
      prompt templates. One template per `Dimension` enum value;
      version string in template metadata.
- [ ] Create `internal/review/provider/llm/`: default `ReviewProvider`
      impl that takes a `pkg/llm.Backend` and renders prompts per
      dimension.
- [ ] Implement JSON verdict parsing from `Backend.Generate` response:
      score (0..100), rationale, prompt ID. Malformed output →
      `ErrProviderUnavailable`.
- [ ] Compute `ReviewResponse.PromptID` deterministically from
      template version + content hash.
- [ ] Wire engine §"Subjective" phase to call `ReviewProvider.Review`
      for each finding requiring subjective review (per detector
      classification).
- [ ] Create `internal/attestation/attestation.go`: signing primitive
      using ed25519 from `crypto/ed25519` (stdlib, no third-party).
- [ ] Append-only resolution log: write `Resolution` entries with
      attestation to `<statePath>/resolutions.log` (JSON-lines,
      monotonic).
- [ ] Resolution-note heuristic (RFC §"Agent integration"): empty
      note → `ErrEmptyResolutionNote`; note must reference at least
      one modified file (lightweight check, not LLM-backed).
- [ ] OTEL spans `provider.review` parent the `llm.generate` span;
      attribute `dimension`, `prompt_id`.
- [ ] If `LLMExtension.Operations()` is available (Langfuse case),
      call `Operations.Score(...)` after each review for
      prompt-versioned audit trail.
- [ ] Cost tracking: `llm.cost.usd_total` counter incremented per
      review using `Backend.Capabilities().{Input,Output}CostPerMTok`.
- [ ] Table-driven tests for prompt rendering + verdict parsing
      using stub backend.
- [ ] Attestation roundtrip test: sign → verify → tamper → verify
      fails.

#### Success Criteria

- Subjective phase produces a `ReviewResponse` with non-empty
  rationale for each `Dimension` against a stub backend.
- Resolution log validates: signed entries verify; tampered entries
  fail verification.
- Cost metric reflects realistic input/output token counts when run
  against the Anthropic backend with a known model.
- Empty resolution notes fail with `ErrEmptyResolutionNote`; notes
  not referencing the modified files are flagged (warning, not
  rejection).
- `pkg/provider` API stability hash recorded.
- Coverage ≥ 80% for `pkg/provider`, `internal/review/...`,
  `internal/attestation/...`.

---

### Phase 6: Public client and CLI scaffolding

Land the operator-facing `pkg/client` driver and the Cobra command tree
skeleton with `version` and `init`. CLI subcommands that need the
engine arrive in Phase 7.

#### Tasks

- [ ] Add `github.com/spf13/cobra` to `go.mod`.
- [ ] Create `pkg/client/options.go`: `Option`, `config`, every
      `WithX` constructor from DESIGN-0003.
- [ ] Create `pkg/client/client.go`: `Client` struct, `New`, all
      methods (`Scan`, `Next`, `Resolve`, `LoadState`, `Score`).
- [ ] `Client` holds an unexported `*engine.Engine` — single
      `pkg/` → `internal/` boundary point.
- [ ] Implement `SkipObservabilityInit()` — when set, `Client` does
      not call `observability.Init`; trusts caller to have done it.
- [ ] Create `cmd/deslopinator/cmd/root.go`: `newRootCmd(client, out)`
      constructor, persistent flags table from DESIGN-0002, no
      package-level vars, no `init()`.
- [ ] Add persistent flags: `--config`, `--path`, `--profile`,
      `--format`, `--state-file`, `--verbose`/`-v`, `--quiet`/`-q`,
      `--no-otel`, `--no-llm-extension`, `--no-observability`.
- [ ] Format flag accepts `text`, `json`, `jsonl`. Default `text`.
- [ ] Create `cmd/deslopinator/cmd/version.go`: `newVersionCmd()`,
      ldflag-injected `version`, `commit`, `date`.
- [ ] Create `cmd/deslopinator/cmd/init.go`: writes
      `.deslopinator.hcl` and `.deslopinator/` from the embedded
      sample. `--force` to overwrite.
- [ ] Create `cmd/deslopinator/cmd/completion.go`: re-export Cobra's
      builtin `completion` subcommand.
- [ ] `cmd/deslopinator/main.go`:
      `func main() { os.Exit(cmd.Execute()) }`.
- [ ] Help-text golden test (`cmd/deslopinator/cmd/help_test.go`):
      diff `--help` output against
      `testdata/help/{root,version,init,completion}.golden.txt`.
- [ ] Per-command unit test pattern: build command with
      `bytes.Buffer` for stdout/stderr; assert output and error.

#### Success Criteria

- `deslopinator version` prints a version string from ldflags.
- `deslopinator init` writes a valid HCL config that
  `internal/config.Load` accepts.
- `deslopinator init` refuses to overwrite without `--force`.
- `deslopinator completion bash` emits a working completion script.
- `deslopinator --help` matches the golden file byte-for-byte.
- `goreleaser build --snapshot` succeeds against this CLI.
- Coverage ≥ 80% for `pkg/client/...` and `cmd/deslopinator/cmd/...`.

---

### Phase 7: Core CLI commands

Implement the command set the agent loop and CI consumers depend on:
`scan`, `next`, `resolve`, `status`, `findings`, `score`, plus the
`state` and `review` subcommand groups.

#### Tasks

- [ ] `scan`: flags `--workers`, `--per-detector-timeout`,
      `--no-subjective`, `--detectors`, `--languages`. Output: scan
      summary (counts, score, duration). Exit 0 on completion
      regardless of findings.
- [ ] `next`: flags `--phase`, `--limit`. Returns one work item by
      default; `--format jsonl` supported when `--limit > 1`.
- [ ] `resolve <status> <id>`: positional status (`fixed`,
      `dismissed`, `wontfix`); required `--note`; `--force` to bypass
      heuristic. Empty notes return exit 2.
- [ ] `status`: prints scores, queue depth per phase, last scan
      time. `--format json` returns a structured snapshot.
- [ ] `findings [QUERY]`: free-form query (`severity:high tier:1
      lang:go`). Flags `--limit`, `--offset`. Supports `text`, `json`,
      `jsonl`.
- [ ] `score`: prints strict + lenient scores. `--history` for
      trend; `--format jsonl` streams per-snapshot records.
- [ ] `state show`: pretty-print `StateV1`. `--format json`.
- [ ] `state migrate`: requires `--yes` to write; prints diff
      otherwise. Exits 4 if no migration needed; 0 on success.
- [ ] `state validate`: re-verifies attestation chain on the
      resolution log.
- [ ] `review list`: lists configured providers and capabilities.
- [ ] `review run --provider X --finding ID`: debug aid; calls
      provider directly without scorer.
- [ ] `config validate`: decodes `.deslopinator.hcl`, prints any
      warnings/errors. Exits 0 on clean, 3 on config error.
- [ ] Exit code policy enforced across all commands:
      0/1/2/3/4/5 per DESIGN-0002 §"Output formats and exit codes".
- [ ] Sentinel error → JSON: `--format json` on error emits
      `{"error": {"code": "ErrBackendRateLimited", "message": "..."}}`.
- [ ] Help-text golden file extended for every command.
- [ ] `internal/test/parity/parity_test.go`: runs each command
      through `os/exec` (CLI) and through `pkg/client` (Go API),
      diffs the resulting state file. Asserts wire-shape parity.
- [ ] End-to-end test under `internal/test/e2e/`: `go build` the
      binary, run a full agent loop (`scan` → `next` → `resolve`
      → `next` → `scan`) against a fixture repo.

#### Success Criteria

- All commands implemented match the spec in DESIGN-0002 §"Per-command
  flags and behavior".
- CLI/client parity test passes — every command produces the same
  state file via CLI as via `pkg/client`.
- End-to-end test completes the full agent loop against a fixture
  repo without errors.
- Sentinel errors round-trip through `--format json` correctly
  (`error.code` field matches `errors.Is` chain).
- Help-text golden files are stable across runs.
- `make ci` passes.
- Coverage ≥ 80% for all new CLI command files.

---

### Phase 8: Additional backends and Go language plugin

Round out the backend set (OpenAI-compatible + Ollama) and write the
first Go-language detectors greenfield in `internal/lang/golang/`.

#### Tasks

- [ ] Create `internal/llm/openaicompat/`: full HTTP impl against
      `POST /v1/chat/completions`. Configurable `base_url` covers
      OpenAI, Azure, OpenRouter, Together, Groq, vLLM gateways.
  - [ ] Request encoder (chat messages, tools, response_format).
  - [ ] Response decoder (choices, tool_calls, usage).
  - [ ] Status code → sentinel error mapping with vendor-specific
        error code parsing.
- [ ] Create `internal/llm/ollama/`: full impl against
      `POST /api/chat`.
  - [ ] **Note: Ollama streams NDJSON** (newline-delimited JSON over
        chunked transfer), not SSE. Non-streaming v1 collects until
        `done: true`. Use `bufio.Scanner` over the response body.
  - [ ] No auth header; local-first model.
  - [ ] Capabilities populated from a hard-coded model table; no
        cost tracking (Ollama is local).
- [ ] Add `golang.org/x/tools/go/{ssa,packages,analysis}` and
      `github.com/dave/dst` to `go.mod`.
- [ ] Create `internal/lang/golang/`: AST + SSA + DST loader.
  - [ ] `loader.go`: `golang.org/x/tools/go/packages.Load` with
        `NeedSyntax | NeedTypes | NeedTypesInfo | NeedDeps` mode.
  - [ ] `ssa.go`: `ssa.NewProgram` + `ssaprog.Build()` over the
        loaded packages.
  - [ ] `dst.go`: parallel DST tree for source-rewrite affordances.
  - [ ] Per-package caching keyed by package path + content hash so
        the SSA build cost is paid once per scan.
- [ ] Three Tier-1/2 Go detectors written greenfield (no port — see
      O-1 resolution):
  - [ ] `golang.unused_functions` (Tier-1, `TierPureParallel`):
        SSA reachability from declared exports + `main`. Skip
        functions on test files when scanning non-test mode.
  - [ ] `golang.dead_branches` (Tier-1, `TierPureParallel`): SSA
        branch reachability via constant folding; reports
        unreachable basic blocks.
  - [ ] `golang.near_duplicates` (Tier-2, `TierParallelReduce`):
        normalized SSA basic-block hashing per function in the
        parallel pass; union-find clustering across functions in
        the reduce pass.
- [ ] OpenAI-compat contract test (`-tags=integration` +
      `OPENAI_API_KEY`): minimal prompt round-trip.
- [ ] Ollama contract test (`-tags=integration` + local Ollama
      running): minimal prompt round-trip.
- [ ] Build a known-bad Go fixture under
      `testdata/golang/known_bad/` containing deliberate cases per
      detector: at least one unused function, one dead branch, and
      two near-duplicate function pairs.
- [ ] Engine integration test exercises all three detectors against
      the fixture; assert findings match a golden file.
- [ ] Update `deslopinator init` sample HCL to show all three
      backend variants commented out.

#### Success Criteria

- OpenAI-compat backend passes contract test against real OpenAI API.
- Ollama backend passes contract test against a local Ollama instance.
- All three Go detectors produce findings on the known-bad fixture
  with stable IDs across runs.
- `engine.Run` against the fixture produces `StateV1` matching a
  golden file (modulo timestamps and signatures).
- Determinism property test still passes after the Go detectors
  land.
- Coverage ≥ 80% for `internal/llm/openaicompat`,
  `internal/llm/ollama`, `internal/lang/golang/...`.

---

### Phase 9: Stability tests and v0.1.0 release

Lock the public API, run the full release rehearsal, and tag.

#### Tasks

- [ ] Create `pkg/api/api_stability_test.go`: reflection over every
      exported type/method, dump SHA-256 hash to a golden file.
      Any change fails CI; reviewers regenerate intentionally.
- [ ] Create `internal/test/apicompat/`: skeleton in place for
      cross-version test. No-op until v0.2.0 (needs a previous
      tagged minor to build against). Document the trigger condition.
- [ ] CLI/client parity test (Phase 7) extended to run as part of CI
      gate, not just on demand.
- [ ] `make ci` green: lint, test, build, license-check all pass.
- [ ] `goreleaser check` passes for the current `.goreleaser.yml`.
- [ ] `make release-local` produces working binaries for
      linux/darwin × amd64/arm64.
- [ ] Run the binary on a sample repo end-to-end on each platform
      where possible (linux + darwin minimum).
- [ ] Nightly 100k-LOC benchmark (per O-7 resolution): fetch
      `kubernetes/kubernetes` at a pinned tag (recorded in the bench
      file), run `engine.Run` against it, assert wall-clock < 30s on
      the M-series 8-core reference machine. Network dependency is
      acceptable in nightly; not gated on PR runs.
- [ ] Re-run the cgroup `GOMAXPROCS` contract test from Phase 4 as a
      release-gate check (per O-8 resolution). Failure here blocks
      tagging.
- [ ] Skill-file synthesis stub: write `internal/agent/skill.go` with
      a `Synthesize(...) ([]byte, error)` signature stub. Real impl
      is RFC Phase 5 (out of scope for v0.1.0); the package exists
      so future PRs don't need to introduce it.
- [ ] Update the in-tree sample `.deslopinator.hcl` to match the
      finalized schema.
- [ ] Write the `v0.1.0` release notes via
      `git cliff -o CHANGELOG.md`. Hand-edit for narrative.
- [ ] Tag and push: `make release TAG=v0.1.0`.
- [ ] Verify GitHub Actions release workflow produces signed
      checksums and uploads the goreleaser archives.
- [ ] Mark RFC-0001 status: Phase 1 Complete in the RFC doc.
- [ ] Update CLAUDE.md "Current state" line to reflect v0.1.0
      shipped.
- [ ] Notify deslopinator-operator repo (issue or PR) that
      `pkg/api` is importable.

#### Success Criteria

- `pkg/api` API stability hash recorded. Subsequent PRs that change
  `pkg/api` exports fail CI until the hash is regenerated.
- `make ci` passes on a fresh clone with no warnings.
- `goreleaser release --snapshot --clean --skip=publish` succeeds.
- 100k-LOC Go repo benchmark: scan completes in < 30s on M-series
  8-core laptop (RFC Success Criteria #5).
- A binary built from the v0.1.0 tag runs on linux and darwin and
  produces a valid `StateV1` against a fixture repo.
- The deslopinator-operator repo can `go get
  github.com/donaldgifford/deslopinator/pkg/api@v0.1.0` and import
  the public types.
- All in-doc references to "Phase 1" (RFC) line up with what shipped.

---

## File Changes

Key files created across all phases. Items in *italics* are scaffolding
or test-only; bold are stable public surfaces.

| Path | Action | Phase | Description |
| --- | --- | --- | --- |
| **`pkg/api/`** | Create | 0 | Public domain types — stable contract. |
| **`pkg/logger/`** | Create | 0 | slog factory, public swap point. |
| `internal/config/` | Create | 1 | HCL2 decoder. |
| **`pkg/observability/`** | Create | 2 | OTEL Init + LLMExtension. |
| **`pkg/observability/langfuse/`** | Create | 2 | Reference LLMExtension impl. |
| `internal/observability/langfuse/` | Create | 2 | HTTP/Noop/Buffered clients. |
| **`pkg/llm/`** | Create | 3 | Backend interface + sentinels. |
| **`pkg/llm/{anthropic,openai,ollama}/`** | Create | 3 | Vendor sub-interfaces. |
| `internal/llm/{stub,anthropic}/` | Create | 3 | Stub + Anthropic backends. |
| `internal/engine/{parallel,detector,state,scoring,queue}/` | Create | 4 | Engine core. |
| `internal/engine/detector/empty_files/` | Create | 4 | *Smoke-test detector.* |
| **`pkg/provider/`** | Create | 5 | ReviewProvider interface. |
| `internal/review/{prompt,provider/llm}/` | Create | 5 | Prompt + composer. |
| `internal/attestation/` | Create | 5 | ed25519 signing. |
| **`pkg/client/`** | Create | 6 | Engine driver. |
| `cmd/deslopinator/cmd/{root,version,init,completion}.go` | Create | 6 | CLI scaffolding. |
| `cmd/deslopinator/cmd/{scan,next,resolve,status,findings,score}.go` | Create | 7 | Core commands. |
| `cmd/deslopinator/cmd/{state,review,config}.go` | Create | 7 | Subcommand groups. |
| `internal/test/{parity,e2e}/` | Create | 7 | *CLI parity + e2e tests.* |
| `internal/llm/{openaicompat,ollama}/` | Create | 8 | Remaining backends. |
| `internal/lang/golang/` | Create | 8 | SSA+DST Go plugin. |
| `internal/agent/skill.go` | Create | 9 | *Skill-file synth stub.* |
| `pkg/api/api_stability_test.go` | Create | 9 | API freeze test. |
| `internal/test/apicompat/` | Create | 9 | *Cross-version skeleton.* |

## Testing Plan

Test pyramid we commit to throughout:

- **Unit tests** for every exported function in `pkg/` (target ≥ 80%
  coverage per package). Table-driven tests preferred (Uber style).
- **Integration tests** under `internal/test/integration/` and
  `-tags=integration` for tests requiring real services (Anthropic API,
  OTEL collector, Langfuse, local Ollama). Run nightly, not on every
  PR.
- **Race tests** with `-race` for any concurrency primitive (worker
  pool, buffered Langfuse client). Run in standard CI.
- **Goroutine leak tests** via `go.uber.org/goleak` for any test that
  spawns goroutines. Required for `engine`, `pool`, `bufferedclient`.
- **Determinism property tests**: random ordering or seed → identical
  output. Required for engine + scoring.
- **API stability tests** (Phase 9): reflection over `pkg/api` →
  golden hash. Any unintentional change fails CI.
- **CLI/client parity tests** (Phase 7+): every CLI command paired
  against the equivalent `pkg/client` call. Asserts wire-shape parity.
- **Help-text golden tests** (Phase 6+): `--help` output frozen so
  agent skill-file synthesis (RFC Phase 5) has a stable contract.
- **End-to-end** (Phase 7+): build binary, run a real agent loop on
  a fixture repo, assert state file shape and exit codes.
- **Benchmarks** (Phase 4+): scan latency on a representative
  fixture; required to gate Phase 9 (RFC SC#5: <30s on 100k-LOC).

Common helpers:
- `t.TempDir()` for any filesystem operation. Never write to repo
  paths from tests.
- `httptest.Server` for backend HTTP fixtures.
- `bytes.Buffer` for command stdout/stderr capture.
- Stub backend (`internal/llm/stub`) for any test that would
  otherwise need a real LLM.

## Dependencies

External dependencies, in order of introduction:

| Phase | Dependency | Justification (per ADR-0002) |
| --- | --- | --- |
| 0 | (stdlib only) | — |
| 1 | `github.com/hashicorp/hcl/v2` | Justification 1 (no stdlib HCL); ADR-0006. |
| 1 | `github.com/hashicorp/hcl/v2/gohcl` | Same. |
| 2 | `go.opentelemetry.io/otel` (+sdk, OTLP exporters, propagation) | Justification 1 (no stdlib OTEL); ADR-0005. |
| 3 | (stdlib for HTTP/JSON; **no AI SDK imports**) | ADR-0004. |
| 4 | `golang.org/x/sync` | Justification 3 (don't reinvent errgroup); ADR-0002. |
| 5 | (stdlib `crypto/ed25519`) | — |
| 6 | `github.com/spf13/cobra` | Justification 2 (multi-level subcommands); ADR-0001. |
| 8 | `golang.org/x/tools/go/{ssa,packages,analysis}` | Justification 1 (Go AST/SSA); ADR-0002. |
| 8 | `github.com/dave/dst` | Justification 1 (DST manipulation); ADR-0002. |
| (test) | `github.com/stretchr/testify` (require + assert) | Test-only; ADR-0002. |
| (test) | `go.uber.org/goleak` | Test-only; goroutine-leak verification. |

License-check (`make license-check`) gates each phase. Forbidden imports
remain forbidden throughout: anthropic-sdk-go, openai SDKs, ollama Go
package, langfuse-go-sdk, langchaingo. CI enforces.

Internal prerequisites:
- Phase 0 must complete before any other phase starts.
- Phase 1 → Phase 2: observability config types come from `pkg/api.Config`.
- Phase 3 → Phase 5: `ReviewProvider` impl wraps a `Backend`.
- Phase 4 → Phase 5: subjective phase plugs into engine's phase 3.
- Phases 4+5 → Phase 6: `pkg/client` constructs an `Engine` and
  `ReviewProvider`.
- Phase 6 → Phase 7: every command consumes `pkg/client`.
- Phases 7+8 → Phase 9: parity tests and golden files presume the
  command set and the Go detectors are in.

## Open Questions

### O-1. Legacy `deslop` codebase port — **RESOLVED (greenfield)**

**Phase affected:** 8.
**Context:** RFC-0001 and DESIGN-0001 originally referenced porting
SSA-based detectors from a legacy `dgifford/deslop` repo.
**Resolution:** Assume the legacy code is unrecoverable. Phase 8
writes the three Go detectors (`unused_functions`, `dead_branches`,
`near_duplicates`) fresh against `golang.org/x/tools/go/{ssa,
packages,analysis}` + `github.com/dave/dst`. RFC-0001 and
DESIGN-0001 §"Migration / Rollout Plan" still reference a port —
those references are now stale and should be treated as historical
context, not blocking work. Phase 8 task list reflects the
greenfield approach.

### O-2. Skill-file synthesis: stub in Phase 9 or full RFC Phase 5 deferral? — **RESOLVED**

**Phase affected:** 9.
**Resolution:** Keep the stub package
(`internal/agent/skill.go` with a `Synthesize(...) ([]byte, error)`
signature returning `ErrCapabilityNotImplemented`). Reason:
import-path stability — future PRs that wire real synthesis don't
have to introduce the package, and the agent skill-file contract has
a designated home from v0.1.0. Stub is < 20 lines, no maintenance
cost. Confirmed in Phase 9 task list.

### O-3. Phase 4 detector tier split: when does `near_duplicates` land? — **RESOLVED**

**Phase affected:** 4.
**Resolution:** Phase 4 ships *two* smoke detectors so both detector
tiers are exercised before Phase 8:

- `empty_files` (`TierPureParallel`) — per-unit fan-out path.
- `exact_dupes` (`TierParallelReduce`) — parallel scoring + serial
  reduce path. Hashes file bytes, joins identical-hash unit groups
  into a cluster finding.

Real `near_duplicates` (SSA-based) lands in Phase 8 against the same
`Reducer` interface. Belt-and-suspenders win for small cost.
Reflected in Phase 4 task list.

### O-4. State file location relative to repo root vs cwd — **RESOLVED**

**Phase affected:** 4.
**Resolution:** Default state path is
`<repo-root>/.deslopinator/state.json`, where repo-root comes from
Phase 1's `.git/` auto-detection. If auto-detect fails (no `.git/`
ancestor):

- **CLI:** error out with `ErrConfigError`, exit code 3. Message
  asks the user to pass `--path` or `--state-file` explicitly.
- **`pkg/client` Go API:** require explicit `WithStatePath(...)`
  at construction; no implicit fallback. The operator (which runs
  in pods with no `.git/`) reads the path from its CR spec and
  passes it via `WithStatePath`.

No silent fallback to cwd or home dir — clearest behavior, matches
the operator deployment topology. Reflected in Phase 4 task list.

### O-5. Anthropic prompt-caching capability — public sub-interface or hidden? — **RESOLVED**

**Phase affected:** 3.
**Resolution:** Sub-interface present in v0.1.0; method
`AnthropicBackend.PromptCacheControl(...)` is **declared but
reserved** — concrete impl returns `ErrCapabilityNotImplemented`
(new sentinel, added to the Phase 3 errors task). Full caching
implementation lands in v0.2.0 once review-phase observability tells
us expected savings. Keeping the signature stable from day one
means v0.2.0 is purely additive (no breaking interface change).
Reflected in Phase 3 task list.

### O-6. Per-detector configuration — does `.deslopinator.hcl` need a `detector "name" { ... }` block in v0.1.0? — **RESOLVED**

**Phase affected:** 1.
**Resolution:** No per-detector blocks in v0.1.0. The schema stays
at `detectors = []` (on/off list). The first per-detector tuning
block lands when a real detector demands it — likely Phase 8's
`near_duplicates` similarity threshold, but that decision lives with
that PR. HCL handles labeled blocks additively, so this is not a
breaking change either way. No task changes needed.

### O-7. Performance benchmark fixture: vendored or fetched? — **RESOLVED**

**Phase affected:** 4 and 9.
**Resolution:** Two-tier:

- **Phase 4 per-PR benchmark:** vendor a small ~10k-LOC Go fixture
  under `testdata/fixtures/small_go_repo/`, pinned to a specific
  upstream tag/SHA documented in the fixture README. Runs in
  standard CI; PR-friendly.
- **Phase 9 release-gate benchmark:** fetch
  `kubernetes/kubernetes` at a pinned tag at test time, run the
  100k-LOC scan, assert < 30s on M-series 8-core. Network dependency
  acceptable for nightly; not gated on PRs.

Reflected in Phase 4 and Phase 9 task lists.

### O-8. Cgroup GOMAXPROCS verification (DESIGN-0001 Q2) — Phase 4 or Phase 9? — **RESOLVED**

**Phase affected:** 4 and 9.
**Resolution:** Both. Phase 4 lands the contract test under
`internal/engine/parallel/cgroup_test.go` gated by
`-tags=integration`: Kind cluster + pod with CPU limit + exec the
test binary + assert `runtime.GOMAXPROCS(0)` returns the limited
value. Phase 9 re-runs the same test as a release-gate check;
failure blocks tagging. Catches the issue early *and* doesn't let
it regress before release. Reflected in both phase task lists.

## References

- RFC-0001 — overall direction and Phase 1 scope.
- ADR-0001 — Cobra; constructor pattern.
- ADR-0002 — stdlib-first; approved-deps list driving Phase
  dependency table.
- ADR-0003 — public/private boundary; Phases 0, 3, 5, 6 implement
  this.
- ADR-0004 — AI provider abstraction; Phases 3 and 8.
- ADR-0005 — observability stack; Phase 2.
- ADR-0006 — HCL2 config; Phase 1.
- DESIGN-0001 — engine and worker pool; Phase 4.
- DESIGN-0002 — CLI surface; Phases 6 and 7.
- DESIGN-0003 — public API; Phases 0, 3, 5, 6, and 9.
- `github.com/donaldgifford/server-price-tracker/pkg/{extract,judge,
  logger,observability}` — pattern reference for the LLM transport,
  review provider, logger, and observability packages.
