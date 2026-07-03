# Phase 17 — ZON Parser Hardening

## Problem

Several core functions parse or rewrite ZON files using line scanning and string search
rather than the project's `schema/zon_util.zig` parser:

### `source_pkg.zig`

- **`extractField`** (line 289): finds a field value with `std.mem.indexOf(needle)` and
  reads up to the next `,`.  Breaks if the field spans multiple lines, if the value
  contains a comma, or if the field order differs from the expected layout.

- **`extractPathsBlock`** (line 300): locates `.paths = .{ ... }` by brace counting.
  Breaks on nested braces (e.g., paths values that are themselves structs) and on
  alternate whitespace or comment placement.

- **`readExtraDepsFromSource`** (line 159): reads `.dependencies` line-by-line,
  matching `.path = "..."` patterns.  Breaks on multi-line dep entries, on URL deps
  (`.url = ...`), and if the dep name and `.path` are on separate lines.

### `build_fallback.zig`

- **`patchFingerprintInBuildZigZon`** (line 481): replaces the fingerprint value by
  string search for `.fingerprint = `.  Breaks if there is a `.fingerprint` field in
  an inner struct or if the field uses unusual whitespace.

All four functions have the same root cause: they were written before `zon_util.zig`
existed (or as quick one-off implementations) and were never upgraded to use the
structured parser.

### Additional bug: `PackageCache.put` panics on OOM

**`resolve/root.zig:357`:**

```zig
fn put(self: *PackageCache, key: []const u8, value: model.PackageManifest) void {
    self.entries.put(self.allocator, key, value) catch unreachable;
}
```

`catch unreachable` panics under memory pressure.  This should propagate the error.

---

## Required changes

### 1. Replace `extractField` and `extractPathsBlock` with `zon_util.zig` parsing

**File:** `realize/source_pkg.zig`, function `readSourceFields`

Parse `build.zig.zon` using `zon_util.parseDocument` and extract fields by name using
`zon_util.Object`:

```zig
fn readSourceFields(self: *SourcePkgRealize, source_dir: []const u8) !SourceFields {
    const content = ...; // read build.zig.zon
    const sentinel = try self.allocator.dupeZ(u8, content);
    defer self.allocator.free(sentinel);
    var doc = try zon_util.parseDocument(self.allocator, sentinel);
    defer doc.deinit(self.allocator);

    const root = try zon_util.Object.fromNode(&doc, .root);

    const name_node  = try root.require("name");
    const name       = try zon_util.parseIdentOrStringAlloc(self.allocator, &doc, name_node);

    const fp_node    = root.get("fingerprint");
    const fingerprint: ?u64 = if (fp_node) |n|
        @as(u64, @bitCast(try zon_util.parseInt(&doc, n))) // adjust for zon_util API
    else null;

    // ...similar for version, minimum_zig_version, paths
}
```

The `paths` field extraction must also handle the `.paths = .{ "a", "b" }` array form
correctly using `zon_util.Array`.

The serialized `paths_text` currently carried as a raw string (re-emitted verbatim)
should be replaced with a structured `[][]const u8` and re-serialized cleanly.

### 2. Replace `readExtraDepsFromSource` with `zon_util.zig` parsing

**File:** `realize/source_pkg.zig`, function `readExtraDepsFromSource`

Parse the `.dependencies` struct from `build.zig.zon`:

```zig
const deps_node = root.get("dependencies") orelse return result;
const deps_obj  = try zon_util.Object.fromNode(&doc, deps_node);
for (0..deps_obj.fieldCount()) |i| {
    const dep_name = deps_obj.fieldName(i);
    if (resolved_deps.contains(dep_name)) continue;

    const dep_val = try zon_util.Object.fromNode(&doc, deps_obj.fieldNode(i));
    const path_node = dep_val.get("path") orelse continue;
    const rel_path = try zon_util.parseNonEmptyStringAlloc(self.allocator, &doc, path_node);
    // ...resolve and store
}
```

This handles multi-line entries, URL deps (no `.path` field — `get("path")` returns
null), and arbitrary field ordering.

### 3. Replace `patchFingerprintInBuildZigZon` with structured rewrite

**File:** `realize/build_fallback.zig`

Rather than patching in place, regenerate the entire `build.zig.zon` with the corrected
fingerprint:

1. Parse the file with `zon_util`.
2. Extract all fields into a `SourceFields` struct (reusing the `readSourceFields`
   function from `source_pkg.zig` after fix #1 above).
3. Re-emit with the corrected fingerprint using `generateBuildZigZon`.

This eliminates the fragile string replacement entirely and reuses already-tested code.

### 4. Fix `PackageCache.put` OOM panic

**File:** `resolve/root.zig`

Change the `PackageCache` `put` method to propagate errors:

```zig
fn put(self: *PackageCache, key: []const u8, value: model.PackageManifest) !void {
    try self.entries.put(self.allocator, key, value);
}
```

Update the single call site in `resolveManifests` to handle the error:

```zig
try self.package_cache.put(cache_key, dep_manifest);
```

---

## Files to change

| File | Change |
|---|---|
| `realize/source_pkg.zig` | Replace `extractField`, `extractPathsBlock`, `readExtraDepsFromSource` with `zon_util` parsing |
| `realize/source_pkg.zig` | Change `SourceFields.paths_text: []const u8` to `paths: [][]const u8`; update `generateBuildZigZon` |
| `realize/build_fallback.zig` | Replace `patchFingerprintInBuildZigZon` with parse-and-regenerate |
| `resolve/root.zig` | Fix `PackageCache.put` to return `!void`; update call site |

---

## What not to change

Do not rewrite ZON *emission* code (`emit` in `zpkg-build/src/root.zig`,
`generateBuildZigZon` in `source_pkg.zig`).  Emitting hand-formatted ZON strings is
fine.  The problem is *parsing* existing ZON files with string search.

---

## Validation

For each changed parser:

- Write a test with the field of interest at the end of the file (not first).
- Write a test with extra whitespace and blank lines inside the block.
- Write a test with the dependency block containing a URL dep (`url = "..."`) as well
  as a path dep.
- Write a test with a fingerprint value that is zero-padded differently from the
  emitted format.

Also:

- Verify `zig build test` passes with no regressions.
- Verify that the diamond example continues to build end-to-end.

---

## Exit criteria

- `extractField`, `extractPathsBlock`, and `readExtraDepsFromSource` are deleted and
  replaced with `zon_util`-based implementations.
- `patchFingerprintInBuildZigZon` is deleted and replaced with a
  parse-and-regenerate approach.
- `PackageCache.put` propagates `!void` instead of `catch unreachable`.
- All new code paths have tests covering the edge cases listed above.
- `zig build test` passes with no regressions.
