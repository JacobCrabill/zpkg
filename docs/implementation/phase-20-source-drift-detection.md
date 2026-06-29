# Phase 20 — Source Drift Detection

## Problem

When a developer modifies a source file without running `zpkg update`, the lockfile's
`source_hash` is stale.  The build executor computes the store key using
`instance.source_hash` (the lockfile's value), not the actual current source content.
If the old artifact exists in the store under that key, it is used silently:

```zig
// build_fallback.zig:281-291
const hex_digest = instance_key_mod.deriveHex(allocator, .{
    ...
    .source_hash = instance.source_hash,  // ← lockfile value, never verified
    ...
});
```

Consequence: `libA` source is edited, but `zpkg build` reuses the old binary.  The
developer's change is invisible to downstream packages until they notice the binary
hasn't changed and manually run `zpkg update`.  On a team, one developer's stale
lockfile can cause another developer to reuse the wrong artifact from a shared store.

---

## Goal

Before accepting a store hit, verify that the actual current source hash matches the
lockfile's recorded `source_hash`.  On mismatch, warn the developer and treat the
instance as a store miss (force rebuild).

---

## Design

### Where to check

In `planBuild` (inside `dfsVisit`), after computing the store key, hash the actual
source directory and compare with `instance.source_hash`.  If they differ, mark the
instance as a miss regardless of whether the store key exists.

This keeps the check in the planning phase rather than the execution phase, so the
full set of stale packages is visible before any build work starts.

### Hash computation

Re-use `src/hash/source_hash.zig:hashPackageSource`.  The source directory is available
from `instance.source_path` (after Phase 19 makes paths resolvable).

### Behavior on mismatch

Two options:

**Option A (warn + rebuild):** Log a warning and mark the instance as a miss.  The
rebuild uses the new source and stores under the new key (the new source hash updates
the key).  The lockfile is not updated automatically.

```
[warn]  diamond.libA#target: source has changed since last 'zpkg update'
        lockfile hash: a61a1d...
        actual hash:   f09c3b...
        Forcing rebuild. Run 'zpkg update' to update the lockfile.
[build] diamond.libA#target  (new key)
```

**Option B (error):** Treat a drift as a hard error.  The developer must run
`zpkg update` before building.

```
error: diamond.libA#target: source has changed since last 'zpkg update'
       lockfile hash: a61a1d...
       actual hash:   f09c3b...
       Run 'zpkg update' to regenerate the lockfile.
```

Option A is recommended: it keeps the build working while surfacing the problem.
A `--strict-lockfile` flag can enable Option B behavior for CI.

### Performance

Hashing is the dominant cost.  For a repo with 50 packages each containing 1,000 files,
this adds O(50 × 1000) file reads before any build work starts.  This is acceptable
for a correctness check, but a future optimization could cache hashes keyed by directory
mtime (similar to `make`-style timestamps).

For the MVP, always hash; document the overhead.

---

## Required changes

### 1. `realize/build_fallback.zig:dfsVisit` — verify source hash

After computing `hex_digest` and before checking the store:

```zig
// Verify source hash against lockfile if source_path is known.
if (instance.source_path.len > 0) blk: {
    const abs_source = try resolveLockfilePath(
        allocator, lockfile_dir, instance.source_path
    );
    defer allocator.free(abs_source);

    const src_dir = std.Io.Dir.cwd().openDir(io, abs_source, .{}) catch break :blk;
    defer src_dir.close(io);

    const actual_hex = source_hash.hashPackageSource(
        allocator, src_dir, io, 1
    ) catch break :blk;

    if (!std.mem.eql(u8, &actual_hex, instance.source_hash)) {
        // Warn and force miss.
        try printStderr(io,
            "warning: {s}: source has changed since last 'zpkg update'\n" ++
            "         lockfile hash: {s}\n" ++
            "         actual hash:   {s}\n" ++
            "         Forcing rebuild. Run 'zpkg update' to update the lockfile.\n",
            .{ key_text, instance.source_hash, actual_hex }
        );
        // Skip store-hit check; mark as miss below.
        drift_detected = true;
    }
}
```

### 2. `realize/build_fallback.zig:planBuild` — thread `io` and `lockfile_dir` into `dfsVisit`

`planBuild` gains `io: std.Io` and `lockfile_dir: []const u8` parameters.
`dfsVisit` gains the same.  The existing callers in `cli/build.zig` already have `io`
and `abs_root`; these are passed through.

### 3. `cli/build.zig` — pass `io` and `lockfile_dir` to `planBuild`

```zig
var plan = try build_fallback.planBuild(
    allocator, lockfile, &store, mode, toolchain_fp,
    io, abs_root   // ← new args
);
```

### 4. `cli/build.zig` — add `--strict-lockfile` flag

When set, convert source drift warnings into errors and abort before any build work.

---

## Files to change

| File | Change |
|---|---|
| `src/realize/build_fallback.zig` | `dfsVisit` verifies source hash; emits warning on drift; marks miss |
| `src/realize/build_fallback.zig` | `planBuild` signature gains `io` and `lockfile_dir` |
| `src/cli/build.zig` | Pass `io` and `abs_root` to `planBuild`; add `--strict-lockfile` flag |
| `src/cli/test_cmd.zig` | Same changes as `build.zig` |

---

## Validation

- Modify a source file in `examples/diamond/libA/src/`.
- Run `zpkg build examples/diamond/app`.
- Confirm a drift warning is printed for `diamond.libA#target`.
- Confirm libA is rebuilt (store miss path) using the new source.
- Confirm downstream packages (libC, libD, libE, app) are also rebuilt (new dep key).
- Without modification, confirm no drift warnings are printed.
- With `--strict-lockfile`, confirm a drift causes a hard error before any build.
- `zig build test` passes with no regressions.

---

## Exit criteria

- Source changes are never silently ignored.
- Modified packages produce a drift warning and are forced to rebuild.
- Unmodified packages produce no drift output.
- `--strict-lockfile` flag turns drift warnings into errors.
- `zig build test` passes.
