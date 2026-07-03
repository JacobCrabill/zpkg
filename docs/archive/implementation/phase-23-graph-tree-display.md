# Phase 23 — Graph Tree Display

## Problem

`zpkg graph` shows a flat list of instances rather than the actual dependency tree:

```
diamond.app#target @ 0.1.0.0
  diamond.libA#target @ 0.1.0.0
  diamond.libB#target @ 0.1.0.0
  diamond.libC#target @ 0.1.0.0
  diamond.libD#target @ 0.1.0.0
  diamond.libE#target @ 0.1.0.0
```

The actual dependency tree is:
```
diamond.app → diamond.libE
  diamond.libE → diamond.libC, diamond.libD
    diamond.libC → diamond.libA
    diamond.libD → diamond.libA, diamond.libB
```

This happens because `cli/graph.zig:87` calls `lockfile.findInstance(root_ref)` where
`root_ref` is derived from the lockfile's `.root` entry.  The root package
(`diamond.app`) is not stored as an instance — only its transitive dependencies are.
`findInstance` returns null, and the fallback at line 90 prints all instances flat.

The recursive `printInstanceDeps` function at line 104 is already correct and would
produce the right tree if it could be reached.

---

## Goal

Print the dependency tree starting from the root package.  Show direct and transitive
deps with correct indentation and connectors.  Make the output useful as a diagnostic
tool for understanding package relationships.

---

## Design

### Root instance gap

The root package (`diamond.app`) has deps recorded in `zpkg.zon` and implicitly in the
lockfile via its `source_path` entries, but there is no `instances` entry for the root
itself.  The lockfile only records the transitive dependency instances, not the root.

Options:

**Option A:** Add the root to the lockfile instances list.  This requires recording the
root's deps as a `LockfileInstance` entry in `generateLockfile`.

**Option B:** In `graph.zig`, build the root's dep list from the lockfile's instance
entries by finding all instances that match the root package's direct deps declared in
the zpkg.zon file (which `graph` would need to also read).

**Option C:** In `graph.zig`, when the root instance is not found in the lockfile, use
a synthetic root node whose deps are derived from all top-level instances (those not
referenced as a dep by any other instance).

Option A is cleanest because it makes the lockfile self-contained.

### Option A: Add root to lockfile instances

In `cli/lock.zig:generateLockfile`, include the root package as an instance:

```zig
// Add root instance with its direct deps from the resolved graph.
const root_instance_key = try std.fmt.allocPrint(
    allocator, "{s}#target", .{resolved.package_id.asText()}
);
const root_deps = ...; // from resolver.resolved.get(root_instance_key).deps
```

The root's `source_path` is `pkg_root` (or `.` relative to itself, since the lockfile
lives in the same directory).

### Graph display improvements

Once the root instance is findable, `printInstanceDeps` produces the correct output.
Make additional display improvements:

1. Show dep version next to each node, not just for the root.
2. Use tree connectors (`├─`, `└─`, `│ `) consistently (already started at line 134).
3. In `--verbose` mode, show:
   - per-instance selected options
   - content-addressed store key (16-char prefix)
   - whether the instance is a store hit or miss (requires plan information, so this
     may be a separate flag rather than `--verbose`)
4. Deduplicate shared deps (e.g., `diamond.libA` appears in multiple paths; show it
   fully on first occurrence and as a back-reference on subsequent ones):
   ```
   ├─ libC: diamond.libC#target @ 0.1.0.0
   │    └─ libA: diamond.libA#target @ 0.1.0.0
   └─ libD: diamond.libD#target @ 0.1.0.0
        ├─ libA: diamond.libA#target (see above)
        └─ libB: diamond.libB#target @ 0.1.0.0
   ```

---

## Required changes

### 1. `cli/lock.zig:generateLockfile` — include root as an instance

The root package's deps are available from `resolver.resolved`:

```zig
// The root appears in resolver.resolved; include it as a lockfile instance.
// Its source_path is "." (relative to the lockfile directory).
const root_key_str = try std.fmt.allocPrint(
    allocator, "{s}#target", .{resolved.package_id.asText()}
);
defer allocator.free(root_key_str);

if (resolver.resolved.get(root_key_str)) |root_pkg| {
    // Build root instance entry analogously to dep instances.
    // source_path = "." (lockfile lives in the root package directory).
    ...
    try instances.append(allocator, .{
        .key          = root_inst_key,
        .package_id   = root_pkg_id,
        .domain       = .target,
        .version      = resolved.version,
        .source_hash  = root_source_hash,
        .source_path  = ".",   // relative: lockfile is in the root package dir
        .selected_options = &.{},
        .deps         = root_deps_slice,
    });
}
```

### 2. `cli/graph.zig` — remove flat fallback; always use tree display

After the root instance is in the lockfile, `lockfile.findInstance(root_ref)` will
return it.  Remove the flat fallback at line 90–98 (or keep it only as an emergency
fallback with a warning).

### 3. `cli/graph.zig:printInstanceDeps` — add deduplication

Track visited instance keys in a `std.StringHashMap(void)`.  On second encounter,
print `(see above)` instead of recursing.

### 4. Regenerate `examples/diamond/app/zpkg.lock.zon`

After adding the root to `generateLockfile`, regenerate the lockfile with
`zpkg update examples/diamond/app`.  The root instance entry will appear.

---

## Files to change

| File | Change |
|---|---|
| `src/cli/lock.zig` | Include root package as a lockfile instance with its deps |
| `src/cli/update.zig` | Same (via shared `generateLockfile`) |
| `src/cli/graph.zig` | Remove flat fallback; add deduplication; improve version display |
| `examples/diamond/app/zpkg.lock.zon` | Regenerate |

---

## Validation

- `zpkg graph examples/diamond/app` shows the full dependency tree:
  ```
  diamond.app#target @ 0.1.0.0
  └─ libE: diamond.libE#target @ 0.1.0.0
       ├─ libC: diamond.libC#target @ 0.1.0.0
       │    └─ libA: diamond.libA#target @ 0.1.0.0
       └─ libD: diamond.libD#target @ 0.1.0.0
            ├─ libA: diamond.libA#target (see above)
            └─ libB: diamond.libB#target @ 0.1.0.0
  ```
- `--verbose` shows selected options for each node.
- Shared deps (libA) appear once fully and as back-references thereafter.
- `zpkg build examples/diamond/app` still works end-to-end.
- `zig build test` passes with no regressions.

---

## Exit criteria

- `zpkg graph` shows the full dependency tree, not a flat list.
- Shared deps are deduplicated with back-references.
- The root package is included as a lockfile instance.
- `zig build test` passes.
