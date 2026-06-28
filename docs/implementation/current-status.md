# Current Implementation Status

_Last updated by Manager: 2026-06-28_

## Source of truth

This file is the live status ledger for the subagent-based implementation.

It should be updated whenever any of the following happens:

- a developer lane starts
- a developer lane reports completion or times out
- a reviewer returns findings
- required findings are fixed
- a lane is approved
- a lane is merged to `main`
- a task is intentionally abandoned/superseded
- a stash or branch is created that matters to later recovery

This file should track the **current exact state**, not an idealized plan.

---

## Repository state

- Branch: `main`
- HEAD: `926a907` (about to advance)
- HEAD summary: `Update status: Phase 02 complete, Phase 03 is next`
- Working tree: Phase 03 implementation complete, reviewed, all required findings fixed — ready to commit

### Relevant stash entries

- None currently in use

---

## Phase summary

| Phase | Status | Notes |
|---|---|---|
| Phase 00 - Bootstrap | Approved and merged | Root scaffold complete and reviewed |
| Phase 01 - Schema and model | Approved and merged | Includes `zpkg.zon`, lockfile, graph, and manifest parsing foundations, plus inspect command |
| Phase 02 - Hashing and identity | Approved and merged | Toolchain + instance-key + source-hash complete |
| Phase 03 - Resolution and lockfile | Approved and merged | Resolver core, drift detection, `lock`/`update` CLI complete; reviewed and fixed |
| Phase 04 - Store and manifest mgmt | Not started | Waiting on Phase 03 |
| Phase 05 - `zpkg-build` and graph emission | Not started | Waiting on Phase 03 |
| Phase 06 - Workspace realization | Not started | Waiting on Phase 05 |
| Phase 07 - Build fallback pipeline | Not started | Waiting on Phase 06 |
| Phase 08 - CLI and UX | Partial | `inspect`, `lock`, `update` exist; broader CLI remains incomplete |
| Phase 09 - Export and relocation | Not started | Waiting on Phase 07 |
| Phase 10 - Reproducibility and CI | Not started | Waiting on Phases 07/09 |

---

## Completed and merged work

### Approved + merged lanes

1. **bootstrap-lane**
   - Outcome: root Zig package, build/test/run scaffold
   - Merged to `main`

2. **example-fixtures-lane**
   - Outcome: example package tree and test fixture directories
   - Merged to `main`

3. **schema-core-lane**
   - Outcome: shared model primitives (`Version`, `PackageId`, options, conditions, domains)
   - Merged to `main`

4. **package-schema-lane**
   - Outcome: `zpkg.zon` parsing/validation foundation
   - Merged to `main`

5. **lock-graph-schema-lane**
   - Outcome: lockfile / graph / manifest schema foundation
   - Merged to `main`

6. **package-schema follow-up fixes**
   - Outcome: working `zpkg inspect`, actionable `zpkg.zon` diagnostics
   - Merged to `main`

7. **manifest dependency identity follow-up**
   - Outcome: manifest deps keyed by `<package_id>#<domain>`
   - Merged to `main`

8. **toolchain + instance-key core**
   - Outcome: toolchain fingerprint model, serialization, digesting, instance-key derivation, root exports
   - Commits on `main`:
     - `71327f3` — `Implement toolchain fingerprint and instance key core`
     - `c880b80` — `Require full toolchain fingerprint identity`
   - Review status: approved

9. **source-hash core**
   - Outcome: source hashing module for package content hashing
   - Commits on `main`:
     - `e90a4a0` — `Implement source hash module with file hashing and directory traversal`
   - Review status: approved

10. **Phase 03 resolver core + lockfile authority**
   - Outcome: resolver core, drift detection module, `zpkg lock` and `zpkg update` CLI commands
   - Files: `src/resolve/root.zig`, `src/resolve/drift.zig`, `src/cli/lock.zig`, `src/cli/update.zig`, `src/model/lockfile.zig`
   - Review status: approved — 6 required findings fixed (double-free, dangling cache key, wrong arg index, file handle leak, string-literal UB in deinit)
   - Merged to `main`

---

## Current active / unresolved work

### Phase 04, 05, 06 - Next parallel window

**Status:** unlocked by Phase 03 merge

These lanes can now start:
- `store-lane` (Phase 04 — local binary store and manifest management)
- `wrapper-lane` (Phase 05 — `zpkg-build` helper package)
- `cli-inspect-graph-lane` (Phase 08 partial — `zpkg graph` command)

---

## Agent status ledger

### Closed / superseded

These agent outputs have already been accounted for and should not be used as the source of truth anymore:
- `c751581d-ab66-4b0` — bootstrap developer
- `3411eb9e-20a3-455` — early example-fixtures attempt
- `cab269d3-3183-48d` — schema-core developer
- `7e1f75a6-6f50-4ec` — package-schema developer
- `424c9bbf-7869-44e` — lock/graph-schema developer
- `e53b1c64-f19a-424` — package-schema fix attempt that stalled
- `02261565-dcb1-470` — manifest dep fix developer
- `389e6da2-6cbb-4aa` — hashing reconnaissance only
- `502cb973-1b20-4cb` — hashing reconnaissance only
- `681ee94e-be9e-441` / branch `pi-agent-681ee94e-be9e-441` — older toolchain-key branch snapshot, superseded by merged `main`
- `759a124f-1b58-4e7` / `ed9bb80d-1689-403` — older reviews against stale toolchain snapshots
- `1945ae39-591d-4f6` — source-hash reconnaissance only
- `0339030d-f1fa-479` — source-hash reconnaissance only
- `55daf1aa-304c-447` — source-hash reconnaissance only
- `384e9c7d-8723-441` — source-hash reconnaissance only
- `9d60f0fd-0f34-400` — source-hash reconnaissance only

### Open / still relevant

These are the unresolved areas still needing closure:
- **resolver-core implementation lane:** partial attempts exist, but **none approved/merged**

---

## Blocking items

None currently. Phase 03 is merged. Phases 04/05 parallel window is open.

---

## Recommended immediate next actions

Start parallel lanes for Phase 04 and Phase 05:
- `store-lane`: implement `src/store/layout.zig`, `src/store/manifest.zig`, `src/store/archive.zig`, `src/store/store.zig`
- `wrapper-lane`: implement `pkg/zpkg-build/` package and update example packages to use it
- After those: Phase 06 workspace realization

---

## How to update this file

When updating this file, always include:

- branch + HEAD commit
- whether working tree is clean
- which phases are:
  - not started
  - in progress
  - implemented awaiting review
  - approved and merged
  - blocked
- active/stale/superseded agent IDs
- any important stash/branch recovery points
- the exact next manager action
