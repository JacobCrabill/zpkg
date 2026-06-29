# Phase 22 — Build Profiles

## Problem

The workspace profile is hardcoded to `"debug-native"` in two places:

1. `realize/workspace.zig` exports `pub fn defaultProfile() []const u8 { return "debug-native"; }`
2. `realize/build_fallback.zig:287` passes `.optimize = .Debug` when deriving the
   instance key.

This means:
- All artifacts are stored under a single key regardless of optimize mode.
- `zpkg build` always produces debug binaries; there is no way to request a release build.
- Different optimize modes overwrite each other in the store (same key for Debug and
  ReleaseFast).
- Sanitizer builds (ASAN, TSAN), coverage builds, and custom variant builds are impossible.

For a large-scale C++ project, multiple profiles are not optional — release builds,
ASAN builds, and CI coverage runs are standard daily workflows.

---

## Goal

Introduce a `--profile <name>` flag to `zpkg build`, `zpkg test`, and `zpkg export`.
Map profile names to Zig optimize modes and workspace subdirectory names.  Include the
optimize mode in the content-addressed store key so artifacts from different profiles
do not collide.

---

## Design

### Built-in profiles

Define a small set of built-in profile names with canonical optimize mode mappings:

| Profile name | Zig optimize mode | Notes |
|---|---|---|
| `debug` (default) | `Debug` | Asserts on; no optimization |
| `release` | `ReleaseFast` | Maximum optimization |
| `safe` | `ReleaseSafe` | Optimized with safety checks |
| `small` | `ReleaseSmall` | Size-optimized |

The workspace directory becomes `.zpkg/work/<profile>-<target-triple>/`.
For native builds: `.zpkg/work/debug-native/`, `.zpkg/work/release-native/`, etc.

### Custom profiles (post-MVP)

Custom profiles (e.g., `asan`, `coverage`) with user-specified optimize mode overrides
and additional compile flags can be defined in a `zpkg.profiles.zon` file at the
workspace root.  This is deferred beyond this phase.

### Profile in the store key

`planBuild` currently passes `.optimize = .Debug` hardcoded.  It must instead receive
the profile's `OptimizeMode` and pass it through to `instance_key_mod.deriveHex`.

Since optimize mode is already part of the `InstanceKeyInput` struct, this is a
one-line change once the mode is threaded through.

### CLI changes

`zpkg build`, `zpkg test`, and `zpkg export` gain a `--profile <name>` flag:

```
zpkg build . --profile release
zpkg build . --profile debug   (default if omitted)
zpkg test  . --profile debug
```

Unrecognized profile names produce a clear error listing valid options.

---

## Required changes

### 1. `realize/workspace.zig` — parameterize profile

Replace `defaultProfile()` with a profile type:

```zig
pub const Profile = struct {
    name: []const u8,
    optimize: std.builtin.OptimizeMode,

    pub fn parse(name: []const u8) !Profile {
        if (std.mem.eql(u8, name, "debug"))   return .{ .name = "debug",   .optimize = .Debug };
        if (std.mem.eql(u8, name, "release")) return .{ .name = "release", .optimize = .ReleaseFast };
        if (std.mem.eql(u8, name, "safe"))    return .{ .name = "safe",    .optimize = .ReleaseSafe };
        if (std.mem.eql(u8, name, "small"))   return .{ .name = "small",   .optimize = .ReleaseSmall };
        return error.UnknownProfile;
    }

    pub fn defaultProfile() Profile {
        return .{ .name = "debug", .optimize = .Debug };
    }
};
```

`WorkspaceLayout.init` takes `profile: Profile` instead of a `[]const u8`.  The
workspace subdirectory becomes `<profile.name>-<target-suffix>`.

### 2. `realize/build_fallback.zig:planBuild` — accept optimize mode

`planBuild` signature gains `optimize: std.builtin.OptimizeMode`.  Pass it to
`deriveHex` instead of the hardcoded `.Debug`.

```zig
pub fn planBuild(
    allocator: std.mem.Allocator,
    lockfile: model.Lockfile,
    store: *store_mod.Store,
    mode: BuildMode,
    toolchain_fp: model.ToolchainFingerprint,
    optimize: std.builtin.OptimizeMode,   // ← new
) !BuildPlan {
```

### 3. `cli/build.zig` — add `--profile` flag

```zig
var profile = realize.workspace.Profile.defaultProfile();

// In arg parse loop:
} else if (std.mem.eql(u8, args[i], "--profile")) {
    i += 1;
    if (i >= args.len) { ... return error.InvalidArgument; }
    profile = realize.workspace.Profile.parse(args[i]) catch {
        try writeStderrFmt(io,
            "error: unknown profile '{s}'; valid profiles: debug, release, safe, small\n",
            .{args[i]}
        );
        return error.InvalidArgument;
    };
}
```

Pass `profile.optimize` to `planBuild` and `profile` to `WorkspaceLayout.init`.

### 4. `cli/test_cmd.zig` — same `--profile` flag

### 5. `cli/export.zig` — same `--profile` flag

### 6. `cli/build.zig:runBuild` — pass optimize to `zig build`

When invoking `zig build install --prefix <staging>`, add `-Doptimize=<mode>`:

```zig
const optimize_flag = switch (optimize) {
    .Debug        => "Debug",
    .ReleaseFast  => "ReleaseFast",
    .ReleaseSafe  => "ReleaseSafe",
    .ReleaseSmall => "ReleaseSmall",
};
const argv = &.{ "zig", "build", "install", "--prefix", staging_dir, "-Doptimize=" ++ optimize_flag };
```

This requires runtime string building since the flag is dynamic.

### 7. Update diamond example for multi-profile test

Add a test in `docs/quickstart.md` showing:
```sh
zpkg build . --profile release
```

---

## Files to change

| File | Change |
|---|---|
| `src/realize/workspace.zig` | Replace `defaultProfile()` with `Profile` struct |
| `src/realize/build_fallback.zig` | `planBuild` gains `optimize` param; remove hardcoded `.Debug` |
| `src/cli/build.zig` | Add `--profile` flag; thread profile through |
| `src/cli/test_cmd.zig` | Add `--profile` flag |
| `src/cli/export.zig` | Add `--profile` flag |
| `docs/quickstart.md` | Show `--profile release` example |

---

## Validation

- `zpkg build examples/diamond/app` produces a debug build (default).
- `zpkg build examples/diamond/app --profile release` produces a release build.
- Debug and release artifacts are stored under different keys in the store.
- A warm rebuild with `--profile release` hits the release store entries.
- A warm rebuild with `--profile debug` hits the debug store entries without rebuilding
  the release artifacts.
- `zpkg build . --profile unknown` fails with a clear error listing valid profiles.
- `zig build test` passes with no regressions.

---

## Exit criteria

- `--profile <name>` selects the optimize mode for the entire build.
- Profile name appears in the workspace directory (`.zpkg/work/release-native/`).
- Optimize mode is included in the content-addressed store key.
- Debug and release builds can coexist in the store without colliding.
- `zig build test` passes.
