# Phase 08 - CLI, Graph Introspection, and Developer UX

## Purpose

Make the system inspectable and usable by developers.

This phase covers:

- stable CLI command structure
- graph inspection
- diagnostics and summaries
- quickstart-quality usability

## Phase dependencies

- Some work can start after Phase 00 or Phase 01.
- Full value depends on: Phases 03, 05, 06, 07.

## Parallelism

- `P08-A` can start early.
- `P08-B` depends on schema and graph parsing.
- `P08-C` can be built incrementally while build/store/realization mature.
- `P08-D` follows when command surfaces stabilize.

## Work units

### P08-A - CLI framework and help structure

**Goal**
- Define the stable command grammar and help output.

**Likely files**
- `src/main.zig`
- `src/cli/`

**Requirements**
- MVP commands:
  - `inspect`
  - `graph`
  - `lock`
  - `update`
  - `realize`
  - `build`
  - `test`
  - `export`
- Consistent help output and argument parsing conventions

**Validation**
- `zig build run -- --help`
- `zig build run -- <command> --help`

**Exit criteria**
- CLI surface is stable enough for other phases to target

---

### P08-B - `inspect` and `graph`

**Goal**
- Provide introspection into package, lockfile, and target graph state.

**Likely files**
- `src/cli/inspect.zig`
- `src/cli/graph.zig`

**Requirements**
- `inspect` shows normalized package contract and optionally identity details
- `graph` default shows resolved package graph from lockfile
- `graph --verbose` or equivalent includes target graph details from `zpkg.graph.zon`

**Validation**
- `zig build run -- inspect <root>`
- `zig build run -- graph <root>`
- `zig build run -- graph <root> --verbose`

**Exit criteria**
- Developers can explain resolution and target structure without reading intermediate files manually

---

### P08-C - Diagnostics and summaries

**Goal**
- Make failures and outcomes easy to understand.

**Likely files**
- `src/util/diag.zig`
- all CLI command files

**Requirements**
- On build/test/export failures, include:
  - package id
  - domain
  - instance key if known
  - realized workspace path if known
- Common failure modes should suggest next actions
- Summary output should distinguish:
  - cache hits
  - cache misses
  - source builds
  - lockfile problems

**Validation**
- Golden tests for error messages and build summaries

**Exit criteria**
- Diagnostics are good enough that users do not need to attach a debugger for common failures

---

### P08-D - Quickstart and workflow docs

**Goal**
- Document the supported local workflows.

**Likely files**
- `docs/`

**Requirements**
- Explain:
  - creating a lockfile
  - building
  - building with tests
  - running tests
  - graph inspection
  - realizing workspace for debug
- Keep examples aligned with the actual sample workspace

**Validation**
- Manual dry run by another engineer or by following from a clean checkout

**Exit criteria**
- Another engineer can follow the documented workflow and reproduce the sample build locally

## Phase completion criteria

This phase is complete when:

- command help is stable
- graph inspection is useful
- diagnostics are actionable
- the documented workflow is realistic for another engineer to follow
