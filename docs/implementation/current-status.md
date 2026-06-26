# Current Implementation Status

_Last updated by Manager: 2026-06-26_

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
- HEAD: `c880b80`
- HEAD summary: `Require full toolchain fingerprint identity`
- Working tree: clean

### Relevant stash entries

- `stash@{0}` — `On main: manager-temp-resolver-before-cleanup`
  - created to preserve an earlier uncommitted resolver work-in-progress before switching strategy
- `stash@{1}` — `On pi-agent-cab269d3-3183-48d: manager-temp-untracked`
  - older schema-core management stash

---

## Phase summary

| Phase | Status | Notes |
|---|---|---|
| Phase 00 - Bootstrap | Approved and merged | Root scaffold complete and reviewed |
| Phase 01 - Schema and model | Approved and merged | Includes `zpkg.zon`, lockfile, graph, and manifest parsing foundations, plus inspect command |
| Phase 02 - Hashing and identity | In progress | Toolchain + instance-key subtask implemented and committed; source-hash subtask still missing |
| Phase 03 - Resolution and lockfile | In progress | No approved resolver implementation on `main` yet |
| Phase 04 - Store and manifest mgmt | Not started | Waiting on Phases 02 and 03 |
| Phase 05 - `zpkg-build` and graph emission | Not started | Waiting on Phases 02 and 03 |
| Phase 06 - Workspace realization | Not started | Waiting on Phases 04 and 05 |
| Phase 07 - Build fallback pipeline | Not started | Waiting on Phase 06 |
| Phase 08 - CLI and UX | Partial | `inspect` exists; broader CLI remains incomplete |
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

---

## Current active / unresolved work

### Phase 02 - Source-hash subtask

**Status:** not implemented yet

Multiple agent attempts stalled in reconnaissance without producing code on `main`:
- `1945ae39-591d-4f6` — reconnaissance only
- `0339030d-f1fa-479` — reconnaissance only
- `55daf1aa-304c-447` — reconnaissance only
- `384e9c7d-8723-441` — reconnaissance only
- `9d60f0fd-0f34-400` — reconnaissance only

**Current truth:**
- `src/hash/source_hash.zig` does not exist on `main`
- `src/hash/root.zig` does not yet export a source-hash module
- no source-hash tests exist on `main`

**Required next step:**
- launch or continue a tightly-scoped developer lane that directly implements `src/hash/source_hash.zig` and tests

### Phase 03 - Resolver / lockfile authority

**Status:** not implemented on `main`

There were multiple partial resolver attempts, but none are approved or merged:
- `66e93a0d-3f2e-4e0` — partial broad Phase 03 implementation in working tree, later stashed
- `869ffb99-6e25-419` — partial fix attempt, branch commit exists but not complete/reviewable
  - branch: `pi-agent-869ffb99-6e25-419`
  - commit: `7df9ae5`
- `de874d74-6a9b-42f` — partial resolver-core attempt

**Current truth on `main`:**
- `src/resolve/root.zig` is still placeholder-level for actual resolver behavior
- no approved resolver core exists on `main`
- lock/update/build/test/export authority-gate flows are not implemented on `main`

**Required next step:**
- complete a fresh resolver-core lane from clean `main`
- then review/merge it
- then implement the broader lock/update/build/test/export authority-gate layer if still separate

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

### Open / still relevant

These are the unresolved areas still needing closure:
- source-hash implementation lane: **none successfully landed yet**
- resolver-core implementation lane: partial attempts exist, but **none approved/merged**

---

## Blocking items

1. **Phase 02 source hash is missing**
   - blocks full completion of hashing/identity
   - resolver may temporarily use placeholders, but Phase 02 cannot be called done

2. **Phase 03 resolver/authority implementation is missing on `main`**
   - blocks later lanes that need a stable resolved graph

3. **Main parallel window cannot start safely**
   - `store-lane`
   - `wrapper-lane`
   - `cli-inspect-graph-lane`
   should wait until both Phase 02 and Phase 03 are approved and merged

---

## Recommended immediate next actions

1. Finish and approve **Phase 02 source-hash subtask**
2. Finish and approve **Phase 03 resolver-core**
3. If needed, follow resolver-core with a second focused **lock/update/build/test/export gate** lane
4. Only then start:
   - store-lane
   - wrapper-lane
   - cli-inspect-graph-lane

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
