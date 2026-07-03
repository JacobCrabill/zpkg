# zpkg Architecture

zpkg is a source-and-binary package/build orchestrator built on top of the Zig
build system. It lets a large multi-package codebase build each package once, cache
the built artifacts in a content-addressed store, and have downstream packages
transparently consume either the freshly-built source outputs or the cached
prebuilt binaries — while still letting you edit any package's source in place and
have the change picked up automatically.

Think "Nix/Conan-style binary caching, expressed natively through `zig build`."

---

## The core idea: two layers of identity

The whole design rests on separating **which sources** from **how they're built**:

1. **Source identity → the lockfile.** `zpkg.lock.zon` pins, for every package in
   the graph, its resolved version, a content hash of its source directory, and
   where that source lives. This is the "what," and it is target/profile
   independent.

2. **Build configuration → the content-addressed store key.** At build time each
   package instance gets a hash (`instance_key.deriveHex`) computed from its locked
   source identity **plus** the build profile (optimize mode, linkage, target
   triple, toolchain fingerprint) **plus** the store keys of its dependencies. That
   hash names its slot in the store.

Because the store key folds in the build profile, the same sources built `Debug`
vs `ReleaseFast`, or for different targets, occupy **distinct** store slots and
never collide — while an unchanged rebuild is a pure cache hit. Editing a
package's source changes its source hash, which changes its store key and every
downstream key, so exactly the affected subtree rebuilds.

(See [`version-ranges-plan.md`](version-ranges-plan.md) and
[`profile-target-axis-plan.md`](profile-target-axis-plan.md) for the design of the
resolution and profile axes, including deferred work.)

---

## Key files

| File | Written by | Purpose |
|---|---|---|
| `zpkg.zon` | you | Package **manifest**: identity, dependencies (with version ranges), build options, and declared targets. |
| `build.zig` / `build.zig.zon` | you | Standard Zig build script + manifest. `build.zig` uses the `zpkg-build` shim to declare its targets and link dependencies. |
| `zpkg.graph.zon` | `build.zig` (via `zpkg-build`) | The package's target/edge graph, emitted during `zig build` so zpkg understands what each package produces. |
| `zpkg.lock.zon` | `zpkg lock` / `update` / `build` | The **lockfile**: the fully-resolved graph, pinning each instance's version, source hash, source path, and dependencies. |
| `.zpkg/` | zpkg | Generated workspace + content-addressed store (git-ignored). |

### `zpkg.zon` (manifest)

```zig
.{
    .schema = 1,
    .package = .{
        .name = "libc",
        .id = "diamond.libC",         // canonical, namespaced id
        .version = "0.1.0.0",         // major.minor.patch[.revision]
        .backend = .zig,
    },
    .deps = .{
        .libA = .{                    // alias used in build.zig
            .package = "diamond.libA",
            .require = .{ .version = "^0.1.0" },   // a version range (see below)
            .source_path = "../libA",              // relative to this zpkg.zon
        },
    },
    .targets = .{
        .libC = .{ .kind = .library, .linkage = .static },
    },
    // optional: .options = .{ ... }  build options, some marked .abi = true
}
```

- **Versions** are 4-component `major.minor.patch.revision`. The 4th (`revision`)
  is a "release-tweak" pin; range operators compare on `major.minor.patch` only,
  and only an exact `=x.y.z.t` honors the 4th digit.
- **`require`** accepts version ranges: `=`, `>=`, `<=`, `>`, `<`, `^` (caret),
  `~` (tilde), `*`/`any`, and comma-separated conjunctions (`">=1.2, <2.0"`). A
  bare version means caret. Requirements are **enforced** during resolution: if a
  dependency's resolved version doesn't satisfy the range, resolution fails with a
  clear message (and, since a package resolves to one version, this also detects
  diamond conflicts).

---

## The pipeline

```
zpkg.zon (+ deps' zpkg.zon)
        │  resolve (native host, enforce version ranges)
        ▼
zpkg.lock.zon  ──────────────►  plan  ──►  per-instance build  ──►  content-addressed store
   (source identity)         (topological       (zig build install         (.zpkg/store)
                              waves, hits/         → staging → archive)
                              misses)
                                                     │ realize workspace
                                                     ▼
                          .zpkg/work/<profile>/   ──►  root `zig build`  ──►  ./zig-out
                          (source realizations +
                           binary adapters)
```

### 1. Resolution (`src/resolve/`)

Starting from the root `zpkg.zon`, the resolver walks dependencies (each pinned to
a local `source_path`), parses their manifests, and builds the graph. It resolves
for the **native host** (cross-target resolution is deferred), deduplicates by
`package_id#domain` (one version per package), and **enforces version
requirements** against each resolved version.

### 2. Lockfile (`zpkg lock` / `update`, `src/resolve/lockgen.zig`)

The resolved graph is serialized to `zpkg.lock.zon`. Each instance records its
`version`, a `source_hash` (content hash of the source tree), a `source_path`
relative to the lockfile directory (so the lockfile is portable across checkouts),
and its dependency edges. `zpkg build` **auto-creates** the lockfile if it's
missing, so a fresh checkout needs no separate `lock` step.

### 3. Planning (`src/realize/build_fallback.zig`)

`planBuild` reads the lockfile, derives every instance's content-addressed store
key, and groups instances into dependency-ordered **waves**. Each instance is
classified as a **store hit** (artifact already present) or **miss** (needs
building). The store key incorporates the build profile, so the plan is
profile-specific.

### 4. Build execution

For each wave, misses are built (in parallel, up to `--jobs`); hits are reified
directly from the store. Building an instance:
- **realizes** its source into the workspace (symlink the source tree + rewrite
  `build.zig.zon` dependencies to workspace-local paths),
- runs `zig build install --prefix <staging>` with the profile's `-Doptimize` /
  `-Dtarget` flags,
- archives the staging prefix into the store under the content-addressed key.

Before building, a **drift** pre-pass re-hashes store-hit sources; if a source
changed since the lockfile was written it warns and rebuilds (or errors under
`--strict-lockfile`).

### 5. Workspace realization (`src/realize/`, the `Realizer`)

Each dependency is materialized into `.zpkg/work/<profile>/deps/<pkg>#<domain>/`
as one of two forms:

- **Source realization** — a symlink forest of the real source plus a
  `build.zig.zon` copied verbatim from source with only `.dependencies` rewritten
  to workspace-local paths. Used when the package is being built from source.
- **Binary adapter** — a *generated* `build.zig` that exposes the prebuilt `.a`
  files from the store (via `noopMake` + a redirected `generated_bin.path`, so no
  recompilation), plus symlinks into the expanded store prefix, plus a
  `build.zig.zon` copied from source with `.dependencies` and `.paths` rewritten.
  Used for store hits, so downstream packages link the cached binary. Crucially the
  adapter carries the **same `.fingerprint`** as the source package (copied
  verbatim), so it's the same package identity to Zig.

The root package is realized as a source package, and a final `zig build` links
everything, producing `./zig-out` (symlinked into the package root).

### 6. Content-addressed store (`src/store/`)

`.zpkg/store/` holds, per store key:
- `artifacts/<hex>/archive.tar` — the built prefix (`lib/`, `include/`, `bin/`, …),
- `artifacts/<hex>/manifest.zon` — the artifact's identity + dependency instances,
- `expanded/<hex>/` — the extracted prefix, symlinked into binary adapters.

The store is shared across profiles and rebuilds; it's the durable cache.

---

## Build profiles

A **profile** is the build configuration: `{ optimize, linkage, target }`
(`src/realize/profile.zig`). It drives:
- the `-Doptimize=<Mode>` / `-Dtarget=<triple>` flags passed to every `zig build`,
- the store key (so profiles are independent cache slots),
- the workspace directory slug: `<optimize>-<target>[-shared]` (the default
  `Debug`/native/static yields `debug-native`).

CLI flags on `build`/`test`: `--release[=safe|fast|small]`, `--target <triple>`.
`--linkage` is intentionally not exposed yet (there's no standard `zig build`
linkage option to make it take effect). Cross-`--target` is rejected for `test`
(running foreign binaries needs an emulator).

---

## `zpkg-build` (the build shim)

zpkg needs to know what targets a package produces and how they connect — the
`zpkg.graph.zon`. Rather than parse `build.zig`, a package's `build.zig` can
*declare* this by importing the `zpkg-build` shim (in `pkg/zpkg-build`): construct a
`Package`, add its targets/artifacts/edges, and `emit` the graph during
`zig build`. See `examples/diamond/app/build.zig` for the pattern. (A package may
also ship a committed `zpkg.graph.zon` instead of regenerating it.) The package's
own `build.zig` otherwise stays standard Zig and consumes dependencies via
`b.dependency(alias)` — which resolves to whatever zpkg realized (source or
prebuilt-binary adapter).

---

## CLI & UX

Commands: `inspect`, `graph`, `lock`, `update`, `realize`, `build`, `test`,
`export`, `clean`, `version` (plus `--help`, `--version`/`-V`). See
[getting-started.md](getting-started.md) for usage.

- **Status reporter** (`src/util/status.zig`): a general reporter for concurrent
  child jobs. On a TTY it renders a live single-line status (spinner + active jobs
  + elapsed, colorized); on a non-TTY it prints one line per transition. Selectable
  via `--progress auto|plain|live`.
- **Diagnostics** (`src/util/diag.zig`): the single home for CLI output, with a
  consistent `error:` / `hint:` style.
- **Streams**: all progress/status/errors go to **stderr**; stdout is reserved for
  genuine machine-readable output (`inspect`, `graph`, `update --dry-run`,
  `version`). So `zpkg build > /dev/null` still shows progress.

---

## Directory layout (generated, git-ignored)

```
<pkg>/
├── zpkg.zon                     # you
├── build.zig, build.zig.zon     # you
├── zpkg.graph.zon               # emitted by zig build
├── zpkg.lock.zon                # zpkg lock/update/build
├── zig-out/                     # → .zpkg/work/<profile>/root/zig-out
└── .zpkg/
    ├── work/<profile>/          # realized workspace (per build profile)
    │   ├── root/                # the root package, realized
    │   ├── deps/<pkg>#<domain>/ # each dep: source realization or binary adapter
    │   └── staging/<...>/       # zig build install prefixes
    └── store/                   # content-addressed cache (shared across profiles)
        ├── artifacts/<hex>/{archive.tar, manifest.zon}
        └── expanded/<hex>/
```

## Source map

| Area | Location |
|---|---|
| Manifest / lockfile / version / target models | `src/model/` |
| Manifest + lockfile ZON parsing/rendering | `src/schema/` |
| Dependency resolution + lockfile generation | `src/resolve/` |
| Source hashing, instance keys, toolchain fingerprint | `src/hash/` |
| Content-addressed store + archives | `src/store/` |
| Workspace realization, binary adapters, build execution, profiles | `src/realize/` |
| Export (relocatable closure bundles) | `src/export/` |
| CLI commands | `src/cli/` |
| Status reporter, diagnostics, workspace layout | `src/util/` |
| The `zpkg-build` shim library | `pkg/zpkg-build/` |
| Example packages | `examples/` |
| End-to-end integration test | `test/integration/diamond.sh` |
