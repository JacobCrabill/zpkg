# Phase 16 — Source Location Model

## Problem

Both `resolve/root.zig` and `realize/build_fallback.zig` find source packages by
deriving a filesystem path from the package ID:

```zig
// build_fallback.zig:246–252
const pkg_basename = if (std.mem.lastIndexOfScalar(u8, pkg_name, '.')) |dot_idx|
    pkg_name[dot_idx + 1 ..]
else pkg_name;
const source_dir = try std.Io.Dir.path.join(allocator, &.{ self.pkg_root, "..", pkg_basename });
```

This convention is:
- **Undocumented** — not mentioned in `zpkg.zon` schema docs or the architecture doc.
- **Unvalidated** — no error until the directory is accessed.
- **Implicit** — the package ID must encode the directory name.
- **Brittle** — fails the moment any package lives outside the flat sibling layout:
  nested directories, different repositories, renamed directories, external packages.

The same pattern appears in `resolve/root.zig:182–189` for reading `zpkg.zon` during
resolution.

---

## Goal

Replace the implicit filesystem convention with explicit, validated source location
configuration.  The resolver and build executor must never derive a source path from a
package ID.  All source paths must be declared explicitly and verified at
`zpkg lock` time.

---

## Design

### Option A: `source_path` field in `zpkg.zon`

Each dependency declaration in `zpkg.zon` gains an optional `source_path`:

```zig
.deps = .{
    .libA = .{
        .package = "diamond.libA",
        .require = .{ .version = "=0.1.0.0" },
        .source_path = "../libA",   // ← new: relative to this zpkg.zon
    },
},
```

`zpkg lock` reads these paths during resolution and records the resolved absolute paths
in the lockfile.  The resolver no longer guesses.

**Pros:** self-contained; each package describes where its dependencies live.
**Cons:** repeats paths that may already be configured in `build.zig.zon`; doesn't
scale well for a workspace with many packages.

### Option B: Workspace manifest (`zpkg.workspace.zon`)

A workspace-level file at the repository root lists all packages:

```zig
.{
    .schema = 1,
    .packages = .{
        .@"diamond.libA" = .{ .path = "examples/diamond/libA" },
        .@"diamond.libB" = .{ .path = "examples/diamond/libB" },
        .@"diamond.libC" = .{ .path = "examples/diamond/libC" },
        // ...
    },
}
```

`zpkg` searches for `zpkg.workspace.zon` up the directory tree from the root package,
similar to how `Cargo` finds `Cargo.toml` workspaces.  When found, the workspace
manifest is the authoritative source-path map.

**Pros:** centralizes all package locations; enables a shared lockfile across the
workspace; natural fit for monorepos.
**Cons:** requires a new file and new tooling; external packages still need a separate
mechanism.

### Option C: Both (recommended)

Implement the workspace manifest (Option B) as the primary mechanism and allow
`source_path` overrides in `zpkg.zon` (Option A) for cases where the workspace
manifest doesn't apply (e.g., a standalone package depending on a package in a
different repository).

For the MVP fix, Option A alone is sufficient to unblock non-toy repos.  Option B
is the right long-term structure and can be layered on top.

---

## Required changes (Option A — MVP scope)

### 1. `zpkg.zon` schema: add `source_path` to dependency entries

**File:** `src/schema/zpkg.zig`, `docs/zpkg-schema.md`

Add an optional `source_path: ?[]const u8` field to `Dependency` (or the parsed
`model.Dependency`).  The field is a path string relative to the declaring package's
`zpkg.zon`.

Validation at parse time:
- If present, must be a non-empty string.
- Must not be an absolute path.
- The referenced directory is validated to exist (and contain a `zpkg.zon`) at
  `zpkg lock` time, not at parse time.

### 2. Resolver: use `source_path` when provided; error when absent

**File:** `src/resolve/root.zig`

Change `parseDependencyManifest` to:
1. If the dependency's `source_path` is set, resolve it relative to the current
   package's directory and read `<source_path>/zpkg.zon`.
2. If `source_path` is absent, produce a clear error:

```
error: dependency 'diamond.libA' has no source_path.
Hint: add .source_path = "<relative-path>" to the .deps.libA entry in zpkg.zon,
or add this package to a zpkg.workspace.zon file.
```

Remove the implicit `../basename` fallback entirely.

### 3. Lockfile: record resolved source paths

**File:** `src/schema/lockfile.zig`, `src/model/lockfile.zig`

Each lockfile instance entry gains a `source_path` field recording the absolute path
to the source directory at lock time:

```zon
.@"diamond.libA#target" = .{
    .package     = "diamond.libA",
    .source_path = "/home/user/projects/diamond/libA",  // ← new
    ...
},
```

This allows `zpkg build` to find sources from the lockfile directly without re-running
the resolver.

### 4. Build executor: use lockfile `source_path`

**File:** `realize/build_fallback.zig`

Replace the `../basename` derivation with `instance.source_path` from the lockfile
entry.  If `source_path` is missing from the lockfile entry (old lockfile format), emit
a clear error asking the user to re-run `zpkg lock`.

### 5. Update diamond example `zpkg.zon` files

Add `source_path` to every dependency in `examples/diamond/*/zpkg.zon`:

```zig
// examples/diamond/libC/zpkg.zon
.deps = .{
    .libA = .{
        .package = "diamond.libA",
        .require = .{ .version = "=0.1.0.0" },
        .source_path = "../libA",
    },
},
```

Regenerate `zpkg.lock.zon` after updating.

---

## Option B additions (workspace manifest — post-MVP)

When the workspace manifest is implemented:

- Add `zpkg.workspace.zon` parsing to `src/schema/`.
- `zpkg` searches for the file from the root package dir upward, stopping at a
  filesystem root or a directory that has no `zpkg.workspace.zon`.
- If found, the workspace manifest is used as the source of truth for all package
  source paths, overriding `source_path` entries in individual `zpkg.zon` files.
- `zpkg lock` should accept an optional `--workspace <path>` flag to pin the workspace
  root explicitly.
- A single `zpkg.lock.zon` at the workspace root can replace per-package lockfiles.

---

## Files to change

| File | Change |
|---|---|
| `src/schema/zpkg.zig` | Parse optional `source_path` field in dependency entries |
| `src/model/package.zig` | Add `source_path: ?[]const u8` to `Dependency` |
| `src/schema/lockfile.zig` | Parse/emit `source_path` in instance entries |
| `src/model/lockfile.zig` | Add `source_path: []const u8` to `Instance` |
| `src/resolve/root.zig` | Use `source_path`; error when absent |
| `src/realize/build_fallback.zig` | Use `instance.source_path` from lockfile |
| `src/cli/lock.zig` | Validate source paths during lock generation |
| `docs/zpkg-schema.md` | Document `source_path` field |
| `docs/zpkg-lockfile.md` | Document `source_path` in lockfile entries |
| `examples/diamond/*/zpkg.zon` | Add `source_path` to all dep entries |
| `examples/diamond/app/zpkg.lock.zon` | Regenerate |

---

## Validation

After this phase:

- `zpkg lock .` in `examples/diamond/app` succeeds with explicit `source_path` fields
  in all `zpkg.zon` files.
- `zpkg lock .` with a dep missing `source_path` fails with a clear, actionable error.
- `zpkg build .` in `examples/diamond/app` succeeds (both cold and warm store).
- Moving a package directory and updating its `source_path` (without changing the ID
  or version) works correctly: the lockfile is regenerated, the existing store artifact
  is reused (same source hash if files didn't change), and the new path is used.
- A package in a non-sibling location (e.g., two levels up) works when `source_path`
  points there correctly.

---

## Exit criteria

- No code in `resolve/` or `realize/` derives a filesystem path from a package ID.
- All package source paths are declared in `zpkg.zon` via `source_path` and recorded
  in the lockfile.
- The diamond example works end-to-end with explicit `source_path` declarations.
- Missing `source_path` produces a clear, actionable error.
- `zig build test` passes with no regressions.
