---
id: DESIGN-0001
title: "Deslopinator engine and worker pool"
status: Draft
author: Donald Gifford
created: 2026-05-07
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0001: Deslopinator engine and worker pool

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
  - [Component diagram](#component-diagram)
  - [Engine lifecycle](#engine-lifecycle)
  - [Detector contract](#detector-contract)
  - [Worker pool and fan-out/fan-in](#worker-pool-and-fan-outfan-in)
  - [Phase coordination](#phase-coordination)
  - [Observability hooks](#observability-hooks)
  - [Cancellation, timeouts, errors](#cancellation-timeouts-errors)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Overview

The engine is the language-agnostic core that loads sources, fans out
detector work across goroutines, reduces findings, computes scores, and
persists state. This design fixes the engine's package boundaries, the
detector contract, and the concurrency primitives so subsequent language
plugins (RFC Phase 4) and the Kubernetes operator (ADR-0003) plug in
without re-litigating the shape.

## Goals and Non-Goals

### Goals

- A single `Engine` type that owns scan execution end-to-end.
- A pluggable `Detector` interface that lets us add Go-specific detectors
  (Phase 1) and tree-sitter-driven detectors (Phase 4) without reshaping
  the engine.
- Native Go concurrency: parallel detector execution bounded by a worker
  pool, with deterministic output regardless of goroutine scheduling.
- Bounded memory on large repos — no "load every file's AST simultaneously"
  surprises.
- Hit RFC-0001's Success Criteria #5: 100k-LOC Go repo scan in <30s on an
  M-series 8-core laptop.

### Non-Goals

- Detector implementations themselves (covered per-language in Phase 1+).
- Scoring algorithm details (covered in DESIGN-0001's sibling work,
  Phase 2 — see ADR sequence on scoring weights).
- Subjective-review provider implementations (covered by Phase 3 ADR /
  DESIGN follow-up).
- Distributed scan-sharding across hosts. Within-process parallelism only;
  RFC-0001 explicitly defers cross-host sharding to the operator layer.

## Background

RFC-0001 frames within-run parallelism as the headline differentiator vs
desloppify's single-process Python scan. The detection phase is
embarrassingly parallel for most detector classes, with a handful of
serial-reduce steps (union-find clustering for near-duplicate detection,
score aggregation). The Go ecosystem has good primitives for this —
`golang.org/x/sync/errgroup` for cancellation-aware fan-out,
`runtime.GOMAXPROCS` for sizing, channels for fan-in — and ADR-0002
explicitly approves these.

The kubebuilder operator parallel pattern (RFC §"Concurrency model"
reference to RFC-0001 / DESIGN-0001 in the renovate-operator repo)
sharded work across pods via Indexed Jobs. Same fan-out/fan-in shape,
different layer: this design is goroutines-across-cores, the operator's
prior art is pods-across-nodes.

## Detailed Design

### Component diagram

```
┌──────────────────────────────────────────────────────────────────┐
│ pkg/client.Client                                                 │
│   - Scan(ctx, ScanRequest) (*ScanResult, error)                   │
│   - Next(ctx) (*WorkItem, error)                                  │
│   - Resolve(ctx, ResolveRequest) error                            │
└──────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│ internal/engine.Engine                                            │
│   - Run(ctx, ScanRequest) (*ScanResult, error)                    │
│   - holds: Sources, []Detector, *Pool, *Reducer, *Scorer, *Store  │
└──────────────────────────────────────────────────────────────────┘
       │           │             │              │            │
       ▼           ▼             ▼              ▼            ▼
┌─────────┐ ┌─────────────┐ ┌──────────┐ ┌────────────┐ ┌─────────┐
│ Sources │ │  Detectors  │ │   Pool   │ │  Reducer   │ │  Store  │
│ loader  │ │ (interface) │ │ workers  │ │ aggregate  │ │  state  │
│ AST/SSA │ │ Tier 1..N   │ │ errgroup │ │ findings   │ │  files  │
└─────────┘ └─────────────┘ └──────────┘ └────────────┘ └─────────┘
                                                              │
                                                              ▼
                                                    ┌───────────────┐
                                                    │  Scorer       │
                                                    │  Strict +     │
                                                    │  Lenient +    │
                                                    │  history      │
                                                    └───────────────┘
```

### Engine lifecycle

`Engine.Run(ctx, ScanRequest)` executes phases in fixed order. Phases run
serially; *within* a phase, work fans out to the pool.

```
Phase 0  Sources      Resolve --path, build []AnalysisUnit
Phase 1  Detect       Fan-out detectors over units → []Finding
Phase 2  Reduce       Cluster/dedupe findings (per-detector reduce)
Phase 3  Subjective   Optional: ReviewProvider over reducible findings
Phase 4  Score        Compute strict + lenient scores
Phase 5  Persist      StateV1 → state file (atomic write)
Phase 6  Queue        Build phase-gated work queue from findings
```

Each phase has a single error return point. On error, the engine cancels
ctx, drains in-flight goroutines, and returns the error wrapped with the
phase name (e.g., `engine: detect phase: <err>`).

### Detector contract

```go
// Tier indicates how detectors interact with concurrency.
type Tier int

const (
    TierPureParallel    Tier = iota // independent per-unit, no shared state
    TierParallelReduce              // parallel score, serial reduce step
    TierStrictSerial                // must observe units in deterministic order
)

type Detector interface {
    Name() string                                  // stable id, used in findings
    Tier() Tier
    Languages() []Language                          // empty == all
    Run(ctx context.Context, unit AnalysisUnit) ([]Finding, error)
}

// Reducer is implemented by TierParallelReduce detectors.
type Reducer interface {
    Detector
    Reduce(ctx context.Context, findings []Finding) ([]Finding, error)
}
```

Notes:

- `Run` operates on a single unit and returns its findings. The pool calls
  it concurrently across units.
- `TierStrictSerial` detectors are rare (e.g., naming-convention learning
  that needs deterministic visit order). The pool degrades to a single
  worker for them.
- Detectors are stateless across `Run` calls. Per-scan caches live on
  the unit or on a detector-private struct passed via context value with
  a typed key (revive `context-keys-type` rule).
- Findings include `DetectorName` so the reducer can route them.

### Worker pool and fan-out/fan-in

```go
// internal/engine/parallel/pool.go

type Pool struct {
    maxWorkers int  // min(GOMAXPROCS, cfg.MaxWorkers, len(units))
    bufferSize int  // ring buffer depth — bounds memory pressure
}

func (p *Pool) RunDetector(
    ctx context.Context,
    det Detector,
    units []AnalysisUnit,
) ([]Finding, error) {
    // 1. Channel of units, sized to bufferSize
    // 2. errgroup with maxWorkers consumers
    // 3. Each worker calls det.Run(ctx, unit), sends findings to out chan
    // 4. Main goroutine drains out into []Finding (preserving deterministic
    //    order via per-unit sequence number)
    // 5. errgroup.Wait → cancel-aware error propagation
}
```

Determinism rule: the slice returned to callers is sorted by
`(unit.Path, finding.Line, finding.DetectorName)`. The order findings are
*produced* in is non-deterministic; the order they are *returned* in is
not. This means goroutine scheduling cannot affect the score, the queue,
or the state file — RFC-0001 risk row "within-run parallelism introduces
detector ordering bugs" mitigated.

Worker sizing default: `min(runtime.GOMAXPROCS(0), cfg.MaxWorkers, len(units))`
with `cfg.MaxWorkers` defaulting to GOMAXPROCS. CLI flag `--workers` lets
operators dial it down for shared CI runners.

### Phase coordination

Phases share an internal context. Cancellation in any phase cancels all
remaining phases. The reducer phase blocks on the detect phase by virtue
of being sequential; we do *not* try to overlap detect/reduce, because the
union-find structure for clustering needs the full finding set anyway and
the latency win would be marginal on the scan budgets we care about.

The subjective review phase is the one we pipeline. While the scorer
processes mechanical findings, the review phase fans out
`ReviewProvider.Review` calls over reducible findings. Token-bucket-style
rate limiting (`golang.org/x/time/rate`) on the provider — defer to
DESIGN follow-up in Phase 3, not in this document.

### Observability hooks

Each phase wraps work in OTEL spans (ADR-0005):

- `engine.scan` wraps the entire `Engine.Run` call.
- `engine.phase.<name>` wraps each phase (`sources`, `detect`, `reduce`,
  `subjective`, `score`, `persist`, `queue`).
- `engine.detector.<name>` wraps each `Detector.Run` invocation, with
  `detector.tier`, `detector.unit_count`, and `detector.language` as
  span attributes.

Metrics (counters / histograms) are emitted via the global meter from
`pkg/observability`. Detector authors do not call `tracer.Start` or
`meter.Counter` directly — the engine wraps them; detector code stays
focused on analysis logic.

When observability is disabled (config or `--no-otel`), the global
providers are no-op, so the wrapping calls compile to ~zero work
(see ADR-0005). Detector code is unchanged either way.

### Cancellation, timeouts, errors

- Engine accepts `context.Context`. Per-detector timeouts are configured
  in `ScanOptions.PerDetectorTimeout` (default 60s). Exceeding it cancels
  the detector and produces a `Finding` of `Severity: Warning,
  DetectorName: "engine.detector_timeout"`.
- Per-unit panics are recovered in the worker, converted to
  `Finding{Severity: Error, ...}`, and do not abort the scan. The scan
  is best-effort — agent integration depends on `scan` always producing a
  state file.
- Sentinel errors in `pkg/api/errors.go`:
  - `ErrStateSchemaMismatch` — state file schema newer than binary.
  - `ErrPhaseGateUnsatisfied` — `next` called before phases complete.
  - `ErrEmptyResolutionNote` — `resolve` called without `--note`.

## API / Interface Changes

This design introduces:

- `internal/engine.Engine` — private struct, constructed via `NewEngine(opts ...Option)`.
- `internal/engine/detector.Detector` — interface (described above).
  Re-exported via `pkg/api` only for *types* it references
  (`Finding`, `AnalysisUnit`, `Tier`); the interface itself stays
  internal because we don't yet support out-of-tree detectors.
- `pkg/client.Client.Scan` — public surface that constructs an `Engine`
  and calls `Run`. The operator imports this.
- CLI flag additions to `deslopinator scan` (also see DESIGN-0002):
  `--workers N`, `--per-detector-timeout DUR`, `--no-subjective`.

No changes to `StateV1` — that schema is fixed by RFC-0001 §"State schema
with explicit migrations" and ADR-0003 §"Stability contract".

## Data Model

```go
// pkg/api/scan.go (public)

type AnalysisUnit struct {
    Path     string   // repo-relative
    Language Language
    Bytes    []byte   // file contents at scan time; reused across detectors
    AST      any      // language-specific; opaque to engine
}

type ScanRequest struct {
    Path        string
    Languages   []Language    // empty == auto-detect
    Detectors   []string      // empty == all enabled
    Profile     string        // named profile from .deslopinator.yaml
    Options     ScanOptions
}

type ScanOptions struct {
    MaxWorkers          int
    PerDetectorTimeout  time.Duration
    DisableSubjective   bool
    StatePath           string  // default: .deslopinator/state.json
}

type ScanResult struct {
    StatePath string
    Score     ScoreSnapshot
    Counts    FindingCounts
    Duration  time.Duration
}
```

`AnalysisUnit.AST` is `any` because each language plugin owns its AST
type (`*ast.File` for Go, `*sitter.Node` for tree-sitter languages).
Detectors type-assert based on `Language`.

## Testing Strategy

- **Detector unit tests.** Each detector has a table-driven test under
  `internal/engine/detector/<name>/<name>_test.go`. Inputs are
  hand-crafted `AnalysisUnit` fixtures.
- **Worker pool race test.** `internal/engine/parallel/pool_test.go` runs
  with `-race` and a deterministic seed. Asserts that the same input
  produces byte-identical output across N runs (determinism property).
- **Engine integration test.** `internal/engine/engine_test.go` runs the
  full pipeline against a minimal Go repo fixture under `testdata/`,
  asserts the produced `StateV1` matches a golden file modulo timestamps.
- **Determinism property test.** Quickcheck-style: generate random unit
  orderings, assert the engine produces the same `ScoreSnapshot`. This
  is the test row that catches the RFC-0001 risk "ordering bugs".
- **Benchmark.** `BenchmarkEngine_KubernetesRepo` runs against a vendored
  100k-LOC fixture (or a checked-out commit of `kubernetes/kubernetes`),
  asserts wall-clock <30s on the developer-laptop reference machine.
  Runs nightly, not on every PR, because it's slow.
- **Cancellation test.** `engine_cancel_test.go` issues `Scan` with a
  context that cancels mid-detect; asserts no goroutine leaks
  (`goleak.VerifyNone(t)`).

## Migration / Rollout Plan

This is greenfield code. There is no legacy deslopinator engine to
migrate from in this repo. Rollout sequence within Phase 1:

1. Land `internal/engine/parallel/pool.go` + tests. No behavior visible.
2. Land `internal/engine/detector/` interface + a single trivial detector
   (e.g., empty-files detector). Visible via `deslopinator scan` with a
   feature flag.
3. Port the existing `dgifford/deslop` SSA-based unused-function detector
   into `internal/lang/golang/`.
4. Wire the scorer (Phase 2 follow-up).
5. Cut Phase 1 release tag.

Existing `deslop` users do not exist; no deprecation needed.

## Open Questions

1. **Should `AnalysisUnit.Bytes` be `[]byte` or `func() ([]byte, error)`?**
   Lazy loading reduces peak memory on large repos but complicates
   detector caching. Default to `[]byte` and revisit if profiling shows
   pressure on real repos. **Status: open — track and revisit after
   first benchmark on a real 100k-LOC repo.**
2. **GOMAXPROCS sizing under containerd / Kubernetes cgroups.** The
   operator (ADR-0003) will run inside pods; default `runtime.GOMAXPROCS(0)`
   reads cgroup limits in Go 1.25+. **Status: needs verification.**
   Action: write a contract test that runs the engine inside a Kind
   cluster (Kubernetes 1.30+) with a CPU limit set on the pod, asserts
   `runtime.GOMAXPROCS(0)` returns the limited value, and validates
   the 30s benchmark holds. Land the test before claiming the
   success-criteria benchmark transfers to operator deployments.
3. **Error model for `Detector.Run` returning *both* findings and an
   error.** **Status: resolved.** Best-effort scan: keep the partial
   findings, propagate the error wrapped with the detector name.
   Engine sums all per-detector errors with `errors.Join` for the
   phase return. Documented in §"Cancellation, timeouts, errors".
4. **Where does `--profile` live?** **Status: resolved by ADR-0006.**
   Profile selection comes from `--profile` flag → `DESLOPINATOR_PROFILE`
   env var → top-level `default_profile` in `.deslopinator.hcl`. See
   ADR-0006 §"Discovery and merge order" for the full precedence chain.

## References

- RFC-0001 §"Concurrency model" and §"Implementation Phases" — Phase 1.
- ADR-0001 — CLI framework that calls into this engine.
- ADR-0002 — `golang.org/x/sync/errgroup` approval.
- ADR-0003 — public surface that exposes engine types via `pkg/api`.
- ADR-0004 — AI provider abstraction; subjective phase calls
  `pkg/llm.Backend.Generate` via `pkg/provider.ReviewProvider`.
- ADR-0005 — observability; the engine emits the `engine.*` spans and
  metrics described in §"Observability hooks".
- DESIGN-0002 — CLI surface that consumes `Engine.Run` via `pkg/client`.
- DESIGN-0003 — operator-facing API that wraps the engine.
- [errgroup docs](https://pkg.go.dev/golang.org/x/sync/errgroup).
- [go.uber.org/goleak](https://pkg.go.dev/go.uber.org/goleak) for the
  cancellation tests above.
