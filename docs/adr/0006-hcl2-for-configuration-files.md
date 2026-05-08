---
id: ADR-0006
title: "HCL2 for configuration files"
status: Proposed
author: Donald Gifford
created: 2026-05-08
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0006. HCL2 for configuration files

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
  - [Scope of "config files"](#scope-of-config-files)
  - [Discovery and merge order](#discovery-and-merge-order)
  - [Schema versioning](#schema-versioning)
  - [Approved dependency](#approved-dependency)
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

DESIGN-0002 originally drafted `.deslopinator.yaml` as the user-facing
config file. Several things make YAML a worse fit than HCL2 for this
project's specific config shape:

1. **The config has nested, typed blocks with backend-specific
   variants** — `review.backend "anthropic" { ... }`,
   `review.backend "ollama" { ... }`, multiple
   `profile "name" { ... }` blocks, observability sub-blocks per
   exporter (ADR-0005). HCL2's labeled-block syntax expresses this
   naturally; YAML expresses it via discriminator fields and nested
   maps that keep degrading in readability as the schema grows.
2. **We will eventually want expressions** — env-var interpolation
   (`api_key_env = env.ANTHROPIC_API_KEY`), profile inheritance,
   conditional defaults. HCL2 has these built in via cty + the
   evaluation context. YAML requires either string-templating
   (preprocess pass) or a custom DSL inside string values.
3. **`wiz-go-sdk` precedent.** The RFC §"References" already cites
   `wiz-go-sdk` and "HCL-config patterns we may adopt for
   `.deslopinator.hcl`." This ADR makes that adoption concrete.
4. **The user-facing config is not a Kubernetes object.** Operator
   CRDs in the deslopinator-operator repo are YAML by Kubernetes
   convention — that's unaffected by this decision. CRDs and our CLI
   config are different surfaces with different audiences.

The cost is one approved third-party dependency
(`github.com/hashicorp/hcl/v2`) and the discipline of maintaining a
schema-decoded type set. ADR-0002 §"When third-party is allowed"
case 1 (stdlib does not provide the capability) covers HCL.

## Decision

All deslopinator-owned configuration files use HCL2. YAML is reserved
for files that interoperate with external tools that require it
(GitHub Actions workflows, Kubernetes manifests in the operator,
linter configs that ship as YAML — `.golangci.yml`, `.markdownlint.yaml`).

### Scope of "config files"

In-scope (HCL2):

- `.deslopinator.hcl` — primary user config: profiles, review backend
  selection, observability toggles, per-detector overrides.
- Any future `*.deslopinator.hcl` profile fragments under
  `.deslopinator/profiles/`.
- Detector-specific configuration emitted by `deslopinator init`.

Out of scope (stays in original format):

- `mise.toml`, `go.mod`, `cliff.toml` — tool-imposed formats.
- `.golangci.yml`, `.markdownlint.yaml`, `.yamllint.yml`,
  `.prettierrc.yaml`, `.yamlfmt.yml`, `.codecov.yml` — linter / tool
  configs.
- `.github/workflows/*.yml`, `.github/*.yml` — GitHub-imposed.
- `mkdocs.yml`, `.docz.yaml` — wiki/doc tooling that requires YAML.
- The deslopinator-operator's CRDs and Helm chart values — Kubernetes
  ecosystem convention.
- `docker-bake.hcl` — already HCL (Buildx).

### Discovery and merge order

```
1. Defaults baked into the binary (no file)
2. /etc/deslopinator/config.hcl                    (system-wide)
3. $XDG_CONFIG_HOME/deslopinator/config.hcl        (user-global)
4. ./.deslopinator.hcl                             (repo-local)
5. ./.deslopinator/profiles/<profile>.hcl          (selected profile)
6. Env var overrides (DESLOPINATOR_<KEY>)
7. CLI flags
```

Later wins, key by key. Files are decoded in order; HCL2's evaluation
context carries forward so a later file can reference values declared
in an earlier one.

### Schema versioning

Top-level `version = 1` is required. The decoder rejects unknown
versions with a clear error pointing at a migration command (mirrors
the StateV1 pattern from RFC-0001 §"State schema with explicit
migrations" — ADR-0003 §"Stability contract" rule 3).

Sample top of `.deslopinator.hcl`:

```hcl
version = 1

profile "default" {
  path    = "."
  workers = 0  # 0 == GOMAXPROCS

  review {
    enabled = true
    backend "anthropic" {
      model       = "claude-opus-4-7"
      api_key_env = "ANTHROPIC_API_KEY"
    }
  }

  observability {
    otel {
      enabled  = true
      endpoint = "localhost:4317"
      insecure = true
    }
    langfuse {
      enabled        = true
      host           = "https://cloud.langfuse.com"
      public_key_env = "LANGFUSE_PUBLIC_KEY"
      secret_key_env = "LANGFUSE_SECRET_KEY"
      buffered       = true
    }
  }
}

profile "ci" {
  path    = "."
  workers = 2

  review {
    enabled = false  # CI runs mechanical-only
  }

  observability {
    otel     { enabled = false }
    langfuse { enabled = false }
  }
}
```

Schema migrations between versions are explicit Go functions
(`migrateV1ToV2`), gated by the `version` field. Same model as
StateV1 → StateVN.

### Approved dependency

`github.com/hashicorp/hcl/v2` is added to ADR-0002's approved
third-party list. Rationale: HCL2 is the only well-maintained Go
implementation of the spec; the only alternative is forking the
official one. Justification number 1 (stdlib doesn't provide HCL).

We use:
- `hcl/v2` for parsing and the AST.
- `hcl/v2/gohcl` for struct-tag-based decoding into typed Go structs.
- `hcl/v2/hclsimple` for "load file → struct" one-liners in tests
  and trivial paths.
- `zclconf/go-cty/cty` (transitive) for the evaluation context.

We do **not** use:
- `terraform-plugin-sdk` or related Terraform-specific HCL helpers —
  too much surface, wrong audience.
- HCL1. Dead.

## Consequences

### Positive

- Config schema scales gracefully as the engine grows (multiple
  backends, per-detector overrides, profile inheritance) without
  the readability collapse YAML hits at depth >3.
- Env var interpolation, conditional defaults, and profile inheritance
  are first-class via HCL2 expressions instead of bolted-on string
  templating.
- Aligns with the broader internal stack (`wiz-go-sdk`, Terraform-
  flavored tooling). Contributors moving between repos see one
  config grammar.
- Schema-decoded structs mean the Go types and the docs are the same
  thing — `gohcl` struct tags double as the user-facing schema.

### Negative

- One more third-party dep. Apache-2.0, well-maintained by HashiCorp,
  but it does pull in `cty` and a handful of supporting packages.
  License-check passes; binary size increase is bounded
  (~1.5–2 MB).
- Contributors unfamiliar with HCL face a small learning curve.
  Mitigation: `deslopinator init` emits a fully-commented sample
  `.deslopinator.hcl`; CLAUDE.md links to the HCL2 spec.
- IDE support for HCL is good in JetBrains and VS Code (HashiCorp's
  language server) but not universal. YAML has wider editor support
  by default.
- We have to write a `deslopinator config validate` subcommand
  (DESIGN-0002) — HCL doesn't have a "yamllint" equivalent in the
  install-everywhere ecosystem.

### Neutral

- Per-profile config still maps to the same Go structs the engine
  consumes; HCL is just the wire format. Internal APIs are unaffected.
- HCL2's evaluation model is more powerful than we currently need.
  We can adopt features (functions, `for` expressions, dynamic blocks)
  incrementally without schema-breaking changes.
- Decoded errors are typically clearer than YAML's
  ("expected attribute, got block at line 12") which is a small but
  real UX win.

## Alternatives Considered

**Stay with YAML.** Rejected for the reasons in §Context. The schema
DESIGN-0002 originally sketched is already at the depth where YAML
becomes hard to read; the multi-backend story (ADR-0004) makes it
worse.

**TOML.** Rejected. Better than YAML for flat configs; degrades
similarly for nested/labeled blocks. No expression language.
`mise.toml` is a counterexample where TOML works because the schema
is shallow; ours isn't.

**JSON / JSON5.** Rejected. JSON is fine for machine-emitted
configuration but is a poor authoring format (no comments in JSON,
no trailing-comma forgiveness). JSON5 fixes that but lacks Go ecosystem
support.

**CUE.** Considered. Excellent constraint language and type system,
genuinely powerful for config validation. Rejected for v1 because:
(a) the dep is heavy and pulls in a real interpreter,
(b) authoring tooling outside JetBrains is sparse,
(c) we don't yet have a constraint-validation use case that HCL2
+ struct tags doesn't cover. Revisit if config-as-code use cases
emerge.

**Starlark.** Rejected. Imperative config DSL is overkill and conflicts
with the "config is data, not code" property we want — Starlark
configs are turing-complete and deny static analysis of "what does
this config evaluate to?"

## References

- ADR-0002 — stdlib-first policy; this ADR adds `hcl/v2` to the
  approved list under justification 1.
- ADR-0003 — public API package layout. Config types live in
  `pkg/api/config.go` (newly added).
- ADR-0004 — AI provider abstraction; backend selection is a
  labeled-block construct that HCL handles cleanly.
- ADR-0005 — observability config; another nested-block case.
- DESIGN-0002 — CLI surface; the `--config` flag, env-var
  precedence, and profile selection that this ADR formalizes.
- RFC-0001 §"References" — original mention of
  `.deslopinator.hcl`.
- [HCL2 spec](https://github.com/hashicorp/hcl/blob/main/hclsyntax/spec.md).
- [`gohcl` package](https://pkg.go.dev/github.com/hashicorp/hcl/v2/gohcl).
- `github.com/donaldgifford/wiz-go-sdk` — internal precedent for HCL
  configuration decoded via `gohcl`.
