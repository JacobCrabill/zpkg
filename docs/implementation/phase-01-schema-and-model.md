# Phase 01 - Schema and Model Foundation

## Purpose

Implement the core typed models and parsers for:

- `zpkg.zon`
- `zpkg.lock.zon`
- `zpkg.graph.zon`
- `manifest.zon`

This phase defines the data contracts used by every later phase.

## Phase dependencies

- Requires: Phase 00
- Unlocks: Phases 02, 03, 05

## Parallelism

Can be split into parallel tracks after common model shape is agreed:

- `P01-A` - versions, package ids, options, conditions
- `P01-B` - `zpkg.zon`
- `P01-C` - `zpkg.lock.zon`
- `P01-D` - `zpkg.graph.zon` and `manifest.zon`
- `P01-E` - cross-schema tests after the others stabilize

## Work units

### P01-A - Core scalar/domain model

**Goal**
- Implement normalized types shared across all schema layers.

**Likely files**
- `src/model/version.zig`
- `src/model/package_id.zig`
- `src/model/options.zig`
- `src/model/conditions.zig`
- `src/model/domain.zig`

**Requirements**
- Normalize `1.2.3` -> `1.2.3.0`
- Preserve ordering semantics for 3-/4-component versions
- Represent option values as a tagged union supporting:
  - bool
  - int
  - string
- Support MVP condition axes only:
  - domain
  - host_os
  - host_arch
  - target_os
  - target_arch
  - option equality

**Validation**
- Unit tests for parsing, normalization, ordering, and condition evaluation

**Exit criteria**
- Shared value model is stable and reused by all schema parsers

---

### P01-B - `zpkg.zon` parser and validator

**Goal**
- Parse and validate the package contract file.

**Likely files**
- `src/schema/zpkg.zig`
- `src/model/package.zig`
- `src/model/target.zig`
- `src/cli/inspect.zig`

**Requirements**
- Validate required sections:
  - `.schema`
  - `.package`
  - `.targets`
- Validate target kinds:
  - library
  - executable
  - zig_module
  - headers
  - resource_set
- Validate `.linkage` only on `.library`
- Validate dependency entries contain:
  - alias
  - canonical package id
  - exact version requirement in MVP
  - optional `when`
- Reject `.required`
- Normalize values on parse

**Validation**
- `zig build test`
- `zig build run -- inspect <example-package>`

**Exit criteria**
- `inspect` can print normalized package metadata and useful diagnostics

---

### P01-C - `zpkg.lock.zon` parser and validator

**Goal**
- Parse and validate authoritative exact resolution files.

**Likely files**
- `src/schema/lockfile.zig`
- `src/model/lockfile.zig`

**Requirements**
- Parse top-level root and instances
- Parse canonical lockfile instance references, e.g. `package#host`
- Validate every referenced instance exists
- Validate unique `(package_id, domain)` identities
- Preserve dependency aliases in direct edges
- Validate selected options against package option kinds where possible

**Validation**
- Lockfile round-trip tests
- Invalid reference / duplicate instance tests

**Exit criteria**
- Lockfile can be loaded into a semantic model without ambiguity

---

### P01-D - `zpkg.graph.zon` and `manifest.zon` parser/validator

**Goal**
- Parse configure-time target graph metadata and built artifact manifests.

**Likely files**
- `src/schema/graph.zig`
- `src/schema/manifest.zig`
- `src/model/graph.zig`
- `src/model/manifest.zig`

**Requirements**
- Graph schema must model:
  - exported and internal targets
  - explicit target edges
  - include dirs with visibility
  - compile definitions with visibility
  - system libs with visibility
  - artifacts
  - resources
- Manifest schema must model:
  - package id/version/domain
  - source hash
  - instance key
  - selected options
  - resolved dependency instance keys

**Validation**
- Parser unit tests
- Round-trip tests
- Negative tests for invalid target/edge shapes

**Exit criteria**
- Graph and manifest models are ready for wrapper emission and store code

---

### P01-E - Cross-schema invariants and golden coverage

**Goal**
- Add semantic tests that span multiple schema files.

**Likely files**
- `test/schema/`
- `test/golden/`

**Requirements**
- Normalized ZON golden outputs for:
  - `zpkg.zon`
  - `zpkg.lock.zon`
  - `zpkg.graph.zon`
- Semantic mismatch fixtures:
  - duplicate targets
  - malformed conditions
  - invalid version grammar
  - bad linkage placement

**Validation**
- `zig build test`

**Exit criteria**
- Schema layer is stable enough to support hashing and resolution work

## Phase completion criteria

This phase is complete when:

- all four schema documents can be parsed into stable semantic models
- normalization behavior is deterministic
- diagnostics are actionable enough for later CLI work to reuse
