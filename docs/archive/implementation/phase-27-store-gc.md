# Phase 27 — Store Garbage Collection

## Problem

The zpkg store (`$XDG_CACHE_HOME/zpkg/`) grows indefinitely.  Every unique combination
of package + version + toolchain + options + optimize mode + dep graph produces a new
store entry that is never removed.  On an active development machine with:

- 50 packages
- 4 optimize profiles (debug, release, safe, small)
- 3 toolchain versions over a year of development
- weekly source changes causing new store keys

This accumulates to thousands of store entries consuming tens of gigabytes.

The current store layout:
```
$XDG_CACHE_HOME/zpkg/
  artifacts/
    <64-char-hex>/
      prefix.tar.zst
      manifest.zon
  expanded/
    <64-char-hex>/
      include/
      lib/
      bin/
      share/
```

There is no command to prune old entries.

---

## Goal

Implement `zpkg gc` (garbage collect) to remove store entries that are no longer
referenced by any committed lockfile in the repository.

---

## Design

### Reachability

A store entry is "reachable" if its hex key appears in:
1. Any `zpkg.lock.zon` or `zpkg.workspace.lock.zon` accessible from the current workspace.
2. Any additional roots provided by the user via `--keep-ref`.

An entry is "unreachable" if it does not appear in any reachable lockfile.

This is analogous to `git gc`: only objects reachable from named refs are kept.

### GC modes

| Mode | Behavior |
|---|---|
| `zpkg gc` | Dry run: print what would be removed, but do not remove anything |
| `zpkg gc --prune` | Remove unreachable entries |
| `zpkg gc --prune --older-than 30d` | Remove only entries that haven't been accessed in N days |

Dry run is the default to prevent accidental deletion.

### Finding reachable keys

1. Find all `zpkg.lock.zon` and `zpkg.workspace.lock.zon` files.
   - If in a workspace, use the workspace root.
   - Otherwise, search the current directory and up.
   - Accept `--lockfile <path>` to add additional lockfiles.
2. Parse each lockfile and collect all `source_hash` values.
3. For each `(package_id, domain, version, source_hash, toolchain_fp, options, optimize)` tuple,
   derive the hex key via `instance_key_mod.deriveHex`.  Keys present in the store
   and derivable from lockfile data are reachable.

Simpler alternative: collect hex keys from artifact `manifest.zon` files and match
against lockfile data.  This avoids re-deriving keys but requires reading every manifest.

### `--older-than` mode

Use the file mtime on the `artifacts/<key>/` directory.  Entries older than the
threshold that are also unreachable are candidates for removal.  Entries that are
reachable are kept regardless of age.

### Safety checks

Before removing anything:
- Confirm the user passed `--prune`.
- Print a summary: `Removing N entries (X GB)`.
- Ask for confirmation unless `--yes` is passed.

---

## Required changes

### 1. `src/cli/gc.zig` — new command

```zig
pub fn run(args: []const []const u8, io: std.Io) !void {
    // Parse: --prune, --older-than N, --yes, --lockfile <path>
    // Find reachable keys
    // Find all store entries
    // Compute unreachable set
    // Print summary
    // If --prune and (--yes or confirmed), delete entries
}
```

### 2. `src/store/store.zig` — add GC helpers

```zig
/// List all artifact hex keys currently in the store.
pub fn listArtifactKeys(
    self: *Store,
    allocator: std.mem.Allocator,
    io: std.Io,
) ![][]u8 { ... }

/// Compute total size of a store entry (artifacts/ + expanded/).
pub fn entrySize(self: *Store, io: std.Io, hex_key: []const u8) !u64 { ... }

/// Remove a store entry (artifacts/<key>/ and expanded/<key>/).
pub fn removeEntry(self: *Store, io: std.Io, hex_key: []const u8) !void { ... }
```

### 3. `src/cli/root.zig` — route `zpkg gc`

Add `gc` as a new subcommand.

### 4. `docs/quickstart.md` — add GC section

Document `zpkg gc` and `zpkg gc --prune`.

---

## Files to create/change

| File | Change |
|---|---|
| `src/cli/gc.zig` | New: garbage collection command |
| `src/store/store.zig` | Add `listArtifactKeys`, `entrySize`, `removeEntry` |
| `src/cli/root.zig` | Route `zpkg gc` |
| `docs/quickstart.md` | Document GC workflow |

---

## Validation

- Build the diamond example twice (with different source changes between runs) to
  produce multiple store entries.
- `zpkg gc` (dry run) prints both entries as candidates.
- `zpkg gc --prune` (with confirmation) removes entries not referenced by the current
  lockfile.
- Reachable entries are never removed, even with `--prune --yes`.
- After `zpkg gc --prune`, `zpkg build` on a cold store rebuilds correctly.
- `zig build test` passes with no regressions.

---

## Exit criteria

- `zpkg gc` prints what would be removed without modifying the store.
- `zpkg gc --prune` removes unreachable store entries after confirmation.
- Reachable entries (referenced by any accessible lockfile) are never removed.
- `--older-than N` limits pruning to entries older than N days.
- `zig build test` passes.
