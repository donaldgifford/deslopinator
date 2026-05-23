---
id: ADR-0002
title: "Standard library first dependency policy"
status: Proposed
author: Donald Gifford
created: 2026-05-07
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0002. Standard library first dependency policy

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
  - [When third-party is allowed](#when-third-party-is-allowed)
  - [When third-party is not allowed](#when-third-party-is-not-allowed)
  - [Approved third-party dependencies (initial)](#approved-third-party-dependencies-initial)
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

RFC-0001 ships deslopinator as a single static binary distributed via
goreleaser to users who run it in CI and on developer laptops. Two properties
follow:

1. **Surface area for vulnerability scanning matters.** Every transitive
   dependency is something `govulncheck` and Trivy can flag, and every flag
   blocks CI. The current `.github/workflows/ci.yml` exits non-zero on any
   HIGH/CRITICAL Trivy finding.
2. **License risk is real.** The `license-check` allow-list (Apache-2.0, MIT,
   BSD-2/3, ISC, MPL-2.0) is enforced in CI; a pulled-in transitive dep with a
   non-allowed license breaks the build.

The Go standard library covers most of what we need: `net/http`, `encoding/json`,
`log/slog`, `context`, `errors`, `os/exec`, `crypto/*`, `archive/*`,
`go/ast`/`go/parser`/`go/types`/`go/ssa` (the SSA work the RFC builds on).
Reaching for a third-party library when stdlib suffices adds maintenance
surface, audit surface, and binary size with no user-visible benefit.

That said, **dogmatic stdlib-only is a known anti-pattern** — it produces
hand-rolled CLI parsers, ad-hoc retry/backoff logic, custom YAML scanners, and
similar reinventions that are buggier and harder to maintain than the
well-trodden community alternative. Cobra (ADR-0001) is one example; tree-sitter
bindings for non-Go languages (RFC Phase 4) is another.

We need a written policy so contributors and reviewers can resolve
"do we add this dependency?" disagreements without re-litigating the question
each time.

## Decision

Default to the Go standard library. Add a third-party dependency only when at
least one of the following applies, and document which one in the PR
description:

1. **Stdlib does not provide the capability at all.** Examples: SSA construction
   beyond what `golang.org/x/tools/go/ssa` already provides, tree-sitter
   parsing for non-Go languages, multi-arch image construction.
2. **Stdlib provides primitives but no usable composition.** Example: Cobra
   over `flag` for multi-level subcommands and persistent flags (ADR-0001).
3. **Reimplementing in-tree would meaningfully duplicate a battle-tested,
   actively maintained library** to the point that we'd own a non-trivial
   maintenance and security-audit burden for no differentiation. Example:
   `golang.org/x/sync/errgroup` for the worker-pool fan-out (DESIGN-0001) —
   we are not in the goroutine-orchestration-primitives business.
4. **The library is already in our dependency closure transitively** and
   pulling it in directly costs nothing. Promote rather than re-wrap.

When *none* of the above applies, write the stdlib version. Five lines of
`net/http` is fine. Three lines of `encoding/json` is fine. A 50-line HCL
parser is not — use `github.com/hashicorp/hcl/v2`.

### When third-party is allowed

- **CLI framework:** Cobra (ADR-0001). Justification 2 above.
- **Worker-pool primitives:** `golang.org/x/sync/errgroup` and friends.
  Justification 3.
- **Structured logging:** `log/slog` (stdlib). Justification 1 — there is no
  case to add zap/zerolog; slog covers our needs. (`pkg/logger` is a thin
  factory over slog — see ADR-0005.)
- **HCL2 config files:** `github.com/hashicorp/hcl/v2` and
  `github.com/hashicorp/hcl/v2/gohcl` (ADR-0006). Justification 1.
- **Observability:** `go.opentelemetry.io/otel` SDK + OTLP/gRPC exporters
  (ADR-0005). Justification 1 — there is no stdlib OTEL.
- **Tree-sitter bindings (Phase 4):** `github.com/smacker/go-tree-sitter` or
  successor. Justification 1.
- **SSA / AST manipulation:** `golang.org/x/tools/go/ssa`,
  `github.com/dave/dst` (RFC §"Proposed Solution"). Justification 1.
- **AI vendor SDKs:** **never** (ADR-0004). All LLM backends use stdlib
  `net/http` + `encoding/json`. Same rule for the Langfuse client
  (ADR-0005).

### When third-party is not allowed

- **HTTP server / client.** Use `net/http`. No `gin`, `echo`, `chi`, `fiber`,
  `resty`. The RFC does not need an HTTP framework.
- **JSON encode/decode.** Use `encoding/json`. No `goccy/go-json`,
  `bytedance/sonic`. We are not benchmark-bound on JSON.
- **String manipulation, slices, maps.** Use `strings`, `slices`, `maps` (stdlib
  generics shipped in Go 1.21). No `samber/lo`, no `pkg/errors`.
- **Errors.** Use `errors.Is`, `errors.As`, `fmt.Errorf` with `%w`. No
  `pkg/errors` (deprecated, superseded by stdlib).
- **Context-aware sleep / timers.** Use `time.NewTimer` + `ctx.Done()`. No
  `cenkalti/backoff` for simple retry — write the loop. Adopt `backoff` only
  if we need exponential backoff with jitter across multiple call sites.
- **UUIDs.** Use `crypto/rand` to generate ids; only adopt `google/uuid` if
  we hit a need for RFC 4122 v7 monotonic ids.
- **Testing.** Use `testing` (stdlib). Use `testify/require` and `testify/assert`
  *only* in test files for ergonomic assertions — already in our linter
  exception list. No `ginkgo`/`gomega` — the kubebuilder operator may use
  them in its own repo, this one will not.

### Approved third-party dependencies (initial)

These are the only direct (non-test) dependencies allowed without a follow-up
ADR at the time of this decision:

- `github.com/spf13/cobra` (ADR-0001)
- `github.com/spf13/viper` — only if/when ADR-0001's "if needed" trigger fires
- `github.com/hashicorp/hcl/v2` — config parsing (ADR-0006)
- `golang.org/x/sync` — `errgroup`, `semaphore`
- `golang.org/x/tools` — `go/ssa`, `go/packages`, `go/analysis`
- `github.com/dave/dst` — DST manipulation (Phase 1)
- `go.opentelemetry.io/otel` — SDK + API (ADR-0005)
- `go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc` and
  `.../otlpmetric/otlpmetricgrpc` — OTLP/gRPC exporters (ADR-0005)

Forbidden (codified, not just discouraged):

- AI vendor SDKs of any kind (anthropic, openai, ollama, etc.) — see ADR-0004.
- Langfuse Go SDK — we ship our own HTTP client (ADR-0005).
- LangChain Go (`tmc/langchaingo`) — heavy abstraction with no payoff for us.

Adding anything outside the approved list is a PR-time decision the
reviewer must approve, with the justification number noted. Once a dep is
approved twice, add it to this list (amend this ADR).

## Consequences

### Positive

- Smaller binary, smaller dependency closure, fewer CVE notifications.
- License-check stays clean by default — every new license-allow-list entry
  is a deliberate decision rather than a transitive surprise.
- Contributors and Claude Code agents have a written rule to consult before
  reaching for a familiar library.
- The "five lines of stdlib vs. one line of dep" call gets resolved by
  pointing at a justification number, not by taste.

### Negative

- Some PRs will be slower because contributors will write the stdlib version
  rather than `go get` something familiar.
- The approved list will need maintenance — too restrictive a list creates
  friction and rule-bypassing; too permissive defeats the policy. Quarterly
  review during ADR housekeeping.

### Neutral

- This policy applies to direct dependencies only. We do not control
  transitive deps; `license-check` and `govulncheck` are the enforcement
  surface for those.
- Test-only dependencies (`testify`, mock libraries) are out of scope for
  this ADR's "approved list" — covered by the linter config.

## Alternatives Considered

**No policy; case-by-case in PR review.** Rejected. We've seen this play
out in adjacent repos: deps accumulate, the `go.sum` grows, the question
"do we really need X?" gets relitigated every six months, and Trivy/govulncheck
findings spike whenever a transitive package goes stale.

**Stdlib-only, no exceptions.** Rejected. Forces hand-rolling things like
Cobra and tree-sitter that have no business being reinvented. Produces
worse code in the name of dependency purity.

**Vendor everything.** Rejected. Modern Go module proxy + checksum DB plus
goreleaser-built static binaries already give us the supply-chain
guarantees vendoring used to provide. Vendoring just bloats the repo.

## References

- RFC-0001 §"Proposed Solution" — single-binary distribution constraint.
- ADR-0001 — Cobra adoption (the canonical "stdlib not enough" example).
- ADR-0003 — public API package layout, which inherits this policy for
  any types exposed to operator consumers.
- `.github/workflows/license-check.yml`, `.github/workflows/ci.yml` —
  CI enforcement surfaces for this policy.
- [Go Proverbs](https://go-proverbs.github.io/) — "A little copying is better
  than a little dependency."
