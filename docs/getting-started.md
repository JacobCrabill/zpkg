# Getting Started with zpkg

This guide gets you from a fresh checkout to building a multi-package project with
binary caching. For how it all works, see [architecture.md](architecture.md).

## Prerequisites

- **Zig 0.16.0** on your `PATH` (zpkg shells out to `zig build`).
- A POSIX shell (Linux/macOS). The workspace uses symlinks.

## Build zpkg

```sh
zig build            # produces ./zig-out/bin/zpkg
zig build test       # unit tests
zig build integration  # end-to-end test against the diamond example
```

Put `zig-out/bin` on your `PATH`, or invoke `./zig-out/bin/zpkg` directly. The
examples below assume `zpkg` is on your `PATH`.

## Your first build: the diamond example

`examples/diamond` is a small graph: an app links `libE`, which links `libC` and
`libD`, which both link a shared `libA` (plus `libB`) — a genuine "diamond" where
`libA` is reached by two paths but resolves to a single instance.

```
app ── libE ─┬─ libC ── libA
             └─ libD ─┬─ libA
                      └─ libB
```

```sh
cd examples/diamond
zpkg build app
```

You don't need to `lock` first — `build` resolves and creates `zpkg.lock.zon`
automatically. On a TTY you'll see a live status line; the run ends with:

```
Build complete in 3.4s — 5 built, 0 cached (debug-native)
  output: /…/examples/diamond/app/zig-out
```

Run the built binary:

```sh
./app/zig-out/bin/app        # → e_transform(3, 4, 8) = 24
```

### Watch the cache work

Build again — everything is a store hit, so only the root relinks:

```sh
zpkg build app
# Build plan: 5 instances (5 store hits, 0 to build)
```

Now edit a leaf (`libA/src/libA.c`) and rebuild — only `libA` and its dependents
rebuild; unaffected packages stay cached. This is the whole point: change
propagation without rebuilding the world.

### A different profile is a separate cache

```sh
zpkg build app --release
# Build plan: 5 instances (0 store hits, 5 to build)   ← distinct store slot
```

`--release` (and `--target <triple>`) build into a separate `.zpkg/work/<slug>/`
workspace and separate store keys, so they coexist with your Debug build — the
Debug slot stays cached.

### Clean up

```sh
zpkg clean app            # removes .zpkg/work and zig-out
zpkg clean app --store    # also clears the content-addressed store cache
```

## Anatomy of a package

A zpkg package is a normal Zig package (`build.zig` + `build.zig.zon`) plus a
`zpkg.zon` manifest.

### `zpkg.zon`

```zig
.{
    .schema = 1,
    .package = .{
        .name = "libc",
        .id = "diamond.libC",       // canonical namespaced id
        .version = "0.1.0.0",
        .backend = .zig,
    },
    .deps = .{
        .libA = .{
            .package = "diamond.libA",
            .require = .{ .version = "^0.1.0" },  // version range (see below)
            .source_path = "../libA",             // relative to this file
        },
    },
    .targets = .{
        .libC = .{ .kind = .library, .linkage = .static },
    },
}
```

**Version ranges** in `.require.version`:

| Syntax | Meaning |
|---|---|
| `=1.2.3` / `=1.2.3.4` | exact (4-component form pins the release-tweak digit) |
| `^1.2.3` | `>=1.2.3, <2.0.0` (caret; `^0.2.3` → `<0.3.0`) |
| `~1.2.3` | `>=1.2.3, <1.3.0` |
| `>=1.2, <2.0` | intersection of comparators |
| `*` / `any` | any version |
| `1.2.3` | bare = caret |

Requirements are enforced at resolution time; an unsatisfiable one (including a
diamond conflict) fails the build with a clear message.

### `build.zig`

`build.zig` is **standard Zig** — it consumes dependencies via `b.dependency(alias)`
exactly as usual. The key property is that zpkg has already realized each dependency
in the workspace, so `b.dependency("libA")` resolves to whatever zpkg put there — a
source build **or** a prebuilt-binary adapter — without your `build.zig` changing:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libA = b.dependency("libA", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{ .target = target, .optimize = optimize });
    mod.addCSourceFile(.{ .file = b.path("src/libC.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(libA.path("include"));
    mod.linkLibrary(libA.artifact("A"));   // real lib (source) or cached .a (adapter)

    const lib = b.addLibrary(.{ .name = "C", .root_module = mod, .linkage = .static });
    b.installArtifact(lib);
    b.installDirectory(.{ .source_dir = b.path("include"), .install_dir = .header, .install_subdir = "" });
}
```

`build.zig.zon` lists dependencies as path deps; zpkg rewrites these to point at the
realized workspace copies:

```zig
.{
    .name = .diamond_libc,
    .version = "0.1.0",
    .fingerprint = 0x…,          // Zig's package fingerprint — never changed by zpkg
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .libA = .{ .path = "../libA" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "zpkg.zon", "src", "include" },
}
```

### The build graph (`zpkg.graph.zon`)

zpkg needs to know what targets a package produces and how they connect. That's the
`zpkg.graph.zon`. A `build.zig` can emit it during `zig build` using the
`zpkg-build` shim — see `examples/diamond/app/build.zig`:

```zig
const zpkg_build = @import("zpkg-build");
// …inside build():
var pkg = zpkg_build.Package.init(b.allocator, "diamond.app", "target", "0.1.0.0");
_ = try pkg.addTarget("app", .executable, .default, true);
try pkg.addArtifact("app", "app");
try pkg.addEdge("app", .{ .dep_alias = "libE", .target_name = "libE", .role = .link });
try pkg.addDepAlias("libE", "diamond.libE");
try pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon"));
```

(To use the shim, add `.@"zpkg-build" = .{ .path = "…/pkg/zpkg-build" }` to
`build.zig.zon`.) The example libraries ship a committed `zpkg.graph.zon`; the app
regenerates its own on build.

## Command cheat-sheet

| Command | Purpose |
|---|---|
| `zpkg build <pkg> [--release[=safe\|fast\|small]] [--target <t>] [--with-tests] [--jobs N]` | Resolve (auto-lock if needed), build the graph, link the root. |
| `zpkg test <pkg>` | Build and run the test graph. |
| `zpkg lock <pkg>` | Create `zpkg.lock.zon` (fails if it exists). |
| `zpkg update <pkg> [--dry-run]` | Re-resolve and rewrite the lockfile. |
| `zpkg graph <pkg> [--verbose]` | Print the resolved dependency tree. |
| `zpkg inspect <pkg>` | Print the normalized manifest. |
| `zpkg realize <pkg>` | Materialize the workspace from the lockfile + store (no build). |
| `zpkg export <pkg> [id:target]` | Export a relocatable closure bundle. |
| `zpkg clean <pkg> [--store]` | Remove generated artifacts (and optionally the store). |
| `zpkg version` / `zpkg --version` | Print the version. |

Common flags: `--progress auto|plain|live` (status display), `--strict-lockfile`
(treat source drift as an error), `--jobs N` (parallelism).

## Where to go next

- [architecture.md](architecture.md) — how resolution, the store, realization, and
  profiles fit together.
- `examples/` — `hello-lib`, `hello-app`, `hello-tests`, `diamond`, and more.
- [version-ranges-plan.md](version-ranges-plan.md) /
  [profile-target-axis-plan.md](profile-target-axis-plan.md) — design notes,
  including deferred work (version *selection*, cross-target resolution).
