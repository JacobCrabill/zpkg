# Phase 24 — Third-Party Wrapper Packages

## Problem

The architecture document's own examples reference `sai.upstream.protobuf`,
`sai.upstream.gtest`, and `sai.upstream.libyaml`.  None of these packages have
`zpkg.zon` files or `zpkg-build` wrappers.  There is no implemented path for packages
that do not follow the zpkg contract.

Real large-scale C++ projects depend on dozens of external libraries: Protobuf, gRPC,
Abseil, GoogleTest, Boost, OpenCV, Eigen, zlib, RE2, and so on.  Without a way to
integrate these, zpkg is limited to pure first-party repositories with no external
dependencies — an unrealistic constraint.

The situation is analogous to:
- Conan: solved with `conanfile.py` recipes
- Nix: solved with `fetchFromGitHub` + `mkDerivation` expressions
- Cargo: solved with `build.rs` scripts + external build system glue

---

## Goal

Define and implement a "wrapper package" pattern: a zpkg-aware package that wraps a
third-party library, providing the `zpkg.zon` contract and a `build.zig` that builds
or locates the upstream library, without requiring any changes to the upstream source.

---

## Design

### Wrapper package structure

A wrapper package is a first-party package that lives in the monorepo and whose job
is solely to make a third-party library available under the zpkg contract.

```
upstream/
  gtest/
    zpkg.zon          ← declares "sai.upstream.gtest", exports gtest target
    build.zig         ← builds gtest from source or locates system installation
    build.zig.zon     ← declares upstream source as a Zig dependency (or empty)
    src/              ← optional: patches, CMake override files
```

The wrapper package is treated identically to any other first-party package from
zpkg's perspective.  It has a package id, version, exports targets, and is resolved
and built like any other dep.

### Build strategies for the wrapper

Three strategies for building the underlying library:

#### Strategy 1: Build from source using Zig's build system

The wrapper's `build.zig` invokes Zig's C build APIs directly to compile the upstream
library:

```zig
// upstream/gtest/build.zig
pub fn build(b: *std.Build) void {
    const gtest_src = b.dependency("gtest_src", .{});  // tarball or git dep

    const mod = b.createModule(.{ .target = target, .optimize = optimize });
    mod.addCSourceFiles(.{
        .root = gtest_src.path("googletest/src"),
        .files = &.{ "gtest-all.cc" },
        .flags = &.{ "-I", gtest_src.path("googletest/include").getPath(b) },
    });
    mod.addIncludePath(gtest_src.path("googletest/include"));

    const lib = b.addLibrary(.{ .name = "gtest", .root_module = mod, .linkage = .static });
    b.installArtifact(lib);
    b.installDirectory(.{
        .source_dir = gtest_src.path("googletest/include"),
        .install_dir = .header,
        .install_subdir = "",
    });
}
```

This works for libraries with simple build systems.  For complex autoconf/CMake
projects, see Strategy 2.

#### Strategy 2: Invoke the upstream build system via `std.process.spawn`

The wrapper's `build.zig` shells out to `cmake`, `make`, `autoconf`, etc.:

```zig
// Custom build step: run CMake + make
const cmake_step = b.addSystemCommand(&.{
    "cmake", "-S", upstream_src, "-B", build_dir,
    "-DCMAKE_INSTALL_PREFIX=" ++ install_prefix,
    "-DCMAKE_BUILD_TYPE=Release",
});
const make_step = b.addSystemCommand(&.{ "make", "-C", build_dir, "install" });
make_step.step.dependOn(&cmake_step.step);
```

`zpkg-build` validates the declared targets against what's installed in the prefix
after `zig build install` completes.

#### Strategy 3: Locate system installation (pkg-config / find_package)

For libraries that are expected to be installed system-wide:

```zig
// upstream/zlib/build.zig
// Use pkg-config to locate zlib, emit headers and libs from system path.
const zlib = std.Build.Step.Compile.create(b, .{ .name = "zlib", .kind = .lib });
zlib.linkSystemLibrary("z");
// Install header search path for consumers.
b.installDirectory(.{
    .source_dir = .{ .cwd_relative = "/usr/include" },
    .install_dir = .header,
    .install_subdir = "zlib",
    .include_extensions = &.{"zlib.h"},
});
```

This is the lightest strategy but the least portable.

### Required zpkg.zon fields for wrapper packages

A wrapper package's `zpkg.zon` is identical in structure to any other package:

```zig
.{
    .schema = 1,
    .package = .{
        .name = "gtest",
        .id   = "sai.upstream.gtest",
        .version = "1.14.0.0",
        .backend = .zig,
    },
    .targets = .{
        .gtest = .{
            .kind = .library,
            .linkage = .static,
            .test_only = true,    // gtest is a test-only dep
        },
        .gtest_headers = .{
            .kind = .headers,
        },
    },
}
```

### Toolchain fingerprint integration

When the wrapper invokes an external build system, the resulting binary must still be
keyed correctly.  The content-addressed store key already includes the toolchain
fingerprint and selected options, so this is handled automatically as long as the
wrapper's `build.zig.zon` version pin and the toolchain are stable.

### No zpkg core changes required

The wrapper package pattern requires no changes to zpkg's core.  It is a convention
and documentation artifact, not a new subsystem.

---

## Required changes

### 1. Implement `examples/hello-gtest/` wrapper package

Create a minimal wrapper for GoogleTest to prove the pattern works end-to-end:

```
examples/hello-gtest/
  upstream/
    gtest/
      zpkg.zon
      build.zig        ← builds gtest from Zig dep source
      build.zig.zon    ← pins gtest source tarball via Zig package manager
  app-with-tests/
    zpkg.zon           ← depends on sai.upstream.gtest via .when = .{.domain = .host}
    build.zig
    build.zig.zon
    src/
      main_test.cc
    zpkg.lock.zon
```

### 2. Write `docs/zpkg-wrapper-packages.md`

Document the three strategies.  Provide a template `zpkg.zon` and `build.zig` for
each strategy.  Explain how version pinning works for upstream sources.

### 3. Update `docs/zpkg-implementation-plan.md` post-MVP extensions

Move "CMake backend standardization" from "Optional post-MVP extensions" to a concrete
phase reference (Phase 24 or a sub-phase).

### 4. Validate host-domain resolution for test deps

The `hello-gtest` example exercises `when = .{.domain = .host}` for the gtest dep,
which validates the host-domain resolution path that has not been exercised by the
diamond example.

---

## Files to create/change

| File | Change |
|---|---|
| `examples/hello-gtest/upstream/gtest/zpkg.zon` | New: wrapper package manifest |
| `examples/hello-gtest/upstream/gtest/build.zig` | New: build gtest from source |
| `examples/hello-gtest/upstream/gtest/build.zig.zon` | New: pin gtest source |
| `examples/hello-gtest/app-with-tests/zpkg.zon` | New: app with gtest dep |
| `examples/hello-gtest/app-with-tests/build.zig` | New: app build |
| `examples/hello-gtest/app-with-tests/zpkg.lock.zon` | Generated after lock |
| `docs/zpkg-wrapper-packages.md` | New: wrapper package documentation |

---

## Validation

- `zpkg lock examples/hello-gtest/app-with-tests` succeeds.
- `zpkg build examples/hello-gtest/app-with-tests` builds gtest from source on cold store.
- `zpkg test examples/hello-gtest/app-with-tests` builds and runs the test binary.
- Warm store reuses the gtest binary artifact.
- `zig build test` passes with no regressions.

---

## Exit criteria

- A wrapper package for GoogleTest exists and builds end-to-end.
- The wrapper exercises `when = .{.domain = .host}` conditional dependency resolution.
- `docs/zpkg-wrapper-packages.md` documents all three build strategies with templates.
- `zig build test` passes.
