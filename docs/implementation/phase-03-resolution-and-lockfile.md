# Phase 03 - Resolution and Lockfile Authority

## Purpose

Resolve exact package instances from package-level constraints and enforce `zpkg.lock.zon` as the authoritative resolved graph.

## Phase dependencies

- Requires: Phases 01 and 02
- Unlocks: Phases 04, 05, 06, 07, 08, 09

## Parallelism

- `P03-A` and `P03-B` can overlap once the shared output model is agreed.
- `P03-C` depends on both.
- `P03-D` depends on command surfaces from `P03-C`.

## Work units

### P03-A - Resolver core

**Goal**
- Resolve package-level constraints into exact `(package_id, domain)` instances.

**Likely files**
- `src/resolve/resolve.zig`
- `src/resolve/domain.zig`
- `src/resolve/options_select.zig`

**Requirements**
- Support MVP exact version constraints only
- Preserve dependency aliases from `zpkg.zon`
- Apply conditions before instantiating dependencies
- Resolve in domains:
  - host
  - target
- Produce semantic instance references suitable for lockfiles

**Validation**
- Unit tests for:
  - host vs target domain resolution
  - conditional dependencies
  - alias preservation
  - selected options per instance

**Exit criteria**
- Resolver produces exact semantic instances without consulting the binary store

---

### P03-B - Lockfile semantic model and drift detection

**Goal**
- Detect whether a lockfile still matches the current workspace contract.

**Likely files**
- `src/model/lockfile.zig`
- `src/resolve/drift.zig`

**Requirements**
- Compare semantic content, not raw text
- Detect drift for:
  - root package identity/version
  - dependency alias changes
  - constraint changes
  - option-schema incompatibilities
  - missing/extra required deps
- Treat lockfile as authoritative when compatible

**Validation**
- Fixture-based drift tests
- Missing instance reference tests
- Invalid selected-options tests

**Exit criteria**
- `zpkg` can explain exactly why a lockfile is stale or incompatible

---

### P03-C - `lock` and `update` commands

**Goal**
- Implement explicit lockfile lifecycle commands.

**Likely files**
- `src/cli/lock.zig`
- `src/cli/update.zig`

**Requirements**
- `zpkg lock`
  - creates lockfile
  - errors if already exists
- `zpkg update`
  - updates lockfile explicitly
- `zpkg update --dry-run`
  - prints proposed semantic changes without modifying files

**Validation**
- `zig build run -- lock <root>`
- `zig build run -- update <root>`
- `zig build run -- update <root> --dry-run`

**Exit criteria**
- Workspace can generate and explicitly refresh lockfiles

---

### P03-D - Lockfile gates for build/test/export

**Goal**
- Enforce lockfile authority in user-facing workflows.

**Likely files**
- `src/cli/build.zig`
- `src/cli/test.zig`
- `src/cli/export.zig`

**Requirements**
- `build`, `test`, and `export` fail when lockfile is:
  - missing
  - stale
  - incompatible
- diagnostics must include:
  - reason for failure
  - suggested command (`lock` or `update`)

**Validation**
- Integration tests using missing and drifted lockfiles

**Exit criteria**
- No destructive or implicit lockfile rewrites occur in normal build/test/export paths

## Phase completion criteria

This phase is complete when:

- the workspace has a semantically meaningful authoritative lockfile
- `build`/`test`/`export` refuse to proceed on unresolved or stale state
- later phases can rely on exact package/domain instances
