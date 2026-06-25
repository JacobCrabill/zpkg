# Phase 07 - Source-Build Fallback Pipeline

## Purpose

Implement the binary-first, source-fallback build path:

- if an artifact exists in the local store, reuse it
- otherwise build from source, install to staging, publish to store, and continue

## Phase dependencies

- Requires: Phase 06
- Unlocks: Phases 08, 09, 10

## Parallelism

- `P07-A` and `P07-B` can overlap once shared interfaces settle.
- `P07-C` can begin once build execution works for the main graph.
- `P07-D` follows after end-to-end builds are reliable.

## Work units

### P07-A - Topological build planner

**Goal**
- Determine which resolved instances must be built and in what order.

**Likely files**
- `src/realize/build_fallback.zig`

**Requirements**
- Traverse resolved graph by dependency order
- Distinguish host and target instances
- Reuse the same store entry when different roles resolve to the same instance
- Skip nodes already satisfied by the store

**Validation**
- Unit tests over fixture graphs and store-hit/store-miss scenarios

**Exit criteria**
- Planner computes the minimal source-build set for a given build invocation

---

### P07-B - Source build executor and publication

**Goal**
- Build missing packages from source and publish them to the store.

**Likely files**
- `src/realize/build_fallback.zig`
- `src/cli/build.zig`

**Requirements**
- Realize missing package from source
- Invoke `zig build install --prefix <staging>`
- Archive and publish staging prefix into local store
- Reuse generated adapter for downstream consumers after publication
- MVP assumes shared-library-oriented builds

**Validation**
- Cold-store build populates store
- Warm-store build reuses store artifacts
- Deleting one artifact rebuilds only the missing subgraph

**Exit criteria**
- End-to-end `zpkg build` works for sample graph on cold and warm stores

---

### P07-C - Test graph behavior

**Goal**
- Implement differentiated build vs test workflows.

**Likely files**
- `src/cli/build.zig`
- `src/cli/test.zig`

**Requirements**
- `zpkg build`
  - exclude test-only targets by default
- `zpkg build --with-tests`
  - include test graph but do not run tests
- `zpkg test`
  - include test graph and run tests
- `.test` dependencies resolve in host domain in the MVP

**Validation**
- `zig build run -- build <root> --with-tests`
- `zig build run -- test <root>`

**Exit criteria**
- Test-only graph participation matches the design commitments exactly

---

### P07-D - Rebuild correctness and cache behavior

**Goal**
- Verify that binary identity and rebuild behavior are correct.

**Likely files**
- same as above plus test fixtures

**Requirements**
- ABI option change invalidates affected instances
- non-ABI option change does not perturb binary identity
- dependency changes propagate upward correctly

**Validation**
- Integration tests that flip ABI and non-ABI options independently
- Compare cold/warm run logs and selected rebuilt nodes

**Exit criteria**
- Rebuild behavior is predictable enough for developers to trust store reuse

## Phase completion criteria

This phase is complete when:

- the sample graph can be built end-to-end from an empty store
- rerunning the same build reuses binary artifacts instead of rebuilding
- test and build modes behave differently as specified
