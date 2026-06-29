# zpkg Follow-Up Plan

This document catalogs issues found during a post-MVP architecture and implementation
review, organized by priority.  Phase documents for each concrete work item are linked
in-line and live under `docs/implementation/`.

The existing `docs/follow-up.md` note about `zpkg host` is preserved at the bottom.

---

## Priority tiers

| Tier | Meaning |
|---|---|
| **P0** | Blocks the stated core feature — the tool does not do what it claims |
| **P1** | Blocks real-world use — the MVP works only on the toy example |
| **P2** | Correctness / ergonomics — noticeable pain in daily use |
| **P3** | Future-proofing — needed before the tool can grow past first-party packages |

---

## P0 — Core correctness blockers

### P0-A: Binary adapter does not expose artifacts to consuming `build.zig` files

**Status: Resolved in Phase 14.**

The binary adapter now generates a real `build.zig` that exposes prebuilt archives
via the standard `dep.artifact("X")` API using a `noopMake` + `generated_bin` redirect.
Consuming `build.zig` files require no changes.  See the phase doc for full details.

---

### P0-B: Instance keys from `hash/instance_key.zig` are never used as store keys

**Phase doc:** `docs/implementation/phase-15-content-addressed-store.md`

The store key used throughout the build pipeline is the human-readable string
`<package_id>#<domain>` (e.g., `diamond.libA#target`).  The rigorous ABI-identity hash
computed by `src/hash/instance_key.zig` — which includes toolchain fingerprint, ABI
options, dep instance keys, optimize mode, and linkage — is never called anywhere in
the build path.

Consequences:
- Two machines with different C++ stdlib versions get the same store key and may
  exchange incompatible pre-built artifacts.
- Changing the optimize mode (Debug → ReleaseFast) does not invalidate the cache.
- The lockfile stores `source_hash` but not the actual content-addressed key, so it
  does not pin binary artifact identity.
- The toolchain fingerprint work (Phase 02) has no effect on cache correctness.

---

## P1 — Real-world use blockers

### P1-A: Source location discovery uses a fragile filesystem convention

**Phase doc:** `docs/implementation/phase-16-source-location-model.md`

Both `resolve/root.zig` and `realize/build_fallback.zig` find source packages by
stripping the last `.` component of the package ID and looking for `../basename`
relative to the root package:

```zig
// build_fallback.zig:246
const pkg_basename = if (std.mem.lastIndexOfScalar(u8, pkg_name, '.')) |dot_idx|
    pkg_name[dot_idx + 1 ..]
else pkg_name;
const source_dir = try std.Io.Dir.path.join(allocator, &.{ self.pkg_root, "..", pkg_basename });
```

This convention is not documented in `zpkg.zon`, not validated, and fails for any
non-flat directory layout.  It also means the package ID must encode the directory
name — an implicit coupling that breaks the moment packages live in subdirectories,
are renamed, or live in a different repository.

The fix is to add explicit source path configuration: either a `source_path` field in
`zpkg.zon`, a workspace-level manifest that maps package IDs to source roots, or both.

---

### P1-B: `zpkg.graph.zon` is committed to source control but is a generated file

The architecture doc describes `zpkg.graph.zon` as "emitted by `zpkg-build` at
configure time."  In practice the diamond example has it committed to source
(`examples/diamond/*/zpkg.graph.zon`), which creates a stale-file risk: editing
`build.zig` does not regenerate it until the next `zig build` run, but `zpkg` reads it
to plan the build without running `zig build`.

This is a chicken-and-egg problem.  Options:

1. **`zpkg` derives the target graph directly from `zpkg.zon`** (the declared targets
   and deps are already there).  Eliminate `zpkg.graph.zon` as a committed artifact;
   keep it only as a transient configure-time product inside the workspace.

2. **Make `zpkg` regenerate `zpkg.graph.zon`** before reading it, by running
   `zig build --step emit-graph` or similar as a pre-pass.

3. **Document and enforce** that `zpkg.graph.zon` is always regenerated as part of
   `zpkg lock` and must not be committed stale.

Option 1 is the cleanest because it eliminates a redundant file and a whole class of
drift bugs.  The `zpkg.graph.zon` is primarily needed for target-edge information that
isn't in `zpkg.zon`; if that information migrates to `zpkg.zon` (as the architecture
already partly intends), the file becomes unnecessary.

This is tracked without a dedicated phase doc for now — it should be resolved as part
of P1-A or the next schema revision.

---

## P2 — Correctness and ergonomics

### P2-A: ZON text manipulation is fragile — should use `zon_util.zig`

**Phase doc:** `docs/implementation/phase-17-zon-parser-hardening.md`

Several core functions parse or rewrite ZON files using line scanning and string search
rather than the project's own `schema/zon_util.zig` parser:

- `source_pkg.zig`: `extractField`, `extractPathsBlock`, `readExtraDepsFromSource`
- `build_fallback.zig`: `patchFingerprintInBuildZigZon`

These break on valid but differently-formatted ZON (multi-line values, fields in a
different order).  They should be rewritten using the existing ZON parser
infrastructure.

Also in this phase: `PackageCache.put` in `resolve/root.zig` uses `catch unreachable`
on the allocation, which panics under OOM.  It should propagate the error.

---

### P2-B: Builds are sequential — independent packages should build in parallel

**Phase doc:** `docs/implementation/phase-18-parallel-builds.md`

`BuildExecutor.execute` iterates the topological order and calls `buildInstance`
serially.  Packages at the same topo level (e.g., `libA` and `libB` in the diamond)
have no data dependency and could be built concurrently.  For repos with tens of
leaf packages, sequential builds are a material throughput problem.

The fix is to segment the topological order into waves (sets of nodes with no
intra-wave dependency) and dispatch each wave as a concurrent batch using Zig's
thread pool or child-process spawning.

---

### P2-C: `zpkg-build` API is verbose and duplicates `build.zig` information

Every package requires a parallel registration block in `build.zig` that re-states
target names, kinds, linkages, and dep aliases that are already declared in `zpkg.zon`.
Every call requires explicit error handling.  Artifact filenames are hardcoded strings
with no platform awareness (`.a` vs `.lib` vs `.so`).

Near-term ergonomic improvements (no dedicated phase doc yet):

- Derive artifact filenames from the Zig build step rather than requiring them as
  string literals.
- Provide a builder-pattern or comptime wrapper that reduces boilerplate and surfaces
  errors at compile time rather than runtime.
- Generate the `zpkg-build` registration block from `zpkg.zon` as a code-generation
  step, so developers only maintain one file.

---

### P2-D: Static vs. shared inconsistency between spec and implementation

The architecture doc commits to "shared-library-oriented" and states "MVP effectively
requires `shared = true`."  Every package in the diamond example uses `.linkage =
.static`.  Static linkage is the correct default for the described C++ use case
(eliminates RPATH issues, simpler binary distribution).

The architecture doc should be updated to reflect static-first for the MVP, with
shared-library support as an explicit extension.

---

## P3 — Future-proofing and growth

### P3-A: No workspace-level manifest or shared lockfile

The lockfile lives inside the root application package.  In a monorepo with multiple
leaf applications, each has an independent lockfile that may resolve shared deps
differently.  There is no mechanism to detect or prevent inconsistency across apps in
the same repo.

A workspace manifest (`zpkg.workspace.zon` or similar) that lists all packages in the
repository, combined with a single workspace-level lockfile, would be the idiomatic
solution.

---

### P3-B: No external / third-party package story

The architecture document's examples include `sai.upstream.protobuf` and
`sai.upstream.gtest`, but there is no implementation path for packages that do not
have `zpkg.zon` or `zpkg-build` wrappers.  A "wrapper package" pattern (analogous to
Conan's `conanfile.py` or Nix's `mkDerivation`) is needed before the tool can be
applied to any real project with third-party dependencies.

---

### P3-C: No version ranges

Only exact-version constraints (`=0.1.0.0`) are supported.  Practically, packages
need `>=1.0.0 <2.0.0` or `^1.2.0` semantics so compatible upgrades can be made
without editing every consumer's `zpkg.zon`.

---

### P3-D: No build profiles / variants

The workspace directory is hard-coded to `debug-native`.  Real projects need multiple
profiles (debug, release, asan, coverage) and the ability to build the same graph
under different profiles simultaneously without collisions.

---

### P3-E: No store garbage collection

The store grows indefinitely.  A `zpkg gc` command with configurable retention policy
(keep last N versions, keep anything referenced by any committed lockfile, etc.) is
needed before the store becomes a disk space concern on active development machines.

---

### P3-F: Remote store protocol

Mentioned in the original `follow-up.md`:

- `zpkg host` — host a package server, allowing clients to download and upload
  pre-built packages from a server-local zpkg store.
- Use `zpkg host` to test downloading pre-built packages from a remote store, in place
  of building from source when the local store is a cache miss.

---

## Recommended implementation order

```text
P0-A  Binary adapter integration     ← unblocks warm-store path
P0-B  Content-addressed store keys   ← unblocks ABI correctness guarantee
P1-A  Source location model          ← unblocks non-toy repos
P1-B  zpkg.graph.zon lifecycle       ← resolve alongside P1-A
P2-A  ZON parser hardening           ← reliability; low risk
P2-B  Parallel builds                ← throughput
P2-C  zpkg-build ergonomics          ← developer experience
P2-D  Static-first doc correction    ← alignment between spec and code
P3-*  Future extensions              ← as needed
```

P0-A and P0-B are independent and can be implemented in parallel.
P1-A and P1-B are closely related and should be done together.
P2 items are independent of each other.
