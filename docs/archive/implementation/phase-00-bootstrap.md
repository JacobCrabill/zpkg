# Phase 00 - Bootstrap and Scaffolding

## Purpose

Create the executable repository skeleton and sample package harness that all later phases depend on.

## Phase dependencies

- none

## Parallelism

- `P00-A` must start first.
- `P00-B` and `P00-C` can proceed once repository layout conventions from `P00-A` exist.

## Work units

### P00-A - Repository skeleton and root build

**Goal**
- Create the root Zig package and CLI entrypoint.

**Likely files**
- `build.zig`
- `build.zig.zon`
- `src/main.zig`
- `src/cli/`
- `src/model/`
- `src/schema/`
- `src/hash/`
- `src/resolve/`
- `src/realize/`
- `src/store/`
- `src/export/`
- `src/util/`

**Requirements**
- One CLI executable target, e.g. `zpkg`
- A root test target
- Stable generated workspace root convention: `.zpkg/`
- Stable source layout for all future modules

**Validation**
- `zig build`
- `zig build test`
- `zig build run -- --help`

**Exit criteria**
- Repo builds and runs with a placeholder CLI
- Module layout is stable enough for subagents to work in parallel

---

### P00-B - Example package harness

**Goal**
- Create example packages that will become the integration test graph.

**Likely files**
- `examples/hello-lib/`
- `examples/hello-headers/`
- `examples/hello-tool/`
- `examples/hello-app/`
- `examples/hello-tests/`

**Requirements**
- Each example has:
  - `build.zig`
  - `build.zig.zon`
  - `zpkg.zon`
- Collectively, examples cover:
  - shared library target
  - headers-only target
  - executable/tool target
  - resource target
  - test target

**Validation**
- Plain `zig build` works inside each example before `zpkg-build` migration

**Exit criteria**
- Examples exist and are ready to become fixtures in later phases

---

### P00-C - Test and fixture conventions

**Goal**
- Establish test layout and golden/integration fixture conventions.

**Likely files**
- `test/`
- `test/golden/`
- `test/integration/`
- root `build.zig`

**Requirements**
- Unit tests and integration tests have stable homes
- Golden file conventions are documented in code/comments or local docs
- Future schema/graph/workspace tests have a predictable directory layout

**Validation**
- `zig build test`

**Exit criteria**
- Test harness exists and later phases can add parser, golden, and integration coverage without reshaping the repo

## Phase handoff notes

This phase is complete when later subagents can assume:

- stable module paths
- stable test directories
- stable example package roots
- stable `.zpkg/` generated-workspace convention
