# Ready-to-Launch Subagent Invocations

## Purpose

This file contains copy/adapt-and-launch subagent invocation specs for implementing `zpkg` in waves.

These are based on:

- `docs/implementation/subagent-launch-plan.md`
- `docs/implementation/README.md`
- all root architecture/schema docs

---

## Recommended launch mechanism

Use `Agent` for coding lanes, with:

- `subagent_type: "general-purpose"`
- `isolation: "worktree"`
- `run_in_background: true`

Why:

- parallel coding is safer in isolated worktrees
- each lane can run independently
- later follow-up can use `resume` with the returned agent ID

### Recommended defaults

```json
{
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 12,
  "run_in_background": true,
  "isolation": "worktree"
}
```

You can reduce `max_turns` for tightly scoped lanes or increase it for wrapper/build pipeline lanes.

---

## Common coding instructions

Include this guidance in every lane prompt.

```text
Read these docs first:
- docs/zpkg-mvp-architecture.md
- docs/zpkg-implementation-plan.md
- docs/implementation/README.md
- docs/implementation/review-process.md
- the relevant phase file under docs/implementation/
- and, when applicable:
  - docs/zpkg-schema.md
  - docs/zpkg-lockfile.md
  - docs/zpkg-graph-schema.md

Treat these as fixed invariants:
- zpkg.zon = constraints + package contract
- zpkg.lock.zon = authoritative exact resolution
- zpkg.graph.zon = configure-time emitted target graph
- zpkg-build wrappers are mandatory for first-party packages
- resolution identity is per (package_id, domain)

Requirements:
- Add tests with the implementation.
- Do not expand scope into neighboring lanes unless explicitly needed.
- At the end, report:
  - files changed
  - tests/commands run
  - open issues / follow-up suggestions
```

---

## Standard reviewer invocation template

Use this after every developer lane completes.

```json
{
  "description": "Review completed lane",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 8,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "You are reviewing a completed implementation lane. Read docs/zpkg-mvp-architecture.md, docs/zpkg-implementation-plan.md, docs/implementation/README.md, docs/implementation/review-process.md, the specific docs/implementation/phase-XX-...md file for the lane, and any relevant schema docs first. Review the implementation against the phase task definition, the architecture and schema docs, the lane prompt, and general code quality and maintainability expectations. Do not make code changes. Return: 1. Required findings that must be fixed before approval, 2. Optional improvements that should be reported to the Manager for possible follow-up tasks, 3. A final verdict: approve or changes required."
}
```

### Review loop rule

For every developer lane:

1. launch the developer lane
2. when it finishes, launch a clean reviewer subagent
3. if the reviewer returns required findings, resume the developer lane and fix them
4. re-run review until the reviewer approves
5. only then merge and advance dependent waves

---

## Wave 0 - Bootstrap

Launch this first, alone.

### `bootstrap-lane`

```json
{
  "description": "Bootstrap repo skeleton",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 10,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement Phase 00 from docs/implementation/phase-00-bootstrap.md. Read docs/zpkg-mvp-architecture.md, docs/zpkg-implementation-plan.md, docs/implementation/README.md, and docs/implementation/phase-00-bootstrap.md first. Scope: create the root Zig package/build files, create src/main.zig, create the root module directory layout under src/, wire a basic test target, standardize .zpkg/ as generated workspace root, and make zig build, zig build test, and zig build run -- --help work. Constraints: do not implement real schema or business logic yet; keep placeholders small but compile-clean; do not touch docs except if a build-file comment is necessary. Validation to run: zig build; zig build test; zig build run -- --help. At the end, report files changed, commands run, and any structural decisions later lanes must know."
}
```

### Review and merge gate before next wave

After `bootstrap-lane` completes, launch a clean reviewer subagent using the standard reviewer template.
If required findings are returned:
- resume `bootstrap-lane`
- fix the findings
- re-run review until approved

Do not launch later waves until:

- root `zig build` works
- root `zig build test` works
- root CLI help works
- reviewer approval exists for `bootstrap-lane`

---

## Wave 1 - Early foundation split

Launch these after `bootstrap-lane` is merged.

### `example-fixtures-lane`

```json
{
  "description": "Create example fixtures",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 10,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement the example/fixture scaffolding from docs/implementation/phase-00-bootstrap.md and docs/implementation/phase-08-cli-and-ux.md. Read docs/zpkg-mvp-architecture.md, docs/implementation/README.md, docs/implementation/phase-00-bootstrap.md, and docs/implementation/phase-08-cli-and-ux.md first. Scope: create example package roots examples/hello-lib/, examples/hello-headers/, examples/hello-tool/, examples/hello-app/, and examples/hello-tests/. Each should have placeholder build.zig, build.zig.zon, and zpkg.zon. Establish test fixture directories for future golden/integration tests. Constraints: keep examples minimal and compile-clean where possible; do not implement zpkg-build yet; avoid touching root CLI files. Validation: run plain zig build in any examples that are already compilable; if some are intentionally incomplete, note exactly why. Report fixture tree created, which examples compile, and which are placeholders for later migration."
}
```

### `schema-core-lane`

```json
{
  "description": "Implement core model",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 12,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement the shared scalar/domain model from docs/zpkg-schema.md, docs/zpkg-lockfile.md, docs/zpkg-graph-schema.md, and docs/implementation/phase-01-schema-and-model.md. Read those docs first. Scope: implement shared model files for version parsing/normalization/comparison, package ids, option values/types, conditions, and domains (host, target). Add unit tests. Constraints: do not implement top-level schema parsers yet; expose clean APIs that schema lanes can import. Validation: zig build test. Report files changed and any API surfaces schema parsers should depend on."
}
```

### Review and merge gate before next wave

Review both `example-fixtures-lane` and `schema-core-lane` with clean reviewer subagents.
Required findings go back to the original lane. Optional improvements go to the Manager backlog.

Wait for:

- core scalar/domain types to merge
- example package roots to exist
- reviewer approval for both lanes

---

## Wave 2 - Schema layer

Launch these two in parallel after `schema-core-lane` merges.

### `package-schema-lane`

```json
{
  "description": "Implement zpkg schema",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 14,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement the zpkg.zon parser/validator from docs/zpkg-schema.md and docs/implementation/phase-01-schema-and-model.md. Read docs/zpkg-schema.md, docs/implementation/README.md, and docs/implementation/phase-01-schema-and-model.md first. Scope: implement src/schema/zpkg.zig and any supporting package/target model files needed; validate package identity/version, options, dependency alias universe, target declarations, and conditions; reject invalid MVP forms such as unsupported target kinds, malformed versions, bad linkage placement, or invalid condition placement; add parser tests and golden tests. Constraints: keep output normalized and semantic; do not implement lockfile or graph parsers here. Validation: zig build test. Report parser API, test coverage summary, and any unresolved schema ambiguities discovered."
}
```

### `lock-graph-schema-lane`

```json
{
  "description": "Implement lock graph schemas",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 14,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement zpkg.lock.zon, zpkg.graph.zon, and manifest.zon parsers/validators. Read docs/zpkg-lockfile.md, docs/zpkg-graph-schema.md, docs/implementation/README.md, and docs/implementation/phase-01-schema-and-model.md first. Scope: create src/schema/lockfile.zig, src/schema/graph.zig, src/schema/manifest.zig, plus supporting model files if needed; add unit tests and golden tests. Constraints: preserve dependency aliases in lockfile direct edges; model graph target metadata fully enough for later wrapper emission; do not implement resolution logic yet. Validation: zig build test. Report parser/model files created and any assumptions later lanes should honor."
}
```

### Review and merge gate before next wave

Review both schema lanes with clean reviewer subagents.
Fix required findings in the original lane and re-review before merge.

Wait for:

- `zpkg.zon` parser merged
- `lockfile`, `graph`, and `manifest` parsers merged
- schema tests passing
- reviewer approval for both lanes

---

## Wave 3 - Hashing and resolution spine

Launch these after Wave 2 merges.

### `hashing-lane`

```json
{
  "description": "Implement hashing identity",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 14,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement Phase 02 from docs/implementation/phase-02-hashing-and-identity.md. Read docs/zpkg-mvp-architecture.md, docs/implementation/README.md, and docs/implementation/phase-02-hashing-and-identity.md first. Scope: implement in-process source hashing aligned with build.zig.zon.paths semantics, toolchain fingerprint modeling, and instance-key derivation. Add unit tests for ABI vs non-ABI effects and host/target domain effects. Constraints: keep hash inputs inspectable; do not implement unrelated CLI work beyond small supporting hooks if necessary. Validation: zig build test. Report key API entrypoints and test cases proving stability and expected invalidation."
}
```

### `resolver-lane`

```json
{
  "description": "Implement resolver lockfile",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 16,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement Phase 03 from docs/zpkg-lockfile.md and docs/implementation/phase-03-resolution-and-lockfile.md. Read docs/zpkg-mvp-architecture.md, docs/zpkg-lockfile.md, docs/implementation/README.md, and docs/implementation/phase-03-resolution-and-lockfile.md first. Scope: resolver core for exact MVP constraints, lockfile semantic model use, drift detection, lock and update commands, and failure gating for missing/stale lockfiles in build, test, and export. Constraints: lockfile is authoritative; normal build/test/export must not silently rewrite it; preserve alias mapping in resolved edges. Validation: zig build test; zig build run -- lock <example-root>; zig build run -- update <example-root> --dry-run. Report files changed, supported workflow status, and any remaining integration dependency on hashing lane."
}
```

### Review and merge gate before next wave

Review `hashing-lane` and `resolver-lane` independently.
Required findings go back to the corresponding lane.

Wait for:

- identity/hash APIs merged
- exact resolver and lockfile gating merged
- `lock` / `update` basic flow working
- reviewer approval for both lanes

---

## Wave 4 - Main parallel window

Launch these in parallel after `resolver-lane` merges.

### `store-lane`

```json
{
  "description": "Implement local store",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 14,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement Phase 04 from docs/implementation/phase-04-store-and-manifest.md. Read docs/zpkg-mvp-architecture.md, docs/implementation/README.md, and docs/implementation/phase-04-store-and-manifest.md first. Scope: store layout/path derivation, manifest read/write, archive/extract, idempotent expansion, and integrity diagnostics. Constraints: internal store semantics stay distinct from export semantics; keep APIs narrow and reusable by realization/build/export lanes. Validation: zig build test and any integration tests for fake prefix store round-trip. Report store API, test coverage, and assumptions realization/export lanes should rely on."
}
```

### `wrapper-lane`

```json
{
  "description": "Implement zpkg build wrappers",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 18,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement Phase 05 from docs/zpkg-graph-schema.md and docs/implementation/phase-05-zpkg-build-and-graph.md. Read docs/zpkg-mvp-architecture.md, docs/zpkg-graph-schema.md, docs/implementation/README.md, and docs/implementation/phase-05-zpkg-build-and-graph.md first. Scope: create pkg/zpkg-build/, implement the mandatory wrapper API, emit zpkg.graph.zon at configure time, implement strict validation against zpkg.zon, and migrate example packages to zpkg-build once the wrapper API is usable. Constraints: wrappers are mandatory for first-party packages; build registration must use dependency aliases; exported/public targets must validate strictly against declarations. Validation: zig build test; configure example packages and parse emitted zpkg.graph.zon. Report wrapper API summary, migrated examples, and validation behavior implemented."
}
```

### `cli-inspect-graph-lane`

```json
{
  "description": "Implement inspect graph UX",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 12,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement the inspect/graph/help UX portions from docs/implementation/phase-08-cli-and-ux.md plus the relevant schema docs. Read docs/implementation/README.md, docs/implementation/phase-08-cli-and-ux.md, docs/zpkg-schema.md, docs/zpkg-lockfile.md, and docs/zpkg-graph-schema.md first. Scope: stabilize root CLI help and command dispatch, implement inspect, and implement graph. graph should default to package graph and verbose graph mode should include target graph data when available. Constraints: avoid overlapping with resolver command files except where main dispatch requires it; diagnostics can be basic for now. Validation: zig build run -- --help; zig build run -- inspect <example-root>; zig build run -- graph <example-root>. Report command behavior and known gaps awaiting later lanes."
}
```

### Review and merge gate before next wave

Review `store-lane`, `wrapper-lane`, and `cli-inspect-graph-lane` independently.
Optional improvements should not block merge unless they reveal a correctness or spec issue.

Wait for:

- store APIs merged
- `zpkg-build` wrappers and `zpkg.graph.zon` emission merged
- examples migrated enough to emit graphs
- reviewer approval for all required predecessor lanes

---

## Wave 5 - Re-convergence on realization

Launch after store + wrapper lanes merge.

### `realization-lane`

```json
{
  "description": "Implement realization workspace",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 16,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement Phase 06 from docs/implementation/phase-06-workspace-realization.md. Read docs/zpkg-mvp-architecture.md, docs/implementation/README.md, and docs/implementation/phase-06-workspace-realization.md first. Scope: workspace layout planner, source package realization, binary adapter generation, and the realize CLI command. Constraints: never mutate developer checkouts in place; generate local-path-only realized packages; adapters must expose enough metadata to look equivalent to source deps from consuming build.zig. Validation: zig build test; zig build run -- realize <example-root>; manually inspect realized workspace and run zig build inside it if possible. Report files changed, which example graphs realize successfully, and remaining prerequisites for full build fallback."
}
```

### Review and merge gate before next wave

Review `realization-lane` with a clean reviewer subagent.
If required findings are returned, resume the same lane and re-review.

Wait for:

- `realize` works on at least the example graph
- source and binary package materialization are both implemented
- reviewer approval for `realization-lane`

---

## Wave 6 - End-to-end build/test pipeline

Launch after realization lane merges.

### `build-pipeline-lane`

```json
{
  "description": "Implement build pipeline",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 18,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement Phase 07 from docs/implementation/phase-07-build-fallback.md. Read docs/zpkg-mvp-architecture.md, docs/implementation/README.md, and docs/implementation/phase-07-build-fallback.md first. Scope: topological build planner, source-build fallback executor, store publication after source build, warm-store reuse, build --with-tests, and test. Constraints: treat host and target instances distinctly; reuse identical resolved package instances across roles where possible; MVP is shared-library-oriented. Validation: cold-store build of example graph; warm-store repeat build; build --with-tests; test; selective rebuild after deleting one artifact or changing one ABI option. Report end-to-end status, commands run, and any remaining adapter/store issues uncovered."
}
```

### Review and merge gate before next wave

Review `build-pipeline-lane` with a clean reviewer subagent.
Reviewer should pay special attention to architecture compliance, domain handling, store reuse behavior, and adequacy of integration tests.

Wait for:

- cold-store build works
- warm-store build reuses artifacts
- test mode behavior works as specified
- reviewer approval for `build-pipeline-lane`

---

## Wave 7 - Late parallel window

Launch these in parallel once the build pipeline is mostly green.

### `export-lane`

```json
{
  "description": "Implement export relocation",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 16,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement Phase 09 from docs/implementation/phase-09-export-and-relocation.md. Read docs/zpkg-mvp-architecture.md, docs/implementation/README.md, and docs/implementation/phase-09-export-and-relocation.md first. Scope: export closure planner, relocatable bundle assembly, package-rooted and target-rooted export, and byte-identical collision acceptance with differing-content collision failure. Constraints: target-domain closure by default; lockfile required; env/dev-shell activation is primary; direct execution where practical. Validation: zig build run -- export <example-root>; unpack and validate via env activation; collision tests. Report export behavior implemented and what kinds of bundles were tested successfully."
}
```

### `ux-diagnostics-lane`

```json
{
  "description": "Polish UX diagnostics",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 12,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement the remaining UX/diagnostic polish from docs/implementation/phase-08-cli-and-ux.md. Read docs/implementation/README.md and docs/implementation/phase-08-cli-and-ux.md first. Scope: improve diagnostics and summaries across commands, ensure failures include package id, domain, instance key, and workspace path when known, tighten help text, and update docs as needed for actual command behavior. Constraints: avoid changing architecture or command semantics. Validation: targeted negative tests for common failures and command help review. Report improved diagnostics examples and docs updated."
}
```

### `repro-ci-lane`

```json
{
  "description": "Implement repro and ci",
  "subagent_type": "general-purpose",
  "thinking": "medium",
  "max_turns": 14,
  "run_in_background": true,
  "isolation": "worktree",
  "prompt": "Implement Phase 10 from docs/implementation/phase-10-reproducibility-and-ci.md. Read docs/zpkg-mvp-architecture.md, docs/implementation/README.md, and docs/implementation/phase-10-reproducibility-and-ci.md first. Scope: deterministic output audit, cold/warm store CI jobs, and reproducibility documentation. Constraints: compare semantic outputs, not just ad hoc logs; document what does and does not affect binary identity. Validation: CI or equivalent local scripts for cold/warm builds and repeated realization comparison. Report CI matrix added, deterministic behaviors verified, and remaining nondeterminism if any."
}
```

---

### Final review gate

Review `export-lane`, `ux-diagnostics-lane`, and `repro-ci-lane` independently with clean reviewer subagents.

Required findings must be sent back to the original developer lane for correction.
Optional improvements should be recorded by the Manager as follow-up tasks.

Do not mark the implementation complete until all late-wave lanes have reviewer approval.

## Practical first launch set

If you want the smallest useful initial kickoff, launch in this order:

1. `bootstrap-lane`
2. after merge:
   - `example-fixtures-lane`
   - `schema-core-lane`
3. after merge:
   - `package-schema-lane`
   - `lock-graph-schema-lane`
4. after merge:
   - `hashing-lane`
   - `resolver-lane`
5. after merge:
   - `store-lane`
   - `wrapper-lane`
   - `cli-inspect-graph-lane`

That is the best stopping point before the big realization/build convergence work.

Remember: every lane merge should happen only after reviewer approval.

---

## Resume guidance

When a lane finishes, save:

- the returned agent ID
- the lane name
- whether its worktree contains changes to cherry-pick/merge

For follow-up, use `resume` with the same agent ID instead of creating a fresh agent.

Suggested tracking table:

```text
bootstrap-lane        -> <agent_id>
example-fixtures-lane -> <agent_id>
schema-core-lane      -> <agent_id>
package-schema-lane   -> <agent_id>
lock-graph-schema-lane-> <agent_id>
hashing-lane          -> <agent_id>
resolver-lane         -> <agent_id>
store-lane            -> <agent_id>
wrapper-lane          -> <agent_id>
cli-inspect-graph-lane-> <agent_id>
realization-lane      -> <agent_id>
build-pipeline-lane   -> <agent_id>
export-lane           -> <agent_id>
ux-diagnostics-lane   -> <agent_id>
repro-ci-lane         -> <agent_id>
```
