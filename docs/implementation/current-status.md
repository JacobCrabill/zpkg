# Current Implementation Status

_Last updated: 2026-06-29 (Phase 17 complete)_

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
- HEAD: `7265fa7` — `Implement Phase 17: ZON parser hardening`
- Working tree: clean

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
| Phase 04 - Store and manifest mgmt | Approved and merged | Store layout, manifest, archive, Store facade; reviewed and fixed |
| Phase 05 - `zpkg-build` and graph emission | Approved and merged | Package API, emit, validate, hello-lib migrated; reviewed and fixed |
| Phase 06 - Workspace realization | Approved and merged | WorkspaceLayout, source symlink-forest, binary adapter, realize CLI |
| Phase 07 - Build fallback pipeline | Approved and merged | Topo planner, executor, zpkg build/test CLI; reviewed and fixed |
| Phase 08 - CLI and UX | Approved and merged | graph command, diag helpers, CLI polish, quickstart doc |
| Phase 09 - Export and relocation | Approved and merged | planExport, assembleBundle, collision policy, zpkg export CLI |
| Phase 10 - Reproducibility and CI | Approved and merged | determinism sort fix, reproducibility doc, CI workflow |
| Phase 12 - Resolver and lockfile completion | Approved and merged | parseDependencyManifest reads real zpkg.zon; generateLockfile walks resolved graph; fingerprint and extra-dep fixes in workspace build.zig.zon |
| Phase 13 - Source hash, per-command help, realize fix, root build | Approved and merged | real source_hash at lock time; --help for all subcommands; workspace fingerprint fix; zpkg build now builds root package and symlinks zig-out |
| Phase 14 - Binary adapter integration | Complete | Warm-store path works: noopMake + generated_bin redirect; no .o extraction; dep.artifact() transparent across source and binary paths |
| Phase 15 - Content-addressed store keys | Complete | Store dirs are 64-char hex digests; toolchain detected at build time; double-free and fallbackHex findings fixed |
| Phase 16 - Source location model | Complete | explicit source_path in zpkg.zon + lockfile; source_dirs tracked in Resolver; paths normalized via std.fs.path.resolve |
| Phase 17 - ZON parser hardening | Complete | zon_util AST parsing for all build.zig.zon reads; patchFingerprint parse-and-regenerate; PackageCache OOM fixed |
| Phase 18 - Parallel builds | Not started | P2: wave-based concurrent dispatch for independent packages in build executor |

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

Phases 00–15 implemented, reviewed, and merged.

### Known stubs (non-blocking)

- **`TargetKind.test_suite`**: `hello-tests` uses `.executable`; no enum variant exists yet
- **Named-target filter completeness**: `LockfileInstance.target_name` is always `null` (resolver tracks package+domain only)
- **null `target_name` backward-compat test**: correct behavior, no explicit test

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

Milestone A (Schemas, hashes, resolution) is complete. Milestone B (Store, wrappers, realization) is complete. Milestone C (End-to-end build) is complete.

A post-MVP architecture review identified four correctness issues requiring follow-up work, documented in `docs/follow-up.md` and in phases 14–18 under `docs/implementation/`.

**Recommended next actions (in order of priority):**

1. **Phase 16** (P1) — source location model
2. **Phase 17** (P2) and **Phase 18** (P2) — can be done in parallel after P1

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
