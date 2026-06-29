# Phase 19 — Relative Source Paths in Lockfile

## Problem

`zpkg lock` and `zpkg update` record absolute source paths in the lockfile:

```zon
.@"diamond.libA#target" = .{
    .source_path = "/home/jacob/Codes/personal/zpkg/examples/diamond/libA",
    ...
},
```

These paths are machine-specific.  A lockfile committed to source control cannot be
used by another developer without running `zpkg update`, because the absolute paths
from one machine will not exist on another.  In CI, the checkout path is usually a
fresh temporary directory.  Every developer must re-run `zpkg update` after every
checkout, defeating the purpose of a committed lockfile.

---

## Goal

Store source paths in the lockfile relative to the workspace root (the directory
containing the root `zpkg.zon`), and resolve them to absolute at use time.  The
lockfile must be portable across machines with different checkout locations.

---

## Design

### Relative path form in the lockfile

Source paths in the lockfile are stored relative to the directory containing the
lockfile itself (i.e., the root package directory).  Example:

```zon
.@"diamond.libA#target" = .{
    .source_path = "../../libA",   // relative to examples/diamond/app/
    ...
},
```

At use time (`zpkg build`, `zpkg export`), the tool resolves:
```
abs_path = resolve(lockfile_dir, instance.source_path)
```

### Lock-time conversion

In `cli/lock.zig:generateLockfile`, after computing `dep_dir_path` (currently the
absolute path from the resolver), convert it to a path relative to the lockfile's
directory before storing it in the instance.

```zig
// Before storing:
const rel_path = try std.fs.path.relative(allocator, pkg_root, dep_dir_path);
```

`pkg_root` is the directory that will contain the lockfile (passed into
`generateLockfile` already).

### Build-time resolution

In `realize/build_fallback.zig:buildInstance` and `reifyStoreHit`, resolve
`instance.source_path` against the lockfile directory:

```zig
const abs_source = if (std.fs.path.isAbsolute(instance.source_path))
    try allocator.dupe(u8, instance.source_path)
else
    try std.fs.path.resolve(allocator, &.{ lockfile_dir, instance.source_path });
```

The `lockfile_dir` must be threaded into `BuildExecutor` at construction time.

### Backward compatibility

Accept both absolute and relative paths on read: if `instance.source_path` starts
with `/`, treat it as absolute (old lockfile); otherwise resolve relative to the
lockfile directory.  This allows old lockfiles to continue working without requiring
immediate regeneration.

---

## Required changes

### 1. `cli/lock.zig` — convert absolute path to relative before storing

In `generateLockfile`, replace:
```zig
const src_path_str = try allocator.dupe(u8, dep_dir_path);
```
with:
```zig
const src_path_str = try std.fs.path.relative(allocator, pkg_root, dep_dir_path);
```

This requires `pkg_root` to be passed into `generateLockfile` (it is already, but
currently ignored via `_ = pkg_root`).

### 2. `cli/update.zig` — same change as lock.zig

`zpkg update` calls the same `generateLockfile` function; the fix applies automatically
once `lock.zig` is updated.

### 3. `realize/build_fallback.zig` — resolve relative paths at use time

`BuildExecutor` gains a `lockfile_dir: []const u8` field set at construction.

In `buildInstance`:
```zig
const abs_source_dir = try resolveLockfilePath(
    allocator, self.lockfile_dir, instance.source_path
);
defer allocator.free(abs_source_dir);
```

Add helper:
```zig
fn resolveLockfilePath(
    allocator: std.mem.Allocator,
    lockfile_dir: []const u8,
    path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ lockfile_dir, path });
}
```

### 4. `cli/build.zig` — pass lockfile_dir to BuildExecutor

```zig
var executor = build_fallback.BuildExecutor.init(
    allocator, io, &store, &layout, abs_root,
    abs_root,   // ← lockfile_dir; lockfile lives in pkg root
    max_jobs
);
```

### 5. Regenerate diamond example lockfile

After the change, run `zpkg update examples/diamond/app` to regenerate the lockfile
with relative paths.  Verify the paths are relative and correct.

---

## Files to change

| File | Change |
|---|---|
| `src/cli/lock.zig` | Convert absolute dep path to relative before storing in lockfile |
| `src/cli/update.zig` | Same (shared via `generateLockfile`) |
| `src/realize/build_fallback.zig` | Add `lockfile_dir` to `BuildExecutor`; resolve relative paths at use time |
| `src/cli/build.zig` | Pass `abs_root` as `lockfile_dir` to executor |
| `examples/diamond/app/zpkg.lock.zon` | Regenerate with relative paths |

---

## Validation

- Run `zpkg update examples/diamond/app`; confirm `source_path` entries in the
  lockfile are relative (e.g., `../../libA` or `../libA` depending on layout).
- Copy the lockfile to a different directory (or a machine with a different checkout
  path) and confirm `zpkg build` still resolves source correctly.
- Run `zpkg build examples/diamond/app` cold and warm; both must succeed.
- An old lockfile with absolute paths should continue to work (backward-compat path).
- `zig build test` passes with no regressions.

---

## Exit criteria

- Lockfile `source_path` values are relative to the lockfile's directory.
- `zpkg build` resolves relative paths correctly against the lockfile directory.
- The diamond example lockfile is committed with relative paths and is usable from any
  checkout location without modification.
- Absolute paths in old lockfiles are still accepted (backward compatibility).
- `zig build test` passes.
