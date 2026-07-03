# Phase 21 — Enforce zpkg-build Mandate Across All Packages

## Problem

The architecture requires "First-party packages must use the `zpkg-build` wrapper layer;
wrapper usage is mandatory."  In the diamond example, only `app/build.zig` uses
`zpkg-build`.  The five library packages (`libA`, `libB`, `libC`, `libD`, `libE`) are
plain Zig `build.zig` files with no zpkg-build registration.

Consequences:
- `zpkg.graph.zon` is never emitted for libraries, so the declared-vs-registered
  contract validation never runs for dependencies.
- Target-edge information is absent for all library packages, meaning `zpkg` cannot
  know which artifacts each library exports.
- The validation that is the primary correctness guarantee of the tool is absent for
  4 of the 5 packages in the only working example.

---

## Goal

Migrate all diamond example packages to use `zpkg-build` for target registration and
graph emission.  Add a build-time check that fails loudly if a realized source package's
`build.zig` does not emit `zpkg.graph.zon` after `zig build`.

---

## Design

### What zpkg-build must do for each package

Every first-party `build.zig` must:

1. Import and initialize `zpkg_build.Package`.
2. Register each exported target (`addTarget`).
3. Register each dep alias (`addDepAlias`) used by the package.
4. Register target edges (`addEdge`) for all dependencies.
5. Register artifacts (`addArtifact`) for each exported target.
6. Call `pkg.emit(...)` to write `zpkg.graph.zon`.

The existing API is already capable of all of this; the issue is that library packages
haven't been updated.

### Graph emission check in `zpkg build`

After running `zig build install --prefix <staging>` for a source package, `zpkg`
checks that `<realized_dir>/zpkg.graph.zon` exists.  If not, it warns:

```
warning: diamond.libA#target: build.zig did not emit zpkg.graph.zon.
         Ensure all packages use zpkg-build and call pkg.emit(...).
```

This is a warning, not a hard error, in Phase 21, so existing non-migrated packages
can still build.  A future phase or flag can promote it to an error.

---

## Required changes

### 1. Migrate `libA/build.zig`

libA has no dependencies.  The registration block is minimal:

```zig
const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var pkg = zpkg_build.Package.init(b.allocator, "diamond.libA", "target", "0.1.0.0");
    _ = pkg.addTarget("libA", .library, .static, true) catch return;
    pkg.addArtifact("libA", "A") catch return;
    pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon")) catch {};

    const mod = b.createModule(.{ .target = target, .optimize = optimize });
    mod.addCSourceFile(.{ .file = b.path("src/libA.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));
    const lib = b.addLibrary(.{ .name = "A", .root_module = mod, .linkage = .static });
    b.installArtifact(lib);
    b.installDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });
}
```

Also add `zpkg-build` to `libA/build.zig.zon`:
```zon
.dependencies = .{
    .@"zpkg-build" = .{ .path = "../../../pkg/zpkg-build" },
},
```

### 2. Migrate `libB/build.zig`

Same pattern as libA.  libB has no dependencies:
- Register target `libB` as `.library, .static`.
- Artifact name `"B"`.

### 3. Migrate `libC/build.zig`

libC depends on `libA`:
- Register target `libC` as `.library, .static`.
- Register dep alias `"libA"` → `"diamond.libA"`.
- Register edge: `libC` → `libA:libA` via `.link` role.
- Artifact name `"C"`.

### 4. Migrate `libD/build.zig`

libD depends on `libA` and `libB`:
- Register target `libD` as `.library, .static`.
- Register dep aliases `"libA"` and `"libB"`.
- Register edges: `libD` → `libA:libA` and `libD` → `libB:libB`, both `.link`.
- Artifact name `"D"`.

### 5. Migrate `libE/build.zig`

libE depends on `libC` and `libD`:
- Register target `libE` as `.library, .static`.
- Register dep aliases `"libC"` and `"libD"`.
- Register edges: `libE` → `libC:libC` and `libE` → `libD:libD`, both `.link`.
- Artifact name `"E"`.

### 6. `build_fallback.zig:buildInstance` — post-build graph emission check

After `zig build install` succeeds, check for `zpkg.graph.zon`:

```zig
const graph_path = try std.Io.Dir.path.join(
    allocator, &.{ realized_dir, "zpkg.graph.zon" }
);
defer allocator.free(graph_path);
const graph_exists = blk: {
    const f = std.Io.Dir.openFileAbsolute(io, graph_path, .{}) catch {
        break :blk false;
    };
    f.close(io);
    break :blk true;
};
if (!graph_exists) {
    try printStderr(io,
        "warning: '{s}': build.zig did not emit zpkg.graph.zon.\n" ++
        "         Ensure the package uses zpkg-build and calls pkg.emit(...).\n",
        .{display_key}
    );
}
```

### 7. Update `examples/diamond/*/zpkg.zon`

Each library's `zpkg.zon` should declare its targets matching what's registered in
`build.zig`.  Verify these are already present (they are from earlier phases) and
add any missing fields.

### 8. Remove committed `zpkg.graph.zon` files from source tree

These are now generated at configure time.  Add them to `.gitignore` (or the Zig
equivalent).  Remove the committed copies from `examples/diamond/*/`.

---

## Files to change

| File | Change |
|---|---|
| `examples/diamond/libA/build.zig` | Add zpkg-build registration |
| `examples/diamond/libA/build.zig.zon` | Already has zpkg-build dep |
| `examples/diamond/libB/build.zig` | Add zpkg-build registration |
| `examples/diamond/libB/build.zig.zon` | Add zpkg-build dep if missing |
| `examples/diamond/libC/build.zig` | Add zpkg-build registration (with libA edge) |
| `examples/diamond/libD/build.zig` | Add zpkg-build registration (with libA+libB edges) |
| `examples/diamond/libE/build.zig` | Add zpkg-build registration (with libC+libD edges) |
| `src/realize/build_fallback.zig` | Post-build graph emission warning |
| `examples/diamond/**/zpkg.graph.zon` | Delete committed copies; add to .gitignore |

---

## Validation

- Run `zpkg build examples/diamond/app` cold.
- Confirm `zpkg.graph.zon` files appear in the realized workspace dirs for all 5
  library packages after their builds complete.
- Confirm no "did not emit zpkg.graph.zon" warnings are printed.
- Confirm the diamond example still builds and the app binary runs correctly.
- Delete one `build.zig`'s `pkg.emit()` call; confirm the warning fires.
- `zig build test` passes with no regressions.

---

## Exit criteria

- All 6 diamond packages have zpkg-build registration and `pkg.emit()` calls.
- `zpkg.graph.zon` is emitted at configure time for every realized package.
- Committed `zpkg.graph.zon` files are removed from the source tree.
- `build_fallback.zig` warns when a package's build does not produce `zpkg.graph.zon`.
- `zig build test` passes.
