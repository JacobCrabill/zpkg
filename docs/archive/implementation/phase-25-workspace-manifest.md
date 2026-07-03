# Phase 25 — Workspace Manifest

## Problem

In a monorepo with multiple applications, each application has its own `zpkg.lock.zon`.
There is no mechanism to detect or prevent inconsistency:

- `appA` resolves `libX` at version `1.2.0`
- `appB` resolves `libX` at version `1.3.0`
- Both lockfiles are valid in isolation, but when deployed together or when a shared
  build cache is used, the mismatch causes subtle errors

Additionally, per-package lockfiles mean:
- A developer changes `libX` and must update every downstream app's lockfile manually
- CI must build N separate dependency graphs for N apps, even if they share most deps
- There is no single command to "build everything in the repo"

For large C++ projects (50+ packages, 5-10 apps), this is not just inconvenient — it
makes consistent cross-app builds impractical.

---

## Goal

Introduce a `zpkg.workspace.zon` file at the repository root that:

1. Lists all packages in the repository with their source paths.
2. Establishes a single shared lockfile for the workspace.
3. Enables `zpkg build` (without a package argument) to build all packages.
4. Ensures all packages resolve shared deps to the same version.

---

## Design

### `zpkg.workspace.zon` schema

```zig
.{
    .schema = 1,

    .packages = .{
        .@"diamond.libA" = .{ .path = "examples/diamond/libA" },
        .@"diamond.libB" = .{ .path = "examples/diamond/libB" },
        .@"diamond.libC" = .{ .path = "examples/diamond/libC" },
        .@"diamond.libD" = .{ .path = "examples/diamond/libD" },
        .@"diamond.libE" = .{ .path = "examples/diamond/libE" },
        .@"diamond.app"  = .{ .path = "examples/diamond/app" },
    },
}
```

Paths are relative to the `zpkg.workspace.zon` file.

### Workspace lockfile

When a `zpkg.workspace.zon` is present, `zpkg lock` generates a single
`zpkg.workspace.lock.zon` at the workspace root rather than per-package lockfiles.

The workspace lockfile resolves all packages in the workspace simultaneously, enforcing
a single version per `(package_id, domain)` pair across the entire repo.  Any version
conflict (two packages requiring incompatible versions of a shared dep) is a hard error
at `zpkg lock` time.

### Discovery

`zpkg` searches for `zpkg.workspace.zon` by walking up the directory tree from the
package root, stopping at the filesystem root.  This mirrors Cargo's workspace discovery.

When found:
- The workspace lockfile is used for all builds in the workspace.
- Per-package `zpkg.lock.zon` files are no longer generated or read.
- `source_path` overrides in individual `zpkg.zon` files are still honoured but
  should be consistent with workspace package paths.

When not found: per-package lockfile behavior continues unchanged.

### `zpkg build` without a package argument

When run from within a workspace (with a `zpkg.workspace.zon` found), `zpkg build`
with no argument builds all packages in the workspace in dependency order.

`zpkg build <pkg-id>` builds a specific package and its transitive dependencies.

### Workspace commands

New/updated commands:

| Command | Behavior |
|---|---|
| `zpkg workspace lock` | Generate `zpkg.workspace.lock.zon` from all workspace packages |
| `zpkg workspace update` | Regenerate workspace lockfile |
| `zpkg workspace build` | Build all packages in the workspace |
| `zpkg workspace graph` | Show the combined dependency graph for all packages |

---

## Required changes

### 1. `src/schema/workspace.zig` — new workspace schema

Parse `zpkg.workspace.zon`:

```zig
pub const WorkspaceManifest = struct {
    schema: u32,
    packages: []WorkspacePackage,

    pub fn deinitOwned(self: WorkspaceManifest, allocator: std.mem.Allocator) void { ... }
};

pub const WorkspacePackage = struct {
    id: model.PackageId,
    path: []const u8,
};

pub fn parseFileAlloc(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    filename: []const u8,
) !WorkspaceManifest { ... }
```

### 2. `src/util/workspace.zig` — workspace discovery

```zig
/// Walk up from `start_dir` looking for `zpkg.workspace.zon`.
/// Returns the absolute path of the workspace root, or null if not found.
pub fn findWorkspaceRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_dir: []const u8,
) !?[]u8 { ... }
```

### 3. `src/model/lockfile.zig` — workspace lockfile variant

The workspace lockfile has multiple root packages instead of one:

```zig
pub const WorkspaceLockfile = struct {
    schema: u32,
    roots: []WorkspaceRoot,
    instances: []Instance,
    ...
};
```

### 4. `src/cli/lock.zig` — detect and generate workspace lockfile

Before generating a per-package lockfile, search for `zpkg.workspace.zon`.  If found,
generate `zpkg.workspace.lock.zon` instead.

### 5. `src/cli/build.zig` — workspace-aware build

When invoked from a workspace directory without a package argument, build all workspace
packages in dependency order.

### 6. `src/cli/workspace.zig` — new `zpkg workspace` subcommand

Route `zpkg workspace <subcommand>` to workspace-specific handlers.

---

## Files to create/change

| File | Change |
|---|---|
| `src/schema/workspace.zig` | New: parse `zpkg.workspace.zon` |
| `src/util/workspace.zig` | Update: add `findWorkspaceRoot` |
| `src/model/lockfile.zig` | Add workspace lockfile variant |
| `src/cli/workspace.zig` | New: `zpkg workspace` subcommand |
| `src/cli/lock.zig` | Detect workspace; generate workspace lockfile |
| `src/cli/update.zig` | Detect workspace; update workspace lockfile |
| `src/cli/build.zig` | Workspace-aware build |
| `src/cli/root.zig` | Route `zpkg workspace` |
| `examples/diamond/zpkg.workspace.zon` | New: diamond workspace manifest |
| `docs/zpkg-workspace.md` | New: workspace documentation |

---

## Validation

- Create `examples/diamond/zpkg.workspace.zon` listing all 6 diamond packages.
- `zpkg workspace lock examples/diamond` creates `examples/diamond/zpkg.workspace.lock.zon`
  with all 5 library instances.
- `zpkg build examples/diamond/app` (inside the workspace) uses the workspace lockfile.
- Two apps with conflicting version requirements for a shared dep fail at `zpkg lock`
  with a clear "version conflict" error.
- `zpkg workspace build examples/diamond` builds all packages in the workspace.
- `zig build test` passes with no regressions.

---

## Exit criteria

- `zpkg.workspace.zon` can list all packages in a monorepo.
- A single `zpkg.workspace.lock.zon` resolves all packages to consistent versions.
- Version conflicts across apps are detected at lock time and reported clearly.
- `zpkg workspace build` builds all packages in the workspace.
- Workspace root is discovered automatically by walking up the directory tree.
- `zig build test` passes.
