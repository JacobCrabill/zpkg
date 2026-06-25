# zpkg Implementation Plan

## Purpose

This document breaks the `zpkg` MVP into logical implementation phases with explicit exit criteria.

Detailed per-phase breakdowns suitable for parallel subagents live under:

- `docs/implementation/README.md`
- `docs/implementation/phase-00-bootstrap.md`
- `docs/implementation/phase-01-schema-and-model.md`
- `docs/implementation/phase-02-hashing-and-identity.md`
- `docs/implementation/phase-03-resolution-and-lockfile.md`
- `docs/implementation/phase-04-store-and-manifest.md`
- `docs/implementation/phase-05-zpkg-build-and-graph.md`
- `docs/implementation/phase-06-workspace-realization.md`
- `docs/implementation/phase-07-build-fallback.md`
- `docs/implementation/phase-08-cli-and-ux.md`
- `docs/implementation/phase-09-export-and-relocation.md`
- `docs/implementation/phase-10-reproducibility-and-ci.md`

It assumes the architecture described in:

- `docs/zpkg-mvp-architecture.md`

The MVP target remains:

- first-party packages only
- authoritative lockfile
- `host` / `target` resolution domains
- shared-library-oriented builds in the MVP
- Zig as build frontend, `zpkg` as graph realizer + binary store + workspace generator

---

## Guiding principles

1. **Prefer vertical slices over framework-first work.**
   Each phase should end with a demonstrable workflow, not just types and plumbing.
2. **Keep the package contract small and explicit.**
   Package-level constraints live in `zpkg.zon`; target-edge details live in `build.zig` registration.
3. **Make source and binary realizations look the same to consuming `build.zig` code.**
4. **Do not mutate developer checkouts in place.**
5. **Bias toward deterministic local behavior before adding remote distribution.**
6. **Treat `zpkg.zon` as dependency constraints and `zpkg.lock.zon` as exact resolution.**
7. **Use mandatory `zpkg-build` wrappers for all first-party packages.**
8. **Validate declared package contract vs registered target graph strictly.**
9. **Require a clean review subagent after each implementation lane or phase.**

---

## Phase 0 - Bootstrap and repository scaffolding

### Goals

Establish the repository layout, coding conventions, example packages, and a minimal CLI skeleton.

### Scope

- Create the base source layout for `zpkg`
- Create a sample workspace covering:
  - shared library target
  - headers-only target
  - executable/tool target
  - resource target
  - test target
- Add formatting, basic test runner, and local dev scripts
- Define generated workspace and cache roots

### Deliverables

Suggested repository layout:

```text
src/
  main.zig
  cli/
  model/
  hash/
  realize/
  store/
  schema/
  util/

pkg/
  zpkg-build/

examples/
  hello-lib/
  hello-headers/
  hello-tool/
  hello-app/
  hello-tests/

docs/
  zpkg-mvp-architecture.md
  zpkg-implementation-plan.md
```

### Exit criteria

- `zig build test` succeeds for the `zpkg` repository
- `zig build run -- --help` prints a stable help message
- Example packages exist in-tree for later phases
- Generated-workspace root is standardized, e.g. `.zpkg/`

### Recommended tests

- CLI smoke test:
  - `zpkg --help`
- Basic unit test target wired into `zig build test`
- Formatting/lint script

---

## Phase 1 - Schema and model definition

### Goals

Define the data model that all later phases depend on:

- `zpkg.zon`
- `zpkg.lock.zon`
- `zpkg.graph.zon`
- artifact `manifest.zon`
- in-memory package/target graph model

### Scope

- Formalize `zpkg.zon`
- Formalize `zpkg.lock.zon`
- Formalize `zpkg.graph.zon`
- Formalize `manifest.zon`
- Implement parsing and validation
- Model canonical package identity and 3-/4-component normalized versions
- Model package-level dependency constraints
- Model target declarations:
  - `library`
  - `executable`
  - `zig_module`
  - `headers`
  - `resource_set`
- Model conditions (`when`) with MVP AND-only semantics
- Model package options, including `shared`

### Deliverables

- `docs/zpkg-schema.md`
- `docs/zpkg-lockfile.md`
- `docs/zpkg-graph-schema.md`
- `src/schema/zpkg.zig`
- `src/schema/lockfile.zig`
- `src/schema/graph.zig`
- `src/schema/manifest.zig`
- `src/model/*.zig`

### Exit criteria

- `zpkg inspect <pkg-root>` can parse and print normalized package metadata
- Invalid `zpkg.zon` files produce actionable diagnostics
- Invalid `zpkg.lock.zon` files produce actionable diagnostics
- Sample packages all validate successfully
- Parsed output clearly shows:
  - package display name
  - canonical package id
  - normalized package version
  - package options
  - dependency alias vs canonical package id
  - dependency version requirement
  - target declarations
  - target conditions

### Recommended tests

#### Unit tests
- Parse minimal valid `zpkg.zon`
- Parse full-featured `zpkg.zon`
- Normalize `1.2.3` to `1.2.3.0`
- Reject malformed version strings
- Reject malformed version constraints
- Reject dependencies missing canonical package ids
- Reject unknown target kinds
- Reject invalid `when` placement or invalid condition keys
- Reject duplicate target names

#### Golden tests
- Normalize package metadata to stable ZON output
- Validate diagnostics for malformed examples

---

## Phase 2 - Source identity and instance-key engine

### Goals

Implement deterministic identity for:

- source packages
- resolved package instances

### Scope

- Implement in-process source hashing
- Match Zig package semantics as closely as practical using `build.zig.zon.paths`
- Implement instance-key canonicalization and hashing
- Include domain-specific resolution (`host` / `target`)
- Include toolchain identity fields:
  - Zig version
  - host/target triples
  - C/C++ compiler identity/version
  - sysroot/libc identity
  - C++ stdlib / ABI mode

### Deliverables

- `src/hash/source_hash.zig`
- `src/hash/instance_key.zig`
- `docs/zpkg-instance-key.md`

### Exit criteria

- Given the same graph and profile, `zpkg` produces the same source hashes and instance keys across repeated runs
- Reordering dependency declarations or options does not change instance keys
- Changing an ABI-relevant field does change the instance key
- Changing a non-ABI option does not change the instance key
- The same package resolved in `host` vs `target` domains yields distinct keys when domain-specific inputs differ

### Recommended tests

#### Unit tests
- Stable source hashing across repeated runs
- Canonical sort behavior for options and deps
- ABI option flip changes key
- non-ABI option flip does not change key
- host vs target domain changes key when appropriate
- dependency key changes propagate upward

#### Integration tests
- Snapshot tests for normalized key input serialization
- Compare source hash outputs before/after edits to included files

---

## Phase 3 - Lockfile and resolution core

### Goals

Implement authoritative exact resolution and lockfile behavior.

### Scope

- Resolve package-level constraints into exact `(package_id, domain)` instances
- Record selected package options per resolved instance
- Record full transitive graph in `zpkg.lock.zon`
- Implement lockfile drift detection
- Implement lock/update command semantics

### Deliverables

- `src/model/lockfile.zig`
- `src/resolve/resolve.zig`
- `src/cli/lock.zig`
- `src/cli/update.zig`

### Exit criteria

- `zpkg lock` creates a lockfile and errors if one already exists
- `zpkg update` updates the lockfile explicitly
- `zpkg update --dry-run` shows proposed changes without modifying files
- `zpkg build` fails with a detailed message if the lockfile is missing or incompatible
- Lockfile entries record:
  - package id
  - domain
  - resolved version
  - source identity/hash
  - selected options
  - direct resolved deps

### Recommended tests

#### Unit tests
- Constraint mismatch detection
- Domain-specific lockfile entries
- Option changes recorded per resolved instance

#### Integration tests
- Missing lockfile -> failure with suggested `zpkg lock`
- Drifted lockfile -> failure with suggested `zpkg update`
- `update --dry-run` output matches proposed modifications

---

## Phase 4 - Local binary store and manifest management

### Goals

Implement the local artifact store layout and manifest lifecycle.

### Scope

- Store layout for `artifacts/` and `expanded/`
- Manifest read/write
- Prefix archive creation/extraction
- Presence checks and integrity checks
- Keep internal store semantics separate from relocatable export semantics

### Deliverables

- `src/store/layout.zig`
- `src/store/manifest.zig`
- `src/store/archive.zig`
- `src/store/store.zig`

### Exit criteria

- `zpkg` can store an installed prefix under the expected instance key
- `zpkg` can locate and, if needed, expand a stored artifact
- Expanding the same artifact twice is idempotent
- Stored and reloaded manifest contents round-trip without semantic changes

### Recommended tests

#### Unit tests
- Store path derivation from instance key
- Manifest round-trip serialization
- Archive/extract round-trip for a sample prefix tree

#### Integration tests
- Create a fake prefix, store it, reload it, and verify file layout
- Re-expansion of an already-expanded artifact is a no-op
- Missing/corrupt manifest produces clear failure

---

## Phase 5 - `zpkg-build` helper package and configure-time graph emission

### Goals

Define and implement the stable wrapper layer that all first-party `build.zig` files will use.

### Scope

- Implement `zpkg-build`
- Wrap target creation for exported/public targets
- Register target edges with:
  - dependency alias
  - target name
  - role
  - visibility
- Register include directories and compile definitions with public/private visibility
- Register tools and resources
- Emit `zpkg.graph.zon` at configure time
- Validate declared `zpkg.zon` contract vs registered graph strictly

### Deliverables

- `pkg/zpkg-build/`
- `docs/zpkg-build-contract.md`
- example packages updated to use `zpkg-build`

### Exit criteria

- Example packages consume dependencies only through `zpkg-build`
- `zpkg-build` emits `zpkg.graph.zon` in the realized package root at configure time
- Declared targets and registered targets must match or the build errors
- Registered edges to undeclared package dependency aliases error
- Registered metadata mismatches declared target metadata error

### Recommended tests

#### Unit tests
- Resolve include/lib/bin/share paths from registered metadata
- Resolve tool path by exported name
- Validate public/private include-dir and compile-definition metadata
- Validate strict mismatch detection

#### Integration tests
- Configure a sample package and inspect emitted `zpkg.graph.zon`
- Build sample app against source-realized shared library
- Build sample app against binary-adapter shared library
- Use exported sample tool in a generated build step
- Consume a `.headers` target through a `.link` edge

---

## Phase 6 - Workspace realization engine

### Goals

Generate the realized local workspace used by Zig.

### Scope

- Realized source package writer
- Binary adapter package writer
- `build.zig.zon` rewriting to local path deps
- Stable workspace layout under `.zpkg/work/...`
- `zpkg.graph.zon` placement in realized package roots
- Symlink-forest strategy for source realizations

### Deliverables

- `src/realize/workspace.zig`
- `src/realize/source_pkg.zig`
- `src/realize/binary_adapter.zig`
- `docs/zpkg-realized-workspace.md`

### Exit criteria

- `zpkg realize <root>` creates a complete local workspace with:
  - realized root package
  - realized source deps where needed
  - generated binary adapters where available
  - emitted `zpkg.graph.zon`
- Generated `build.zig.zon` files resolve using local path deps only
- Re-running realization without graph changes is idempotent
- No source repository files are modified in place

### Recommended tests

#### Golden tests
- Realized workspace tree matches expected layout
- Generated `build.zig.zon` matches canonical form
- Generated binary adapter files match expected content

#### Integration tests
- `zig build --fetch` is not needed inside the realized workspace for already-realized deps
- `zig build` in the realized workspace configures successfully for the sample graph

---

## Phase 7 - Source-build fallback pipeline

### Goals

Implement the actual binary-miss -> source-build -> store -> reuse loop.

### Scope

- Topological traversal over the resolved graph
- Binary existence check by instance key
- Source realization for missing nodes
- Invoke `zig build install --prefix <staging>` for realizable packages
- Publish resulting prefixes to the local store
- Replace downstream consumption with binary adapters after publication
- MVP assumes shared-library builds

### Deliverables

- `src/realize/build_fallback.zig`
- `src/cli/build.zig`
- end-to-end `zpkg build` command for one platform/profile

### Exit criteria

- On a cold store, `zpkg build <root>` builds missing dependencies from source and stores their prefixes
- On a warm store, `zpkg build <root>` reuses existing binary artifacts instead of rebuilding
- Downstream packages can consume a previously source-built package through its binary adapter
- Build results are reproducible across two clean runs with the same inputs

### Recommended tests

#### Integration tests
- Cold-store end-to-end build of sample graph
- Warm-store repeat build with no rebuild of unchanged deps
- Delete one artifact and verify only the missing subgraph rebuilds
- Modify one ABI-relevant dep option and verify rebuild propagates appropriately

#### Clear observable outcomes
- First run logs binary misses and source builds
- Second run logs binary hits for the same nodes

---

## Phase 8 - Test, graph, and developer UX commands

### Goals

Make the tool usable and debuggable for developers.

### Scope

- Implement and refine commands:
  - `zpkg inspect`
  - `zpkg graph`
  - `zpkg realize`
  - `zpkg build`
  - `zpkg test`
  - `zpkg export`
- Position `realize` as an advanced/debug command
- Add progress reporting and concise summaries
- Add clear error reporting for invalid graphs and failed builds

### Deliverables

- stable CLI help and command structure
- basic human-readable summaries
- error message improvements
- local usage docs

### Exit criteria

- A developer can run a documented quickstart and build the sample graph successfully
- `zpkg graph` shows the resolved package graph by default
- a verbose graph mode can include target graph information from `zpkg.graph.zon`
- `zpkg test` builds the test graph and runs tests
- `zpkg build --with-tests` builds the test graph without running tests
- failed builds identify the package, instance key, and workspace path involved

### Recommended tests

- CLI smoke tests for all supported commands
- Golden tests for error messages on common failure scenarios
- Manual dry run of the quickstart doc by someone other than the implementer

---

## Phase 9 - Export and relocation workflow

### Goals

Implement relocatable exported closure bundles.

### Scope

- Export package closures or named target closures
- Default export to target-domain closure only
- Exclude host-only tool/build/test deps by default
- Support relocatable export bundles separate from internal store layout
- Prefer env/dev-shell activation as primary runtime model
- Support direct execution after unpack where practical
- Implement export collision policy:
  - allow byte-identical collisions
  - error on non-identical collisions

### Deliverables

- `src/cli/export.zig`
- `src/export/export.zig`
- `docs/zpkg-export.md`

### Exit criteria

- `zpkg export <package>` exports all exported, non-test, target-domain targets by default
- `zpkg export <package_id>:<target_name>` exports the closure rooted at a specific target
- Export requires an authoritative lockfile
- Exported bundles are relocatable and include activation/wrapper support as needed
- Byte-identical resource collisions are allowed; differing-content collisions fail clearly

### Recommended tests

#### Integration tests
- Export package-level closure
- Export named-target closure
- Unpack and use bundle via env activation
- Verify a directly runnable case works where supported
- Verify byte-identical collision acceptance and differing-content collision failure

---

## Phase 10 - Reproducibility hardening

### Goals

Stabilize the MVP for team use.

### Scope

- Ensure realized workspace generation is deterministic
- Ensure lockfile + source hash + selected options reproduce the same resolved instances
- Improve cache correctness checks
- Document reproducibility guarantees

### Deliverables

- deterministic output guarantees documented
- CI workflows for cold/warm store cases

### Exit criteria

- Realizing the same lockfile twice yields equivalent workspace content
- Rebuilding from a clean local cache with the same lockfile yields the same dependency instance keys
- CI can run the full sample build from scratch and from a warm store
- Build logs show stable package ordering and stable instance keys

### Recommended tests

#### Integration tests
- clean checkout + lockfile + cold store
- clean checkout + lockfile + warm store
- verify identical instance keys and equivalent realized workspace output

---

## Optional post-MVP extensions

These are intentionally out of MVP scope, but should be kept in mind when making format decisions.

### Candidate extensions

- remote binary artifact mirror/publish
- version-range dependency solving on top of canonical package ids
- incompatible shared-dependency detection with richer solver diagnostics
- multiple host/target profiles
- cross compilation
- static linkage support
- host-oriented export/dev-shell workflows for tests
- sysroot/toolchain packaging
- Python environment assembly from realized prefixes
- CMake backend standardization
- artifact signatures / provenance metadata
- store garbage collection and retention policy

---

## Cross-phase sample workspace requirements

The sample workspace should eventually include at least:

- `hello-lib`
  - shared library target
  - exported public headers
- `hello-headers`
  - headers-only target
- `hello-tool`
  - build-time executable/tool target
- `hello-app`
  - depends on `hello-lib`
  - may use `hello-tool` during build
- `hello-tests`
  - test-only executable consuming host-domain test deps
- one resource target

This sample graph is the primary acceptance harness for the MVP.

---

## Suggested milestone map

### Milestone A - Schemas, hashes, and resolution
Complete:
- Phase 0
- Phase 1
- Phase 2
- Phase 3

**Outcome:** `zpkg` understands packages, versions, targets, domains, and authoritative resolution.

### Milestone B - Store, wrappers, and realization
Complete:
- Phase 4
- Phase 5
- Phase 6

**Outcome:** `zpkg` can generate a local Zig workspace and a stable dependency surface for source and binary deps.

### Milestone C - End-to-end build and UX
Complete:
- Phase 7
- Phase 8

**Outcome:** cold-store source fallback and warm-store binary reuse both work, and the graph is inspectable/debuggable.

### Milestone D - Export and reproducibility
Complete:
- Phase 9
- Phase 10

**Outcome:** the MVP supports authoritative export of relocatable closures and deterministic local behavior.

---

## MVP completion definition

The MVP is complete when all of the following are true:

1. A sample multi-package graph can be built with `zpkg build`.
2. Missing artifacts trigger source builds automatically.
3. Built artifacts are stored as reusable installed prefixes.
4. Re-running the same build on a warm store reuses binary artifacts.
5. First-party `build.zig` files use the mandatory `zpkg-build` contract.
6. `zpkg.zon` declarations and emitted `zpkg.graph.zon` are validated strictly.
7. Realized workspaces are generated without mutating source repositories.
8. An authoritative lockfile exists with exact chosen versions, source identities, domains, and selected options.
9. `zpkg export` can produce a relocatable target-domain closure.
10. The workflow is documented well enough for another engineer to reproduce it locally.
11. Each phase/lane has been reviewed by a clean reviewer subagent, with required findings fixed and approval recorded.

---

## Recommended implementation order inside each phase

Within each phase, implement in this order:

1. data model / schema
2. pure functions / unit tests
3. filesystem effects
4. CLI surface
5. end-to-end integration test

This keeps testability high and reduces rework.

---

## Remaining ambiguity level

The architecture is considered specified enough to proceed with concrete schema docs and code implementation. Remaining decisions should be treated as implementation-level naming or ergonomics choices, not structural design changes.
