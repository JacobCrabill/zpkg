# Phase 15 — Content-Addressed Store Keys

## Problem

The store key used throughout the build pipeline is the human-readable string
`<package_id>#<domain>`:

```zig
// build_fallback.zig:74
const key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
    instance.key.package_id.asText(),
    instance.key.domain.asText(),
});
```

The store directory on disk reflects this: `artifacts/diamond.libA#target/`.

`src/hash/instance_key.zig` computes a rigorous ABI-identity hash that includes
toolchain fingerprint, ABI options, dep instance keys, optimize mode, and linkage — but
this function is **never called** in the build path.  The lockfile also stores
`source_hash` but no content-addressed key.

### Consequences

- Two machines with different compiler versions, sysroots, or stdlib ABIs get the same
  store key and can exchange incompatible pre-built artifacts.
- Changing optimize mode (Debug → ReleaseFast) does not invalidate the cache.
- A dependency whose ABI-relevant options changed but whose source didn't change
  reuses a stale cached artifact.
- The entire toolchain fingerprint work (Phase 02) has zero effect on cache correctness.

---

## Design

### The instance key is the store key

`src/hash/instance_key.zig` already defines the right abstraction.  The store key for
every artifact must be the hex digest produced by `deriveHex`, not the human-readable
`<pkg_id>#<domain>` string.

The lockfile must record the computed instance key per entry so that:
1. `zpkg build` can look up artifacts directly without recomputing the key each time.
2. Two developers with the same lockfile and the same toolchain always get the same
   instance key and can share cached artifacts.
3. Two developers with different toolchains get different instance keys and do not
   collide in a shared store.

### Lockfile changes

Each lockfile instance entry gains an `instance_key` field (a hex string):

```zon
.@"diamond.libA#target" = .{
    .package = "diamond.libA",
    .domain  = .target,
    .version = "0.1.0.0",
    .source_hash = "a61a1d449a74c7461331ed52b9b74fb3",
    .instance_key = "3f8a2c...",   // ← new: computed by instance_key.zig
    .selected_options = .{},
    .deps = .{},
},
```

The human-readable `<pkg_id>#<domain>` string is kept as the **lockfile map key** (the
field name under `.instances`) because it is human-readable, stable across toolchain
changes, and sufficient for diamond deduplication.  The `instance_key` is the
binary-artifact identity.

### Store key: instance key hex digest

The store directory layout changes from:

```
artifacts/diamond.libA#target/
```

to:

```
artifacts/<hex-digest>/
```

The store still needs a human-readable index to answer "what is the instance key for
`diamond.libA#target` with this toolchain?"  This is provided by the lockfile itself:
callers read the lockfile to get the `instance_key` hex, then look up
`artifacts/<hex>/`.

### `zpkg lock` must compute instance keys

`zpkg lock` currently computes `source_hash` for each package.  It must also compute
`instance_key` for each resolved instance.  This requires:

1. A `ToolchainFingerprint` from the active toolchain (already modeled in
   `src/model/toolchain.zig`; the fingerprint must be detected at `zpkg lock` time or
   at `zpkg build` time — see tradeoff below).
2. The sorted ABI option values for each instance.
3. The sorted list of resolved dependency instance keys (bottom-up, since leaves have
   no deps).

### Toolchain detection timing

Two valid designs:

**Option A: `zpkg lock` embeds the toolchain fingerprint**
- Instance keys are computed once at lock time.
- Lockfile is fully authoritative: same lockfile always produces the same store keys.
- Tradeoff: the lockfile is tied to one toolchain.  Different toolchains require
  separate lockfiles or a lockfile with multiple platform entries.

**Option B: `zpkg build` computes instance keys at build time**
- `zpkg lock` records source hashes and dep graph; instance keys are recomputed each
  run using the current toolchain.
- Lockfile is platform-agnostic; the same lockfile works across toolchains.
- Tradeoff: two developers with different toolchains always get different instance keys
  even if the source is identical (which is correct behavior but may surprise users).

**Recommended:** Option B for the MVP.  It matches how Nix/Bazel work (the build key
depends on the build environment), avoids locking the lockfile to a single toolchain,
and requires no lockfile format changes beyond the `instance_key` field which simply
becomes a field computed at build time (and not stored in the lockfile for Option B —
the lockfile stores only `source_hash` and dep graph; the instance key is derived
transiently during `zpkg build`).

Under Option B the lockfile schema does **not** need an `instance_key` field.  The
store uses the instance key as the directory name, but the key is computed on-the-fly
during `zpkg build` rather than locked in.

---

## Required changes

### 1. Detect toolchain fingerprint at `zpkg build` time

Add a function in `src/hash/toolchain_fingerprint.zig` (or a new
`src/hash/detect.zig`) that probes the active toolchain:

- Run `zig version` and parse the output.
- Detect host triple from `zig env`.
- Detect C/C++ compiler identity via `--version` flag.
- Detect sysroot and libc if configured.

This is a new system-interaction step; it requires `std.process.run` calls and may be
slow.  Cache the result for the duration of a single `zpkg build` invocation.

### 2. Compute instance keys bottom-up in `BuildExecutor` / `planBuild`

After detecting the toolchain fingerprint, compute instance keys in topological order
(leaves first):

```
instance_key("diamond.libA") = hash(pkg_id, version, domain, source_hash,
                                    abi_options, toolchain_fp, dep_keys=[])
instance_key("diamond.libC") = hash(..., dep_keys=[instance_key("diamond.libA")])
...
```

Store the computed keys in a local map for use throughout the build session.

### 3. Change store lookups and writes to use the computed instance key

Replace all `key_text` = `<pkg_id>#<domain>` derivations in:

- `realize/build_fallback.zig` (`planBuild`, `dfsVisit`, `buildInstance`)
- `store/store.zig` (`hasArtifact`, `storeArtifact`, `expandArtifact`, `diagnose`)
- `realize/workspace.zig` (workspace paths)
- `realize/binary_adapter.zig` (store path references)

The human-readable `<pkg_id>#<domain>` is kept as a display/log label only.

### 4. Update the `zpkg build` log output

Display both the human-readable label and the instance key prefix in build output:

```
[miss] diamond.libA#target  (key: 3f8a2c...)  -- building from source
[hit]  diamond.libA#target  (key: 3f8a2c...)
```

### 5. Update `zpkg inspect` to show computed instance keys

`zpkg inspect` should report the instance key that would be used for the current
toolchain so developers can understand why two machines get different keys.

---

## Files to change

| File | Change |
|---|---|
| `hash/toolchain_fingerprint.zig` | Add `detect(allocator, io) !ToolchainFingerprint` |
| `hash/instance_key.zig` | No logic changes; already correct |
| `realize/build_fallback.zig` | Compute instance keys via `instance_key.deriveHex`; use hex as store key |
| `store/store.zig` | Accept content-hash key; update path derivation |
| `store/layout.zig` | Update path functions to accept opaque key string |
| `cli/build.zig` | Detect toolchain, pass fingerprint into plan/executor |
| `cli/inspect.zig` | Show computed instance key for current toolchain |
| `schema/lockfile.zig` | (Optional) add `instance_key` field under Option A |
| `model/lockfile.zig` | (Optional) model the field |
| `examples/diamond/app/zpkg.lock.zon` | Regenerate after schema changes |

---

## Validation

After this phase:

- Two builds with the same toolchain and source produce identical store directories.
- Rebuilding after changing only optimize mode places artifacts in a different store
  entry (different instance key).
- Rebuilding with a different C++ compiler version produces a different instance key
  and triggers a source build.
- The store directory names are hex digests (no human-readable package names).
- `zpkg build` log shows the key alongside the human-readable label.
- `zig build test` passes with no regressions.

---

## Exit criteria

- `instance_key.deriveHex` is called for every build instance in `zpkg build`.
- Store directory names are content-hash keys, not human-readable strings.
- Changing an ABI-relevant option or the toolchain version changes the store key and
  triggers a rebuild.
- Changing a non-ABI option does not change the store key.
- Two machines with the same toolchain and lockfile produce identical store keys.
