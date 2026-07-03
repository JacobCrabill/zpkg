# Phase 26 — zpkg-build Code Generation from zpkg.zon

## Problem

Every first-party package requires a parallel registration block in `build.zig` that
re-states target names, kinds, linkages, dep aliases, and edges that are already
declared in `zpkg.zon`.  The `app/build.zig` zpkg-build block is 32 lines of boilerplate
for a single-target application:

```zig
var pkg = zpkg_build.Package.init(b.allocator, "diamond.app", "target", "0.1.0.0");
_ = pkg.addTarget("app", .executable, .default, true) catch |err| {
    std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
    return;
};
pkg.addArtifact("app", "app") catch |err| {
    std.debug.print("zpkg-build: addArtifact failed: {}\n", .{err});
    return;
};
pkg.addEdge("app", .{
    .dep_alias   = "libE",
    .target_name = "libE",
    .role        = .link,
}) catch |err| {
    std.debug.print("zpkg-build: addEdge failed: {}\n", .{err});
    return;
};
pkg.addDepAlias("libE", "diamond.libE") catch |err| {
    std.debug.print("zpkg-build: addDepAlias failed: {}\n", .{err});
    return;
};
pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon")) catch |err| {
    std.debug.print("zpkg-build: emit failed: {}\n", .{err});
};
```

For a monorepo with 50 packages, this is:
- ~1,600 lines of boilerplate across the codebase.
- A maintenance burden: each rename in `zpkg.zon` requires a corresponding change in
  `build.zig`.
- A source of silent errors: mismatches between `zpkg.zon` and `build.zig` registrations
  are only caught at build time, not at author time.

---

## Goal

Add a `zpkg generate` command that reads `zpkg.zon` and generates the corresponding
`zpkg-build` registration block as a Zig source snippet.  Developers paste or
`--write` the output into their `build.zig`.

As a stretch goal, provide a comptime-generated registration helper that entirely
eliminates the boilerplate at the cost of Zig's compile-time evaluation.

---

## Design

### Option A: Code generation command (`zpkg generate`)

`zpkg generate <pkg-root>` reads `zpkg.zon` and prints the zpkg-build registration
block for that package:

```sh
$ zpkg generate examples/diamond/app
# Paste the following into your build.zig:

var pkg = zpkg_build.Package.init(
    b.allocator, "diamond.app", "target", "0.1.0.0"
);
defer pkg.deinit();
pkg.addTarget("app", .executable, .default, true) catch @panic("zpkg-build");
pkg.addArtifact("app", "app") catch @panic("zpkg-build");
pkg.addEdge("app", .{
    .dep_alias   = "libE",
    .target_name = "libE",
    .role        = .link,
}) catch @panic("zpkg-build");
pkg.addDepAlias("libE", "diamond.libE") catch @panic("zpkg-build");
pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon")) catch {};
```

With `--write`, it replaces the existing zpkg-build block in `build.zig` in place
(identified by `// zpkg-build:begin` and `// zpkg-build:end` sentinel comments).

#### Sentinel comments

The generated block is wrapped in sentinel comments so `zpkg generate --write` can
locate and replace it without touching the rest of `build.zig`:

```zig
// zpkg-build:begin
var pkg = zpkg_build.Package.init(...);
// ... generated registration ...
// zpkg-build:end
```

### Option B: Comptime registration helper (stretch)

A comptime function in `zpkg-build` reads the `zpkg.zon` content as a string literal
and generates the registration calls at compile time:

```zig
// In build.zig:
const zpkg_zon = @embedFile("zpkg.zon");
zpkg_build.autoRegister(b, zpkg_zon) catch @panic("zpkg-build auto-register failed");
```

This eliminates all boilerplate entirely but requires implementing a comptime ZON
parser, which is non-trivial.  Deferred to a later phase.

### Edge inference

For Option A, the generated edge list comes from the dep aliases declared in
`zpkg.zon`.  The target-to-target edge details (which target in package A links to
which target in package B) must be inferred or prompted:

- If a package exports exactly one library target and has a dep with exactly one
  exported library, the edge is inferred as `.link`.
- If ambiguous, `zpkg generate` emits a comment:
  ```zig
  // TODO: fill in target_name for dep alias "libX"
  pkg.addEdge("myLib", .{
      .dep_alias   = "libX",
      .target_name = "???",  // which target from libX?
      .role        = .link,
  }) catch @panic("zpkg-build");
  ```

---

## Required changes

### 1. `src/cli/generate.zig` — new command

```zig
pub fn run(args: []const []const u8, io: std.Io) !void {
    // Parse args: <pkg-root>, optional --write
    // Read zpkg.zon
    // Generate zpkg-build registration block
    // Print or write to build.zig
}
```

### 2. `src/codegen/zpkg_build_gen.zig` — code generation logic

```zig
/// Generate the zpkg-build registration block for a package manifest.
/// Returns an owned slice of Zig source text.
pub fn generateBlock(
    allocator: std.mem.Allocator,
    manifest: model.PackageManifest,
) ![]u8 { ... }
```

### 3. `src/codegen/build_zig_patch.zig` — in-place replacement

```zig
/// Replace the content between `// zpkg-build:begin` and `// zpkg-build:end`
/// sentinels in `build.zig` with `new_block`.
pub fn patchBuildZig(
    allocator: std.mem.Allocator,
    io: std.Io,
    build_zig_path: []const u8,
    new_block: []const u8,
) !void { ... }
```

### 4. `src/cli/root.zig` — route `zpkg generate`

Add `generate` as a new subcommand.

### 5. Update diamond example

Run `zpkg generate --write` on each diamond package and verify the generated blocks
match what's currently hand-written.

---

## Files to create/change

| File | Change |
|---|---|
| `src/cli/generate.zig` | New: `zpkg generate` command |
| `src/codegen/zpkg_build_gen.zig` | New: block generation logic |
| `src/codegen/build_zig_patch.zig` | New: in-place build.zig patching |
| `src/cli/root.zig` | Route `zpkg generate` |
| `docs/quickstart.md` | Add `zpkg generate` to the setup workflow |

---

## Validation

- `zpkg generate examples/diamond/app` prints a correct registration block.
- `zpkg generate --write examples/diamond/app` patches `build.zig` in place; the result
  is identical to the hand-written block for app.
- Running `zpkg build examples/diamond/app` after the in-place patch still succeeds.
- `zpkg generate` on a package with a `TODO` dep correctly emits a `// TODO:` comment.
- `zig build test` passes with no regressions.

---

## Exit criteria

- `zpkg generate <pkg-root>` prints the zpkg-build registration block derived from
  `zpkg.zon`.
- `zpkg generate --write <pkg-root>` patches `build.zig` in place within sentinels.
- Generated blocks are syntactically correct Zig and match expected registration.
- `zig build test` passes.
