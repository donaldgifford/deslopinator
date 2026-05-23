# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project context

**deslopinator** is a Go-native, agent-first codebase health tool with an anti-gaming scoring model. The full direction — architecture, scoring philosophy, phasing, and prior-art comparison against `peteromallet/desloppify` — lives in `docs/rfc/0001-deslopinator-go-native-codebase-health-with-anti-gaming-scoring.md`. The supporting ADRs and DESIGN docs flesh out concrete decisions:

- **ADR-0001** — Cobra CLI framework with cobra-cli scaffolding (constructor pattern, no package-level vars).
- **ADR-0002** — Standard library first dependency policy (approved-deps list, AI vendor SDKs explicitly forbidden).
- **ADR-0003** — Public API package layout: `pkg/api`, `pkg/llm`, `pkg/provider`, `pkg/logger`, `pkg/observability`, `pkg/client` are stable surfaces the **deslopinator-operator** (separate kubebuilder repo) imports; everything under `internal/` is unimportable from outside this module.
- **ADR-0004** — AI provider abstraction with no vendor SDK imports. Two-layer interface (`pkg/llm.Backend` for transport, `pkg/provider.ReviewProvider` for semantics) plus vendor sub-interfaces (`AnthropicBackend`, `OpenAIBackend`, `OllamaBackend`) for vendor-specific features. **No fallback** — failed backends return typed sentinel errors (`ErrBackendUnavailable`, `ErrBackendRateLimited`, etc.); fallback is the user's orchestration concern. Streaming reserved on `GenerateRequest`; vendor LLM streaming is still SSE (Anthropic/OpenAI) or NDJSON (Ollama). Pattern reference: `server-price-tracker/pkg/{extract,judge}`.
- **ADR-0005** — OTEL is the only observability backbone; default deployment is plain OTEL. Langfuse / Phoenix / LangSmith layer on via a single `LLMExtension` interface — same shape as ADR-0004's vendor sub-interfaces. Disable short-circuits to no-op providers. `pkg/logger` is public and interface-driven via `slog.Handler`; swap to zap/zerolog via `logger.NewWithHandler` only if profiling demands. Pattern reference: `server-price-tracker/pkg/{logger,observability}`.
- **ADR-0006** — HCL2 for all deslopinator-owned config files (`.deslopinator.hcl`). YAML is reserved for tool-imposed formats (`.golangci.yml`, GitHub Actions, kubebuilder CRDs in the operator repo).
- **DESIGN-0001** — Engine + worker pool: detector tiers, fan-out/fan-in over `errgroup`, deterministic output regardless of scheduling, OTEL spans wrap each phase.
- **DESIGN-0002** — CLI command surface: `scan`, `next`, `resolve`, `status`, `findings`, `score`, `state`, `review`, `init`. HCL2 `.deslopinator.hcl` config; persistent flags include `--no-otel`/`--no-llm-extension`.
- **DESIGN-0003** — Concrete `pkg/api` / `pkg/llm` / `pkg/provider` / `pkg/logger` / `pkg/observability` / `pkg/client` shapes the operator builds CRDs against; `StateV1` is frozen.
- **IMPL-0001** — Active phasing plan for v0.1.0: 10 phases (0–9), each with checkbox tasks and success criteria. Open questions resolved. **Start here when picking up implementation work** — `docs/impl/0001-initial-deslopinator-implementation-phasing.md`.

**Read the RFC and these docs before making non-trivial design decisions.** They define the boundary rules (`lang/` may import `engine/`, never the reverse; `pkg/` defines the contract, `internal/` implements it), the in-tree-only `ReviewProvider` boundary, the versioned `StateV1` schema, and the agent execution loop (`scan` → `next` → `resolve`).

Current state: pre-Phase-0 scaffold. `cmd/deslopinator/main.go` is a stub with no `main()`. None of the `internal/` or `pkg/` trees from the DESIGN docs exist yet. **Next implementation step is IMPL-0001 Phase 0** (repo foundation + public types under `pkg/api` and `pkg/logger`).

## Common commands

Tooling is pinned in `mise.toml` (Go 1.26.2, golangci-lint 2.11.4, goreleaser, helm, kubebuilder, docz, etc.). Run `mise install` once to materialize it.

```bash
make build              # build ./cmd/deslopinator into build/bin/deslopinator
make test               # go test -v -race ./...
make test-pkg PKG=./internal/engine/scoring   # single package
make test-coverage      # writes coverage.out (CI uploads to Codecov)
make test-report        # coverage.out + opens HTML report
make lint               # golangci-lint run ./...
make lint-fix           # golangci-lint --fix
make fmt                # gofmt -s -w + goimports (-local github.com/donaldgifford)
make check              # lint + test (pre-commit gate)
make ci                 # lint + test + build + license-check (full CI gate)
make license-check      # go-licenses against Apache-2.0/MIT/BSD-2/BSD-3/ISC/MPL-2.0
make release-local      # goreleaser snapshot (no publish, no sign)
```

The Makefile's `log-%` pattern echoes each target's `##` help comment when invoked via `$(MAKE) log-$@` — keep the `##` annotations on new targets so `make help` and the log lines stay accurate.

## Conventions worth knowing

- **Interface-driven design for swap points.** When a vendor or backend can vary (LLM providers, observability platforms, logger handlers, rationale codes vs text), expose a common interface in `pkg/` plus an optional vendor sub-interface alongside — `Backend` + `AnthropicBackend` (ADR-0004), `LLMExtension` + `langfuse.Operations` (ADR-0005). Drive selection via HCL config blocks, not by hard-coding.
- **NEVER import AI vendor SDKs.** Forbidden: `anthropic-sdk-go`, `openai-go` (or `sashabaranov/go-openai`), `ollama/ollama`, `langfuse-go-sdk`, `tmc/langchaingo`. Backends speak HTTP directly via `net/http` + `encoding/json`. Same rule for Langfuse — we ship our own HTTP client. See ADR-0002 approved-deps list and ADR-0004.
- **Pattern reference repo:** `github.com/donaldgifford/server-price-tracker` — `pkg/{extract,judge,logger,observability}` are the canonical references for our `pkg/{llm,provider,logger,observability}`. Direct copy-paste of structural patterns is acceptable; we do NOT import the package.
- **Module path:** `github.com/donaldgifford/deslopinator`. `goimports` is configured with `-local github.com/donaldgifford` so local imports group separately; `.golangci.yml`'s `goimports.local-prefixes` matches.
- **Linter baseline:** `.golangci.yml` is based on the Uber Go Style Guide. Notable strict settings: `gocyclo` min-complexity 15, `funlen` 100 lines / 50 statements, `nestif` 4, `nakedret` max 5 lines, `goconst` triggers at 3 occurrences, `errcheck` checks blanks and type assertions. `nolintlint` requires both an explanation and a specific linter — never write a bare `//nolint`.
- **License:** Apache-2.0 (RFC §"OSI-approved license" — this is a deliberate differentiation from desloppify's OSNL). The `license-check` allow-list is the source of truth for acceptable transitive deps.
- **Branch prefixes** (drives PR auto-labeling via `.github/labeler.yml`): `feature/`, `fix/`, `chore/`, `docs/`, `security/`. The `git-workflow:branch` skill enforces this.
- **Documentation lifecycle:** managed by `docz` (`.docz.yaml`). New design docs go under `docs/{rfc,adr,design,impl,plan,investigation}/` — use the `docz:create` skill rather than hand-rolling filenames; it allocates IDs and updates README index tables.
- **Commit message / PR labels:** `pr-labels.yml` workflow expects one of `major`/`minor`/`patch`/`dont-release` for semver impact; `scripts/labels.sh` is the authoritative tool for syncing labels to the GitHub repo.

## CI gates

`.github/workflows/ci.yml` runs on every PR: labeler, `golangci-lint` (v2.11.4), `make test-coverage` + Codecov, `govulncheck` + Trivy (HIGH/CRITICAL fail), goreleaser `build --snapshot`, and a docker-bake `ci` target. Anything new that breaks one of these will block merge — reproduce locally with `make ci` plus `goreleaser build --snapshot --clean` before pushing.
