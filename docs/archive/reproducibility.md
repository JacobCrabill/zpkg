# Reproducibility Guarantees

## Source hash

The source hash covers every file reachable through the `.paths` entries in
`build.zig.zon`.  Specifically it includes:

- The relative file path within the package tree
- The full byte content of each file

What it does **not** cover:

- Files outside `.paths` (e.g., `README.md` if not listed)
- File ownership, permissions, or timestamps
- Host username or working directory

Hashing is performed by `src/hash/source_hash.zig`.  Directory entries are
visited in sorted order so the result is independent of filesystem readdir
order.

## Instance key

An instance key is a deterministic hex digest derived from the following fields
(all included, in this order):

- `zpkg.instance_key.v1` domain tag
- `package_schema_version`
- `package_id`
- `version`
- `domain` (host or target)
- `source_hash`
- ABI options — name-sorted, values included, non-ABI options excluded
- `optimize` mode (Debug / ReleaseFast / ReleaseSafe / ReleaseSmall)
- `linkage` (static or shared)
- Toolchain fingerprint — compiler id+version, sysroot id+version, libc, C++ stdlib, ABI mode
- Dependency instance keys — sorted by (package_id, domain, instance_key)

See `src/hash/instance_key.zig` for the canonical implementation.

### What does NOT affect binary identity

- Non-ABI build options (e.g., `build_tests`, `enable_docs`)
- Build timestamps
- Host username or home directory
- Absolute paths to the build tree
- Files outside the declared `.paths`

## Lockfile authority

`zpkg.lock.zon` pins exact instance keys for every resolved package.  A locked
build:

- Uses the pinned instance key for every dependency
- Skips resolution if all instance keys are already present in the store
- Never re-derives keys from source unless the lockfile is deleted or `zpkg update` is run

## Rebuild triggers

A rebuild is forced when any of the following change:

- Source file content inside `.paths` (source hash changes)
- An ABI option value (instance key changes)
- `optimize` mode or `linkage`
- Toolchain fingerprint (compiler, sysroot, libc, or C++ stdlib version)
- The instance key of any direct dependency (propagates transitively)
- `version` field in the package manifest
- `domain` (host vs target)

## Non-triggers (no rebuild)

The following changes do **not** cause a rebuild:

- Non-ABI option value flip (e.g., toggling `build_tests`)
- Source file change outside the declared `.paths`
- Build timestamp or hostname change
- Reordering of options or dependencies in the manifest (keys are sorted before hashing)

## Workspace generation determinism

`SourcePkgRealize.generateBuildZigZon` emits dependency entries sorted
lexicographically by dep name, not in HashMap insertion or iteration order.
This guarantees byte-identical `build.zig.zon` output for identical inputs
regardless of hash-map internal state.

`BinaryAdapter.generate` symlinks a fixed set of subdirs (`include`, `lib`,
`bin`, `share`) in a fixed order defined by the `prefix_dirs` constant.

`WorkspaceLayout.ensureDirs` creates a fixed set of directories — no
iteration-order dependence.
