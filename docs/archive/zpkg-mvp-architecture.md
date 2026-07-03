# zpkg MVP Architecture

## Goal

Build a Zig-based tool (`zpkg`) that:

1. computes a deterministic **source identity** and **ABI/build instance key** for each package instance,
2. checks a local **binary prefix store** for that key,
3. falls back to a **source build** if the binary is missing,
4. generates a **realized Zig workspace** where dependencies are represented as either:
   - realized source packages, or
   - generated binary adapter packages,
5. runs plain `zig build` in that realized workspace,
6. can later export a resolved closure as a relocatable tarball.

This MVP is intentionally **not** a general package manager. It is a **graph realizer + binary store + workspace generator** for first-party packages.

---

## Design commitments

These decisions are intentionally locked down for the MVP:

- `zpkg.zon` is the **constraints + package contract** file.
- `zpkg.lock.zon` is the **authoritative exact resolution** file.
- First-party packages must support `zig build install --prefix <staging>`.
- First-party packages must use the `zpkg-build` wrapper layer; wrapper usage is **mandatory**.
- Targets are first-class, but the model is **hybrid**:
  - `zpkg.zon` declares exported/public targets,
  - `build.zig` registers the actual target graph and validates against the declarations.
- Package resolution is done per **domain**:
  - `host`
  - `target`
- MVP is **shared-library-oriented**. Static linkage is deferred, but the schema already models it.
- Runtime/dev iteration primarily uses **environment/dev-shell activation**.
- Exported bundles should be relocatable, but the internal store does not need to use the same format.

---

## Source identity

Question: **What source tree is this package?**

For the MVP, `zpkg` should compute source identity **in process**, while matching Zig package semantics as closely as practical:

- use `build.zig.zon.paths` as the package boundary
- hash the same included files Zig would treat as package contents
- track Zig's behavior closely enough that the result is consistent with the active Zig toolchain

This makes source identity:

- deterministic
- aligned with Zig package behavior
- independent of shelling out to `zig fetch`

---

## Package identity and versioning

Each package has:

- `.package.id` — canonical machine identity
- `.package.name` — human-facing display name
- `.package.version` — semantic version

### Package id rules

- IDs are explicit, maintainer-chosen, namespaced identifiers, e.g.:
  - `sai.pilot.object_tracker`
  - `sai.upstream.libyaml`
- Nothing is implicit from upstream lineage.
- If `package.id` changes, it is a **new package**.

### Version rules

Versions are SemVer-like with an optional fourth numeric component:

- `1.2.3`
- `1.2.3.0`
- `1.2.3.4`

Normalization rules:

- `1.2.3` and `1.2.3.0` are equivalent after normalization
- versions compare lexicographically across the normalized 4-tuple
- e.g. `1.2.3 < 1.2.3.1 < 1.2.3.2`

Future/post-MVP:

- prerelease forms such as `2.2.0-rc1`
- version ranges such as `^1.2.0` or `>=1.2.0 <2.0.0`

Resolution policy:

- one resolved version per canonical package id **per domain** in a realized graph
- incompatible shared-dependency requirements produce a detailed error

---

## `zpkg.zon` model

Each first-party package provides:

- `build.zig`
- `build.zig.zon`
- `zpkg.zon`

`zpkg.zon` should declare:

- package identity and version
- package-wide options
- package-level dependency constraints
- exported/public target declarations

It should **not** duplicate the full target-to-target edge graph. That graph is registered from `build.zig` through `zpkg-build`.

### Example `zpkg.zon`

```zig
.{
    .schema = 1,

    .package = .{
        .name = "object_tracker",
        .id = "sai.pilot.object_tracker",
        .version = "1.2.3.0",
        .backend = .zig,
    },

    .options = .{
        .shared = .{
            .kind = .bool,
            .default = true,
            .abi = true,
        },
        .with_cuda = .{
            .kind = .bool,
            .default = false,
            .abi = true,
        },
        .build_tests = .{
            .kind = .bool,
            .default = false,
            .abi = false,
        },
    },

    .deps = .{
        .protobuf = .{
            .package = "sai.upstream.protobuf",
            .require = .{
                .version = "=4.1.2.0",
            },
        },
        .gtest = .{
            .package = "sai.upstream.gtest",
            .require = .{
                .version = "=1.14.0.0",
            },
            .when = .{
                .domain = .host,
                .options = .{
                    .build_tests = true,
                },
            },
        },
    },

    .targets = .{
        .tracker = .{
            .kind = .library,
            .linkage = .default,
        },
        .tracker_headers = .{
            .kind = .headers,
        },
        .tracker_models = .{
            .kind = .resource_set,
        },
        .tracker_tests = .{
            .kind = .executable,
            .test_only = true,
        },
    },
}
```

### Key rules

- `.deps.<alias>` defines the allowed dependency universe for the package.
- `.deps.<alias>` contains:
  - canonical package id
  - constraints
  - optional conditions
- `.deps.<alias>` does **not** contain:
  - role
  - visibility
  - target name
- `.required` is omitted entirely; if a dependency entry is active under its condition, it is required.
- `zpkg-build` registration must reference package dependencies by **alias**, matching `build.zig.zon` / `build.zig` usage.

---

## Conditions

MVP conditions use AND-only matching.

Example:

```zig
.when = .{
    .domain = .host,
    .host_os = .linux,
    .target_arch = .x86_64,
    .options = .{
        .shared = true,
        .with_cuda = false,
    },
}
```

### Allowed MVP condition axes

- `domain = .host | .target`
- `host_os`
- `host_arch`
- `target_os`
- `target_arch`
- package option equality via `.options`

### MVP placement rules

`when` is allowed on:

- package-level dependency entries
- target declarations
- target export/resource entries when needed

No OR/NOT logic in the MVP.

---

## Target model

Targets are first-class, but only **exported/externally consumable** targets must appear in `zpkg.zon`.

Internal helper targets may exist in `build.zig` registration only, as long as they are not exported or externally referenced.

### Target kinds

MVP target kinds:

- `.library`
- `.executable`
- `.zig_module`
- `.headers`
- `.resource_set`

### Library linkage

Library linkage is represented as:

- `.linkage = .default | .shared | .static`

Where:

- `.default` means: follow the package-wide `shared` option
- MVP effectively requires `shared = true`
- static support is deferred, but the schema is already forward-compatible

### Headers targets

`.headers` is a real target kind.

It exists for header-only/template-heavy packages and behaves like an interface target:

- no binary artifact
- exports include directories
- may export compile definitions
- is consumed through `.link` edges

Separate from that, library targets also need public/private include-path metadata because public exported headers are different from private build-only headers.

### Target naming

- Target names are unique within a package.
- Renaming an exported target is a compatibility/signature change.
- External reference syntax is `package_id:target_name`.

---

## Domains and roles

Resolution domains are intentionally minimal:

- `host`
- `target`

Roles map into those domains:

- `.tool` -> `host`
- `.build` -> `host`
- `.test` -> `host`
- `.link` -> `target`

Notes:

- `.run` is deferred; for now it is treated as a special installation/export concern rather than a first-class role.
- A single package may appear in multiple roles, e.g. `protobuf` as both runtime library and host code generator.
- Different roles should reuse the same underlying source/binary artifacts when the resolved package instance is otherwise identical.

### Test behavior

- `zpkg build` builds the non-test graph.
- `zpkg build --with-tests` builds the test graph without running tests.
- `zpkg test` builds the test graph and runs tests.
- Test-only targets should use `.test_only = true` in `zpkg.zon`.

---

## Dependency and propagation model

`zpkg.zon` declares package-level dependency constraints; actual target edges live in `build.zig` registration.

### Edge metadata lives in build registration

Target-to-target edges registered by `zpkg-build` carry:

- dependency alias
- target name
- role
- visibility

Visibility belongs on the **edge**.

### Public/private propagation

For `.link` edges, public propagation should include:

- public include directories
- public compile definitions
- system libraries
- transitive shared libraries as needed for link/runtime correctness

The following do not automatically propagate in the MVP:

- resources
- zig modules
- tools

They remain accessible when explicitly requested.

---

## Compile definitions and include paths

### Include paths

Include paths are modeled as **directories**, not individual files.

Each include directory has visibility:

- `public`
- `private`

`.headers` targets export include dirs but no binary artifact.

### Compile definitions

Compile definitions should use a structured ZON-friendly format such as:

```zig
.{ .key = "FOO", .value = 1 }
.{ .key = "USE_SSL", .value = true }
.{ .key = "API_LEVEL", .value = "v2" }
```

Allowed MVP value types:

- string
- int
- bool

---

## Resources

Resources are first-class targets of kind `.resource_set`.

They are installed under `share/` and are exported by target.

### Resource install policy

- developers specify the file(s) to install
- developers specify the subdirectory under `share/`
- `zpkg-build` should provide a helper for a default namespaced path based on package id / target name
- collisions are only considered at export time
- export allows byte-identical collisions and errors on non-identical collisions

---

## Hybrid metadata and `zpkg-build`

The model is intentionally hybrid:

- `zpkg.zon` declares the package contract
- `build.zig` registers the actual target graph

`zpkg-build` wrappers are mandatory for all first-party packages. They should wrap:

- target creation
- exported target registration
- target-edge registration
- include-dir / compile-definition visibility metadata
- tool/resource registration

### Configure-time graph emission

During configure, `zpkg-build` emits:

- `zpkg.graph.zon`

This file lives in the realized package root and is the configure-time representation of the registered target graph.

### Validation rules

Validation is strict:

- declared target missing from registration -> error
- registered exported target missing from `zpkg.zon` -> error
- registered edge to undeclared package dependency alias -> error
- target kind/linkage mismatch -> error
- declared-vs-registered export mismatch -> error

---

## Realized workspace model

Do not mutate developer checkouts in place.

Generate a realized workspace such as:

```text
.zpkg/
  work/
    linux-x86_64-gnu-releasefast/
      root/
        build.zig
        build.zig.zon
        zpkg.graph.zon
        src/        -> symlink to actual source tree
      deps/
        foo/
        bar/
```

Each realized package is one of two forms.

### Source realization

A symlink forest or lightweight copy containing:

- original `build.zig`
- original sources
- generated `build.zig.zon` with local path deps
- emitted `zpkg.graph.zon`

### Binary adapter package

A generated Zig package containing:

- `build.zig`
- `build.zig.zon`
- `manifest.zon`
- generated metadata module(s)
- references to an expanded binary prefix in the local store

This keeps every package in a normal Zig build root and avoids in-place mutation of source repos.

---

## Binary adapter contract

A generated binary adapter package is a real Zig package that exposes prebuilt
artifacts through the standard `dep.artifact("X")` API, making it transparent to
consuming `build.zig` files — they work identically whether a dependency comes from
source or from the store.

### How it works

For each prebuilt static library in the store artifact (e.g. `lib/libE.a`), the
adapter generates a `b.addLibrary` step and then bypasses normal compilation:

```zig
const lib_e = b.addLibrary(.{ .name = "E", .root_module = mod_e, .linkage = .static });
b.installArtifact(lib_e);   // allocates generated_bin via getEmittedBin()
lib_e.generated_bin.?.path = b.pathFromRoot("lib/libE.a");  // point at prebuilt archive
lib_e.step.makeFn = noopMake;  // skip llvm-ar; store archive is used directly
```

`generated_bin.?.path` is set at configure time to the symlink in the adapter directory
that resolves to the store's expanded artifact.  `noopMake` prevents the normal
`make` function from overwriting that path with a Zig cache path.  The linker receives
the prebuilt `.a` as a positional argument and extracts its object files directly —
no duplication, no re-archiving.

Transitive static library dependencies are wired through the standard Zig build graph:
```zig
mod_e.linkLibrary(libC_dep.artifact("C"));
mod_e.linkLibrary(libD_dep.artifact("D"));
```
Zig's `getCompileDependencies` traversal propagates these to the final consumer's link
command automatically.  The consuming `build.zig` only needs to reference its direct
dependencies.

### Adapter directory layout

```
deps/<pkg>#<domain>/
    build.zig          — generated; exposes artifacts via noopMake + generated_bin redirect
    build.zig.zon      — generated; fingerprint auto-corrected on first use
    include/           — symlink → store/expanded/<pkg>#<domain>/include/
    lib/               — symlink → store/expanded/<pkg>#<domain>/lib/
    bin/               — symlink → store/expanded/<pkg>#<domain>/bin/   (if present)
    share/             — symlink → store/expanded/<pkg>#<domain>/share/ (if present)
```

No object files are extracted from the store archives.  The adapter directory contains
only the two generated files and symlinks into the (read-only) expanded store prefix.

---

## Store and export model

Keep source and binary stores separate.

### Source store

```text
$XDG_CACHE_HOME/zpkg/
  sources/
    <zig_like_pkg_hash>/
```

### Internal binary store

```text
$XDG_CACHE_HOME/zpkg/
  artifacts/
    <instance_key>/
      prefix.tar.zst
      manifest.zon
  expanded/
    <instance_key>/
      include/
      lib/
      bin/
      share/
```

Internal store semantics and export semantics are intentionally separate:

- the internal store can rely on stable expanded paths
- exported bundles must be relocatable

### Exported closure bundles

`zpkg export` should create a relocatable closure tarball.

Supported behavior:

- environment/dev-shell activation is the primary runtime model
- direct execution after unpack should work where practical
- export may add wrapper scripts / relative runtime search paths as needed
- default export includes **target-domain** closure only
- host-only tool/build/test dependencies are excluded unless explicitly requested later

`zpkg export <package>` exports all exported, non-test, target-domain targets of the package by default.

`zpkg export <package_id>:<target_name>` exports the closure rooted at a specific target.

Export requires an authoritative `zpkg.lock.zon`.

---

## Artifact manifest

Stored/exported artifact manifests should capture at least:

- schema version
- package name / id / version
- domain
- source hash
- instance key
- selected package options
- target triple
- optimize mode
- linkage mode
- exported targets
- resolved dependency instance keys

Manifest `.deps` keys use resolved dependency identity in `<package_id>#<domain>` form so the same package can appear in both host and target domains.

Example:

```zig
.{
    .schema = 1,
    .name = "foo",
    .package_id = "sai.example.foo",
    .package_version = "1.2.3.0",
    .domain = .target,
    .source_hash = "...",
    .instance_key = "...",
    .target = "x86_64-linux-gnu",
    .optimize = "ReleaseFast",
    .linkage = .shared,
    .selected_options = .{
        .shared = true,
    },
    .deps = .{
        .@"sai.example.bar#host" = "<host_instance_key>",
        .@"sai.example.bar#target" = "<target_instance_key>",
    },
}
```

---

## Instance key model

Use `std.Build.Cache.HashHelper` to compute a deterministic build-instance key.

### Required inputs

Include at least:

- package schema version
- package canonical id
- resolved package version
- domain (`host` / `target`)
- source package hash
- selected package options
- target triple
- optimization mode
- linkage mode
- Zig version
- host triple
- target triple
- C/C++ compiler identity/version
- sysroot/libc identity
- C++ stdlib / ABI mode
- sorted dependency instance keys

### Excluded inputs

Do not include:

- local absolute paths
- shell-local environment noise
- non-ABI development toggles

---

## Lockfile model

`zpkg.lock.zon` is authoritative and records the full transitive graph.

If it is missing or incompatible with `zpkg.zon`, normal build/export commands should fail with a detailed error and suggest the appropriate command.

Expected commands:

- `zpkg lock` — create the lockfile, error if it already exists
- `zpkg update` — update lockfile
- `zpkg update --dry-run` — show proposed changes without modifying files

Each lockfile entry should capture at least:

- package id
- domain (`host` / `target`)
- resolved version
- source identity/hash
- selected package options
- direct resolved package dependencies

Options are resolved per package instance, and therefore effectively per `(package_id, domain)` lockfile entry.

---

## Command model

MVP command set:

- `zpkg inspect`
- `zpkg graph`
- `zpkg lock`
- `zpkg update`
- `zpkg realize`
- `zpkg build`
- `zpkg test`
- `zpkg export`

### Notes

- `zpkg graph` should show the resolved package graph by default; a verbose mode can include the target graph from `zpkg.graph.zon`.
- `zpkg realize` is an advanced/debugging command that resolves and materializes the workspace but stops before compilation.

---

## MVP summary

The MVP now assumes:

- first-party packages only
- package ids are explicit and stable
- package versions are normalized 3- or 4-component semantic versions
- package-level constraints + target-level build registration
- strict validation between `zpkg.zon` and `zpkg-build` registration
- authoritative lockfile
- host/target domain resolution
- shared-library-focused builds
- relocatable export bundles
- environment/dev-shell-first runtime workflow
