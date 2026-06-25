# Phase 05 - `zpkg-build` Wrappers and Graph Emission

## Purpose

Implement the mandatory wrapper layer used by all first-party `build.zig` files.

This phase is responsible for:

- wrapper API design
- target registration
- edge registration
- configure-time emission of `zpkg.graph.zon`
- strict validation against `zpkg.zon`

## Phase dependencies

- Requires: Phases 01 and 03
- Can run in parallel with: Phase 04 and portions of Phase 08
- Unlocks: Phases 06, 07, 08, 09

## Parallelism

- `P05-A` must happen first.
- `P05-B` and `P05-C` can overlap after the API is stable.
- `P05-D` follows once wrappers and validation are usable.

## Work units

### P05-A - Wrapper API and contract design

**Goal**
- Define the public `zpkg-build` surface used by first-party packages.

**Likely files**
- `pkg/zpkg-build/build.zig`
- `pkg/zpkg-build/src/root.zig`
- `docs/zpkg-build-contract.md`

**Requirements**
- Wrap:
  - target creation
  - target export registration
  - dependency edge registration
  - include-dir metadata
  - compile-definition metadata
  - tools
  - resources
- Support target kinds:
  - library
  - executable
  - zig_module
  - headers
  - resource_set
- Support edge roles:
  - link
  - tool
  - build
  - test
- Use dependency aliases, not raw package ids

**Validation**
- Wrapper package compiles
- Contract doc examples are internally consistent

**Exit criteria**
- API is expressive enough to model all declared MVP target and edge semantics

---

### P05-B - Configure-time `zpkg.graph.zon` emission

**Goal**
- Emit the registered target graph during configure.

**Likely files**
- `pkg/zpkg-build/src/graph_emit.zig`

**Requirements**
- Emit graph file in ZON only
- Place `zpkg.graph.zon` in the realized package root
- Record:
  - package identity/domain
  - selected options
  - dependency alias mapping
  - all registered targets
  - target edges
  - include dirs
  - compile definitions
  - artifacts
  - system libs
  - resources

**Validation**
- Configure sample package and inspect emitted graph file
- Graph file parses via `src/schema/graph.zig`

**Exit criteria**
- Wrapper registration produces a machine-readable target graph without compiling artifacts

---

### P05-C - Strict contract validation

**Goal**
- Enforce consistency between static declarations and emitted graph.

**Likely files**
- `pkg/zpkg-build/src/validate.zig`

**Requirements**
- Fail on:
  - declared exported target missing from registration
  - registered exported target absent from `zpkg.zon`
  - target kind/linkage mismatch
  - undeclared dependency alias in registered edge
  - declared-vs-registered export mismatch
- Internal helper targets are allowed if not exported

**Validation**
- Negative integration fixtures for each mismatch type

**Exit criteria**
- Hybrid declaration/registration model is trustworthy and self-checking

---

### P05-D - Example package migration

**Goal**
- Convert example packages to use `zpkg-build` wrappers.

**Likely files**
- `examples/hello-lib/build.zig`
- `examples/hello-headers/build.zig`
- `examples/hello-tool/build.zig`
- `examples/hello-app/build.zig`
- `examples/hello-tests/build.zig`

**Requirements**
- Examples should demonstrate:
  - exported shared library
  - headers-only target consumed through `.link`
  - tool target consumed through `.tool`
  - resource target
  - test-only target
- Configure succeeds and emits valid graph files

**Validation**
- Configure each example and parse `zpkg.graph.zon`

**Exit criteria**
- Example packages become canonical reference implementations for the wrapper API

## Phase completion criteria

This phase is complete when:

- first-party build registration is mandatory and usable
- `zpkg.graph.zon` is emitted at configure time
- strict validation catches drift between `zpkg.zon` and `build.zig`
