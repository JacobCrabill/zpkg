# Phase 11 - Cleanup and Completeness

## Purpose

Close the known stubs and gaps left after the MVP implementation. This phase
makes the tool actually usable end-to-end rather than adding new features.

## Phase dependencies

- Requires: Phases 00–10 merged
- No phase unblocked by this one (it is the final cleanup milestone)

## Parallelism

- P11-A and P11-B are independent and can run in parallel
- P11-C depends on P11-B (examples must use `zpkg-build` before the ZON fix matters)
- P11-D is independent

---

## Work units

### P11-A — `zpkg test` per-instance test execution

**Goal**

`zpkg test <pkg-root>` currently delegates to `runBuild(.run_tests)` but never
invokes `zig build test`. Make it actually run tests for each instance.

**Files**

- `src/cli/test_cmd.zig` — replace the P07-C stub
- `src/realize/build_fallback.zig` — implement `.run_tests` mode in `buildInstance`

**Requirements**

- For each source-domain instance in the build plan, after `zig build install`,
  additionally run `zig build test --prefix <staging>` in the realized workspace
- Report per-instance pass/fail; continue running all instances before returning
  an aggregate error
- Store hits (binary-only instances) skip the test step with a `[skip]` annotation
  and a note that pre-built binaries do not carry test binaries

**Validation**

- `zpkg test examples/hello-lib` runs the hello-lib test suite
- Failing tests produce a non-zero exit code from `zpkg test`

**Exit criteria**

- The `_ = mode;` TODO in `buildInstance` is removed

---

### P11-B — Migrate remaining examples to `zpkg-build`

**Goal**

All four remaining examples must register their targets via `zpkg-build` and
emit `zpkg.graph.zon` so `zpkg graph --verbose` can introspect them.

**Files** (one `build.zig` per example)

- `examples/hello-headers/build.zig`
- `examples/hello-tool/build.zig`
- `examples/hello-app/build.zig`
- `examples/hello-tests/build.zig`

**Requirements for each example**

- Import `zpkg-build` and construct a `Package`
- Register all targets with correct `kind` (`.library`, `.executable`, `.headers`,
  `.resource_set`, `.test_suite` as applicable)
- Declare `addIncludeDir`, `addArtifact`, `addEdge`, and `addDepAlias` as needed
- Call `pkg.emit(b.graph.io, "zpkg.graph.zon")` before the standard build artifacts
- Do not call `pkg.deinit()` (build arena owns lifetime)

**Reference**

`examples/hello-lib/build.zig` is the canonical migrated example.

**Validation**

- `zig build` in each example directory succeeds
- `zpkg graph --verbose examples/<name>` shows the target graph

**Exit criteria**

- No example `build.zig` uses direct `std.Build` target registration without
  also registering via `zpkg-build`

---

### P11-C — Quote non-identifier dep names in `generateBuildZigZon`

**Goal**

`src/realize/source_pkg.zig::generateBuildZigZon` emits dep names as bare ZON
field names (`.{name} = .{ .path = ... }`). If a dep name contains hyphens,
dots, or other non-identifier characters the output is syntactically invalid ZON.

**Files**

- `src/realize/source_pkg.zig` — fix `generateBuildZigZon`
- `pkg/zpkg-build/src/root.zig` — verify `isBareIdentifier` (already present)
  and import/use it here, or duplicate the predicate locally

**Requirements**

- Reuse or replicate the `isBareIdentifier` predicate from `zpkg-build`
- When the dep name is not a bare identifier, emit it as a quoted string key:
  `@"dep-name" = .{ .path = ... }`
- Add a unit test covering a dep name with a hyphen

**Validation**

- `zig build test` passes
- Generated `build.zig.zon` with a hyphenated dep name parses as valid ZON

**Exit criteria**

- No dep name, however spelled, can produce syntactically invalid `build.zig.zon`

---

### P11-D — Named-target export filter

**Goal**

`src/export/export.zig::planExport` filters by `package_id` when
`opts.target == .named` but ignores `target_name`. The TODO comment deferred
this until the lockfile model carries per-target metadata. Add that metadata
and wire up the filter.

**Files**

- `src/model/lockfile.zig` — add optional `target_name: ?[]const u8` to
  `LockfileInstance` (nullable; existing lockfiles set it to `null`)
- `src/resolve/root.zig` — populate `target_name` when writing instances
  during lockfile generation
- `src/export/export.zig` — remove the TODO; filter by `target_name` when set

**Requirements**

- Lockfile format change must be backward-compatible: a `target_name` field
  that is absent or `null` is treated as "any target from this package"
- `zpkg export examples/hello-lib zpkg.example.hello_lib:hello` exports only
  the `hello` target's closure (not `hello_headers` or `hello_assets`)
- Add a unit test for the named-target filter path

**Validation**

- `zig build test` passes
- `zpkg export <root> <pkg_id>:<target>` produces a smaller bundle than
  `zpkg export <root>` for a package with multiple targets

**Exit criteria**

- The `// TODO: filter by target_name once LockfileInstance carries it` comment
  in `export.zig` is removed

---

## Phase completion criteria

This phase is complete when:

- `zpkg test` actually runs per-instance test suites
- All five example packages emit `zpkg.graph.zon` via `zpkg-build`
- `generateBuildZigZon` never emits syntactically invalid ZON for any dep name
- `zpkg export <root> <pkg_id>:<target>` filters to the named target's closure
- `zig build test` passes with no TODO stubs remaining from Phases 07–10
