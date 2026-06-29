# Diamond Dependency Walkthrough

This guide walks you through the `examples/diamond` example, which demonstrates how zpkg handles a
multi-layer diamond dependency graph. By the end you will understand every file in the example and
know how to onboard onto a zpkg-managed C library project.

---

## 1. Overview

### What this example demonstrates

- A four-layer C library dependency graph with a shared base library (libA)
- How to write `build.zig` for C libraries in Zig 0.16
- How to write `zpkg.zon` package descriptors and `zpkg.graph.zon` graph snapshots
- How zpkg resolves the diamond: `libA` appears once in the lockfile even though two packages need it
- How `zig build` wires path dependencies together in a flat workspace

### Dependency graph

```
        libA   libB        <- Layer 0: base libraries (no deps)
       /    \ /
    libC    libD           <- Layer 1: libC->libA, libD->libA+libB
       \    /
        libE               <- Layer 2: libE->libC+libD
          |
         app               <- Layer 3: app->libE
```

The diamond: both `libC` and `libD` depend on `libA`. `libE` then depends on both `libC` and
`libD`. At link time, `libA.a` must appear exactly once on the linker command line regardless of
how many dependents name it.

### Why the diamond matters

In naive package managers, if two packages declare a dependency on the same library, you can end up
with two copies of that library in the build — potentially with mismatched symbols, duplicate
global state, or link errors. zpkg uses a content-addressed store and instance keys so that two
packages that resolve to the same instance of a dependency share a single build artifact. The
lockfile records the winner of every diamond, and all packages downstream see the same instance.

---

## 2. The C source libraries

### libA — base arithmetic (no dependencies)

```c
// include/libA.h
int a_add(int x, int y);
int a_sub(int x, int y);
```

Implements integer addition and subtraction. libA has no dependencies on other packages.

### libB — base bitwise utilities (no dependencies)

```c
// include/libB.h
int b_shift_left(int x, int n);
int b_mask(int x, int bits);
```

Implements bit-shift and bit-mask operations. libB also has no package dependencies.

### libC — derived arithmetic (depends on libA)

```c
// include/libC.h
int c_double(int x);   // returns a_add(x, x)
int c_negate(int x);   // returns a_sub(0, x)
```

libC `#include`s `libA.h` and calls `a_add` and `a_sub`.

### libD — scaled operations (depends on libA and libB)

```c
// include/libD.h
int d_scale(int x, int factor);   // repeated a_add
int d_low_bits(int x, int n);     // b_mask(b_shift_left(x, 0), n)
```

libD depends on both libA and libB, creating the two arms of the diamond.

### libE — combined transform (depends on libC and libD)

```c
// include/libE.h
int e_transform(int x, int factor, int bits);
```

```c
// src/libE.c
int e_transform(int x, int factor, int bits) {
    int doubled = c_double(x);
    int scaled  = d_scale(doubled, factor);
    return d_low_bits(scaled, bits);
}
```

libE brings libC and libD together. Transitively it needs libA (through both libC and libD) and
libB (through libD). The linker sees all of them.

### app — the top-level program (depends on libE)

```c
// src/main.c
#include <stdio.h>
#include "libE.h"
int main(void) {
    int result = e_transform(3, 4, 8);
    printf("e_transform(3, 4, 8) = %d\n", result);
    return 0;
}
```

Expected output: `e_transform(3, 4, 8) = 24`

---

## 3. Standard Zig package setup

### build.zig for a C library

Each package has a `build.zig` that follows this pattern:

```zig
const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build block (see section 5) ---
    // ...

    // --- Standard Zig build artifacts ---
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    mod.addCSourceFile(.{ .file = b.path("src/libA.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));

    const lib = b.addLibrary(.{
        .name = "A",
        .linkage = .static,
        .root_module = mod,
    });
    lib.installHeader(b.path("include/libA.h"), "libA.h");
    b.installArtifact(lib);
}
```

**Zig 0.16 API notes:**

- C source files and include paths are methods on `*std.Build.Module`, not on `*std.Build.Step.Compile`.
  Always call `mod.addCSourceFile(...)` and `mod.addIncludePath(...)` before passing `mod` to
  `b.addLibrary(...)`.
- `lib.installHeader(src, dest)` is still a method on `*Compile`.
- `b.addLibrary(.{ .linkage = .static, ... })` creates a static library; use `.linkage = .dynamic`
  for shared libraries.

### build.zig.zon

Every Zig package needs a `build.zig.zon` manifest:

```zon
.{
    .name = .diamond_liba,        // bare Zig identifier (no hyphens, no uppercase)
    .version = "0.1.0",           // semver string
    .fingerprint = 0x48fd401ed735c0f2,  // computed by `zig build`; see note below
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .@"zpkg-build" = .{ .path = "../../../pkg/zpkg-build" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "zpkg.zon", "src", "include" },
}
```

**Fingerprint:** Zig computes the fingerprint from the package name and file contents. If you put
an arbitrary value, `zig build` will error and tell you the correct value:

```
error: invalid fingerprint: 0xaa00000000000001;
if this is a new or forked package, use this value: 0x48fd401ed735c0f2
```

Just paste the suggested value and run `zig build` again.

**Name rule:** The `.name` field must be a valid bare Zig identifier — no hyphens, no uppercase. Use
underscores. `diamond_liba` is valid; `diamond-libA` is not.

**Paths:** List every directory and file that is part of this package. Consumers who depend on this
package via a path dep will only see files listed here.

### Adding a path dependency in build.zig.zon

libC depends on libA. Add it under `.dependencies`:

```zon
.{
    .name = .diamond_libc,
    .version = "0.1.0",
    .fingerprint = 0xa6f32132731a41e2,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .@"zpkg-build" = .{ .path = "../../../pkg/zpkg-build" },
        .libA = .{ .path = "../libA" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "zpkg.zon", "src", "include" },
}
```

The key `.libA` is the dependency name you use in `build.zig` when calling `b.dependency("libA", ...)`.

### Consuming a path dependency in build.zig

```zig
const libA_dep = b.dependency("libA", .{ .target = target, .optimize = optimize });
const libA_art = libA_dep.artifact("A");   // "A" matches .name = "A" in libA's b.addLibrary

const mod = b.createModule(.{ .target = target, .optimize = optimize });
mod.addCSourceFile(.{ .file = b.path("src/libC.c"), .flags = &.{} });
mod.addIncludePath(b.path("include"));
mod.addIncludePath(libA_dep.path("include"));   // expose libA headers to our C sources
mod.linkLibrary(libA_art);

const lib = b.addLibrary(.{ .name = "C", .linkage = .static, .root_module = mod });
```

`libA_dep.path("include")` returns a lazy path to libA's `include/` directory, which Zig resolves
to the correct absolute path at build time regardless of where `zig build` was invoked.

This pattern works identically whether `libA` is built from source or served from the
zpkg store as a binary adapter.  When all dependencies are store hits, zpkg generates
an adapter `build.zig` for each one that exposes the prebuilt `.a` via the same
`dep.artifact("A")` call — consuming packages see no difference.

### Verifying libA standalone

```
$ cd examples/diamond/libA
$ zig build
$ ls zig-out/lib/
libA.a
$ ls zig-out/include/
libA.h
```

libA has no dependencies so it is the best package to verify the basic setup is working.

---

## 4. Adding zpkg package descriptors (zpkg.zon)

Each package also has a `zpkg.zon` that zpkg reads (independent of Zig's build system). This is
the package descriptor that zpkg uses for version resolution, dependency tracking, and the lockfile.

### zpkg.zon for libA (no dependencies)

```zon
.{
    .schema = 1,

    .package = .{
        .name = "libA",
        .id = "diamond.libA",   // globally unique reverse-DNS identifier
        .version = "0.1.0.0",   // four-part version: major.minor.patch.revision
        .backend = .zig,
    },

    .targets = .{
        .libA = .{
            .kind = .library,
            .linkage = .static,
        },
    },
}
```

### zpkg.zon for libC (with dependency)

```zon
.{
    .schema = 1,

    .package = .{
        .name = "libC",
        .id = "diamond.libC",
        .version = "0.1.0.0",
        .backend = .zig,
    },

    .deps = .{
        .libA = .{
            .package = "diamond.libA",
            .require = .{ .version = "=0.1.0.0" },
        },
    },

    .targets = .{
        .libC = .{
            .kind = .library,
            .linkage = .static,
        },
    },
}
```

### Key concepts

**package_id naming convention:** Use reverse-DNS style: `<project>.<component>`. For this example,
`diamond.libA`, `diamond.libC`, etc. The id must be globally unique; in a real registry it would
include your organization name.

**Version format:** zpkg uses a four-part version string `major.minor.patch.revision`. The extra
`revision` field lets you release package-descriptor updates without changing the library version.
Zig's `build.zig.zon` uses the standard three-part semver.

**Dependency alias vs package_id:** The key `.libA` under `.deps` is the *alias* — the local name
you use to refer to this dependency within the package. The `.package = "diamond.libA"` is the
*package_id* — the globally unique name in the registry. These are intentionally separate so that
you can rename a local dep alias without breaking anything upstream.

**Domain:** The `.when = .{ .domain = .host }` qualifier (seen in the hello-app example for tool
deps) restricts a dependency to the host domain. In the diamond example all deps are in the default
`target` domain (omitting `.when` means target). Domain separation ensures you don't accidentally
link a cross-compiled library into a host tool.

---

## 5. Adding zpkg-build graph emission

The `build.zig` file also includes a `zpkg_build.Package` block that records the package's targets
and dependency edges in machine-readable form. This is how zpkg knows the build graph without
running a full Zig build.

### The zpkg-build block in build.zig

```zig
var pkg = zpkg_build.Package.init(b.allocator, "diamond.libC", "target", "0.1.0.0");

_ = pkg.addTarget("libC", .library, .static, true) catch |err| { ... };
pkg.addIncludeDir("libC", .{ .path = "include", .visibility = .public }) catch |err| { ... };
pkg.addArtifact("libC", "libC.a") catch |err| { ... };
pkg.addEdge("libC", .{
    .dep_alias = "libA",
    .target_name = "libA",
    .role = .link,
}) catch |err| { ... };
pkg.addDepAlias("libA", "diamond.libA") catch |err| { ... };

pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon")) catch |err| { ... };
```

**Important:** Use `b.pathFromRoot("zpkg.graph.zon")` — not a bare relative path string. When
libA's `build.zig` is invoked as a path dependency within libC's build, the process working
directory is the root package's directory (libC's directory, not libA's). Using
`b.pathFromRoot(...)` resolves to an absolute path within each package's own source tree, so each
package writes its own `zpkg.graph.zon` correctly.

### What zpkg.graph.zon contains

`pkg.emit()` writes a snapshot of the package's build graph to `zpkg.graph.zon`. This file is
committed to source control and read by zpkg without running `zig build`. Example for libC:

```zon
.{
    .schema = 1,
    .package = "diamond.libC",
    .domain = .target,
    .version = "0.1.0.0",
    .selected_options = .{},
    .dep_alias_mapping = .{
        .libA = "diamond.libA",
    },
    .targets = .{
        .libC = .{
            .kind = .library,
            .linkage = .static,
            .exported = true,
            .edges = .{
                .{ .dep_alias = "libA", .target_name = "libA", .role = .link },
            },
            .include_dirs = .{
                .{ .path = "include", .visibility = .public },
            },
            .compile_defs = .{},
            .artifacts = .{ "libC.a" },
            .system_libs = .{},
            .resources = .{},
        },
    },
}
```

Fields:
- `dep_alias_mapping`: maps each local alias to its resolved package_id
- `targets`: the buildable targets with their edges (what they link against), include dirs, and
  output artifacts
- `edges`: each edge names the dep alias, the target within that dep, and the role (`.link` means
  link the artifact; `.tool` means run the artifact as a build tool)
- `exported = true`: this target is part of the package's public API; other packages can depend on it

The `zpkg.graph.zon` file acts as a build graph cache. zpkg reads it to understand the dependency
graph without invoking `zig build` for every package.

---

## 6. Generating the lockfile

Once all packages have `zpkg.zon` files, generate the lockfile with:

```
$ zpkg lock examples/diamond/app
```

The lockfile (`zpkg.lock.zon`) records:
- The exact instance key for every package in the transitive closure
- Which instance of each package wins the diamond resolution
- The build options that were selected (if any)

**Diamond deduplication:** Both libC and libD list `diamond.libA` as a dependency. zpkg's
resolver sees two paths to `diamond.libA` in the graph. Since both require the same version
(`=0.1.0.0`) and domain (`target`), they resolve to the same instance. The lockfile contains
`diamond.libA` once, with a single instance key. libC and libD both point to that same instance.

An instance key is a content hash that encodes: the package_id, version, domain, selected build
options, and the instance keys of all dependencies. Two packages that depend on the same package
with the same configuration will always get the same instance key, making deduplication exact and
reproducible.

---

## 7. First-pass build: building from source

With a lockfile in place:

```
$ zpkg build examples/diamond/app
```

zpkg computes the build order using a topological sort — leaves first:

```
[miss] diamond.libA  0.1.0.0  (no cached artifact)
[miss] diamond.libB  0.1.0.0
[miss] diamond.libC  0.1.0.0
[miss] diamond.libD  0.1.0.0
[miss] diamond.libE  0.1.0.0
[miss] diamond.app   0.1.0.0
```

Every instance is a cache miss on first build (fresh checkout or empty store). zpkg:

1. Checks `.zpkg/store/<instance-key>/` — not found (`[miss]`)
2. Generates a realized `build.zig.zon` with correct path deps pointing into the store
3. Runs `zig build` in the package's source directory
4. Copies build outputs into `.zpkg/store/<instance-key>/`

After the first pass, all six packages are in the local store.

---

## 8. Second-pass build: cache hits

Run the same command again:

```
$ zpkg build examples/diamond/app
```

Expected output:

```
[hit]  diamond.libA  0.1.0.0
[hit]  diamond.libB  0.1.0.0
[hit]  diamond.libC  0.1.0.0
[hit]  diamond.libD  0.1.0.0
[hit]  diamond.libE  0.1.0.0
[hit]  diamond.app   0.1.0.0
```

Every instance is found in the store — nothing is recompiled. The build completes in milliseconds.
This is the core value of zpkg: if the inputs (source hash + dependency instance keys + build
options + toolchain fingerprint) haven't changed, the output is guaranteed to be the same, so zpkg
skips the build entirely.

**What is NOT rebuilt:** Zig's incremental compiler is not invoked at all. zpkg doesn't even look
at `.zig-cache`. The store hit is a pure file-system lookup on the instance key.

---

## 9. Workspace realization

To build with a standard `zig build` command (without zpkg orchestrating each step), use:

```
$ zpkg realize examples/diamond/app
```

This creates a workspace directory (e.g., `.zpkg/workspace/diamond.app/`) containing:

- A symlink forest pointing into the store for each dependency
- A generated `build.zig.zon` with `.path` dependencies replaced by absolute store paths
- A copy (or symlink) of the app's own source

You can then run `zig build` directly in the workspace:

```
$ cd .zpkg/workspace/diamond.app
$ zig build run
e_transform(3, 4, 8) = 24
```

The generated `build.zig.zon` looks something like:

```zon
.{
    .name = .diamond_app,
    .version = "0.1.0",
    .dependencies = .{
        .@"zpkg-build" = .{ .path = "/path/to/zpkg/pkg/zpkg-build" },
        .libE = .{ .path = "/home/user/.zpkg/store/<libE-instance-key>" },
    },
    ...
}
```

All relative paths from the original `build.zig.zon` are replaced with absolute paths to the
store. This means `zig build` resolves all dependencies correctly regardless of where the workspace
is located.

---

## 10. Running the app

After `zig build` succeeds:

```
$ zig-out/bin/app
e_transform(3, 4, 8) = 24
```

The math: `e_transform(3, 4, 8)`:
1. `c_double(3)` = `a_add(3, 3)` = 6
2. `d_scale(6, 4)` = `a_add` iterated 4 times = 24
3. `d_low_bits(24, 8)` = `b_mask(24, 8)` = `24 & 0xFF` = 24

---

## 11. Onboarding a new developer

A developer joins the team and clones the repository. Here is the exact sequence:

```
$ git clone <repo-url>
$ cd <repo>
```

The lockfile (`zpkg.lock.zon`) is committed to the repository. The developer does not need to run
`zpkg lock` — the locked instance keys are already determined.

```
$ zpkg build examples/diamond/app
```

On first run their local store (usually `~/.zpkg/store/`) is empty, so every package is a miss:

```
[miss] diamond.libA  0.1.0.0  -- building...
[miss] diamond.libB  0.1.0.0  -- building...
[miss] diamond.libC  0.1.0.0  -- building...
[miss] diamond.libD  0.1.0.0  -- building...
[miss] diamond.libE  0.1.0.0  -- building...
[miss] diamond.app   0.1.0.0  -- building...
```

After the first build completes, every subsequent run is instant:

```
$ zpkg build examples/diamond/app
[hit]  diamond.libA  0.1.0.0
...
[hit]  diamond.app   0.1.0.0
```

### CI pre-population

CI can pre-populate a shared store (e.g. on an NFS mount or S3-backed cache) so that developers
who pull from a branch with unchanged dependencies never rebuild anything:

```
# CI job (after building successfully):
$ zpkg store push --remote s3://my-bucket/zpkg-store

# Developer workstation:
$ zpkg store fetch --remote s3://my-bucket/zpkg-store diamond.app 0.1.0.0
$ zpkg build examples/diamond/app
[hit]  diamond.libA  0.1.0.0   (fetched from remote)
[hit]  ...
```

Because instance keys are content-addressed, the developer's local instance key for `diamond.libA`
is identical to the CI-produced one, so the remote artifact is an exact match.

---

## 12. Glossary

**package_id**
A globally unique identifier for a package, written in reverse-DNS style: `diamond.libA`. Used in
`zpkg.zon` and `zpkg.graph.zon`. Not the same as the Zig `build.zig.zon` `.name` field.

**instance key**
A content hash that uniquely identifies one built instance of a package. It is computed from the
package_id, version, domain, selected build options, and the instance keys of all dependencies.
If any input changes, the instance key changes, and the package is rebuilt from scratch.

**domain**
The build context in which a package is consumed: `target` (cross-compiled for the target
platform) or `host` (built for the machine running the build). Tool dependencies (code generators,
pre-processors) use the `host` domain; libraries linked into the final output use `target`.

**alias**
The local name by which one package refers to a dependency. In `zpkg.zon`, the key under `.deps`
(e.g., `.libA = .{ .package = "diamond.libA", ... }`). The alias is the name used in `build.zig`
(`b.dependency("libA", ...)`). The alias and the package_id do not need to match.

**store**
The content-addressed cache of built package artifacts, typically at `~/.zpkg/store/` or a
project-local `.zpkg/store/`. Each entry is keyed by instance key. Hitting the store means no
compilation occurs.

**workspace**
A directory that zpkg generates for a specific package instance, containing a symlink forest into
the store and a generated `build.zig.zon` with absolute dependency paths. Running `zig build` in a
workspace produces the final binary or library.

**lockfile**
The `zpkg.lock.zon` file committed alongside source code. It records the exact instance key for
every package in the transitive dependency graph, making the build reproducible across machines and
time. Updating a dependency version requires re-running `zpkg lock` to generate a new lockfile.
