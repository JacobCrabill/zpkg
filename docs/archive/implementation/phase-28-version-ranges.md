# Phase 28 — Version Ranges

## Problem

Only exact-version constraints are supported:

```zig
.require = .{ .version = "=1.14.0.0" },
```

This forces every consumer of a package to declare the exact same version.  In a
monorepo with 30 packages that all depend on protobuf, every `zpkg.zon` must list the
identical version string.  When protobuf is upgraded:

1. Every `zpkg.zon` must be edited individually.
2. Forgetting one file causes a conflict error at `zpkg lock` time.
3. Staggered upgrades (different packages on different versions) are impossible by design.

For external packages managed by wrapper packages (Phase 24), pinning an exact version
is often acceptable, but for first-party packages in a monorepo, compatible-version
semantics (`^1.2.0`) or minimum-version semantics (`>=1.2.0`) are standard practice.

---

## Goal

Implement `^`, `>=`, `<=`, and `=` version constraint operators.  The resolver selects
the highest version that satisfies all constraints across the full dependency graph.
Version conflicts (no version satisfies all constraints simultaneously) are hard errors.

---

## Design

### Constraint syntax

Extend the version constraint field in `zpkg.zon`:

```zig
.require = .{ .version = "^1.2.0" },    // compatible: >= 1.2.0, < 2.0.0
.require = .{ .version = ">=1.2.0" },   // minimum
.require = .{ .version = ">=1.2.0 <2.0.0" },  // range
.require = .{ .version = "=1.2.3.0" },  // exact (existing)
```

MVP operators:
- `=x.y.z.w` — exact match (existing)
- `^x.y.z` — compatible: `>= x.y.z, < (x+1).0.0` (SemVer caret)
- `>=x.y.z` — minimum version
- `<=x.y.z` — maximum version

Compound ranges (`>=1.2.0 <2.0.0`) are expressed as two constraint tokens separated
by whitespace.

### Resolver changes

The current resolver (`resolve/root.zig`) performs no version selection — it takes
the version from the package's `zpkg.zon` directly.  With version ranges, the resolver
must:

1. Collect all constraints on a given `package_id` from all direct dependents.
2. Select the highest version in the monorepo that satisfies all constraints.
3. Fail with a conflict error if no version satisfies all constraints.

Since zpkg works with first-party and wrapper packages in a monorepo (not a remote
package registry), "available versions" are the versions declared in each package's
own `zpkg.zon`.  The resolver must discover all packages with a given ID across the
workspace to find the candidate version set.

This ties version ranges to the workspace manifest (Phase 25): without a workspace
manifest listing all packages, the resolver cannot discover what versions are available.

For this phase, the resolver can operate on a simplified model:
- Collect all packages in the workspace (from `zpkg.workspace.zon`).
- For each package ID, record the declared version from its `zpkg.zon`.
- Use this as the candidate set for version selection.

### Conflict reporting

When no version satisfies all constraints:

```
error: version conflict for 'sai.upstream.protobuf':
  app requires ^4.0.0  (satisfied by 4.1.2)
  legacy_lib requires =3.21.0  (not compatible with ^4.0.0)

  The following packages require incompatible versions:
    app         → ^4.0.0
    legacy_lib  → =3.21.0

  Hint: update legacy_lib to require ^4.0.0 or add a separate instance
        for the incompatible version (advanced; see docs/zpkg-version-conflicts.md).
```

---

## Required changes

### 1. `src/model/version.zig` — version constraint types

```zig
pub const ConstraintOp = enum { exact, gte, lte, caret };

pub const VersionConstraint = struct {
    op: ConstraintOp,
    version: Version,

    pub fn satisfies(self: VersionConstraint, v: Version) bool { ... }
};

pub const VersionRequirement = struct {
    constraints: []VersionConstraint,  // all must be satisfied (AND)

    pub fn satisfies(self: VersionRequirement, v: Version) bool { ... }
};

pub fn parseRequirement(text: []const u8) !VersionRequirement { ... }
```

### 2. `src/schema/zpkg.zig` — parse version requirement

Replace the existing string-based version constraint parsing with `parseRequirement`.

### 3. `src/resolve/root.zig` — version selection

Add version selection logic:

```zig
fn selectVersion(
    allocator: std.mem.Allocator,
    package_id: model.PackageId,
    candidates: []const model.Version,
    constraints: []const VersionConstraint,
) !model.Version { ... }
```

When the workspace manifest is available, `candidates` comes from discovered package
versions.  Without a workspace manifest, `candidates` contains only the version
declared in the direct dependency's `zpkg.zon` (current behavior, now constraint-checked).

### 4. `src/resolve/drift.zig` — drift detection for range constraints

Update drift detection to understand range constraints: a locked version is valid as
long as it still satisfies all current constraints, even if it's not the latest
satisfying version.

### 5. `src/schema/lockfile.zig` — record selected version

The lockfile already records `resolved version`; no schema change is needed.  The
constraint string in `zpkg.zon` is not recorded in the lockfile (only the chosen
version is).

### 6. `docs/zpkg-schema.md` — document constraint syntax

---

## Files to change

| File | Change |
|---|---|
| `src/model/version.zig` | Add `VersionConstraint`, `VersionRequirement`, `parseRequirement` |
| `src/schema/zpkg.zig` | Parse `require.version` using `parseRequirement` |
| `src/resolve/root.zig` | Add version selection with constraint checking |
| `src/resolve/drift.zig` | Understand range constraints in drift detection |
| `docs/zpkg-schema.md` | Document constraint operators |
| `docs/zpkg-lockfile.md` | Clarify lockfile records chosen version, not constraint |

---

## Validation

- A `zpkg.zon` with `require = .{ .version = "^0.1.0" }` resolves successfully.
- A `zpkg.zon` with `require = .{ .version = ">=0.1.0 <0.2.0" }` resolves correctly.
- Two packages requiring `^0.1.0` and `^0.1.0` (both satisfied by 0.1.0) resolve to
  the same instance.
- Two packages requiring `=0.1.0` and `=0.2.0` for the same dep produce a conflict
  error with a clear message.
- Existing `=0.1.0.0` constraints continue to work unchanged.
- `zig build test` passes with new unit tests for all constraint operators.

---

## Exit criteria

- `=`, `^`, `>=`, `<=` operators are parsed from `require.version`.
- Constraints are checked during resolution; violations produce clear errors.
- The diamond example still works with `=` constraints unchanged.
- New unit tests cover all operators and conflict scenarios.
- `zig build test` passes.
