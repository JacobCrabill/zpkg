# Phase 10 - Reproducibility and CI Hardening

## Purpose

Turn the working MVP into a deterministic, team-usable system.

This phase focuses on:

- deterministic workspace generation
- stable instance-key behavior
- cold/warm store CI coverage
- documented reproducibility guarantees

## Phase dependencies

- Requires: successful end-to-end build pipeline from Phase 07
- Benefits from: export behavior from Phase 09

## Parallelism

- `P10-A` and `P10-B` can run in parallel.
- `P10-C` can overlap once findings from those are clear.

## Work units

### P10-A - Deterministic output audit

**Goal**
- Audit emitted files and realized workspace generation for determinism.

**Likely files**
- `src/realize/`
- `src/schema/`
- tests under `test/`

**Requirements**
- Sort emitted maps and lists before serialization
- Stabilize path and dependency ordering
- Ensure repeated realization of same inputs produces equivalent output

**Validation**
- Realize the same workspace twice and compare outputs
- Snapshot `zpkg.lock.zon`, `zpkg.graph.zon`, manifests, and adapter files

**Exit criteria**
- Repeated runs produce equivalent workspace content and metadata

---

### P10-B - Cold/warm store CI matrix

**Goal**
- Make cache behavior verifiable in automation.

**Likely files**
- CI configuration under repository root
- supporting test scripts if needed

**Requirements**
- CI jobs for:
  - clean checkout + cold store build
  - warm store repeat build
- Validate:
  - stable instance keys
  - expected cache hits/misses
  - successful test workflow

**Validation**
- CI execution plus local scripted equivalents

**Exit criteria**
- CI proves both correctness from scratch and reuse from warm store

---

### P10-C - Reproducibility guarantee documentation

**Goal**
- Document what inputs affect identity and rebuild behavior.

**Likely files**
- `docs/`

**Requirements**
- Explain what is included in:
  - source hash
  - instance key
  - lockfile authority
- Explain what does **not** affect binary identity
- Document expected rebuild triggers and non-triggers

**Validation**
- Review against actual tests and fixtures

**Exit criteria**
- The team has a precise written contract for reproducibility and rebuild behavior

## Phase completion criteria

This phase is complete when:

- deterministic behavior is verified by tests and CI
- instance-key stability is demonstrably trustworthy
- rebuild-trigger rules are documented clearly enough for day-to-day engineering use
