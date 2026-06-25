# Phase 04 - Local Store and Manifest Management

## Purpose

Implement the local binary prefix store used for binary reuse.

This phase defines:

- on-disk store layout
- manifest serialization
- archive/extract behavior
- integrity/error handling

## Phase dependencies

- Requires: Phase 03
- Can run in parallel with: Phase 05 and early Phase 08 work
- Unlocks: Phases 06, 07, 09, 10

## Parallelism

- `P04-A`, `P04-B`, and `P04-C` can overlap once the schema is stable.
- `P04-D` should follow after the other three exist.

## Work units

### P04-A - Store layout and path derivation

**Goal**
- Implement deterministic local paths for archives, manifests, and expanded prefixes.

**Likely files**
- `src/store/layout.zig`
- `src/store/store.zig`

**Requirements**
- Support layout:
  - `artifacts/<instance_key>/`
  - `expanded/<instance_key>/`
- Derive archive, manifest, and expansion paths from instance key only
- Keep internal store semantics distinct from export semantics

**Validation**
- Unit tests for store path derivation

**Exit criteria**
- Instance key to path mapping is deterministic and stable

---

### P04-B - Manifest read/write

**Goal**
- Implement artifact manifest round-trip behavior.

**Likely files**
- `src/store/manifest.zig`

**Requirements**
- Serialize and parse manifest fields from `docs/zpkg-graph-schema.md` and `docs/zpkg-lockfile.md`
- Preserve:
  - package id/version/domain
  - selected options
  - instance key
  - dependency instance keys
- Use canonical ZON formatting where feasible

**Validation**
- Round-trip unit tests
- Snapshot tests of canonical serialized output

**Exit criteria**
- Manifest model is stable enough for adapters and export logic to consume later

---

### P04-C - Archive and expansion mechanics

**Goal**
- Store prefixes and expand them on demand.

**Likely files**
- `src/store/archive.zig`
- `src/store/store.zig`

**Requirements**
- Create a prefix archive from a staging install dir
- Expand archive to `expanded/<instance_key>/`
- Expansion must be idempotent
- Re-expanding an already expanded artifact must not corrupt content

**Validation**
- Archive/extract round-trip tests
- Idempotent expansion integration test

**Exit criteria**
- Local store can persist and rehydrate prefixes reliably

---

### P04-D - Integrity and failure diagnostics

**Goal**
- Surface clear failures for bad artifacts.

**Likely files**
- `src/store/store.zig`
- `src/util/diag.zig`

**Requirements**
- Detect and report:
  - missing manifest
  - missing archive
  - corrupt archive
  - inconsistent expanded prefix
- Diagnostics should include instance key and relevant file paths

**Validation**
- Negative integration tests with intentionally corrupted fixtures

**Exit criteria**
- Store failures are actionable for developers and higher-level commands

## Phase completion criteria

This phase is complete when:

- an installed prefix can be stored and expanded deterministically
- manifests round-trip correctly
- the store is robust enough for binary adapters and export planning
