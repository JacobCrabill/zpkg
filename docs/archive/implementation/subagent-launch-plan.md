# Subagent Launch Plan

## Purpose

This document turns the detailed phase plans into a concrete launch order for coding subagents.

It is optimized for:

- parallel work with minimal file conflicts
- persistent agent sessions across multiple waves
- clear merge gates between serialized stages
- concrete prompts that can be pasted into `session_subagent` or `Agent`

---

## Recommended execution style

For code-writing tasks that may run in parallel, prefer:

- `Agent` with `isolation: "worktree"`

For long-running follow-up within the same lane, keep a stable lane/session identity, e.g.:

- `bootstrap-lane`
- `schema-core-lane`
- `resolver-lane`
- `wrapper-lane`

This reduces cross-lane file conflicts and makes it easier to resume work.

Every coding lane must be followed by a clean review lane before merge.

---

## Global instructions for all coding subagents

Use these in every coding prompt:

1. Read the relevant docs first:
   - `docs/zpkg-mvp-architecture.md`
   - `docs/zpkg-implementation-plan.md`
   - the relevant file under `docs/implementation/`
   - and, when applicable:
     - `docs/zpkg-schema.md`
     - `docs/zpkg-lockfile.md`
     - `docs/zpkg-graph-schema.md`
2. Treat these as fixed invariants:
   - `zpkg.zon` = constraints + package contract
   - `zpkg.lock.zon` = authoritative exact resolution
   - `zpkg.graph.zon` = configure-time emitted graph
   - `zpkg-build` wrappers are mandatory
   - resolution identity is per `(package_id, domain)`
3. Add tests with the implementation.
4. Do not expand scope into neighboring lanes unless explicitly asked.
5. At the end, report:
   - files changed
   - tests/commands run
   - open issues / follow-up suggestions

## Review requirement

After every developer lane completes, launch a clean reviewer subagent.

Reviewer must compare the implementation against:

- `docs/zpkg-mvp-architecture.md`
- `docs/zpkg-implementation-plan.md`
- the relevant `docs/implementation/phase-XX-...md`
- the relevant schema docs
- the lane/task prompt
- general code quality and maintainability expectations

Reviewer output must separate:

- **Required findings**
  - must be fixed by the developer lane before approval
- **Optional improvements**
  - report to the Manager as possible follow-up tasks

A lane is not complete until the reviewer approves it after any required fixes.

## Status update requirement

After every significant state transition, the Manager must update:

- `docs/implementation/current-status.md`

Significant state transitions include:

- developer lane launched
- developer lane timed out / aborted / superseded
- developer lane completed
- reviewer returned required findings
- reviewer approved
- lane merged to `main`
- stash/branch recovery point created

Do not rely on memory or older chat history alone; keep the status ledger exact and current.

---

## Lane ownership map

Use this to avoid unnecessary conflicts.

### Lane 0 - Bootstrap
Owns:
- `build.zig`
- `build.zig.zon`
- `src/main.zig`
- top-level module directories under `src/`
- root test harness layout

### Lane 1 - Example fixtures
Owns:
- `examples/hello-lib/`
- `examples/hello-headers/`
- `examples/hello-tool/`
- `examples/hello-app/`
- `examples/hello-tests/`
- `test/` and golden/integration fixture roots where needed

### Lane 2 - Schema core
Owns:
- `src/model/version.zig`
- `src/model/package_id.zig`
- `src/model/options.zig`
- `src/model/conditions.zig`
- `src/model/domain.zig`

### Lane 3 - Package schema
Owns:
- `src/schema/zpkg.zig`
- `src/model/package.zig`
- `src/model/target.zig`

### Lane 4 - Lock/graph/manifest schemas
Owns:
- `src/schema/lockfile.zig`
- `src/schema/graph.zig`
- `src/schema/manifest.zig`
- `src/model/lockfile.zig`
- `src/model/graph.zig`
- `src/model/manifest.zig`

### Lane 5 - Hashing and identity
Owns:
- `src/hash/source_hash.zig`
- `src/hash/toolchain_fingerprint.zig`
- `src/hash/instance_key.zig`
- supporting utility files under `src/util/`

### Lane 6 - Resolver and lockfile commands
Owns:
- `src/resolve/resolve.zig`
- `src/resolve/domain.zig`
- `src/resolve/options_select.zig`
- `src/resolve/drift.zig`
- `src/cli/lock.zig`
- `src/cli/update.zig`

### Lane 7 - Store and manifest handling
Owns:
- `src/store/layout.zig`
- `src/store/store.zig`
- `src/store/archive.zig`
- `src/store/manifest.zig`

### Lane 8 - `zpkg-build` wrapper and graph emission
Owns:
- `pkg/zpkg-build/`
- `docs/zpkg-build-contract.md`
- later migration of example `build.zig` files if coordinated

### Lane 9 - CLI inspect/graph/help
Owns:
- `src/cli/inspect.zig`
- `src/cli/graph.zig`
- command dispatch additions in `src/main.zig` after coordination
- diagnostics helpers if coordinated

### Lane 10 - Workspace realization and adapters
Owns:
- `src/realize/workspace.zig`
- `src/realize/source_pkg.zig`
- `src/realize/binary_adapter.zig`
- `src/cli/realize.zig`

### Lane 11 - Build/test pipeline
Owns:
- `src/realize/build_fallback.zig`
- `src/cli/build.zig`
- `src/cli/test.zig`

### Lane 12 - Export and relocation
Owns:
- `src/export/export.zig`
- `src/cli/export.zig`

### Lane 13 - UX, diagnostics, CI, reproducibility
Owns:
- `src/util/diag.zig`
- remaining CLI polish
- CI files
- reproducibility docs/tests

---

## Launch waves

## Wave 0 - Bootstrap the repo

### Agent: `bootstrap-lane`
**Type**: coding agent in worktree
**Depends on**: nothing

**Prompt**

Implement Phase 00 from:
- `docs/zpkg-mvp-architecture.md`
- `docs/zpkg-implementation-plan.md`
- `docs/implementation/phase-00-bootstrap.md`

Scope:
- create the root Zig package/build files
- create `src/main.zig`
- create the root module directory layout under `src/`
- wire a basic test target
- standardize `.zpkg/` as generated workspace root
- make `zig build`, `zig build test`, and `zig build run -- --help` work

Constraints:
- do not implement real schema or business logic yet
- keep placeholders small but compile-clean
- do not touch docs except if a build file comment is necessary

Validation to run:
- `zig build`
- `zig build test`
- `zig build run -- --help`

Report back with:
- files created/changed
- commands run
- any structural decisions that later lanes must know

---

## Wave 0 review gate

After `bootstrap-lane` finishes:

1. launch a clean reviewer subagent
2. if it returns required findings, resume `bootstrap-lane` to fix them
3. re-run review until approved

No later wave should start until the bootstrap lane has reviewer approval.

## Wave 1 - Foundation split

Launch after Wave 0 merges.

### Agent: `example-fixtures-lane`
**Type**: coding agent in worktree
**Depends on**: Wave 0

**Prompt**

Implement the example/fixture scaffolding from:
- `docs/zpkg-mvp-architecture.md`
- `docs/implementation/phase-00-bootstrap.md`
- `docs/implementation/phase-08-cli-and-ux.md` (for eventual fixture usage)

Scope:
- create example package roots:
  - `examples/hello-lib/`
  - `examples/hello-headers/`
  - `examples/hello-tool/`
  - `examples/hello-app/`
  - `examples/hello-tests/`
- each should have placeholder:
  - `build.zig`
  - `build.zig.zon`
  - `zpkg.zon`
- establish test fixture directories for future golden/integration tests

Constraints:
- keep the examples minimal and compile-clean where possible
- do not implement `zpkg-build` yet
- avoid touching root CLI files

Validation to run:
- plain `zig build` in any examples that are already compilable
- if some examples are intentionally incomplete, note exactly why

Report back with:
- fixture tree created
- which examples already compile
- which examples are placeholders for later migration

---

### Agent: `schema-core-lane`
**Type**: coding agent in worktree
**Depends on**: Wave 0

**Prompt**

Implement the shared scalar/domain model from:
- `docs/zpkg-schema.md`
- `docs/zpkg-lockfile.md`
- `docs/zpkg-graph-schema.md`
- `docs/implementation/phase-01-schema-and-model.md`

Scope:
- implement shared model files for:
  - version parsing/normalization/comparison
  - package ids
  - option values/types
  - conditions
  - domains (`host`, `target`)
- add unit tests

Constraints:
- do not implement top-level schema parsers yet
- expose clean APIs that schema lanes can import

Validation to run:
- `zig build test`

Report back with:
- files changed
- any API surfaces schema parsers should depend on

---

## Wave 1 review gate

After `example-fixtures-lane` and `schema-core-lane` finish:

- review each lane independently with a clean reviewer subagent
- send required findings back to the corresponding developer lane
- treat optional improvements as Manager follow-up candidates

Do not start Wave 2 until both lanes have reviewer approval.

## Wave 2 - Schema layer

Launch after `schema-core-lane` merges.

### Agent: `package-schema-lane`
**Type**: coding agent in worktree
**Depends on**: Wave 1 schema core

**Prompt**

Implement the `zpkg.zon` parser/validator from:
- `docs/zpkg-schema.md`
- `docs/implementation/phase-01-schema-and-model.md`

Scope:
- implement `src/schema/zpkg.zig`
- implement supporting model files for packages/targets if needed
- validate:
  - package identity/version
  - options
  - dependency alias universe
  - target declarations
  - conditions
- reject invalid MVP forms (e.g. unsupported target kinds, malformed versions, bad linkage placement)
- add parser tests and golden tests

Constraints:
- keep output normalized and semantic
- do not implement lockfile or graph parsers here

Validation to run:
- `zig build test`

Report back with:
- parser API
- test coverage summary
- any unresolved schema ambiguities discovered

---

### Agent: `lock-graph-schema-lane`
**Type**: coding agent in worktree
**Depends on**: Wave 1 schema core

**Prompt**

Implement:
- `zpkg.lock.zon` parser/validator
- `zpkg.graph.zon` parser/validator
- `manifest.zon` parser/validator

Use:
- `docs/zpkg-lockfile.md`
- `docs/zpkg-graph-schema.md`
- `docs/implementation/phase-01-schema-and-model.md`

Scope:
- create:
  - `src/schema/lockfile.zig`
  - `src/schema/graph.zig`
  - `src/schema/manifest.zig`
  - supporting model files if needed
- add unit tests and golden tests

Constraints:
- preserve dependency aliases in lockfile direct edges
- model graph target metadata fully enough for later wrapper emission
- do not implement resolution logic yet

Validation to run:
- `zig build test`

Report back with:
- parser/model files created
- any assumptions later lanes should honor

---

## Wave 2 review gate

After `package-schema-lane` and `lock-graph-schema-lane` finish:

- review each lane independently
- fix required findings in the original lane
- re-review before merge

Do not start Wave 3 until both schema lanes have reviewer approval.

## Wave 3 - Hashing and resolution spine

Launch after Wave 2 merges.

### Agent: `hashing-lane`
**Type**: coding agent in worktree
**Depends on**: Wave 2

**Prompt**

Implement Phase 02 from:
- `docs/zpkg-mvp-architecture.md`
- `docs/implementation/phase-02-hashing-and-identity.md`

Scope:
- in-process source hashing aligned with `build.zig.zon.paths`
- toolchain fingerprint modeling
- instance-key derivation
- unit tests for ABI vs non-ABI effects and domain effects

Constraints:
- keep hash inputs inspectable
- do not implement CLI command changes beyond small supporting hooks unless necessary

Validation to run:
- `zig build test`

Report back with:
- key API entrypoints
- test cases proving stability and expected invalidation

---

### Agent: `resolver-lane`
**Type**: coding agent in worktree
**Depends on**: Wave 2, ideally after hashing APIs are at least stubbed or merged

**Prompt**

Implement Phase 03 from:
- `docs/zpkg-lockfile.md`
- `docs/implementation/phase-03-resolution-and-lockfile.md`

Scope:
- resolver core for exact MVP constraints
- lockfile semantic model use
- drift detection
- `lock` and `update` commands
- failure gating for missing/stale lockfiles in `build`, `test`, and `export`

Constraints:
- lockfile is authoritative
- normal build/test/export must not silently rewrite lockfile
- preserve alias mapping in resolved edges

Validation to run:
- `zig build test`
- `zig build run -- lock <example-root>`
- `zig build run -- update <example-root> --dry-run`

Report back with:
- files changed
- supported workflow status
- any remaining integration dependency on hashing lane

---

## Wave 3 review gate

After `hashing-lane` and `resolver-lane` finish:

- review each lane independently
- send required findings back to the original lane
- re-review until approval

Do not start Wave 4 until both lanes have reviewer approval.

## Wave 4 - Main parallel window

Launch after resolver lane merges.

### Agent: `store-lane`
**Type**: coding agent in worktree
**Depends on**: Wave 3 resolver

**Prompt**

Implement Phase 04 from:
- `docs/zpkg-mvp-architecture.md`
- `docs/implementation/phase-04-store-and-manifest.md`

Scope:
- store layout/path derivation
- manifest read/write
- archive/extract
- idempotent expansion
- integrity diagnostics

Constraints:
- internal store semantics stay distinct from export semantics
- keep APIs narrow and reusable by realization/build/export lanes

Validation to run:
- `zig build test`
- any integration tests for fake prefix store round-trip

Report back with:
- store API
- test coverage
- assumptions realization/export lanes should rely on

---

### Agent: `wrapper-lane`
**Type**: coding agent in worktree
**Depends on**: Wave 3 resolver and Wave 2 graph schema

**Prompt**

Implement Phase 05 from:
- `docs/zpkg-graph-schema.md`
- `docs/implementation/phase-05-zpkg-build-and-graph.md`

Scope:
- create `pkg/zpkg-build/`
- implement mandatory wrapper API
- emit `zpkg.graph.zon` at configure time
- implement strict validation against `zpkg.zon`
- migrate example packages to `zpkg-build` once wrapper API is usable

Constraints:
- wrappers are mandatory for first-party packages
- build registration must use dependency aliases
- exported/public targets must validate strictly against declarations

Validation to run:
- `zig build test`
- configure example packages and parse emitted `zpkg.graph.zon`

Report back with:
- wrapper API summary
- migrated examples
- validation behavior implemented

---

### Agent: `cli-inspect-graph-lane`
**Type**: coding agent in worktree
**Depends on**: Wave 3 resolver, Wave 2 schemas

**Prompt**

Implement the inspect/graph/help UX portions from:
- `docs/implementation/phase-08-cli-and-ux.md`
- plus the relevant schema docs

Scope:
- stabilize root CLI help and command dispatch
- implement `inspect`
- implement `graph`
- `graph` should default to package graph
- verbose graph mode should include target graph data when available

Constraints:
- avoid overlapping with resolver command files except where main dispatch requires it
- diagnostics can be basic for now; polish comes later

Validation to run:
- `zig build run -- --help`
- `zig build run -- inspect <example-root>`
- `zig build run -- graph <example-root>`

Report back with:
- command behavior
- known gaps awaiting later lanes

---

## Wave 4 review gate

After `store-lane`, `wrapper-lane`, and `cli-inspect-graph-lane` finish:

- review each lane independently
- keep optional improvements separate from required findings
- merge only after approval

Do not start Wave 5 until the required predecessor lanes have reviewer approval.

## Wave 5 - Re-convergence on realization

Launch after store and wrapper lanes merge.

### Agent: `realization-lane`
**Type**: coding agent in worktree
**Depends on**: store + wrapper + resolver merged

**Prompt**

Implement Phase 06 from:
- `docs/implementation/phase-06-workspace-realization.md`

Scope:
- workspace layout planner
- source package realization
- binary adapter generation
- `realize` CLI command

Constraints:
- never mutate developer checkouts in place
- generate local-path-only realized packages
- adapters must expose enough metadata to look equivalent to source deps from consuming `build.zig`

Validation to run:
- `zig build test`
- `zig build run -- realize <example-root>`
- manually inspect realized workspace and run `zig build` inside it if possible

Report back with:
- files changed
- which example graphs realize successfully
- remaining prerequisites for full build fallback

---

## Wave 5 review gate

After `realization-lane` finishes:

- launch a clean reviewer subagent
- fix required findings in `realization-lane`
- re-review until approved

Do not start Wave 6 until realization has reviewer approval.

## Wave 6 - End-to-end build/test pipeline

Launch after realization lane merges.

### Agent: `build-pipeline-lane`
**Type**: coding agent in worktree
**Depends on**: realization merged

**Prompt**

Implement Phase 07 from:
- `docs/implementation/phase-07-build-fallback.md`

Scope:
- topological build planner
- source-build fallback executor
- store publication after source build
- warm-store reuse
- `build --with-tests`
- `test`

Constraints:
- treat host and target instances distinctly
- reuse identical resolved package instances across roles where possible
- MVP is shared-library-oriented

Validation to run:
- cold-store build of example graph
- warm-store repeat build
- `build --with-tests`
- `test`
- selective rebuild after deleting one artifact or changing one ABI option

Report back with:
- end-to-end status
- commands run
- any remaining adapter/store issues uncovered

---

## Wave 6 review gate

After `build-pipeline-lane` finishes:

- launch a clean reviewer subagent
- the reviewer should pay special attention to:
  - architecture compliance
  - domain handling
  - cache/store reuse behavior
  - adequacy of integration tests
- fix required findings and re-review until approved

Do not start Wave 7 until the build pipeline lane has reviewer approval.

## Wave 7 - Late parallel window

Launch after build pipeline lane is mostly working.

### Agent: `export-lane`
**Type**: coding agent in worktree
**Depends on**: build pipeline + store + realization

**Prompt**

Implement Phase 09 from:
- `docs/implementation/phase-09-export-and-relocation.md`

Scope:
- export closure planner
- relocatable bundle assembly
- package-rooted and target-rooted export
- byte-identical collision acceptance, differing-content collision failure

Constraints:
- target-domain closure by default
- lockfile required
- env/dev-shell activation is primary; direct execution where practical

Validation to run:
- `zig build run -- export <example-root>`
- unpack and validate via env activation
- collision tests

Report back with:
- export behavior implemented
- what kinds of bundles were tested successfully

---

### Agent: `ux-diagnostics-lane`
**Type**: coding agent in worktree
**Depends on**: build pipeline merged enough for realistic failures

**Prompt**

Implement the remaining UX/diagnostic polish from:
- `docs/implementation/phase-08-cli-and-ux.md`

Scope:
- improve diagnostics and summaries across commands
- ensure failures include package id, domain, instance key, and workspace path when known
- tighten help text and user-facing workflows
- update docs as needed for actual command behavior

Constraints:
- avoid changing architecture or command semantics

Validation to run:
- targeted negative tests for common failures
- command help review

Report back with:
- improved diagnostics examples
- docs updated

---

### Agent: `repro-ci-lane`
**Type**: coding agent in worktree
**Depends on**: build pipeline lane; export lane optional but helpful

**Prompt**

Implement Phase 10 from:
- `docs/implementation/phase-10-reproducibility-and-ci.md`

Scope:
- deterministic output audit
- cold/warm store CI jobs
- reproducibility documentation

Constraints:
- compare semantic outputs, not just ad hoc logs
- document what does and does not affect binary identity

Validation to run:
- CI or equivalent local scripts for cold/warm builds
- repeated realization comparison

Report back with:
- CI matrix added
- deterministic behaviors verified
- remaining nondeterminism if any

---

## Wave 7 review gate

After `export-lane`, `ux-diagnostics-lane`, and `repro-ci-lane` finish:

- review each lane independently
- required findings go back to the original lane
- optional improvements go to the Manager backlog

Final completion requires reviewer approval for all late-wave lanes.

## Minimal launch set if you want fewer agents

If you want a smaller initial batch, use this reduced sequence:

1. `bootstrap-lane`
2. `schema-core-lane`
3. `package-schema-lane`
4. `lock-graph-schema-lane`
5. `hashing-lane`
6. `resolver-lane`
7. in parallel:
   - `store-lane`
   - `wrapper-lane`
   - `cli-inspect-graph-lane`
8. `realization-lane`
9. `build-pipeline-lane`
10. in parallel:
   - `export-lane`
   - `ux-diagnostics-lane`
   - `repro-ci-lane`

---

## Suggested first actual launch order

If launching immediately, I recommend this exact order:

1. `bootstrap-lane`
2. `example-fixtures-lane`
3. `schema-core-lane`
4. after 3 merges:
   - `package-schema-lane`
   - `lock-graph-schema-lane`
5. after 4 merges:
   - `hashing-lane`
   - `resolver-lane`
6. after resolver merges:
   - `store-lane`
   - `wrapper-lane`
   - `cli-inspect-graph-lane`
7. after store + wrapper merge:
   - `realization-lane`
8. after realization merges:
   - `build-pipeline-lane`
9. after build pipeline is green:
   - `export-lane`
   - `ux-diagnostics-lane`
   - `repro-ci-lane`

This gives the best balance between throughput and merge risk.

In all cases, treat a lane as merged/complete only after reviewer approval.
