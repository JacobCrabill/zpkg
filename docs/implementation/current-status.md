# Current Implementation Status

_Last updated: 2026-06-29 (Phases 19–28 planned; post-MVP review complete)_

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
- HEAD: `beef497` — `Update current-status: Phase 18 complete and merged`
- Working tree: modified (`examples/diamond/app/zpkg.lock.zon` regenerated with current paths)

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
| Phase 18 - Parallel builds | Complete | wave dispatch via std.Thread; --jobs N caps concurrency; validation-then-spawn prevents use-after-free on error |
| Phase 19 - Relative lockfile paths | Not started | Lockfile source_path values must be relative to enable team/CI sharing |
| Phase 20 - Source drift detection | Not started | Stale binaries used silently when source changes without re-locking |
| Phase 21 - zpkg-build mandate | Not started | Library packages missing zpkg-build registration; contract validation absent for deps |
| Phase 22 - Build profiles | Not started | All builds hardcoded to debug; no release/asan/coverage support |
| Phase 23 - Graph tree display | Not started | `zpkg graph` shows flat list instead of dependency tree |
| Phase 24 - Third-party wrapper packages | Not started | No story for wrapping non-zpkg upstream libraries (protobuf, gtest, etc.) |
| Phase 25 - Workspace manifest | Not started | No cross-app consistency enforcement; per-package lockfiles diverge silently |
| Phase 26 - zpkg-build code generation | Not started | Build.zig registration is verbose boilerplate duplicating zpkg.zon |
| Phase 27 - Store GC | Not started | Store grows indefinitely; no pruning of unused artifacts |
| Phase 28 - Version ranges | Not started | Only exact-version (`=`) constraints supported; `^`, `>=` deferred |

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

Phases 00–18 implemented, reviewed, and merged.  MVP core is functional: the diamond
example builds end-to-end (cold and warm store), the binary runs correctly, and all
tests pass.

A post-MVP architecture review (2026-06-29) validated correctness of Phases 14–18
and identified ten follow-up phases (19–28) required for the tool to be useful to
developers of a real large-scale multi-package C++ application.

### Known stubs (non-blocking for MVP)

- **`TargetKind.test_suite`**: `hello-tests` uses `.executable`; no enum variant exists yet
- **Named-target filter completeness**: `LockfileInstance.target_name` is always `null` (resolver tracks package+domain only)
- **null `target_name` backward-compat test**: correct behavior, no explicit test
- **Lockfile absolute paths**: `examples/diamond/app/zpkg.lock.zon` currently has absolute paths; addressed by Phase 19

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

No open agent lanes.  All prior lanes have been merged or superseded.

---

## Blocking items

None for the MVP.  Post-MVP phases 19–28 are prioritized below.

---

## Recommended next actions

Milestones A–D (MVP) are complete.  The tool is functional for the diamond toy example.

A post-MVP architecture review (2026-06-29) identified ten follow-up phases needed
before the tool is useful for a real large-scale multi-package C++ project.

### Priority tiers

| Tier | Meaning |
|---|---|
| **P0** | Makes the MVP unusable in practice (correctness or portability blocker) |
| **P1** | Required before the tool can be applied to a real project |
| **P2** | Important ergonomics or developer experience gaps |
| **P3** | Growth and scalability; needed before the tool can expand significantly |

### Recommended implementation order

| Phase | Priority | Title | Rationale |
|---|---|---|---|
| **19** | P0 | Relative lockfile paths | Absolute paths in lockfile prevent team/CI sharing; fixes portability |
| **20** | P0 | Source drift detection | Stale binaries used silently; correctness guarantee requires drift check |
| **21** | P1 | zpkg-build mandate | Library packages bypass contract validation; only app registers with zpkg-build |
| **22** | P1 | Build profiles | No release/asan/coverage builds; all profiles hardcoded to debug |
| **23** | P1 | Graph tree display | `zpkg graph` shows flat list; breaks diagnostic utility |
| **24** | P1 | Third-party wrapper packages | Real projects have external deps; no integration path exists today |
| **25** | P2 | Workspace manifest | Multiple apps diverge on shared dep versions; no enforcement |
| **26** | P2 | zpkg-build code generation | Boilerplate maintenance burden at scale (50+ packages) |
| **27** | P2 | Store GC | Store grows indefinitely on active machines |
| **28** | P3 | Version ranges | Exact-only constraints require mass edits on dependency upgrades |

### Parallelism opportunities

- Phases 19 and 20 are independent; can be implemented in parallel.
- Phase 21 depends on the diamond example being buildable (Phase 19 must land first,
  or the lockfile regenerated manually).
- Phase 22 is independent of 21; can proceed in parallel.
- Phase 23 requires understanding the root-instance gap (fixed cheaply in lock.zig);
  otherwise independent.
- Phase 24 is independent; can proceed after Phase 22 (needs profiles for test builds).
- Phases 25–28 are each independent of each other and can proceed in parallel once
  Phases 19–24 are complete.

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
