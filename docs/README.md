# zpkg Documentation

zpkg is a source-and-binary package/build orchestrator on top of the Zig build
system — build each package in a large multi-package codebase once, cache the
artifacts in a content-addressed store, and let downstream packages transparently
consume source builds or cached binaries. (See the repo [README](../README.md) for
the motivation.)

## Start here

- **[getting-started.md](getting-started.md)** — build zpkg, build the example
  project, write your own package, command cheat-sheet.
- **[architecture.md](architecture.md)** — the two-layer identity model (source
  lockfile vs content-addressed build key), the pipeline, resolution, the store,
  workspace realization, and build profiles.

## Design notes (forward-looking)

- **[version-ranges-plan.md](version-ranges-plan.md)** — dependency version ranges.
  Phase 1 (grammar + enforcement) is implemented; version *selection* is deferred.
- **[profile-target-axis-plan.md](profile-target-axis-plan.md)** — build profiles
  and targets. Host detection, `--release`/`--target`, and store-key wiring are
  implemented; target-aware *resolution* is deferred.

## Archive

[`archive/`](archive/) holds the original MVP architecture/schema docs and the
phased implementation plan (`archive/implementation/`). They describe how zpkg was
bootstrapped and are kept for history — treat `architecture.md` and
`getting-started.md` as the current source of truth.
