# Phase 06 - Workspace Realization

## Purpose

Generate a local, Zig-consumable realized workspace from a resolved lockfile.

This phase turns semantic resolution into concrete on-disk packages:

- source realizations
- binary adapters
- rewritten local `build.zig.zon` files
- colocated `zpkg.graph.zon`

## Phase dependencies

- Requires: Phases 04 and 05, plus Phase 03 lockfile output
- Unlocks: Phases 07, 08, 09, 10

## Parallelism

- `P06-A` should establish workspace layout first.
- `P06-B` and `P06-C` can then run in parallel.
- `P06-D` follows once the above are stable.

## Work units

### P06-A - Workspace layout planner

**Goal**
- Map resolved package instances to deterministic realized paths.

**Likely files**
- `src/realize/workspace.zig`

**Requirements**
- Support workspace layout under `.zpkg/work/<profile>/`
- Create deterministic roots for:
  - realized root package
  - realized dependency packages
- Encode at least target triple and optimize mode into profile naming

**Validation**
- Unit tests for path planning and profile naming

**Exit criteria**
- Realization code has a stable path model to target

---

### P06-B - Source package realization

**Goal**
- Materialize source-backed packages in the realized workspace.

**Likely files**
- `src/realize/source_pkg.zig`

**Requirements**
- Prefer symlink forest or minimal-copy strategy
- Never mutate developer checkouts in place
- Generate local-path-only `build.zig.zon`
- Place `zpkg.graph.zon` in the realized package root

**Validation**
- Golden tests for realized source package layout
- `zig build` configure success inside realized source package

**Exit criteria**
- Source packages can be consumed from the realized workspace without package fetching

---

### P06-C - Binary adapter generation

**Goal**
- Materialize store-backed packages as generated adapter packages.

**Likely files**
- `src/realize/binary_adapter.zig`

**Requirements**
- Expose named lazy paths:
  - include
  - lib
  - bin
  - share
- Expose metadata for:
  - exported targets
  - include dirs
  - compile definitions
  - system libs
  - tools
  - resources
- Avoid `dep.artifact(...)` assumptions for prebuilt tools

**Validation**
- Integration test swapping source dependency for adapter dependency
- Graph/metadata parse tests against generated adapter outputs

**Exit criteria**
- Binary-backed deps are consumable through the same logical contract as source-backed deps

---

### P06-D - `realize` CLI command

**Goal**
- Expose the workspace materialization step as an advanced/debug command.

**Likely files**
- `src/cli/realize.zig`

**Requirements**
- Read `zpkg.zon` + `zpkg.lock.zon`
- Validate compatibility
- Materialize the full workspace
- Stop before source-build fallback or test execution

**Validation**
- `zig build run -- realize <root>`
- repeated command produces equivalent workspace without needless churn

**Exit criteria**
- Developers can inspect and debug the exact realized workspace independently from full builds

## Phase completion criteria

This phase is complete when:

- the resolved graph can be materialized into a local workspace deterministically
- source and binary deps can both be represented as local Zig-consumable packages
- `realize` is usable as an inspection/debugging tool
