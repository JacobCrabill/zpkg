# Detailed Implementation Breakdown

This directory expands `docs/zpkg-implementation-plan.md` into subagent-friendly work units.

Use these files as the working set for parallel implementation.

## Source documents

Primary design inputs:

- `docs/zpkg-mvp-architecture.md`
- `docs/zpkg-implementation-plan.md`
- `docs/zpkg-schema.md`
- `docs/zpkg-lockfile.md`
- `docs/zpkg-graph-schema.md`
- `docs/implementation/review-process.md`
- `docs/implementation/current-status.md`

## Execution model

### Serial foundation

These phases should be treated as the architectural spine and should mostly serialize:

1. Phase 00 - bootstrap
2. Phase 01 - schema and model
3. Phase 02 - hashing and identity
4. Phase 03 - resolution and lockfile

### Main parallel window

After Phase 03 stabilizes, the best parallelism window opens:

- Phase 04 - local store and manifest management
- Phase 05 - `zpkg-build` wrapper package and graph emission
- Phase 08-A/B portions of CLI/inspect/graph UX
- example package migration / fixture refinement inside the above phases

### Re-convergence

These phases depend on the outputs of multiple earlier tracks and should re-converge:

- Phase 06 - workspace realization
- Phase 07 - source-build fallback pipeline

### Late parallel window

After end-to-end builds work:

- Phase 08 - remaining CLI/UX and diagnostics
- Phase 09 - export and relocation
- Phase 10 - reproducibility and CI hardening

## Dependency graph

```text
P00 Bootstrap
  -> P01 Schema/model
    -> P02 Source hash + instance key
      -> P03 Resolution + lockfile
        -> [P04 Store] ----\
        -> [P05 zpkg-build] --+-> P06 Realization
        -> [P08 inspect/graph UX] /
P00 Bootstrap -> example packages -----------/
P06 + P04 -> P07 Build fallback
P07 -> P08 Build/test UX completion
P07 + P04 + P06 -> P09 Export
P07 + P08 + P09 -> P10 Repro/CI
```

## Suggested subagent lanes

### Lane A - Foundation
- `phase-00-bootstrap.md`
- `phase-01-schema-and-model.md`
- `phase-02-hashing-and-identity.md`
- `phase-03-resolution-and-lockfile.md`

### Lane B - Store
- `phase-04-store-and-manifest.md`

### Lane C - Wrapper and graph emission
- `phase-05-zpkg-build-and-graph.md`

### Lane D - Realization
- `phase-06-workspace-realization.md`

### Lane E - Build/test pipeline
- `phase-07-build-fallback.md`

### Lane F - CLI and diagnostics
- `phase-08-cli-and-ux.md`

### Lane G - Export and relocation
- `phase-09-export-and-relocation.md`

### Lane H - Reproducibility and CI
- `phase-10-reproducibility-and-ci.md`

## Review loop

Every lane must go through the review process described in:

- `review-process.md`

Minimum rule set:

1. a developer subagent completes the lane
2. a clean reviewer subagent reviews it against the architecture, schema docs, implementation plan, and lane definition
3. required findings go back to the developer lane for correction
4. optional out-of-scope improvements go back to the Manager as follow-up candidates
5. the reviewer re-checks and approves before merge

No dependent wave should start from an unreviewed lane output.

## Status bookkeeping

The live status ledger is:

- `current-status.md`

Manager must update `current-status.md` whenever any of the following happens:

- a developer lane starts
- a developer lane completes, times out, or is abandoned
- a reviewer returns findings
- required findings are fixed
- a lane is approved
- a lane is merged
- a stash/branch/recovery point is created that matters for later work

`current-status.md` should record the **actual current state**, including:

- current `main` commit
- whether the working tree is clean
- per-phase status
- active / stale / superseded agent IDs
- important stash entries
- exact next manager action

Subagent plans and prompts should be treated as intent; `current-status.md` is the operational source of truth.

## Working rules for subagents

1. Do not change architectural commitments from the root docs without explicit coordination.
2. Treat these as strict invariants:
   - `zpkg.zon` = constraints + package contract
   - `zpkg.lock.zon` = authoritative exact resolution
   - `zpkg.graph.zon` = configure-time emitted target graph
   - `zpkg-build` wrappers are mandatory for first-party packages
   - resolution identity is per `(package_id, domain)`
3. Prefer adding tests and fixtures as part of each work unit rather than as follow-up work.
4. If a task depends on a schema detail that is not yet implemented, stub the data model first and keep interfaces narrow.

## Phase files

- `phase-00-bootstrap.md`
- `phase-01-schema-and-model.md`
- `phase-02-hashing-and-identity.md`
- `phase-03-resolution-and-lockfile.md`
- `phase-04-store-and-manifest.md`
- `phase-05-zpkg-build-and-graph.md`
- `phase-06-workspace-realization.md`
- `phase-07-build-fallback.md`
- `phase-08-cli-and-ux.md`
- `phase-09-export-and-relocation.md`
- `phase-10-reproducibility-and-ci.md`
- `review-process.md`
- `current-status.md`
- `subagent-launch-plan.md`
