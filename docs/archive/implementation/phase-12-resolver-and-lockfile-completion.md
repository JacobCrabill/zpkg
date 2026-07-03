# Phase 12 - Resolver and Lockfile Completion

## Purpose

Make `zpkg lock` and `zpkg build` actually work end-to-end. Currently
both commands run without crashing but produce empty results: the lockfile
has no instances and the build plan has zero items to build.

Two bugs are responsible. They are independent and can be fixed in either order,
but both must be fixed before the pipeline is useful.

## Bug summary

Running `zpkg lock . && zpkg build .` from `examples/diamond/app`:

- `zpkg.lock.zon` is created with `.instances = .{}` — no dep instances at all
- `zpkg build .` reports `Build plan: 0 instances` and exits immediately
- `.zpkg/` store and workspace directories are empty; no `zig-out/` anywhere

---

## Bug 1 — `parseDependencyManifest` is a stub (resolver never recurses)

**File:** `src/resolve/root.zig:175`

**What it does now:**

```zig
fn parseDependencyManifest(self: *Resolver, dep: model.Dependency) !model.PackageManifest {
    // ...
    return model.PackageManifest{
        .package = .{ .name = name, .id = .{ .text = id_text }, ... },
        .deps = &.{},   // ← always empty; resolver never recurses
        .targets = &.{},
    };
}
```

The stub returns a manifest with no dependencies. When `resolveDependencies`
calls `resolveManifests`, it gets a stub manifest for each dep, and that stub
has `deps = &.{}`, so the resolver never recurses beyond depth 1. For
`diamond.app`, only `diamond.libE` is seen; `libC`, `libD`, `libA`, `libB`
are never discovered.

**What it must do:**

Read the actual `zpkg.zon` file for the dependency from disk and parse it.
The path convention (already established in `build_fallback.zig:buildInstance`)
is:

```
<source_root>/../<last_segment_of_package_id>/zpkg.zon
```

For example, `diamond.libE` → `<pkg_root>/../libE/zpkg.zon`.

**Required changes:**

- The `Resolver` needs to know `pkg_root` (the root package's directory path)
  so it can resolve sibling package directories. Add a `source_root: []const u8`
  field to `Resolver` and pass it from `lock.zig`.
- `parseDependencyManifest` should open `<source_root>/../<basename>/zpkg.zon`,
  parse it with `schema.zpkg.parseFileAlloc`, and return the real manifest.
- On parse failure, return a clear error (e.g. `error.DependencyManifestNotFound`)
  with a message naming the missing path.
- The `io: std.Io` capability must also be available inside the resolver. Either
  add it to `Resolver` or pass it through the call chain to `parseDependencyManifest`.

**Basename extraction:** strip namespace prefix at the last `.`:

```zig
const basename = if (std.mem.lastIndexOfScalar(u8, pkg_id_text, '.')) |dot|
    pkg_id_text[dot + 1 ..]
else
    pkg_id_text;
```

This is identical to the pattern already used in `src/cli/realize.zig:145`.

---

## Bug 2 — `generateLockfile` always emits empty instances

**File:** `src/cli/lock.zig:135`

**What it does now:**

```zig
fn generateLockfile(allocator: std.mem.Allocator, resolved: resolve.ResolvedRoot) model.Lockfile {
    ...
    return .{
        .root = .{ .package_id = cloned_id, .version = resolved.version },
        .instances = &.{},   // ← always empty, ignores resolved graph
    };
}
```

`ResolvedRoot` only carries the root package identity. The full resolved
instance graph lives in `Resolver.resolved` (a `ResolvedGraph` backed by a
`StringHashMapUnmanaged(*ResolvedPackage)`), but that map is never consulted
when building the lockfile.

**What it must do:**

Walk `Resolver.resolved` and emit one `model.Instance` per entry, including:
- `key`: the instance key (`<package_id>#<domain>`)
- `package_id`: cloned from `ResolvedPackage.package_id`
- `version`: from `ResolvedPackage.version`
- `domain`: from `ResolvedPackage.domain`
- `source_hash`: `""` for now (hash not computed at lock time in MVP)
- `selected_options`: `&.{}` for now
- `deps`: populated from `ResolvedPackage.deps`

**Required changes:**

- Change `Resolver.resolveRoot` to also return (or expose) the resolved graph.
  The cleanest approach: return a new `ResolvedResult` struct that carries both
  `root: ResolvedRoot` and a reference to `resolver.resolved`.
  Alternatively, add a `pub fn instances(self: *Resolver) iterator` method.
- Change `generateLockfile` signature to accept the resolver or the resolved
  graph directly, and iterate it to build the `[]model.Instance` slice.
- Each `model.Instance` must own its data (all strings duped from allocator);
  `lockfile.deinit(allocator)` will free them.

**Note on `ResolvedPackage.deps`:** these are `Dependency` structs with
`alias: []const u8` and `instance: LockfileInstanceRef`. They are already
populated in `resolveDependencies` via `resolved.appendDep(...)`. Use them
directly when writing `Instance.deps`.

---

## Phase dependencies

- Requires: Phase 03 (resolver scaffold), Phase 11-B (diamond example), recent bug fixes
- Unlocks: meaningful end-to-end `zpkg lock && zpkg build` workflow
- No other phase depends on this

## Parallelism

P12-A (Bug 1 — resolver reads real manifests) and P12-B (Bug 2 — lockfile
emits instances) are logically sequential: Bug 1 must produce populated
instances before Bug 2 is testable. Implement in order: P12-A first,
then P12-B.

## Validation

After both fixes:

```
cd examples/diamond/app
zpkg lock .
# zpkg.lock.zon must contain 5 instances:
#   diamond.libA#target, diamond.libB#target, diamond.libC#target,
#   diamond.libD#target, diamond.libE#target

zpkg build .
# Must print [miss] for each of the 5 instances in topo order
# (libA and libB first, libE last)
# zig-out/ must appear under each realized package workspace
```

## Phase completion criteria

- `zpkg.lock.zon` for `examples/diamond/app` contains all 5 transitive instances
- `zpkg build .` in `examples/diamond/app` builds all 5 from source on first pass
- `zpkg build .` on a second pass reports all 5 as `[hit]` (store cache)
- `zig build test` passes with no regressions
