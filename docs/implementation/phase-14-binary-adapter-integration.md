# Phase 14 — Binary Adapter Integration

## Status: Complete

---

## Problem (original)

The binary adapter's generated `build.zig` was functionally empty:

```zig
pub fn build(b: *std.Build) void {
    _ = b;
    // Binary adapter: all artifacts are pre-built in the store.
}
```

Consuming packages call `libE_dep.artifact("E")`, which requires the dependency's
`build.zig` to produce a Zig `Compile` artifact.  From an empty `build` function,
`dep.artifact(...)` returns nothing and no library is linked.  The warm-store path
silently produced binaries missing all their pre-built dependencies.

---

## Design: compile-step redirect via `noopMake`

The spec originally proposed adopting `namedLazyPath` + a `zpkg_build.linkDep` helper,
which would have required changes to every consuming `build.zig` and would not have
propagated transitive static library dependencies automatically.

The implemented approach instead keeps the standard `dep.artifact("X")` API intact,
making the binary adapter transparent to consuming packages.

### Key insight

Zig's `b.addLibrary` creates a `*Compile` step whose `generated_bin.?.path` is
normally set by `llvm-ar` during the step's `make` function.  Two facts allow us to
bypass this:

1. `generated_bin` is a public `?*GeneratedFile` field, allocated (non-null) when
   `getEmittedBin()` is first called — which `installArtifact` does internally.
2. `step.makeFn` is a replaceable function pointer.

By calling `installArtifact` first (to allocate `generated_bin`), then setting
`generated_bin.?.path` to the prebuilt archive and replacing `makeFn` with a no-op,
we get a `*Compile` step that:

- Returns the prebuilt `.a` when `dep.artifact("E")` is called
- Wires transitive deps normally via `mod.linkLibrary(...)`
- Costs nothing at build time — `noopMake` runs in nanoseconds
- Requires no object file extraction, no re-archiving, no disk duplication

### Why not `addObjectFile`?

`llvm-ar cr output.a input.a` creates an archive-of-archives — the nested `.a` is
stored as an opaque member, which linkers cannot read.  Zig's build system uses
`llvm-ar` internally when creating static library steps, so passing a prebuilt `.a`
via `addObjectFile` produces a malformed output archive.

Extracting `.o` files with `llvm-ar x` and re-archiving works but triples disk usage
per package per build profile — unacceptable for large C++ projects.

### Why not `namedLazyPath`?

The `namedLazyPath` approach exposes directory paths but provides no transitive
dependency wiring.  When `libE` depends on `libC` and `libD`, a consumer linking
only against `libE` would miss `libC` and `libD` unless it listed all transitive
deps explicitly.  The `dep.artifact()` + Zig build graph approach handles this
automatically via `getCompileDependencies` traversal.

---

## Generated adapter build.zig

Example for `diamond.libE` (depends on `libC` and `libD`):

```zig
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libD_dep = b.dependency("libD", .{ .target = target, .optimize = optimize });
    const libC_dep = b.dependency("libC", .{ .target = target, .optimize = optimize });
    const mod_e = b.createModule(.{ .target = target, .optimize = optimize });
    mod_e.linkLibrary(libD_dep.artifact("D"));
    mod_e.linkLibrary(libC_dep.artifact("C"));
    const lib_e = b.addLibrary(.{ .name = "E", .root_module = mod_e, .linkage = .static });
    b.installArtifact(lib_e);
    lib_e.generated_bin.?.path = b.pathFromRoot("lib/libE.a");
    lib_e.step.makeFn = noopMake;
}

fn noopMake(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {}
```

The adapter directory contains only `build.zig`, `build.zig.zon`, and symlinks into
the expanded store prefix.  No object files are extracted.

---

## Files changed

| File | Change |
|---|---|
| `src/realize/binary_adapter.zig` | Replaced empty template with `noopMake` + `generated_bin` redirect; generates real `build.zig` with transitive `linkLibrary` wiring |
| `src/realize/build_fallback.zig` | Added `reifyStoreHit` (workspace dir + adapter generation for store hits); N-pass fingerprint retry with per-file patching; `extractFingerprintFilePath`, `patchFingerprintInFile` helpers |
| `src/cli/build.zig` | `buildRoot` uses N-pass fingerprint retry matching `buildInstance` |
| `docs/zpkg-mvp-architecture.md` | Updated binary adapter contract section to reflect actual design |
| `docs/implementation/current-status.md` | Phase 14 marked complete |
| `docs/follow-up.md` | P0-A entry updated to resolved |

---

## Validation

```
# Cold store — builds all packages from source
cd examples/diamond/app
zpkg build .
./zig-out/bin/app
# Expected: e_transform(3, 4, 8) = 24

# Warm store — all five packages are store hits
rm -rf .zpkg/work zig-out
zpkg build .
./zig-out/bin/app
# Expected: e_transform(3, 4, 8) = 24  (via binary adapters, no source builds)
```

Both paths verified.  `zig build test` passes with no regressions.

---

## Exit criteria (revised)

- Cold-store `zpkg build` produces a working binary using source builds. ✓
- Warm-store `zpkg build` produces a working binary using stored artifacts. ✓
- Consuming `build.zig` files are unchanged — `dep.artifact("X")` works for both paths. ✓
- No object files are extracted from store archives; adapter dirs contain only generated
  files and symlinks. ✓
- `zig build test` passes with no regressions. ✓
